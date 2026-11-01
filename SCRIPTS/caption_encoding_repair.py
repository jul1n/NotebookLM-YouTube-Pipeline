"""Restore demonstrated character-encoding artifacts; never guess missing words."""
from collections import Counter, defaultdict
import difflib
import gzip
import hashlib
import json
from pathlib import Path
import re
import sys
import unicodedata

import caption_source_repair as source
import caption_maintenance as maintenance
import caption_quality as quality
import pipeline_core as core

VERSION='demonstrated-character-artifacts-v1'


def positioned_anchors(text):
    result=[]
    for token in re.finditer(r'\S+',text):
        value=source.anchors(token[0])
        if value:result.append((value[0],token.start(),token.end()))
    return result


def allowed_artifact(old,new):
    if len(new)>1 or len(old)<2 or old==new:return False
    if re.search(r'[A-Za-z0-9]',old):return False
    if any(ord(c)<128 and c not in ' "\'\t' for c in old):return False
    if not new:
        # Some broken exports injected an encoding wrapper before an already
        # correct accented character. Learn such deletions only when the exact
        # nonlinguistic wrapper is demonstrated repeatedly by independent files.
        return len(old)>=8 and len(source.CORRUPTION.findall(old))>=2
    latin=(not new.isascii() and unicodedata.name(new,'').startswith('LATIN'))
    punctuation=new in '‘’“”«»–—…°'
    if not (latin or punctuation):return False
    return bool(source.CORRUPTION.search(old) or re.search(r'[ÃÂûÔ├┬]',old))


def pair_artifacts(before,after,max_windows=500,predicate=None):
    a,b=positioned_anchors(before),positioned_anchors(after)
    common={x[0] for x in a}&{x[0] for x in b}
    a=[x for x in a if x[0] in common];b=[x for x in b if x[0] in common]
    blocks=difflib.SequenceMatcher(None,[x[0] for x in a],[x[0] for x in b],autojunk=True).get_matching_blocks()
    found=Counter();windows=0
    for block in blocks:
        for offset in range(block.size-1):
            i,j=block.a+offset,block.b+offset
            old=before[a[i][2]:a[i+1][1]];new=after[b[j][2]:b[j+1][1]]
            if old==new or len(old)>4000 or len(new)>300:continue
            windows+=1
            for tag,start,end,left,right in difflib.SequenceMatcher(None,old,new,autojunk=False).get_opcodes():
                if tag in {'replace','delete'} and (predicate or allowed_artifact)(old[start:end],new[left:right]):
                    found[(old[start:end],new[left:right])]+=1
            if windows>=max_windows:return found
    return found


def supported_mapping(observations,min_videos=3,min_occurrences=10):
    counts=Counter();videos=defaultdict(set);targets=defaultdict(set)
    for ident,pairs in observations:
        for (old,new),count in pairs.items():
            counts[(old,new)]+=count;videos[(old,new)].add(ident);targets[old].add(new)
    result=[]
    for (old,new),count in counts.items():
        if len(targets[old])==1 and count>=min_occurrences and len(videos[(old,new)])>=min_videos:
            result.append(dict(before=old,after=new,occurrences=count,independent_videos=sorted(videos[(old,new)])))
    return sorted(result,key=lambda x:-len(x['before']))


def prepare_restore(mapping):
    lookup={x['before']:x['after'] for x in mapping}
    return lookup,re.compile('|'.join(re.escape(x) for x in sorted(lookup,key=len,reverse=True))) if lookup else None


def restore(text,mapping,prepared=None):
    if not mapping:return text,dict(accepted=False,reason='no_supported_character_mapping')
    lookup,pattern=prepared or prepare_restore(mapping)
    used=Counter()
    def replace(match):used[match[0]]+=1;return lookup[match[0]]
    candidate=pattern.sub(replace,text)
    changes=sum(used.values());before_signals=len(source.CORRUPTION.findall(text))
    remaining=len(source.CORRUPTION.findall(candidate))
    accepted=(changes>=5 and (before_signals>=5 or (changes>=10 and len(used)>=2))
              and remaining==0 and not re.search(r'[\u2500-\u259f]',candidate))
    # Every ASCII letter and digit must survive in the exact same order. This
    # character restoration cannot paraphrase, insert or remove ordinary words.
    ascii_before=re.sub(r'[^A-Za-z0-9]','',text)
    ascii_after=re.sub(r'[^A-Za-z0-9]','',candidate)
    if ascii_before!=ascii_after:raise RuntimeError('Character mapping changed ASCII content')
    proof=dict(accepted=accepted,substitutions=changes,distinct_artifacts=len(used),
               encoding_signals_before=before_signals,encoding_signals_after=remaining,
               ascii_letters_and_digits_preserved=True,
               applied_templates=[dict(before=k,after=lookup[k],count=v) for k,v in used.items()])
    return (candidate if accepted else text),proof


