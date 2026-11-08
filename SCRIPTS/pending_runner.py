"""Manual, resumable caption acquisition for an immutable pending-video queue."""
import argparse
from collections import Counter
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import time

import pipeline_core as core
from dashboard_export import export_dashboard
from night_runner import integrity


class BatchStopped(Exception):
    pass


def prepare(runtime, folder):
    folder=Path(folder).resolve()
    if (folder/'STATE.json').exists():
        return json.loads((folder/'STATE.json').read_text(encoding='utf-8'))
    with core.closing_database(core.connect(runtime.db,True)) as db:
        rows=[dict(row) for row in db.execute("""SELECT v.youtube_id,v.title,c.prefix,v.upload_date
            FROM videos v JOIN channels c ON c.id=v.channel_id
            WHERE v.status='PENDING' AND trim(COALESCE(v.transcript,''))=''
            ORDER BY CASE WHEN c.prefix='ScienceEtonnante' THEN 0 ELSE 1 END,v.upload_date DESC,v.id""")]
    if any(not core.VIDEO_ID.fullmatch(row['youtube_id']) for row in rows):
        raise ValueError('Invalid ID in pending queue')
    folder.mkdir(parents=True,exist_ok=True)
    core.atomic_json(folder/'QUEUE.json',rows)
    state=dict(status='prepared',created_at=core.now(),total=len(rows),chains=dict(Counter(r['prefix'] for r in rows)),
               cursor=0,results={},stages={},network=dict(calls=0,metadata=0,subtitles=0,last_call=0))
    core.atomic_json(folder/'STATE.json',state)
    return state


