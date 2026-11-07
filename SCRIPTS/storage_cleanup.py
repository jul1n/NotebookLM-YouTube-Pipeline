"""Explicit authorized storage batches, with text/source/backup guards. No network."""
import argparse
from collections import Counter
from functools import lru_cache
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys

import caption_quality as quality
import pipeline_core as core
from prepare_storage_sources import canonical_words
from resolve_legacy_sources import key as filename_key


def digest(text):
    return hashlib.sha256(text.encode('utf8')).hexdigest()


@lru_cache(maxsize=8)
def resolved_root(root):
    return root.resolve()


def checked_path(root, item):
    path=Path(item['path'])
    if not path.is_absolute() or path.is_symlink() or not path.resolve().is_relative_to(resolved_root(root)):
        raise ValueError('Path outside approved repository or symlink')
    if any(p.casefold() in {'.git','_captions_gz','_text_sources_gz','_legacy_rendered_gz','_verified_text_gz','snapshots'} for p in path.relative_to(root).parts):
        raise ValueError('Protected directory')
    if path.name.lower().endswith(('-wal','-shm','-journal')):
        raise ValueError('SQLite journal protected')
    # resolve() above follows ancestor junctions too. Rechecking every ancestor
    # individually adds thousands of redundant round trips to the Drive provider.
    st=path.stat()
    if (st.st_size,st.st_mtime_ns)!=(item['size_bytes'],item['modified_ns']):raise ValueError('File changed since inventory')
    if core.video_id(path.name)!=item['youtube_id']:raise ValueError('Filename ID mismatch')
    return path


def verified_backup(runtime):
    for marker in sorted((runtime.database_dir/'snapshots').glob('*.verified.json'),reverse=True):
        proof=json.loads(marker.read_text(encoding='utf8'));path=core.snapshot_database(runtime,marker)
        if not proof.get('verified') or proof.get('owner')!='notebooklm-pipeline':continue
        if not path.exists() or path.stat().st_size!=proof['size']:continue
        runtime.work.mkdir(parents=True,exist_ok=True)
        cached=runtime.work/('deletion-verified-'+proof['sha256']+'.db')
        h=hashlib.sha256()
        if cached.exists():
            with cached.open('rb') as f:
                for block in iter(lambda:f.read(8*1024**2),b''):h.update(block)
        else:
            runtime.check_space(proof['size']+64*1024**2)
            partial=cached.with_suffix('.copying')
            with path.open('rb') as f,partial.open('wb') as out:
                for block in iter(lambda:f.read(8*1024**2),b''):h.update(block);out.write(block)
                out.flush();os.fsync(out.fileno())
            if h.hexdigest()!=proof['sha256']:raise ValueError('Backup checksum mismatch')
            os.replace(partial,cached)
        if h.hexdigest()!=proof['sha256']:raise ValueError('Backup checksum mismatch')
        return cached,dict(proof,drive_path=str(path))
    raise ValueError('No verified backup')


def metadata_id(path):
    # yt-dlp writes the top-level ID first. Never load/print volatile signed URLs.
    with path.open('rb') as f:head=f.read(4096).decode('utf-8-sig',errors='strict')
    match=re.match(r'\s*\{\s*"id"\s*:\s*"([A-Za-z0-9_-]{11})"\s*[,}]',head)
    return match[1] if match else None


def metadata_matches(path,row):
    if core.video_id(path.name)!=row['youtube_id']:return False
    if path.stat().st_size<=4096:return metadata_id(path)==row['youtube_id']
    # Opening a cloud placeholder can hydrate the entire file. Do not read large
    # old metadata merely to delete it: require the filename ID AND matching title.
    return bool(row['title'] and filename_key(path.name)[1]==filename_key(row['title'])[1])


