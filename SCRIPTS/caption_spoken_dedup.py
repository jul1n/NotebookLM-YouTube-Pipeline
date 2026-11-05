"""User-authorized offline removal of adjacent spoken repetitions."""
import argparse
from collections import Counter
import gzip
import json
import os
from pathlib import Path
import re
import sys
import caption_quality as quality
import caption_maintenance as maintenance
import pipeline_core as core

VERSION='adjacent-spoken-repetitions-v3'
# Reflexive pronouns, grammatical double verbs/determiners and logical negation
# can be consecutive without expressing a repeated utterance.
GRAMMATICAL_DOUBLES={'nous','vous','had','that','not','pas'}

def deduplicate(text,max_unit=128):
    tokens=list(quality.TOKEN.finditer(text));stack=[];positions={};spans=[];examples=[];removed=0;events=0
    for token in tokens:
        word=token[0].casefold();stack.append((word,token));positions.setdefault(word,[]).append(len(stack)-1)
        while True:
            end=len(stack);found=0
            occurrences=positions[stack[-1][0]]
            for occurrence_index in range(len(occurrences)-2,-1,-1):
                previous=occurrences[occurrence_index]
                width=end-1-previous
                if width>max_unit:break
                if 2*width>end:continue
                if width==1 and stack[-1][0] in GRAMMATICAL_DOUBLES:continue
                left=stack[end-2*width:end-width];right=stack[end-width:]
                if all(a[0]==b[0] for a,b in zip(left,right)) and not any(any(c.isdigit() for c in value[0]) for value in right):
                    # Operators distinguish x + x, C/C++ or A - A from a spoken restart.
                    fragment=text[left[0][1].start():right[-1][1].end()+2]
                    if re.search(r'[+*/=<>^%−-]',fragment):continue
                    found=width;break
            if not found:break
            retained=stack[-found-1][1];last=stack[-1][1]
            spans.append((retained.end(),last.end()));removed+=found;events+=1
            if len(examples)<12:examples.append(text[max(0,retained.end()-100):min(len(text),last.end()+100)])
            for value,_ in stack[-found:]:positions[value].pop()
            del stack[-found:]
    merged=[]
    for start,end in sorted(spans):
        if merged and start<=merged[-1][1]:merged[-1]=(merged[-1][0],max(end,merged[-1][1]))
        else:merged.append((start,end))
    chunks=[];cursor=0
    for start,end in merged:chunks.append(text[cursor:start]);cursor=end
    chunks.append(text[cursor:]);result=''.join(chunks)
    if re.findall(r'\d+(?:[.,]\d+)*',text)!=re.findall(r'\d+(?:[.,]\d+)*',result):raise ValueError('Numeric content changed')
    return result,dict(version=VERSION,events=events,removed_words=removed,examples=examples,
                       authorization='User accepts removal of spoken tics and emphasis; only adjacent exact token copies removed',max_unit=max_unit)

def plan(runtime,target):
    if (target/'PLAN.json').exists():return
    target.mkdir(parents=True,exist_ok=True);folder=target/'candidates';folder.mkdir(exist_ok=True)
    records={};journal_path=target/'REVIEWS.jsonl'
    if journal_path.exists():
        for line in journal_path.read_text(encoding='utf8').splitlines():
            try:record=json.loads(line)
            except ValueError:continue
            if record.get('version')==VERSION:records[record['youtube_id']]=record
    entries=[];scanned=0;removed=0;excluded=[];reused=0
    with core.closing_database(core.connect(runtime.db,True)) as db, journal_path.open('a',encoding='utf8') as journal:
        exclusions=core.quality_exclusions(runtime,db)
        for row in db.execute("SELECT v.youtube_id,v.title,v.transcript,c.prefix AS channel FROM videos v JOIN channels c ON c.id=v.channel_id WHERE trim(COALESCE(v.transcript,''))!='' ORDER BY v.id"):
            scanned+=1;old=row['transcript'];ident=row['youtube_id'];before_sha=maintenance.digest(old)
            if ident in exclusions:excluded.append(ident);continue
            cached=records.get(ident);valid=bool(cached and cached['before_sha']==before_sha)
            if valid and cached['item']:
                try:valid=maintenance.digest(gzip.decompress((folder/(ident+'.txt.gz')).read_bytes()).decode('utf8'))==cached['item']['after_sha']
                except (OSError,ValueError,EOFError,UnicodeError):valid=False
            if valid:
                item=cached['item'];reused+=1
            else:
                candidate,evidence=deduplicate(old);item=None
                if candidate!=old:
                    before=quality.inspect_text(old);after=quality.inspect_text(candidate)
                    if not candidate.strip() or after['technical_markers']:raise ValueError('Invalid output '+ident)
                    if deduplicate(candidate)[0]!=candidate:raise ValueError('Non-idempotent output '+ident)
                    item=dict(youtube_id=ident,title=row['title'],channel=row['channel'],category='authorized_adjacent_repetitions',
                        before_sha=before_sha,after_sha=maintenance.digest(candidate),apply=True,metadata={},evidence=evidence,source_review_notes=[],
                        before_quality=before,after_quality=after,opening_before=old[:900],opening_after=candidate[:900])
                    temporary=folder/(ident+'.txt.gz.tmp');temporary.write_bytes(gzip.compress(candidate.encode('utf8'),mtime=0));temporary.replace(folder/(ident+'.txt.gz'))
                journal.write(json.dumps(dict(version=VERSION,youtube_id=ident,before_sha=before_sha,item=item),ensure_ascii=False)+'\n')
            if item:entries.append(item);removed+=item['evidence']['removed_words']
            if scanned%100==0:
                journal.flush();os.fsync(journal.fileno())
                if scanned%500==0:runtime.check_space(256*1024**2)
                progress=dict(scanned=scanned,changes=len(entries),removed_words=removed,reused=reused)
                core.atomic_json(target/'PROGRESS.json',progress);print(json.dumps(progress),flush=True)
    result=dict(version=maintenance.VERSION,deduplicator=VERSION,created_at=core.now(),database=str(runtime.db),texts_scanned=scanned,
        changes=len(entries),counts=dict(Counter(x['category'] for x in entries)),entries=entries,excluded=excluded,removed_words=removed,
        network_calls=0,audio_calls=0,spoken_repetitions_removal_authorized=True)
    core.atomic_json(target/'PLAN.json',result);maintenance.report(target,result)
    print(json.dumps(dict(plan=str(target),changes=len(entries),removed_words=removed)),flush=True)

def main():
    sys.stdout.reconfigure(encoding='utf8',errors='replace')
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--target',type=Path,required=True);parser.add_argument('--apply',action='store_true');args=parser.parse_args()
    runtime=core.Runtime(Path(__file__).resolve().parent.parent);target=args.target.resolve()
    if not target.is_relative_to((runtime.database_dir/'pilot_reports').resolve()):raise ValueError('Report outside project')
    plan(runtime,target)
    if args.apply and not (target/'DONE.json').exists():maintenance.apply(runtime,target)

if __name__=='__main__':main()
