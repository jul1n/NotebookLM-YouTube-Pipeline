"""Offline review of every doubtful transcript, including historic text exports."""
import argparse
from collections import Counter,defaultdict
import gzip
import hashlib
import json
from pathlib import Path
import re
import sys
import unicodedata

import caption_deep_encoding as deep
import caption_encoding_repair as encoding
import caption_maintenance as maintenance
import caption_quality as quality
import caption_source_repair as source
import pipeline_core as core
from resolve_legacy_sources import key as title_key

WEAK=re.compile(r'Ã[^\x00-\x7f]|Â[^\x00-\x7f]')
TIMING=re.compile(r'\d{1,2}:\d{2}(?::\d{2})?[.,]\d{3}\s*-->')
PROTECTED={'not','no','never','without','neither','ne','pas','non','sans','jamais'}


def words(text):
    value=unicodedata.normalize('NFKC',text).replace('’',"'").casefold()
    out=[]
    for word in re.findall(r"\d+(?:[.,]\d+)*|[\w'-]+",value):
        if not out or word!=out[-1]:out.append(word)
    return out


def protected_content(text):
    value=unicodedata.normalize('NFKC',text).replace('’',"'").casefold()
    tokens=re.findall(r"\d+(?:[.,]\d+)*|[\w'-]+",value)
    return [w for w in tokens if any(c.isdigit() for c in w) or w in PROTECTED or w.endswith("n't")]


def restoration_proof(before,after,before_q,after_q,agreement):
    ratio=len(after.split())/max(1,len(before.split()))
    accepted=(agreement['accepted'] and agreement['old_coverage']>=.999 and 1<ratio<=1.10
              and not after_q['technical_markers'] and not after_q['review_signals']['encoding_artifacts']
              and after_q['review_signals']['long_repetition_alerts']<=before_q['review_signals']['long_repetition_alerts']
              and after_q['review_signals']['repeated_word_fraction']<=before_q['review_signals']['repeated_word_fraction']+.02
              and protected_content(before)==protected_content(after))
    return dict(accepted=accepted,word_ratio=ratio,numbers_and_negations_preserved=protected_content(before)==protected_content(after),
                basis='full_timed_source_restores_lost_content_without_new_long_repetitions')