def media_proof(runtime,db,ident,text):
    q=quality.inspect_text(text);s=q['review_signals']
    if q['technical_markers'] or s['encoding_artifacts']:return None,'technical_or_encoding_issue'
    duration=db.execute('SELECT duration FROM videos WHERE youtube_id=?',(ident,)).fetchone()
    if s['word_count']<100:return None,'text_too_short_for_automatic_media_deletion'
    if duration and duration[0] and duration[0]>120 and s['word_count']<duration[0]*.5:
        return None,'text_coverage_too_low_for_duration'
    density=q['suspected_repetitions']/max(1,s['word_count'])*100
    if (density>=.10 and s['long_repetition_alerts']>=2) or (s['longest_repeated_unit']>=10 and s['long_repetition_alerts']>=5):
        return None,'priority_repetition_review'
    # User explicitly permits DB-only retention for already healthy texts. Keep an
    # additional tiny exact text copy, without presenting it as a timed source.
    # No timestamps/source prerequisite under the user-approved text-only policy.
    # Only sparse repetitions entirely classified as short fillers/annotations
    # may pass automatically; unexplained phrases remain blocked.
    oral_profile=(runtime.policy.get('deletion_requires_reprocessable_source') is False
                  and runtime.policy.get('media_text_quality_profile')=='short_oral_fillers_v1')
    explained=s['short_filler_alerts']+s['nonverbal_only_alerts']
    sparse_oral=(oral_profile and q['suspected_repetitions']>0 and explained==q['suspected_repetitions']
                 and s['long_repetition_alerts']==0 and s['repeated_word_fraction']<=.01 and density<=.2)
    if q['status']=='no_heuristic_alert' or sparse_oral:
        sha=digest(text);folder=runtime.root/'WORKING_ZONE/_VERIFIED_TEXT_GZ';folder.mkdir(parents=True,exist_ok=True)
        archive=folder/f'{ident}.{sha}.txt.gz'
        if not archive.exists():archive.write_bytes(gzip.compress(text.encode('utf8'),mtime=0))
        if hashlib.sha256(gzip.decompress(archive.read_bytes())).hexdigest()!=sha:raise ValueError('Text safeguard mismatch')
        return dict(raw_path=str(archive),raw_sha256=sha,text_sha256=sha,quality=q,
                    source_kind='exact_final_text_not_timed_source',quality_profile='short_oral_fillers_v1' if sparse_oral else 'no_heuristic_alert',
                    cleaner_version=core.CAPTION_VERSION),'healthy_database_text_and_backup'
    record=db.execute('SELECT * FROM pipeline_transcripts WHERE youtube_id=?',(ident,)).fetchone()
    if not record:return None,'unexplained_repetitions_require_review' if oral_profile else 'missing_canonical_timed_source'
    source=Path(record['raw_path'])
    legacy=runtime.root/'WORKING_ZONE/_LEGACY_RENDERED_GZ'
    if source.resolve().is_relative_to(legacy.resolve()) and source.name.endswith('.rendered.txt.gz'):
        raw=gzip.decompress(source.read_bytes());sha=hashlib.sha256(raw).hexdigest()
        if sha!=record['sha256']:return None,'source_checksum_mismatch'
        from caption_source_repair import complete_triplicates
        rebuilt,evidence=complete_triplicates(core.strip_caption_markup(raw.decode('utf8')))
        if not evidence['accepted'] or canonical_words(rebuilt)!=canonical_words(text):return None,'legacy_source_reconstruction_not_confirmed'
        return dict(raw_path=str(source),raw_sha256=sha,text_sha256=digest(text),quality=q,
                    source_kind='verified_systematic_triplicate_original',reconstruction=evidence,
                    cleaner_version=core.CAPTION_VERSION),'verified_legacy_source_and_reconstructed_text'
    if not source.resolve().is_relative_to(runtime.archive.resolve()):return None,'source_not_canonical_vtt_srt'
    if not source.name.endswith(('.vtt.gz','.srt.gz')):return None,'source_not_canonical_vtt_srt'
    raw=gzip.decompress(source.read_bytes());sha=hashlib.sha256(raw).hexdigest()
    if sha!=record['sha256']:return None,'source_checksum_mismatch'
    cleaned,timing=core.clean_captions_detailed(raw.decode('utf-8-sig'))
    if timing['timestamp_regressions']:return None,'timestamp_regressions'
    if canonical_words(cleaned)!=canonical_words(text):return None,'source_text_mismatch'
    return dict(raw_path=str(source),raw_sha256=sha,text_sha256=digest(text),quality=q,
                cleaner_version=core.CAPTION_VERSION),'verified_timed_source_and_text'


