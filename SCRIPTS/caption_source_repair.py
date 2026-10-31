"""Prepare reversible repairs using existing timed sources. Never uses network."""
import argparse
from bisect import bisect_right
from collections import Counter
import difflib
import gzip
import hashlib
import json
from pathlib import Path
import re
import sys
import unicodedata

import caption_maintenance as maintenance
import caption_quality as quality
import pipeline_core as core

CORRUPTION=re.compile(r'\ufffd|Ôò|Ôö|û[▓╣┬│]|[┬├][\x80-\uFFFF]')
ASCII_WORD=re.compile(r"[a-z]+(?:'[a-z]+)?")


def anchors(text):
    result=[]
    for token in text.replace('’',"'").split():
        if CORRUPTION.search(token):continue
        word=''.join(c for c in unicodedata.normalize('NFKD',token) if not unicodedata.combining(c))
        word=word.strip('.,!?;:"()[]{}-').casefold()
        if len(word)>=4 and ASCII_WORD.fullmatch(word):result.append(word)
    return result


def concordance(before,after):
    a,b=anchors(before),anchors(after)
    matched=sum(block.size for block in difflib.SequenceMatcher(None,a,b,autojunk=True).get_matching_blocks())
    proof=dict(old_anchors=len(a),new_anchors=len(b),matched_anchors=matched,
               old_coverage=matched/max(1,len(a)),source_coverage=matched/max(1,len(b)),
               unique_matches=len(set(a)&set(b)))
    # The exact video ID and compatible language are checked separately. This
    # ordered lexical agreement rejects incomplete/different translations.
    proof['accepted']=(proof['old_coverage']>=.95 and proof['source_coverage']>=.95
                       and matched>=40 and proof['unique_matches']>=20)
    if not proof['accepted'] and len(CORRUPTION.findall(before))>=5 and not CORRUPTION.search(after):
        common=set(a)&set(b);aa=[w for w in a if w in common];bb=[w for w in b if w in common]
        count=sum(block.size for block in difflib.SequenceMatcher(None,aa,bb,autojunk=True).get_matching_blocks())
        projected=dict(old_coverage=count/max(1,len(aa)),source_coverage=count/max(1,len(bb)),
                       old_vocabulary_coverage=len(common)/max(1,len(set(a))),
                       source_vocabulary_coverage=len(common)/max(1,len(set(b))),matched=count)
        proof['intact_word_projection']=projected
        # Words whose accents were destroyed cannot match their restored form.
        # Compare the remaining shared vocabulary in order, not just a word bag.
        proof['accepted']=(projected['old_coverage']>=.95 and projected['source_coverage']>=.95
                           and projected['old_vocabulary_coverage']>=.85 and projected['source_vocabulary_coverage']>=.70
                           and count>=100 and len(common)>=50)
    return proof