class Review:
    def __init__(self,runtime,target,baseline,inventory,old_index):
        self.runtime=runtime;self.target=target;target.mkdir(parents=True,exist_ok=True);(target/'candidates').mkdir(exist_ok=True)
        self.audit=json.loads(baseline.read_text(encoding='utf8'));self.flags={x['youtube_id']:x['quality'] for x in self.audit['flagged']}
        self.inventory=inventory;self.old_index=old_index;self.records={};self.entries={};self.observations=[]
        self.read_bytes=0;self.read_limit=4_000_000_000;self.index=defaultdict(list);self.aliases=[]
        self.budget_path=runtime.work/('full-review-'+hashlib.sha256(str(target).encode()).hexdigest()[:12]+'.json')
        runtime.work.mkdir(parents=True,exist_ok=True)
        if self.budget_path.exists():self.read_bytes=json.loads(self.budget_path.read_text())['source_bytes_read']

    def read(self,path):
        size=path.stat().st_size
        if size>128_000_000 or self.read_bytes+size>self.read_limit:raise ValueError('source_read_budget')
        self.read_bytes+=size
        core.atomic_json(self.budget_path,dict(source_bytes_read=self.read_bytes))
        data=path.read_bytes()
        if path.suffix=='.gz':data=gzip.decompress(data)
        if len(data)>128_000_000:raise ValueError('decoded_source_too_large')
        return data

    def save(self,item,candidate):
        ident=item['youtube_id'];dest=self.target/'candidates'
        (dest/(ident+'.txt.gz')).write_bytes(gzip.compress(candidate.encode('utf8'),mtime=0))
        core.atomic_json(dest/(ident+'.json'),item);self.entries[ident]=item

    def attach(self,item,raw,path,language,timed,container_sha=None):
        sha=hashlib.sha256(raw).hexdigest();ident=item['youtube_id']
        language=language if re.fullmatch(r'[A-Za-z0-9_-]{1,20}',language or '') else 'und'
        extension='vtt' if raw.lstrip().startswith(b'WEBVTT') else 'srt' if timed else 'txt'
        folder=self.runtime.archive if timed else self.runtime.root/'WORKING_ZONE/_TEXT_SOURCES_GZ'
        folder.mkdir(parents=True,exist_ok=True);archive=folder/f'{ident}.{sha}.{language}.{extension}.gz'
        if not archive.exists():archive.write_bytes(gzip.compress(raw,mtime=0))
        if hashlib.sha256(gzip.decompress(archive.read_bytes())).hexdigest()!=sha:raise RuntimeError('Source checksum mismatch')
        item['timed_source' if timed else 'local_text_source']=dict(raw_path=str(archive),sha256=sha,language=language)
        item['evidence'].update(source_path=str(path),container_sha256=container_sha,source_format=extension)

    def consider(self,row,old,candidate,raw,path,language,timing=None,container_sha=None):
        ident=row['youtube_id'];q=self.quality(ident,old)
        if ' '.join(old.split())==' '.join(candidate.split()):return 'matches_timed_source' if timing and timing['cues'] and not source.CORRUPTION.search(old) else 'same_local_text'
        if words(old)==words(candidate) and not source.CORRUPTION.search(old):return 'same_words_formatting_only'
        agreement=source.concordance(old,candidate)
        if not agreement['accepted']:return 'source_wording_mismatch'
        evidence=dict(agreement=agreement)
        if timing:evidence['timing']={k:v for k,v in timing.items() if k!='removed'}
        item=source.entry(row,old,candidate,q,'verified_local_timed_source' if timing and timing['cues'] else 'verified_local_text_source',evidence)
        if not item and timing and timing['cues']:
            after_q=quality.inspect_text(candidate);proof=restoration_proof(old,candidate,q,after_q,agreement)
            if proof['accepted']:
                item=dict(youtube_id=ident,title=row['title'],channel=row['channel'],category='verified_source_restoration',
                          before_sha=maintenance.digest(old),after_sha=maintenance.digest(candidate),apply=True,metadata={},
                          before_quality=q,after_quality=after_q,evidence=dict(evidence,restoration=proof),source_review_notes=[],opening_before=old[:900],opening_after=candidate[:900])
        if not item:return 'no_demonstrated_quality_gain'
        old_item=self.entries.get(ident)
        if old_item and (old_item['after_quality']['review_signals']['encoding_artifacts'],old_item['after_quality']['suspected_repetitions'])<=(item['after_quality']['review_signals']['encoding_artifacts'],item['after_quality']['suspected_repetitions']):return 'existing_better_candidate'
        self.attach(item,raw,path,language,bool(timing and timing['cues']),container_sha)
        self.save(item,candidate)
        if q['review_signals']['encoding_artifacts'] and not source.CORRUPTION.search(candidate):
            self.observations.append((ident,encoding.pair_artifacts(old,candidate,predicate=deep.allowed_artifact)))
        return 'repair_prepared'

    def quality(self,ident,text):
        if ident in self.flags and self.audit['transcript_hashes'].get(ident)==maintenance.digest(text):return self.flags[ident]
        q=quality.inspect_text(text);self.flags[ident]=q;return q

    def build_index(self,db):
        titles=defaultdict(list);known=set()
        for row in db.execute('SELECT youtube_id,title FROM videos'):
            known.add(row['youtube_id']);titles[title_key(row['title'])[1]].append(row['youtube_id'])
        seen=set()
        for value in json.loads(self.old_index.read_text(encoding='utf8')):
            for name in value['paths']:
                if name not in seen:self.index[value['youtube_id']].append((name,value['language']));seen.add(name)
        for line in self.inventory.read_text(encoding='utf8').splitlines():
            item=json.loads(line);path=Path(item['path']);name=path.name
            eligible=(item['category'] in {'caption_source','canonical_timed_source_protected','canonical_text_source_protected','generated_transcript','other_text'}
                      and name.lower().endswith(('.txt','.vtt','.srt','.txt.gz','.vtt.gz','.srt.gz')))
            if not eligible or str(path) in seen:continue
            ident=core.video_id(name);method='filename_video_id'
            if ident not in known:
                candidates=titles[title_key(name)[1]] if name.lower().endswith(('.vtt','.srt','.vtt.gz','.srt.gz')) else []
                if len(candidates)!=1:continue
                ident=candidates[0];method='unique_title_requires_content_confirmation'
            match=re.search(r'\.([a-z]{2}(?:-[A-Za-z0-9]+)?)\.(?:vtt|srt|txt)(?:\.gz)?$',name)
            lang=match[1] if match else 'und';self.index[ident].append((str(path),lang));seen.add(str(path))
            if method!='filename_video_id':self.aliases.append(dict(youtube_id=ident,path=str(path),method=method))
        for path in self.runtime.archive.glob('*.gz'):
            ident=core.video_id(path.name)
            if ident in known and str(path) not in seen:
                match=re.search(r'\.([a-z]{2}(?:-[A-Za-z0-9]+)?)\.(?:vtt|srt)\.gz$',path.name)
                self.index[ident].append((str(path),match[1] if match else 'und'));seen.add(str(path))
        core.atomic_json(self.target/'SOURCE_ALIASES.json',self.aliases)

    def json_sources(self,db,ids):
        for path in sorted((self.runtime.root/'assets/transcripts').glob('*.json')):
            try:
                data=self.read(path);container_sha=hashlib.sha256(data).hexdigest();values=json.loads(data.decode('utf-8-sig'))
            except (OSError,ValueError,UnicodeError):continue
            if isinstance(values,dict):values=values.get('videos',values.get('data',[]))
            if not isinstance(values,list):continue
            for value in values:
                if not isinstance(value,dict):continue
                ident=value.get('youtube_id');candidate=value.get('transcript')
                if ident not in ids or not isinstance(candidate,str) or not candidate.strip():continue
                row=db.execute('SELECT v.youtube_id,v.title,v.transcript,c.prefix AS channel,c.lang_config FROM videos v JOIN channels c ON c.id=v.channel_id WHERE youtube_id=?',(ident,)).fetchone()
                cleaned=core.strip_caption_markup(candidate);cleaned=' '.join(cleaned.split())
                result=self.consider(row,row['transcript'],cleaned,candidate.encode('utf8'),path,row['lang_config'] or 'und',container_sha=container_sha)
                self.records.setdefault(ident,dict(json_sources=[]))['json_sources'].append(dict(path=str(path),result=result))
            print(json.dumps(dict(json_source=path.name,repairs=len(self.entries),source_bytes_read=self.read_bytes)),flush=True)

    def learn_encoding(self,db,ids):
        learned=encoding.supported_mapping(self.observations)
        previous=self.runtime.database_dir/'pilot_reports/source-repair-max-20261031/ENCODING_DICTIONARY.json'
        inherited=json.loads(previous.read_text(encoding='utf8'))['templates'] if previous.exists() else []
        merged={};conflicts=set()
        for item in inherited+learned:
            old=item['before']
            if old in merged and merged[old]['after']!=item['after']:conflicts.add(old)
            else:merged[old]=item
        mapping=[value for key,value in merged.items() if key not in conflicts]
        dictionary=dict(version=deep.VERSION,templates=mapping,conflicts=sorted(conflicts),new_training_videos=len(self.observations),
                        inherited_dictionary_sha256=hashlib.sha256(previous.read_bytes()).hexdigest() if previous.exists() else None)
        core.atomic_json(self.target/'ENCODING_DICTIONARY.json',dictionary)
        for ident in ids:
            if ident in self.entries:continue
            row=db.execute('SELECT v.youtube_id,v.title,v.transcript,c.prefix AS channel FROM videos v JOIN channels c ON c.id=v.channel_id WHERE youtube_id=?',(ident,)).fetchone()
            old=row['transcript']
            if not source.CORRUPTION.search(old) and not WEAK.search(old):continue
            candidate,proof=deep.restore(old,mapping)
            if not proof['accepted']:continue
            item=source.entry(row,old,candidate,self.quality(ident,old),'demonstrated_deep_encoding_restoration',proof)
            if item:item['evidence']['dictionary_path']=str(self.target/'ENCODING_DICTIONARY.json');self.save(item,candidate)
        print(json.dumps(dict(encoding_templates=len(mapping),new_training=len(self.observations),repairs=len(self.entries))),flush=True)

    def run(self):
        with core.acquisition_lock(self.runtime),core.closing_database(core.connect(self.runtime.db,True)) as db:
            self.build_index(db);ids=set(self.flags)
            for row in db.execute("SELECT youtube_id,transcript FROM videos WHERE trim(COALESCE(transcript,''))!=''"):
                if source.CORRUPTION.search(row['transcript']) or WEAK.search(row['transcript']):ids.add(row['youtube_id'])
            self.json_sources(db,ids);self.learn_encoding(db,ids)
            ordered=sorted(ids,key=lambda ident:(ident not in self.entries,ident))
            for n,ident in enumerate(ordered,1):
                row=db.execute('SELECT v.youtube_id,v.title,v.transcript,c.prefix AS channel,c.lang_config FROM videos v JOIN channels c ON c.id=v.channel_id WHERE youtube_id=?',(ident,)).fetchone()
                old=row['transcript'];q=self.quality(ident,old);tried=[];result='unresolved_no_matching_local_source'
                if ident in self.entries:result='repair_prepared'
                else:
                    if q['suspected_repetitions']>=20:
                        candidate,evidence=source.complete_triplicates(old)
                        item=source.entry(row,old,candidate,q,'short_systemic_triplicates',evidence) if evidence['accepted'] else None
                        if item:self.save(item,candidate);result='repair_prepared'
                    if ident not in self.entries:
                        choices=sorted(self.index.get(ident,[]),key=lambda x:(not x[0].endswith(('.vtt','.srt','.vtt.gz','.srt.gz')),x[0]))
                        for name,language in choices:
                            path=Path(name)
                            try:
                                if path.stat().st_size>8_000_000:tried.append(dict(path=name,result='source_too_large'));continue
                                raw=self.read(path);text=raw.decode('utf-8-sig')
                                if TIMING.search(text):candidate,timing=core.clean_captions_detailed(text)
                                else:candidate=' '.join(core.strip_caption_markup(text).split());timing=None
                                if timing and timing['timestamp_regressions']:reason='timestamp_regressions'
                                else:reason=self.consider(row,old,candidate,raw,path,language,timing)
                            except (OSError,ValueError,EOFError,UnicodeError) as error:reason=type(error).__name__+':'+str(error)[:100]
                            tried.append(dict(path=name,result=reason))
                            if reason in {'repair_prepared','matches_timed_source'}:result=reason;break
                            if reason in {'same_local_text','same_words_formatting_only'}:result=reason
                    if ident not in self.entries and q['suspected_repetitions'] and q['suspected_repetitions']<=q['review_signals']['short_filler_alerts']+q['review_signals']['nonverbal_only_alerts'] and not source.CORRUPTION.search(old):result='reviewed_oral_fillers_or_annotations'
                record=dict(youtube_id=ident,channel=row['channel'],title=row['title'],text_sha256=maintenance.digest(old),quality=q,result=result,sources_tried=tried,
                            json_sources=self.records.get(ident,{}).get('json_sources',[]))
                self.records[ident]=record;core.atomic_json(self.target/'candidates'/(ident+'.review.json'),record)
                if n%100==0:
                    self.runtime.check_space(128*1024**2)
                    core.atomic_json(self.target/'PROGRESS.json',dict(examined=n,total=len(ordered),repairs=len(self.entries),source_bytes_read=self.read_bytes))
                    print(json.dumps(dict(examined=n,total=len(ordered),repairs=len(self.entries),source_bytes_read=self.read_bytes)),flush=True)
        plan=dict(version=maintenance.VERSION,created_at=core.now(),database=str(self.runtime.db),source_cleaner=core.CAPTION_VERSION,
                  entries=list(self.entries.values()),changes=len(self.entries),counts=dict(Counter(x['category'] for x in self.entries.values())),
                  notes=[dict(youtube_id=x['youtube_id'],reason=x['result'],text_sha=x['text_sha256']) for x in self.records.values()],
                  texts_scanned=len(self.records),source_bytes_read=self.read_bytes,network_calls=0,all_doubts_included=True)
        core.atomic_json(self.target/'PLAN.json',plan);core.atomic_json(self.target/'ALL_REVIEWS.json',dict(records=list(self.records.values()),counts=dict(Counter(x['result'] for x in self.records.values()))))
        maintenance.report(self.target,plan)
        print(json.dumps(dict(prepared_changes=len(self.entries),examined=len(self.records),categories=plan['counts'],source_bytes_read=self.read_bytes)),flush=True)


if __name__=='__main__':
    sys.stdout.reconfigure(encoding='utf8',errors='replace');p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,default=Path(__file__).resolve().parent.parent);p.add_argument('--plan',type=Path,required=True)
    p.add_argument('--baseline',type=Path,required=True);p.add_argument('--inventory',type=Path,required=True);p.add_argument('--index',type=Path,required=True)
    a=p.parse_args();runtime=core.Runtime(a.root);target=a.plan.resolve()
    if not target.is_relative_to((runtime.database_dir/'pilot_reports').resolve()):raise ValueError('Private plan required')
    Review(runtime,target,a.baseline,a.inventory,a.index).run()