def prepare(runtime,target,inventory):
    backup,backup_proof=verified_backup(runtime);eligible=[];held=Counter();proofs={}
    with core.closing_database(core.connect(runtime.db,True)) as db, core.closing_database(core.connect(backup,True)) as saved:
        rows={r['youtube_id']:dict(r) for r in db.execute('SELECT * FROM videos')}
        saved_hash={r['youtube_id']:digest(r['transcript'] or '') for r in saved.execute('SELECT youtube_id,transcript FROM videos')}
        for line in inventory.open(encoding='utf8'):
            item=json.loads(line);category=item['category'];ident=item['youtube_id']
            if category not in {'media','video_metadata'} or item['git_tracked']:continue
            row=rows.get(ident)
            if not row or not (row['transcript'] or '').strip():continue
            text=row['transcript'];sha=digest(text)
            if saved_hash.get(ident)!=sha:held['backup_text_mismatch']+=item['size_bytes'];continue
            try:
                path=checked_path(runtime.root,item)
                if category=='video_metadata':
                    if not metadata_matches(path,row):held['metadata_identity_not_confirmed']+=item['size_bytes'];continue
                    if not row['title'] or not row['channel_id']:held['incomplete_database_identity']+=item['size_bytes'];continue
                    evidence=dict(text_sha256=sha,title=row['title'],channel_id=row['channel_id'],upload_date=row['upload_date'],duration=row['duration'],
                                  reason='obsolete_yt_dlp_metadata_identity_preserved_in_database')
                else:
                    if ident not in proofs:proofs[ident]=media_proof(runtime,db,ident,text)
                    evidence,reason=proofs[ident]
                    if not evidence:held[reason]+=item['size_bytes'];continue
                eligible.append(dict(item,evidence=evidence))
            except (OSError,ValueError,EOFError,UnicodeError) as error:
                held[type(error).__name__]+=item['size_bytes']
            if len(eligible) and len(eligible)%500==0:print(json.dumps({'eligible':len(eligible)}),flush=True)
    totals=Counter();counts=Counter()
    for x in eligible:totals[x['category']]+=x['size_bytes'];counts[x['category']]+=1
    result=dict(created_at=core.now(),authorization='User-approved verified storage cleanup; eligibility rechecked against the current policy',policy_snapshot=dict(runtime.policy),
                root=str(runtime.root),database=str(runtime.db),backup=str(backup),backup_proof=backup_proof,
                totals=dict(totals),counts=dict(counts),held_bytes=dict(held),entries=eligible,network_calls=0)
    core.atomic_json(target/'DELETE_PLAN.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='entries'},ensure_ascii=False),flush=True)


def apply(runtime,target):
    plan=json.loads((target/'DELETE_PLAN.json').read_text(encoding='utf8'))
    if Path(plan['root'])!=runtime.root or Path(plan['database'])!=runtime.db:raise ValueError('Wrong repository')
    backup,backup_proof=verified_backup(runtime)
    # Any newer snapshot is accepted only after comparing each exact active text.
    drive_journal=target/'DELETION_JOURNAL.jsonl'
    runtime.work.mkdir(parents=True,exist_ok=True);runtime.check_space(32*1024**2)
    jobkey=hashlib.sha256(str(target).encode('utf8')).hexdigest()[:12]
    journal=runtime.work/f'storage-delete-{jobkey}.jsonl'
    core.atomic_json(target/'JOURNAL_LOCATION.json',dict(canonical_local_journal=str(journal),drive_mirror=str(drive_journal)))
    if not journal.exists() and drive_journal.exists():shutil.copyfile(drive_journal,journal)
    def mirror():
        if journal.exists():
            staged=drive_journal.with_suffix('.jsonl.tmp');shutil.copyfile(journal,staged);os.replace(staged,drive_journal)
    completed=set();totals=Counter();counts=Counter();held=Counter()
    if journal.exists():
        for line in journal.read_text(encoding='utf8').splitlines():
            item=json.loads(line)
            if item['action']=='deleted':completed.add(item['path']);totals[item['category']]+=item['bytes'];counts[item['category']]+=1
    with core.acquisition_lock(runtime), core.closing_database(core.connect(runtime.db,True)) as db, core.closing_database(core.connect(backup,True)) as saved, journal.open('a',encoding='utf8',newline='\n') as log:
        def record(value):
            log.write(json.dumps(dict(value,time=core.now()),ensure_ascii=False)+'\n');log.flush();os.fsync(log.fileno())
        checked={}
        for item in plan['entries']:
            if item['path'] in completed:continue
            ident=item['youtube_id'];category=item['category']
            try:
                path=checked_path(runtime.root,item)
                key=(ident,category)
                if key not in checked:
                    row=db.execute('SELECT * FROM videos WHERE youtube_id=?',(ident,)).fetchone()
                    saved_row=saved.execute('SELECT transcript FROM videos WHERE youtube_id=?',(ident,)).fetchone()
                    if not row or not saved_row or row['transcript']!=saved_row[0] or digest(row['transcript'])!=item['evidence']['text_sha256']:raise ValueError('Active/backup text changed')
                    if category=='media':
                        proof,reason=media_proof(runtime,db,ident,row['transcript'])
                        if not proof or proof['raw_sha256']!=item['evidence']['raw_sha256']:raise ValueError('Source no longer verified: '+reason)
                    checked[key]=dict(row)
                if category=='video_metadata' and not metadata_matches(path,checked[key]):raise ValueError('Metadata ID changed')
                record(dict(action='intent',path=str(path),category=category,bytes=item['size_bytes'],youtube_id=ident,text_sha256=item['evidence']['text_sha256']))
                path.unlink()
                record(dict(action='deleted',path=str(path),category=category,bytes=item['size_bytes'],youtube_id=ident))
                totals[category]+=item['size_bytes'];counts[category]+=1
            except (OSError,ValueError,UnicodeError,EOFError) as error:
                held[str(error)]+=1;record(dict(action='kept',path=item['path'],reason=str(error)))
            if sum(counts.values())%250==0:
                mirror();print(json.dumps(dict(deleted=dict(counts),bytes=dict(totals))),flush=True)
    mirror()
    result=dict(finished_at=core.now(),deleted_files=dict(counts),deleted_bytes=dict(totals),kept=dict(held),backup=str(backup),network_calls=0)
    core.atomic_json(target/'DELETED.json',result);print(json.dumps(result),flush=True)


if __name__=='__main__':
    sys.stdout.reconfigure(encoding='utf8',errors='replace');p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,default=Path(__file__).resolve().parent.parent);p.add_argument('--target',type=Path,required=True)
    p.add_argument('--inventory',type=Path);p.add_argument('--apply',action='store_true');args=p.parse_args()
    runtime=core.Runtime(args.root);target=args.target.resolve()
    if not target.is_relative_to((runtime.database_dir/'pilot_reports').resolve()):raise ValueError('Private report required')
    target.mkdir(parents=True,exist_ok=True)
    apply(runtime,target) if args.apply else prepare(runtime,target,args.inventory)
