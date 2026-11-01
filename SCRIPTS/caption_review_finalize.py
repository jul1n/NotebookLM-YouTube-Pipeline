"""Validate all repair candidates and relearn only from verified source pairs."""
from collections import Counter
import gzip
import hashlib
import json
from pathlib import Path
import re

import caption_deep_encoding as deep
import caption_encoding_repair as encoding
import caption_full_review as full
import caption_maintenance as maintenance
import caption_quality as quality
import caption_source_repair as source
import pipeline_core as core


def canonical_quotes(text):
    return text.translate(str.maketrans({'’':"'",'‘':"'",'“':'"','”':'"'}))


def numeric_content(text):
    return re.findall(r'\d+(?:[.,]\d+)*',text)


def semantic_rejection(item,before,after):
    if item['category'] in {'short_systemic_triplicates','completed_systemic_triplicates'}:return None
    if len(full.WEAK.findall(after))>len(full.WEAK.findall(before)):return 'source_introduces_weak_encoding_artifacts'
    if 'timed_source' in item or 'local_text_source' in item:
        if numeric_content(before)!=numeric_content(after):return 'source_changes_numeric_content'
        if not source.CORRUPTION.search(before) and full.protected_content(before)!=full.protected_content(after):return 'source_changes_negation'
    return None