def complete_triplicates(text):
    """Recover varied whole-document triplicates, including short cue units.

    Internal repetitions in a retained unit survive. Uniform music/ASR loops
    cannot establish this format: at least 20 distinct units are mandatory.
    """
    tokens=list(re.finditer(r'\S+',text));words=[x[0] for x in tokens];positions={}
    for i,word in enumerate(words):positions.setdefault(word,[]).append(i)
    groups=[];i=0;covered=0
    while i<len(words):
        width=0;indices=positions[words[i]];limit=min(40,(len(words)-i)//3)
        for j in reversed(indices[bisect_right(indices,i):bisect_right(indices,i+limit)]):
            n=j-i
            if words[i]==words[i+2*n] and words[i:i+n]==words[i+n:i+2*n]==words[i+2*n:i+3*n]:width=n;break
        if width:groups.append((i,width));covered+=3*width;i+=3*width
        else:i+=1
    unique={tuple(words[i:i+n]) for i,n in groups}
    evidence=dict(groups=len(groups),distinct_units=len(unique),coverage=covered/max(1,len(words)),
                  long_groups=sum(n>=6 for _,n in groups),basis='varied_systematic_exact_triplicates')
    accepted=(evidence['coverage']>=.98 and len(groups)>=25 and len(unique)>=20 and evidence['long_groups']>=20)
    evidence['accepted']=accepted
    if not accepted:return text,evidence
    spans=[(tokens[i+n].start(),tokens[i+3*n-1].end()) for i,n in groups]
    out=[];last=0
    for start,end in spans:out.append(text[last:start]);last=end
    out.append(text[last:]);candidate=' '.join(''.join(out).split())
    evidence.update(removed_tokens=sum(2*n for _,n in groups),removed_spans=spans)
    assert len(candidate.split())==len(words)-evidence['removed_tokens']
    return candidate,evidence


def entry(row,before,candidate,before_quality,category,evidence):
    after=quality.inspect_text(candidate)
    if not candidate.strip() or after['technical_markers']:return None
    before_corrupt=len(CORRUPTION.findall(before));after_corrupt=len(CORRUPTION.findall(candidate))
    if after_corrupt>before_corrupt:return None
    if after['suspected_repetitions']>=before_quality['suspected_repetitions'] and not before_corrupt>after_corrupt:return None
    return dict(youtube_id=row['youtube_id'],channel=row['channel'],title=row['title'],category=category,
                before_sha=maintenance.digest(before),after_sha=maintenance.digest(candidate),apply=True,
                before_quality=before_quality,after_quality=after,evidence=evidence,
                metadata=dict(encoding_signals_before=before_corrupt,encoding_signals_after=after_corrupt),
                source_review_notes=[],opening_before=before[:900],opening_after=candidate[:900])


def prepare(runtime,target,baseline,index_path,limit=None,recover_from=None,selective=False):
    target.mkdir(parents=True,exist_ok=False);(target/'candidates').mkdir()
    baseline=json.loads(baseline.read_text(encoding='utf8'))
    flagged={x['youtube_id']:x for x in baseline['flagged']}
    inventory=json.loads(index_path.read_text(encoding='utf8'));sources={}
    for item in inventory:
        sources.setdefault(item['youtube_id'],[]).append(item)
    entries=[];counts=Counter();examined=0;read_bytes=0;max_read=2_000_000_000;notes=[]
    recovered_progress=json.loads((recover_from/'PROGRESS.json').read_text(encoding='utf8')) if recover_from else {}
    prior_examined=recovered_progress.get('examined',0)
    read_bytes=recovered_progress.get('source_bytes_read',0)

    def save_candidate(item,candidate):
        (target/'candidates'/(item['youtube_id']+'.txt.gz')).write_bytes(gzip.compress(candidate.encode('utf8'),mtime=0))
        core.atomic_json(target/'candidates'/(item['youtube_id']+'.json'),item)
        entries.append(item);counts[item['category']]+=1

    def checkpoint():
        if examined%100==0:
            runtime.check_space(128*1024**2)
            core.atomic_json(target/'PROGRESS.json',dict(examined=examined,changes=len(entries),source_bytes_read=read_bytes,categories=dict(counts)))
            print(json.dumps(dict(examined=examined,changes=len(entries),bytes_read=read_bytes)),flush=True)

    with core.closing_database(core.connect(runtime.db,True)) as db:
        # Finish the prior 20 reconstructions from their archived complete
        # sources, not by deleting short repeated phrases in current prose.
        revisions=db.execute("SELECT * FROM pipeline_revisions WHERE job_id='maintenance-maintenance-20261031-validated'").fetchall()
        completed_ids=set()
        for revision in revisions:
            proof=json.loads(revision['proof'])
            if proof['category']!='systemic_triplicates':continue
            ident=revision['youtube_id']
            row=db.execute('SELECT v.youtube_id,v.title,v.transcript,c.prefix AS channel FROM videos v JOIN channels c ON c.id=v.channel_id WHERE youtube_id=?',(ident,)).fetchone()
            if maintenance.digest(row['transcript'])!=revision['after_sha']:continue
            original=gzip.decompress(Path(revision['original_gzip']).read_bytes()).decode('utf8')
            if maintenance.digest(original)!=revision['before_sha']:raise ValueError('Original checksum mismatch')
            candidate,evidence=complete_triplicates(original)
            if not evidence['accepted']:continue
            evidence.update(original_revision_id=revision['id'],original_sha=revision['before_sha'],source_path=revision['original_gzip'])
            item=entry(row,row['transcript'],candidate,flagged[ident]['quality'],'completed_systemic_triplicates',evidence)
            if item:save_candidate(item,candidate);completed_ids.add(ident)

        # The previous repetition audit did not classify encoding corruption.
        # Include every additional damaged text, not just already flagged rows.
        added=0;encoding_scores={}
        for row in db.execute("SELECT youtube_id,transcript FROM videos WHERE trim(COALESCE(transcript,''))!=''"):
            encoding_scores[row['youtube_id']]=len(CORRUPTION.findall(row['transcript']))
            if row['youtube_id'] not in flagged and CORRUPTION.search(row['transcript']):
                flagged[row['youtube_id']]=dict(youtube_id=row['youtube_id'],quality=quality.inspect_text(row['transcript']))
                added+=1
        print(json.dumps(dict(additional_encoding_texts=added,strong_encoding_texts=sum(v>0 for v in encoding_scores.values()))),flush=True)
        recovered_ids=set()
        if recover_from:
            archives={}
            for path in runtime.archive.glob('*.gz'):
                parts=path.name.split('.')
                if len(parts)==5 and re.fullmatch(r'[a-f0-9]{64}',parts[1]):archives.setdefault(parts[0],[]).append(path)
            for path in (recover_from/'candidates').glob('*.txt.gz'):
                ident=path.name[:11]
                if ident in completed_ids:continue
                candidate=gzip.decompress(path.read_bytes()).decode('utf8')
                row=db.execute('SELECT v.youtube_id,v.title,v.transcript,c.prefix AS channel,c.lang_config FROM videos v JOIN channels c ON c.id=v.channel_id WHERE youtube_id=?',(ident,)).fetchone()
                if not row:raise RuntimeError('Missing recovery row')
                item=None
                for archive in archives.get(ident,[]):
                    raw_bytes=gzip.decompress(archive.read_bytes());sha=hashlib.sha256(raw_bytes).hexdigest()
                    if sha!=archive.name.split('.')[1]:raise RuntimeError('Recovery archive checksum mismatch')
                    recovered,temporal=core.clean_captions_detailed(raw_bytes.decode('utf-8-sig'))
                    if recovered!=candidate:continue
                    match=concordance(row['transcript'],candidate)
                    if not match['accepted']:raise RuntimeError('Recovered source no longer matches active text')
                    evidence=dict(source_path=str(archive),agreement=match,
                                  timing={k:v for k,v in temporal.items() if k!='removed'},display_examples=temporal['removed'][:8],
                                  recovered_from=str(recover_from))
                    item=entry(row,row['transcript'],candidate,flagged[ident]['quality'],'verified_local_timed_source',evidence)
                    if item:item['timed_source']=dict(raw_path=str(archive),sha256=sha,language=archive.name.split('.')[2])
                    break
                if not item:
                    recovered,evidence=complete_triplicates(row['transcript'])
                    if evidence['accepted'] and recovered==candidate:
                        item=entry(row,row['transcript'],candidate,flagged[ident]['quality'],'short_systemic_triplicates',evidence)
                if not item:raise RuntimeError('Cannot verify recovered candidate: '+ident)
                save_candidate(item,candidate);recovered_ids.add(ident)
                if len(recovered_ids)%100==0:print(json.dumps(dict(recovered_candidates=len(recovered_ids))),flush=True)
            print(json.dumps(dict(recovered_candidates=len(recovered_ids),prior_examined=prior_examined,preserved_source_bytes=read_bytes)),flush=True)
        ordered=sorted(flagged.values(),key=lambda x:(-encoding_scores.get(x['youtube_id'],0),-x['quality']['suspected_repetitions']))
        ordinal=0
        for source_flag in ordered:
            ident=source_flag['youtube_id']
            if ident in completed_ids:continue
            ordinal+=1
            if ordinal<=prior_examined or ident in recovered_ids:
                if ident not in recovered_ids:
                    row=db.execute('SELECT v.youtube_id,v.title,v.transcript,c.prefix AS channel FROM videos v JOIN channels c ON c.id=v.channel_id WHERE youtube_id=?',(ident,)).fetchone()
                    notes.append(dict(youtube_id=ident,channel=row['channel'],title=row['title'],reason='previous_pass_no_safe_gain',
                                      text_sha=maintenance.digest(row['transcript']),repetitions=source_flag['quality']['suspected_repetitions'],encoding_signals=encoding_scores.get(ident,0)))
                examined=max(examined,ordinal);continue
            if limit is not None and examined>=limit:break
            examined=ordinal
            row=db.execute('SELECT v.youtube_id,v.title,v.transcript,c.prefix AS channel,c.lang_config FROM videos v JOIN channels c ON c.id=v.channel_id WHERE youtube_id=?',(ident,)).fetchone()
            old=row['transcript'];before_quality=source_flag['quality'];accepted=False
            if (selective and not encoding_scores.get(ident,0)
                    and before_quality['suspected_repetitions']/max(1,len(old.split()))<.01):
                notes.append(dict(youtube_id=ident,channel=row['channel'],title=row['title'],reason='low_density_no_structural_artifact',
                                  text_sha=maintenance.digest(old),repetitions=before_quality['suspected_repetitions'],encoding_signals=0))
                checkpoint();continue
            if before_quality['suspected_repetitions']>=20:
                candidate,evidence=complete_triplicates(old)
                if evidence['accepted']:
                    item=entry(row,old,candidate,before_quality,'short_systemic_triplicates',evidence)
                    if item:save_candidate(item,candidate);accepted=True
            if accepted:continue
            language=(row['lang_config'] or 'und').split('-')[0]
            choices=[s for s in sources.get(ident,[]) if s['language'].split('-')[0] in {language,'und'}]
            choices.sort(key=lambda s:('orig' not in s['language'],s['language']))
            reason='no_local_timed_source' if not choices else 'no_safe_source_match'
            for source in choices:
                for source_path in source['paths']:
                    path=Path(source_path);size=path.stat().st_size
                    if size>8_000_000:reason='source_too_large';continue
                    if read_bytes+size>max_read:reason='source_read_budget';break
                    read_bytes+=size
                    try:
                        payload=path.read_bytes();raw_bytes=gzip.decompress(payload) if path.suffix=='.gz' else payload
                        if len(raw_bytes)>32_000_000:continue
                        raw=raw_bytes.decode('utf-8-sig')
                        candidate,temporal=core.clean_captions_detailed(raw)
                    except (OSError,UnicodeError,EOFError,ValueError):reason='unreadable_source';continue
                    if not candidate or temporal['timestamp_regressions']:reason='invalid_or_regressing_source';continue
                    if ' '.join(candidate.split())==' '.join(old.split()):reason='same_text';accepted=True;break
                    def collapsed(value):
                        words=value.replace('’',"'").casefold().split();out=[]
                        for word in words:
                            if not out or out[-1]!=word:out.append(word)
                        return out
                    if not encoding_scores.get(ident,0) and collapsed(candidate)==collapsed(old):
                        reason='same_after_legacy_single_word_collapse';accepted=True;break
                    match=concordance(old,candidate)
                    if not match['accepted']:reason='source_wording_mismatch';continue
                    evidence=dict(source_path=str(path),agreement=match,
                                  timing={k:v for k,v in temporal.items() if k!='removed'},display_examples=temporal['removed'][:8])
                    item=entry(row,old,candidate,before_quality,'verified_local_timed_source',evidence)
                    if not item:reason='no_quality_gain';accepted=True;break
                    sha=hashlib.sha256(raw_bytes).hexdigest();extension='vtt' if raw.lstrip().startswith('WEBVTT') else 'srt'
                    runtime.archive.mkdir(parents=True,exist_ok=True)
                    archive=runtime.archive/f'{ident}.{sha}.{source["language"]}.{extension}.gz'
                    if not archive.exists():archive.write_bytes(gzip.compress(raw_bytes,mtime=0))
                    if hashlib.sha256(gzip.decompress(archive.read_bytes())).hexdigest()!=sha:raise RuntimeError('Source archive mismatch')
                    item['timed_source']=dict(raw_path=str(archive),sha256=sha,language=source['language'])
                    save_candidate(item,candidate);accepted=True;reason='repaired';break
                if accepted or reason=='source_read_budget':break
            if not accepted or reason in {'no_quality_gain','same_text','same_after_legacy_single_word_collapse'}:
                notes.append(dict(youtube_id=ident,channel=row['channel'],title=row['title'],reason=reason,
                                  text_sha=maintenance.digest(old),repetitions=before_quality['suspected_repetitions'],encoding_signals=len(CORRUPTION.findall(old))))
            counts['examined']=examined
            checkpoint()
    counts.pop('examined',None)
    result=dict(version=maintenance.VERSION,created_at=core.now(),database=str(runtime.db),texts_scanned=examined,
                counts=dict(counts),changes=len(entries),entries=entries,notes=notes,source_bytes_read=read_bytes,network_calls=0,
                source_cleaner=core.CAPTION_VERSION,recovered_from=str(recover_from) if recover_from else None,
                selective_low_density_preservation=selective)
    core.atomic_json(target/'PLAN.json',result);maintenance.report(target,result)
    print(json.dumps(dict(changes=len(entries),examined=examined,counts=counts,bytes_read=read_bytes)),flush=True)


def main():
    sys.stdout.reconfigure(encoding='utf8',errors='replace')
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,default=Path(__file__).resolve().parent.parent)
    p.add_argument('--plan',type=Path,required=True);p.add_argument('--baseline',type=Path,required=True)
    p.add_argument('--index',type=Path,required=True);p.add_argument('--limit',type=int)
    p.add_argument('--recover-from',type=Path);p.add_argument('--selective',action='store_true')
    args=p.parse_args();runtime=core.Runtime(args.root);target=args.plan.resolve()
    if not target.is_relative_to((runtime.database_dir/'pilot_reports').resolve()):raise ValueError('Private plan path required')
    with core.acquisition_lock(runtime):prepare(runtime,target,args.baseline,args.index,args.limit,args.recover_from,args.selective)


if __name__=='__main__':main()
