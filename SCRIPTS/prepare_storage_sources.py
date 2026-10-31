"""Archive matching local timed sources before proposing media deletion."""
import argparse
from collections import Counter
import gzip
import hashlib
import json
from pathlib import Path
import re
import sys
import unicodedata

import caption_maintenance as maintenance
import caption_quality as quality
import caption_source_repair as repair
import pipeline_core as core


def canonical_words(text):
    value=unicodedata.normalize('NFKC',core.strip_caption_markup(text))
    value=value.replace('’',"'").replace('‘',"'").replace('“','"').replace('”','"').casefold()
    result=[]
    for word in value.split():
        if not result or word!=result[-1]:result.append(word)
    return result


def prepare(runtime,target,index,inventory,baseline):
    plan=json.loads((target/'PLAN.json').read_text(encoding='utf8'));proposals={x['youtube_id']:x for x in plan['entries']}
    # Recover fully written, checksummed candidates from an interrupted preparation.
    for receipt in (target/'candidates').glob('*.json'):
        item=json.loads(receipt.read_text(encoding='utf8'));ident=item['youtube_id']
        if ident in proposals or not item.get('timed_source'):continue
        candidate=target/'candidates'/(ident+'.txt.gz')
        if not candidate.exists():continue
        if maintenance.digest(gzip.decompress(candidate.read_bytes()).decode('utf8'))!=item['after_sha']:continue
        source=item['timed_source']
        if hashlib.sha256(gzip.decompress(Path(source['raw_path']).read_bytes())).hexdigest()!=source['sha256']:continue
        plan['entries'].append(item);proposals[ident]=item
    sources={}
    for item in json.loads(index.read_text(encoding='utf8')):sources.setdefault(item['youtube_id'],[]).append(item)
    media_ids={row['youtube_id'] for line in inventory.read_text(encoding='utf8').splitlines()
               if (row:=json.loads(line))['category']=='media' and row['youtube_id']}
    audit=json.loads(baseline.read_text(encoding='utf8'));flags={x['youtube_id']:x['quality'] for x in audit['flagged']}
    read_bytes=0;links=0;repairs=0;attached=0;notes=[];examined=0
    with core.closing_database(core.connect(runtime.db,True)) as db:
        rows=db.execute("SELECT v.youtube_id,v.title,v.transcript,c.prefix AS channel,c.lang_config FROM videos v JOIN channels c ON c.id=v.channel_id WHERE trim(COALESCE(v.transcript,''))!='' ORDER BY v.id").fetchall()
        for row in rows:
            ident=row['youtube_id'];old=row['transcript'];existing=proposals.get(ident)
            inferred=[x for x in sources.get(ident,[]) if x.get('associations')]
            if ident not in media_ids and not (inferred and repair.CORRUPTION.search(old)):continue
            if existing and existing.get('timed_source'):continue
            choices=sources.get(ident,[])
            if not choices:notes.append(dict(youtube_id=ident,reason='no_local_timed_source'));continue
            if existing:
                expected=gzip.decompress((target/'candidates'/(ident+'.txt.gz')).read_bytes()).decode('utf8')
                if maintenance.digest(old)!=existing['before_sha']:raise RuntimeError('Concurrent proposal change')
            else:expected=old
            preferred=(row['lang_config'] or 'und').split('-')[0]
            choices=sorted(choices,key=lambda x:(x['language'].split('-')[0]!=preferred,'orig' not in x['language']))
            found=False;examined+=1
            for source in choices:
                if source['language'].split('-')[0] not in {'fr','en','und'}:continue
                for source_path in source['paths']:
                    path=Path(source_path);size=path.stat().st_size
                    if size>8_000_000:continue
                    if read_bytes+size>500_000_000:break
                    read_bytes+=size
                    try:
                        data=path.read_bytes();raw=gzip.decompress(data) if path.suffix=='.gz' else data
                        text,temporal=core.clean_captions_detailed(raw.decode('utf-8-sig'))
                    except (OSError,EOFError,UnicodeError,ValueError):continue
                    if not text or temporal['timestamp_regressions']:continue
                    same=canonical_words(text)==canonical_words(expected)
                    association=source.get('associations',{}).get(str(path))
                    evidence=dict(source_path=str(path),association=association,
                                  timing={k:v for k,v in temporal.items() if k!='removed'},display_examples=temporal['removed'][:8],
                                  comparison='exact_after_punctuation_and_legacy_adjacent_word_normalization' if same else None)
                    item=existing
                    if same and not quality.ENCODING_ARTIFACT.search(expected):
                        if not existing:
                            q=quality.inspect_text(old)
                            if q['technical_markers'] or q['review_signals']['encoding_artifacts']:continue
                            item=dict(youtube_id=ident,channel=row['channel'],title=row['title'],category='verified_source_archival_only',
                                      before_sha=maintenance.digest(old),after_sha=maintenance.digest(old),apply=True,metadata_only=True,
                                      before_quality=q,after_quality=q,evidence=evidence,metadata={},source_review_notes=[],
                                      opening_before=old[:900],opening_after=old[:900]);links+=1
                        else:
                            item['evidence']['additional_timed_source']=evidence;attached+=1
                    elif not existing:
                        match=repair.concordance(old,text)
                        if not match['accepted']:continue
                        q=flags.get(ident) or quality.inspect_text(old);evidence['agreement']=match
                        item=repair.entry(row,old,text,q,'verified_local_timed_source',evidence)
                        if not item:continue
                        expected=text;repairs+=1
                    else:continue
                    sha=hashlib.sha256(raw).hexdigest();ext='vtt' if raw.lstrip().startswith(b'WEBVTT') else 'srt'
                    runtime.archive.mkdir(parents=True,exist_ok=True)
                    archive=runtime.archive/f'{ident}.{sha}.{source["language"]}.{ext}.gz'
                    if not archive.exists():archive.write_bytes(gzip.compress(raw,mtime=0))
                    if hashlib.sha256(gzip.decompress(archive.read_bytes())).hexdigest()!=sha:raise RuntimeError('Archived source mismatch')
                    item['timed_source']=dict(raw_path=str(archive),sha256=sha,language=source['language'])
                    if not existing:
                        (target/'candidates'/(ident+'.txt.gz')).write_bytes(gzip.compress(expected.encode('utf8'),mtime=0))
                        plan['entries'].append(item);proposals[ident]=item
                    core.atomic_json(target/'candidates'/(ident+'.json'),item)
                    found=True;break
                if found or read_bytes>=500_000_000:break
            if not found:notes.append(dict(youtube_id=ident,reason='no_safe_timed_source_match'))
            if examined%25==0:
                core.atomic_json(target/'PLAN.json',plan)
                runtime.check_space(128*1024**2)
                print(json.dumps(dict(examined=examined,source_links=links,new_text_repairs=repairs,existing_repairs_linked=attached,bytes_read=read_bytes)),flush=True)
    plan['changes']=len(plan['entries']);plan['text_changes']=sum(not x.get('metadata_only',False) for x in plan['entries'])
    plan['counts']=dict(Counter(x['category'] for x in plan['entries']))
    plan['storage_source_preparation']=dict(source_links=links,new_text_repairs=repairs,existing_repairs_linked=attached,
                                            bytes_read=read_bytes,notes=notes)
    core.atomic_json(target/'PLAN.json',plan);maintenance.report(target,plan)
    print(json.dumps(plan['storage_source_preparation'] | dict(notes_count=len(notes),notes=[])),flush=True)


if __name__=='__main__':
    sys.stdout.reconfigure(encoding='utf8',errors='replace');p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,default=Path(__file__).resolve().parent.parent)
    p.add_argument('--plan',type=Path,required=True);p.add_argument('--index',type=Path,required=True)
    p.add_argument('--inventory',type=Path,required=True);p.add_argument('--baseline',type=Path,required=True)
    args=p.parse_args();runtime=core.Runtime(args.root);target=args.plan.resolve()
    if not target.is_relative_to((runtime.database_dir/'pilot_reports').resolve()):raise ValueError('Private plan required')
    with core.acquisition_lock(runtime):prepare(runtime,target,args.index,args.inventory,args.baseline)