def finalize(runtime,target):
    plan=json.loads((target/'PLAN.json').read_text(encoding='utf8'));all_reviews=json.loads((target/'ALL_REVIEWS.json').read_text(encoding='utf8'))
    records={x['youtube_id']:x for x in all_reviews['records']};entries={x['youtube_id']:x for x in plan['entries']};observations=[];training=[];rejected=[]
    inherited_path=runtime.database_dir/'pilot_reports/source-repair-max-20261031/ENCODING_DICTIONARY.json'
    inherited=json.loads(inherited_path.read_text(encoding='utf8')) if inherited_path.exists() else dict(training=[],templates=[])
    extra_bytes=0;extra_limit=100_000_000
    with core.acquisition_lock(runtime),core.closing_database(core.connect(runtime.db,True)) as db:
        def observe(ident,before,after,origin):
            found=encoding.pair_artifacts(before,canonical_quotes(after),predicate=deep.allowed_artifact)
            observations.append((ident,found));training.append(dict(youtube_id=ident,origin=origin,before_sha256=maintenance.digest(before),after_sha256=maintenance.digest(after)))
        for item in inherited['training']:
            ident=item['youtube_id'];row=db.execute('SELECT transcript FROM videos WHERE youtube_id=?',(ident,)).fetchone()
            revision=db.execute('SELECT original_gzip FROM pipeline_revisions WHERE youtube_id=? AND before_sha=? AND after_sha=? ORDER BY id DESC LIMIT 1',(ident,item['before_sha'],item['after_sha'])).fetchone()
            if not row or not revision or maintenance.digest(row[0])!=item['after_sha'] or full.WEAK.search(row[0]):continue
            path=Path(revision[0]);size=path.stat().st_size
            if extra_bytes+size>extra_limit:break
            extra_bytes+=size;raw=gzip.decompress(path.read_bytes())
            if hashlib.sha256(raw).hexdigest()!=item['before_sha']:raise RuntimeError('Historical original checksum mismatch')
            source_path=Path(item['source']['raw_path']);size=source_path.stat().st_size
            if extra_bytes+size>extra_limit:break
            extra_bytes+=size;source_raw=gzip.decompress(source_path.read_bytes())
            if hashlib.sha256(source_raw).hexdigest()!=item['source']['sha256']:raise RuntimeError('Historical caption checksum mismatch')
            observe(ident,raw.decode('utf8'),row[0],'previous_verified_timed_source')
            if len(training)%100==0:print(json.dumps(dict(verified_training_pairs=len(training))),flush=True)
        for ident,item in list(entries.items()):
            row=db.execute('SELECT transcript FROM videos WHERE youtube_id=?',(ident,)).fetchone();before=row[0]
            if maintenance.digest(before)!=item['before_sha']:raise RuntimeError('Concurrent edit before validation')
            candidate_path=target/'candidates'/(ident+'.txt.gz');after=gzip.decompress(candidate_path.read_bytes()).decode('utf8')
            if maintenance.digest(after)!=item['after_sha']:raise RuntimeError('Candidate checksum mismatch')
            reason=semantic_rejection(item,before,after)
            if reason:
                folder=target/'rejected_candidates';folder.mkdir(exist_ok=True)
                (folder/(ident+'.'+item['after_sha']+'.txt.gz')).write_bytes(candidate_path.read_bytes())
                core.atomic_json(folder/(ident+'.json'),dict(item,validation_rejection=reason));entries.pop(ident)
                records[ident]['result']='unresolved_'+reason;rejected.append(dict(youtube_id=ident,reason=reason));continue
            artifact=item.get('timed_source') or item.get('local_text_source')
            if (artifact and source.CORRUPTION.search(before) and not source.CORRUPTION.search(after) and not full.WEAK.search(after)
                    and not item['evidence'].get('additional_encoding_restoration')):
                raw=gzip.decompress(Path(artifact['raw_path']).read_bytes())
                if hashlib.sha256(raw).hexdigest()!=artifact['sha256']:raise RuntimeError('Training source checksum mismatch')
                observe(ident,before,after,'new_verified_local_source')
        learned=encoding.supported_mapping(observations);merged={};conflicts=set()
        for item in learned:
            item=dict(item,after=canonical_quotes(item['after']));old=item['before']
            if old in merged and merged[old]['after']!=item['after']:conflicts.add(old)
            else:merged[old]=item
        mapping=[value for key,value in merged.items() if key not in conflicts]
        dictionary=dict(version=deep.VERSION,templates=mapping,conflicts=sorted(conflicts),verified_training=training,
                        target_normalization='Curly quotation marks use their equivalent ASCII quotation marks',extra_source_bytes=extra_bytes)
        dictionary_path=target/'FINAL_ENCODING_DICTIONARY.json';core.atomic_json(dictionary_path,dictionary)
        dictionary_sha=hashlib.sha256(dictionary_path.read_bytes()).hexdigest();added=0;improved=0
        for ident,record in records.items():
            row=db.execute('SELECT v.youtube_id,v.title,v.transcript,c.prefix AS channel FROM videos v JOIN channels c ON c.id=v.channel_id WHERE youtube_id=?',(ident,)).fetchone()
            before=row['transcript'];existing=entries.get(ident)
            dictionary_only=bool(existing and existing['category']=='demonstrated_deep_encoding_restoration')
            base=before if dictionary_only else gzip.decompress((target/'candidates'/(ident+'.txt.gz')).read_bytes()).decode('utf8') if existing else before
            if not source.CORRUPTION.search(base) and not full.WEAK.search(base):continue
            candidate,proof=deep.restore(base,mapping)
            if not proof['accepted']:
                if dictionary_only:
                    folder=target/'rejected_candidates';folder.mkdir(exist_ok=True)
                    (folder/(ident+'.'+existing['after_sha']+'.txt.gz')).write_bytes((target/'candidates'/(ident+'.txt.gz')).read_bytes())
                    core.atomic_json(folder/(ident+'.json'),dict(existing,validation_rejection='character_mapping_not_reconfirmed'))
                    entries.pop(ident);record['result']='unresolved_character_mapping_not_reconfirmed';rejected.append(dict(youtube_id=ident,reason='character_mapping_not_reconfirmed'))
                continue
            after_q=quality.inspect_text(candidate)
            if after_q['technical_markers'] or after_q['review_signals']['encoding_artifacts']:continue
            evidence=dict(proof,dictionary_path=str(dictionary_path),dictionary_sha256=dictionary_sha,dictionary_version=deep.VERSION)
            if existing:
                item=dict(existing,after_sha=maintenance.digest(candidate),after_quality=after_q,opening_after=candidate[:900],
                          evidence=dict(existing['evidence'],additional_encoding_restoration=evidence));improved+=1
            else:
                item=dict(youtube_id=ident,channel=row['channel'],title=row['title'],category='demonstrated_deep_encoding_restoration',
                          before_sha=maintenance.digest(before),after_sha=maintenance.digest(candidate),apply=True,before_quality=record['quality'],
                          after_quality=after_q,evidence=evidence,metadata={},source_review_notes=[],opening_before=before[:900],opening_after=candidate[:900]);added+=1
            (target/'candidates'/(ident+'.txt.gz')).write_bytes(gzip.compress(candidate.encode('utf8'),mtime=0))
            core.atomic_json(target/'candidates'/(ident+'.json'),item);entries[ident]=item;record['result']='repair_prepared'
        plan.update(entries=list(entries.values()),changes=len(entries),counts=dict(Counter(x['category'] for x in entries.values())),
                    source_bytes_read=plan['source_bytes_read']+extra_bytes,
                    semantic_validation=dict(rejected=rejected,protected_numbers_and_negations=True),
                    final_encoding_training=dict(source_pairs=len(training),templates=len(mapping),added_texts=added,improved_candidates=improved,dictionary_sha256=dictionary_sha))
        plan['notes']=[dict(youtube_id=x['youtube_id'],reason=x['result'],text_sha=x['text_sha256']) for x in records.values()]
        core.atomic_json(target/'PLAN.json',plan);core.atomic_json(target/'ALL_REVIEWS.json',dict(records=list(records.values()),counts=dict(Counter(x['result'] for x in records.values()))))
        core.atomic_json(target/'PLAN_VALIDATED.json',dict(changes=len(entries),reviewed=len(records),rejected=rejected,encoding_training=plan['final_encoding_training'],verified_at=core.now()))
        maintenance.report(target,plan)
        print(json.dumps(dict(changes=len(entries),reviewed=len(records),rejected=len(rejected),encoding_training=plan['final_encoding_training'])),flush=True)


if __name__=='__main__':
    import argparse
    import sys
    sys.stdout.reconfigure(encoding='utf8',errors='replace');p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,default=Path(__file__).resolve().parent.parent);p.add_argument('--plan',type=Path,required=True)
    a=p.parse_args();runtime=core.Runtime(a.root);target=a.plan.resolve()
    if not target.is_relative_to((runtime.database_dir/'pilot_reports').resolve()):raise ValueError('Private plan required')
    finalize(runtime,target)
