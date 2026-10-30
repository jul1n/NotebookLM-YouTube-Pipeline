"""Resumable, one-night maintenance. No media deletion or audio transcription."""
import argparse
from datetime import datetime, timezone
import gzip
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time

import caption_quality as quality
import caption_reconstruction as reconstruction
import pipeline_core as core


class NetworkStop(Exception):
    pass


def sha(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def apply_repairs(runtime,job,progress=lambda value:None):
    archive=runtime.root/'WORKING_ZONE'/'_LEGACY_RENDERED_GZ'
    archive.mkdir(parents=True,exist_ok=True)
    scanned=0;skipped=[]
    with core.closing_database(core.connect(runtime.db)) as db:
        core.init_state(db)
        db.execute('''CREATE TABLE IF NOT EXISTS pipeline_revisions (
        id INTEGER PRIMARY KEY,job_id TEXT,youtube_id TEXT,before_sha TEXT,after_sha TEXT,
        original_gzip TEXT,old_metadata TEXT,proof TEXT,changed_at TEXT,
        UNIQUE(job_id,youtube_id,before_sha))''')
        db.commit()
        # Fetch bounded batches; commit writes separately, never leave a giant
        # read cursor open across modifications of its source table.
        cursor=0
        while True:
            rows=db.execute("SELECT v.id,v.youtube_id,v.transcript,c.lang_config FROM videos v JOIN channels c ON c.id=v.channel_id WHERE v.id>? AND trim(COALESCE(v.transcript,''))!='' ORDER BY v.id LIMIT 100",(cursor,)).fetchall()
            if not rows:break
            for row in rows:
                cursor=row['id'];scanned+=1
                text=row['transcript']
                if not reconstruction.STAMP.search(text) and not quality.MARKERS['inline_timestamp'].search(text):continue
                candidate=reconstruction.reconstruct(text)
                if candidate['mode']!='rendered_triplets':continue
                if candidate['evidence']['timestamp_regressions']:
                    skipped.append(dict(id=row['youtube_id'],reason='timestamp_regression'));continue
                result=candidate['text']
                if not result or result==text:continue
                after=quality.inspect_text(result)
                if after['technical_markers']:
                    skipped.append(dict(id=row['youtube_id'],reason='residual_technical_markers'));continue
                before=quality.inspect_text(text)
                if after['suspected_repetitions']>before['suspected_repetitions']:
                    skipped.append(dict(id=row['youtube_id'],reason='repetition_alert_increase'));continue
                runtime.check_space(128*1024**2)
                ident=row['youtube_id']
                if not core.VIDEO_ID.fullmatch(ident):raise ValueError('Invalid database video ID')
                original_sha=sha(text);result_sha=sha(result)
                raw_path=archive/f'{ident}.{original_sha}.rendered.txt.gz'
                if not raw_path.exists():
                    temporary=raw_path.with_suffix('.gz.tmp')
                    temporary.write_bytes(gzip.compress(text.encode('utf-8'),mtime=0))
                    if gzip.decompress(temporary.read_bytes()).decode('utf-8')!=text:raise RuntimeError('Source archive verification failed')
                    os.replace(temporary,raw_path)
                if hashlib.sha256(gzip.decompress(raw_path.read_bytes())).hexdigest()!=original_sha:
                    raise RuntimeError('Existing source archive hash mismatch')
                old=db.execute('SELECT * FROM pipeline_transcripts WHERE youtube_id=?',(ident,)).fetchone()
                proof={k:v for k,v in candidate.items() if k!='text'}
                proof.update(before_quality=before,after_quality=after)
                with db:
                    changed=db.execute('UPDATE videos SET transcript=? WHERE id=? AND transcript=?',(result,row['id'],text)).rowcount
                    if changed:
                        db.execute('INSERT INTO pipeline_revisions(job_id,youtube_id,before_sha,after_sha,original_gzip,old_metadata,proof,changed_at) VALUES(?,?,?,?,?,?,?,?)',
                                   (job,ident,original_sha,result_sha,str(raw_path),json.dumps(dict(old)) if old else None,json.dumps(proof,ensure_ascii=False),core.now()))
                        db.execute('INSERT OR REPLACE INTO pipeline_transcripts VALUES (?,?,?,?,?,?,?)',
                                   (ident,old['language'] if old and old['language'] else row['lang_config'] or 'und','legacy-rendered-captions',str(raw_path),original_sha,reconstruction.VERSION,core.now()))
                if not changed:skipped.append(dict(id=ident,reason='concurrent_edit'))
            changed_count=db.execute('SELECT count(*) FROM pipeline_revisions WHERE job_id=?',(job,)).fetchone()[0]
            progress(dict(scanned=scanned,changed=changed_count,last_id=cursor))
        changed_count=db.execute('SELECT count(*) FROM pipeline_revisions WHERE job_id=?',(job,)).fetchone()[0]
    return dict(scanned=scanned,changed=changed_count,skipped=skipped)


def integrity(runtime,repair_fts=False):
    runtime.check_space(256*1024**2)
    with core.closing_database(core.connect(runtime.db)) as db:
        checks=[r[0] for r in db.execute('PRAGMA quick_check')]
        if checks!=['ok']:raise RuntimeError('SQLite integrity failure; no network work allowed')
        exists=db.execute("SELECT 1 FROM sqlite_master WHERE name='videos_fts'").fetchone()
        rebuilt=False
        if exists:
            try:
                with db:db.execute("INSERT INTO videos_fts(videos_fts,rank) VALUES('integrity-check',1)")
            except sqlite3.DatabaseError:
                if not repair_fts:raise
                runtime.check_space(2*core.GIB)
                with db:db.execute("INSERT INTO videos_fts(videos_fts) VALUES('rebuild')")
                with db:db.execute("INSERT INTO videos_fts(videos_fts,rank) VALUES('integrity-check',1)")
                rebuilt=True
        counts=db.execute("SELECT count(*),sum(trim(COALESCE(transcript,''))!='') FROM videos").fetchone()
    return dict(sqlite='ok',fts='ok' if exists else 'not_present',fts_rebuilt=rebuilt,videos=counts[0],transcripts=counts[1])


class NightJob:
    def __init__(self,runtime,path):
        self.runtime=runtime;self.path=Path(path).resolve();self.path.mkdir(parents=True,exist_ok=True)
        self.state_path=self.path/'STATE.json'
        self.state=json.loads(self.state_path.read_text(encoding='utf-8')) if self.state_path.exists() else dict(
            job_id=self.path.name,status='prepared',stages={},network=dict(calls=0,metadata=0,subtitles=0,discovery=0,last_call=0),
            channels=['ScienceEtonnante','Fouloscopie','Marc Lou'],deadline='2026-10-31T06:00:00+00:00',created_at=core.now())
        self.save()

    def save(self):
        self.state['updated_at']=core.now();core.atomic_json(self.state_path,self.state)

    def checkpoint(self,stage,progress):
        self.state['current_stage']=stage;self.state['progress']=progress;self.save()
        print(json.dumps(dict(stage=stage,progress=progress),ensure_ascii=False),flush=True)

    def stage(self,name,action):
        if self.state['stages'].get(name,{}).get('status')=='done':return
        self.check_deadline()
        self.checkpoint(name,{})
        result=action()
        self.state['stages'][name]=dict(status='done',result=result,completed_at=core.now())
        self.save()

    def check_deadline(self):
        if datetime.now(timezone.utc)>=datetime.fromisoformat(self.state['deadline']):
            raise RuntimeError('Night deadline reached; do not start further work')

    def network_call(self,original,runtime,db,args,ident=None):
        self.check_deadline();core.pause_guard(db)
        net=self.state['network']
        if '--flat-playlist' in args:kind='discovery';cap=3
        elif '--load-info-json' in args:kind='subtitles';cap=6
        elif '--dump-single-json' in args:kind='metadata';cap=6
        else:raise NetworkStop('Unplanned network operation denied')
        if net['calls']>=15 or net[kind]>=cap:raise NetworkStop('Night request budget exhausted')
        while time.time()-net['last_call']<60:
            self.check_deadline();time.sleep(min(10,60-(time.time()-net['last_call'])))
        net['calls']+=1;net[kind]+=1;net['last_call']=time.time();self.save()
        try:
            return original(runtime,db,['--retries','0','--fragment-retries','0','--extractor-retries','0',*args],ident)
        except (RuntimeError,ValueError,OSError) as error:
            raise NetworkStop(str(error)) from error

    def updates(self):
        if self.state.get('network_blocked'):return dict(blocked=self.state['network_blocked'])
        import urllib.error
        original=core.run_yt
        core.run_yt=lambda rt,db,args,ident=None:self.network_call(original,rt,db,args,ident)
        self.runtime.network_timeout_seconds=120
        outcomes=[]
        try:
            for channel in self.state['channels']:
                key='update:'+channel
                # Mark before acquisition so a crashed process cannot rediscover
                # the same channel repeatedly on every wake-up.
                if key in self.state['stages']:continue
                self.check_deadline()
                self.state['stages'][key]=dict(status='attempted',started_at=core.now());self.save()
                core.discover(self.runtime,channel,playlist_limit=10)
                core.sync(self.runtime,channel,limit=2)
                self.state['stages'][key]=dict(status='done',completed_at=core.now());self.save()
                outcomes.append(channel)
        except (NetworkStop,RuntimeError,ValueError,OSError,urllib.error.HTTPError) as error:
            self.state['network_blocked']=str(error);self.save()
        finally:core.run_yt=original
        return dict(channels_completed=outcomes,budget=self.state['network'],blocked=self.state.get('network_blocked'))

    def quality_audit(self,label):
        report,target=quality.audit_quality(self.runtime,sample_limit=0,progress=lambda n:self.checkpoint(label,dict(scanned=n)))
        return dict(report=str(target/'REPORT.md'),counts=report['status_counts'],texts=report['texts_scanned'])

    def backup(self):
        core.backup(self.runtime)
        return dict(verified_snapshots=len(list((self.runtime.database_dir/'snapshots').glob('*.verified.json'))))

    def dashboard(self):
        for name in ('Audit-DataHealth.ps1','Sync-Dashboard-v15.ps1'):
            result=subprocess.run(['pwsh','-NoProfile','-File',str(self.runtime.root/'SCRIPTS'/name)],capture_output=True,timeout=600)
            if result.returncode:raise RuntimeError(f'Dashboard update failed: {name}')
        return dict(refreshed=True)

    def run(self):
        if self.state['status']=='done':return
        self.state.update(status='running',pid=os.getpid(),started_at=core.now());self.save()
        try:
            with core.acquisition_lock(self.runtime):
                self.stage('backup_before',self.backup)
                self.stage('integrity_before',lambda:integrity(self.runtime,repair_fts=True))
                self.stage('apply',lambda:apply_repairs(self.runtime,self.state['job_id'],lambda p:self.checkpoint('apply',p)))
                self.stage('integrity_after_repair',lambda:integrity(self.runtime))
                self.stage('audit_after_repair',lambda:self.quality_audit('audit_after_repair'))
                self.stage('first_updates',self.updates)
                self.stage('integrity_final',lambda:integrity(self.runtime))
                self.stage('audit_final',lambda:self.quality_audit('audit_final'))
                self.stage('packs',lambda:self.build_packs())
                self.stage('dashboard',self.dashboard)
                self.stage('backup_final',self.backup)
            self.state.update(status='done',completed_at=core.now());self.save()
        except BaseException as error:
            self.state.update(status='error',error=str(error),failed_at=core.now());self.save();raise
        finally:self.report()

    def build_packs(self):
        core.packs(self.runtime)
        return dict(manifest=str(self.runtime.root/'assets/packs/manifest.json'))

    def report(self):
        text='# Programme de la nuit du 31 octobre 2026\n\n'
        text+=f"État : **{self.state['status']}**. Dernière mise à jour UTC : {self.state['updated_at']}.\n\n"
        text+='Aucun audio, aucune suppression de média. Budget local : 10 Go. Arrêt du réseau au premier échec ou HTTP 429 ; aucune nouvelle tentative cette nuit après blocage.\n\n'
        for stage,value in self.state['stages'].items():
            text+=f"## {stage}\n\n```json\n{json.dumps(value,ensure_ascii=False,indent=2)}\n```\n\n"
        if self.state.get('error'):text+=f"Erreur à examiner : {self.state['error']}\n"
        (self.path/'REPORT.md').write_text(text,encoding='utf-8')


def main():
    if hasattr(sys.stdout,'reconfigure'):sys.stdout.reconfigure(encoding='utf-8',errors='replace')
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--job',type=Path,required=True)
    parser.add_argument('--prepare',action='store_true')
    args=parser.parse_args();runtime=core.Runtime(args.root)
    expected=(runtime.database_dir/'night_runs').resolve()
    path=args.job.resolve()
    if not path.is_relative_to(expected):raise ValueError('Job directory must be under DATABASE/night_runs')
    job=NightJob(runtime,path)
    if args.prepare:job.report();print(job.state_path)
    else:job.run()


if __name__=='__main__':main()