class PendingBatch:
    def __init__(self,runtime,folder):
        self.runtime=runtime;self.folder=Path(folder).resolve()
        self.state=prepare(runtime,self.folder)
        self.queue=json.loads((self.folder/'QUEUE.json').read_text(encoding='utf-8'))
        if len(self.queue)!=self.state['total']:raise ValueError('Queue changed')

    def save(self):
        self.state['updated_at']=core.now()
        core.atomic_json(self.folder/'STATE.json',self.state)
        self.report()

    def report(self):
        counts=Counter(x['outcome'] for x in self.state['results'].values())
        text='# Récupération des vidéos en attente\n\n'
        text+=f"État : **{self.state['status']}**. Dernière mise à jour UTC : {self.state.get('updated_at',self.state['created_at'])}.\n\n"
        text+=f"Liste initiale fixe : {self.state['total']} vidéos. Terminées : {self.state['cursor']}. Appels yt-dlp : {self.state['network']['calls']}.\n\n"
        if self.state.get('current'):text+=f"Vidéo en cours : https://www.youtube.com/watch?v={self.state['current']}\n\n"
        if self.state.get('untried_only'):text+='Priorité aux vidéos sans tentative, plus récentes en premier. Échecs isolés différés ; trois échecs consécutifs arrêtent le passage.\n\n'
        text+='| Résultat | Nombre |\n|---|---:|\n'
        for outcome,n in counts.items():text+=f'| {outcome} | {n} |\n'
        if self.state.get('blocked_reason'):text+=f"\nBlocage : {self.state['blocked_reason']}\n"
        if self.state.get('error'):text+=f"\nErreur locale : {self.state['error']}\n"
        text+='\nSous-titres uniquement. Sources locales prioritaires. Au moins une minute entre démarrages yt-dlp. HTTP 429 : pause de 62 minutes et reprise, au maximum trois blocages consécutifs avant arrêt. Autres erreurs : arrêt. Aucun audio ni suppression. Sauvegarde tous les 50 éléments et à la fin.\n'
        (self.folder/'REPORT.md').write_text(text,encoding='utf-8')

    def stage(self,name,action):
        if self.state['stages'].get(name,{}).get('status')=='done':return
        self.state['current_stage']=name;self.save()
        result=action()
        self.state['stages'][name]=dict(status='done',result=result,completed_at=core.now());self.save()

    def network_call(self,original,runtime,db,args,ident=None):
        core.pause_guard(db)
        kind='subtitles' if '--load-info-json' in args else 'metadata' if '--dump-single-json' in args else None
        if not kind:raise BatchStopped('Unplanned network operation')
        net=self.state['network']
        remaining=60-(time.time()-net['last_call'])
        while remaining>0:
            runtime.check_space();time.sleep(min(5,remaining))
            remaining=60-(time.time()-net['last_call'])
        # Persist before launching so a crash cannot silently replay the request.
        net['calls']+=1;net[kind]+=1;net['last_call']=time.time()
        self.state['request_in_flight']=dict(youtube_id=ident,kind=kind,started_at=core.now());self.save()
        try:
            result=original(runtime,db,['--retries','0','--fragment-retries','0','--extractor-retries','0',*args],ident)
        except (OSError,ValueError,RuntimeError) as error:
            paused=db.execute("SELECT value FROM pipeline_control WHERE key='youtube_pause_until'").fetchone()
            if ident and (not paused or paused[0]<=core.now()):core.record_failure(db,ident,'ERR_DL_FAIL',24)
            self.state['blocked_reason']=str(error);self.save()
            raise BatchStopped(str(error)) from error
        self.state.pop('request_in_flight',None);self.save()
        return result

    def wait_for_rate_limit(self):
        self.state['status']='paused';self.state['current_stage']='rate_limit_pause';self.save()
        while True:
            with core.closing_database(core.connect(self.runtime.db,True)) as db:
                row=db.execute("SELECT value FROM pipeline_control WHERE key='youtube_pause_until'").fetchone()
            if not row or row[0]<=core.now():break
            self.state['pause_until_utc']=row[0];self.save()
            due=datetime.strptime(row[0],'%Y-%m-%d %H:%M:%S').replace(tzinfo=timezone.utc).timestamp()
            self.runtime.check_space();time.sleep(min(30,max(1,due-time.time())))
        self.state['status']='running';self.state.pop('pause_until_utc',None);self.save()

    def resume_blocked(self):
        if self.state['status']!='blocked':raise ValueError('Only a known HTTP 429 stop can be resumed')
        index=self.state['cursor']-1
        if index<0:raise ValueError('No interrupted video recorded')
        ident=self.queue[index]['youtube_id']
        with core.closing_database(core.connect(self.runtime.db,True)) as db:
            row=db.execute('SELECT status FROM videos WHERE youtube_id=?',(ident,)).fetchone()
        if not row or row[0]!='ERR_429_BLOCK' or self.state['results'].get(ident,{}).get('outcome')!='network_blocked':
            raise ValueError('Interrupted request requires manual diagnosis')
        self.state.setdefault('resume_history',[]).append(dict(resumed_at=core.now(),cursor=self.state['cursor'],reason=self.state.get('blocked_reason'),previous_result=self.state['results'].get(ident)))
        self.state['cursor']=index
        self.state.pop('request_in_flight',None);self.state.pop('blocked_reason',None)
        self.state.pop('completed_at',None);self.state['status']='prepared'
        # Previous exports and backups remain recorded, but final stages must run again.
        for name in ['integrity_final','packs','dashboard','followup','backup_final']:
            if name in self.state['stages']:
                self.state.setdefault('previous_final_stages',[]).append({name:self.state['stages'].pop(name)})
        self.save()

    def continue_untried(self):
        if self.state['status']!='blocked':raise ValueError('Only a stopped job can continue')
        # Keep the processed prefix and every attempt counter; reorder only its untouched tail.
        original=json.loads((self.folder/'QUEUE.json').read_text(encoding='utf-8'))
        core.atomic_json(self.folder/('QUEUE.before-untried-'+str(time.time_ns())+'.json'),original)
        cursor=self.state['cursor']
        self.queue=self.queue[:cursor]+sorted(self.queue[cursor:],key=lambda row:(row.get('upload_date') or '',row['youtube_id']),reverse=True)
        core.atomic_json(self.folder/'QUEUE.json',self.queue)
        self.state.setdefault('resume_history',[]).append(dict(resumed_at=core.now(),cursor=cursor,mode='untried_first',reason=self.state.get('blocked_reason')))
        self.state.update(status='prepared',untried_only=True,consecutive_failures=0)
        self.state.pop('request_in_flight',None);self.state.pop('blocked_reason',None);self.state.pop('completed_at',None)
        for name in ['integrity_final','packs','dashboard','followup','backup_final']:
            if name in self.state['stages']:
                self.state.setdefault('previous_final_stages',[]).append({name:self.state['stages'].pop(name)})
        self.save()

    def outcome(self,ident):
        with core.closing_database(core.connect(self.runtime.db,True)) as db:
            row=db.execute("SELECT status,length(trim(COALESCE(transcript,''))) n FROM videos WHERE youtube_id=?",(ident,)).fetchone()
        if row is None:return 'missing_record'
        return 'transcript_acquired' if row['n'] else row['status'] or 'unchanged'

    def run(self,resume=False,untried=False):
        if untried:
            with core.acquisition_lock(self.runtime):self.continue_untried()
        if resume:
            with core.acquisition_lock(self.runtime):self.resume_blocked()
        if self.state['status'] in {'done','blocked','error'}:
            print('Existing terminal state; no automatic retry.',flush=True);return
        original=core.run_yt
        with core.acquisition_lock(self.runtime):
            if self.state.get('request_in_flight'):
                self.state.update(status='blocked',blocked_reason='Interrupted request requires review before any retry');self.save();return
            self.state.update(status='running',pid=os.getpid());self.save()
            try:
                self.stage('integrity_before',lambda:integrity(self.runtime))
                self.stage('backup_before',lambda:core.backup(self.runtime))
                if self.state.get('resume_history'):
                    self.stage('integrity_resume_'+str(len(self.state['resume_history'])),lambda:integrity(self.runtime))
                self.wait_for_rate_limit()
                self.state['current_stage']='local_inventory';self.save()
                captions=core.caption_inventory(self.runtime)
                self.state['local_caption_candidates']=sum(len(v) for v in captions.values());self.save()
                core.run_yt=lambda rt,db,args,ident=None:self.network_call(original,rt,db,args,ident)
                self.runtime.network_timeout_seconds=180
                blocked=False
                for index in range(self.state['cursor'],len(self.queue)):
                    row=self.queue[index];ident=row['youtube_id'];self.state['current']=ident
                    self.state['current_stage']='captions';self.save()
                    with core.closing_database(core.connect(self.runtime.db,True)) as db:
                        current=db.execute("SELECT status,trim(COALESCE(transcript,'')) t FROM videos WHERE youtube_id=?",(ident,)).fetchone()
                        attempt=db.execute('SELECT next_attempt_at FROM pipeline_attempts WHERE youtube_id=?',(ident,)).fetchone()
                    if current is None:outcome='missing_record'
                    elif current['t']:outcome='already_has_text'
                    elif self.state.get('untried_only') and attempt:outcome='previously_attempted_skipped'
                    elif current['status'] not in {'PENDING','ERR_429_BLOCK'}:outcome='status_changed_skipped'
                    elif attempt and attempt[0]>core.now():outcome='deferred_skipped'
                    else:
                        while True:
                            try:
                                core.sync(self.runtime,limit=1,youtube_ids=[ident],captions=captions)
                                outcome=self.outcome(ident)
                                self.state['consecutive_rate_limits']=0
                                self.state['consecutive_failures']=0
                                break
                            except BatchStopped:
                                current_outcome=self.outcome(ident)
                                if self.state.get('untried_only'):
                                    reason=self.state.get('blocked_reason','Network failure')
                                    self.state.setdefault('deferred_errors',[]).append(dict(youtube_id=ident,reason=reason,at=core.now()))
                                    self.state['consecutive_failures']=self.state.get('consecutive_failures',0)+1
                                    if self.state['consecutive_failures']>=3:
                                        outcome='network_blocked';blocked=True
                                        break
                                    if current_outcome=='ERR_429_BLOCK':
                                        self.state['cooldowns']=self.state.get('cooldowns',0)+1
                                        self.wait_for_rate_limit()
                                    outcome='rate_limited_deferred' if current_outcome=='ERR_429_BLOCK' else 'download_failed_deferred'
                                    self.state.pop('request_in_flight',None);self.state.pop('blocked_reason',None);self.save()
                                    break
                                if current_outcome=='ERR_429_BLOCK' and self.state.get('consecutive_rate_limits',0)<2:
                                    self.state['cooldowns']=self.state.get('cooldowns',0)+1
                                    self.state['consecutive_rate_limits']=self.state.get('consecutive_rate_limits',0)+1
                                    self.state.setdefault('rate_limit_events',[]).append(dict(youtube_id=ident,at=core.now()))
                                    self.wait_for_rate_limit()
                                    self.state.pop('request_in_flight',None);self.state.pop('blocked_reason',None);self.save()
                                    continue
                                outcome='network_blocked';blocked=True
                                break
                    self.state['results'][ident]=dict(outcome=outcome,completed_at=core.now())
                    self.state['cursor']=index+1;self.save()
                    print(json.dumps(dict(processed=index+1,total=len(self.queue),id=ident,outcome=outcome),ensure_ascii=False),flush=True)
                    if blocked:break
                    if (index+1)%50==0:self.stage(f'backup_{index+1}',lambda:core.backup(self.runtime))
                core.run_yt=original
                self.state.pop('current',None)
                self.stage('integrity_final',lambda:integrity(self.runtime))
                if any(x['outcome']=='transcript_acquired' for x in self.state['results'].values()):
                    self.stage('packs',lambda:core.packs(self.runtime))
                self.stage('dashboard',lambda:export_dashboard(self.runtime))
                self.stage('followup',lambda:core.list_caption_followup(self.runtime))
                self.stage('backup_final',lambda:core.backup(self.runtime))
                self.state.update(status='blocked' if blocked else 'done',completed_at=core.now(),local_bytes=self.runtime.usage())
                self.save()
            except BaseException as error:
                self.state.update(status='error',error=str(error));self.save();raise
            finally:core.run_yt=original


def main():
    if hasattr(sys.stdout,'reconfigure'):sys.stdout.reconfigure(encoding='utf-8',errors='replace')
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--job',type=Path,required=True)
    parser.add_argument('--prepare',action='store_true')
    mode=parser.add_mutually_exclusive_group()
    mode.add_argument('--resume',action='store_true')
    mode.add_argument('--continue-untried',action='store_true')
    args=parser.parse_args();runtime=core.Runtime(args.root)
    folder=args.job.resolve()
    if not folder.is_relative_to((runtime.database_dir/'pending_runs').resolve()):raise ValueError('Job must be under DATABASE/pending_runs')
    batch=PendingBatch(runtime,folder)
    if args.prepare:batch.save();print(json.dumps(batch.state,ensure_ascii=False))
    else:batch.run(resume=args.resume,untried=args.continue_untried)


if __name__=='__main__':main()