def augment(runtime,target):
    plan=json.loads((target/'PLAN.json').read_text(encoding='utf8'))
    observations=[];training=[]
    with core.closing_database(core.connect(runtime.db,True)) as db:
        for item in plan['entries']:
            if (item['category']!='verified_local_timed_source' or not item['metadata'].get('encoding_signals_before')
                    or item['metadata'].get('encoding_signals_after')):continue
            old=db.execute('SELECT transcript FROM videos WHERE youtube_id=?',(item['youtube_id'],)).fetchone()[0]
            if maintenance.digest(old)!=item['before_sha']:raise RuntimeError('Concurrent edit during mapping training')
            candidate=gzip.decompress((target/'candidates'/(item['youtube_id']+'.txt.gz')).read_bytes()).decode('utf8')
            if maintenance.digest(candidate)!=item['after_sha']:raise RuntimeError('Candidate checksum mismatch')
            if re.search(r'[\u2500-\u259f]',candidate):continue
            found=pair_artifacts(old,candidate)
            observations.append((item['youtube_id'],found))
            training.append(dict(youtube_id=item['youtube_id'],before_sha=item['before_sha'],after_sha=item['after_sha'],source=item['timed_source']))
        mapping=supported_mapping(observations)
        dictionary=dict(version=VERSION,templates=mapping,training=training,
                        thresholds=dict(independent_videos=3,occurrences=10),generated_at=core.now())
        core.atomic_json(target/'ENCODING_DICTIONARY.json',dictionary)
        dictionary_sha=hashlib.sha256((target/'ENCODING_DICTIONARY.json').read_bytes()).hexdigest()
        existing={x['youtube_id'] for x in plan['entries']};added=0;substitutions=0;prepared=prepare_restore(mapping)
        for row in db.execute("SELECT v.youtube_id,v.title,v.transcript,c.prefix AS channel FROM videos v JOIN channels c ON c.id=v.channel_id WHERE trim(COALESCE(v.transcript,''))!='' ORDER BY v.id"):
            if row['youtube_id'] in existing:continue
            before=row['transcript']
            if not source.CORRUPTION.search(before) and not re.search(r'Ã|Â|û|Ô|├|┬',before):continue
            candidate,proof=restore(before,mapping,prepared)
            if not proof['accepted']:continue
            before_quality=quality.inspect_text(before)
            item=source.entry(row,before,candidate,before_quality,'demonstrated_encoding_restoration',proof)
            if not item:continue
            item['evidence'].update(dictionary_version=VERSION,dictionary_sha256=dictionary_sha,
                                    dictionary_path=str(target/'ENCODING_DICTIONARY.json'))
            (target/'candidates'/(row['youtube_id']+'.txt.gz')).write_bytes(gzip.compress(candidate.encode('utf8'),mtime=0))
            plan['entries'].append(item);added+=1;substitutions+=proof['substitutions']
            if added%100==0:print(json.dumps(dict(encoding_texts=added,substitutions=substitutions)),flush=True)
    plan['changes']=len(plan['entries']);plan['counts']=dict(Counter(x['category'] for x in plan['entries']))
    plan['character_restoration']=dict(version=VERSION,templates=len(mapping),training_videos=len(training),
                                      additional_texts=added,substitutions=substitutions,dictionary_sha256=dictionary_sha)
    core.atomic_json(target/'PLAN.json',plan);maintenance.report(target,plan)
    print(json.dumps(plan['character_restoration']),flush=True)


if __name__=='__main__':
    sys.stdout.reconfigure(encoding='utf8',errors='replace')
    import argparse
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--plan',type=Path,required=True)
    p.add_argument('--root',type=Path,default=Path(__file__).resolve().parent.parent)
    args=p.parse_args();runtime=core.Runtime(args.root);target=args.plan.resolve()
    if not target.is_relative_to((runtime.database_dir/'pilot_reports').resolve()):raise ValueError('Private plan required')
    with core.acquisition_lock(runtime):augment(runtime,target)
