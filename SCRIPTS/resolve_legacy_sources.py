"""Associate captions lacking a video ID using local filenames and metadata."""
from collections import Counter,defaultdict
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import unicodedata

import pipeline_core as core


def key(name):
    value=name
    for extension in ('.gz','.info.json','.vtt','.srt','.webm','.mp4','.mkv','.m4a','.mp3','.opus','.wav'):
        if value.casefold().endswith(extension):value=value[:-len(extension)]
    value=re.sub(r'\.[a-z]{2}(?:-[A-Za-z0-9]+)?$','',value)
    value=re.sub(r'\.f\d+$','',value)
    value=re.sub(r'\s*\[[A-Za-z0-9_-]{11}\]\s*$','',value)
    date=''
    match=re.match(r'^(\d{8})\s*[-_]\s*',value)
    if match:date=match[1];value=value[match.end():]
    value=unicodedata.normalize('NFKD',unicodedata.normalize('NFKC',value)).casefold()
    value=''.join(c for c in value if not unicodedata.combining(c))
    return date,' '.join(re.sub(r'[\W_]+',' ',value).split())


def top_level_video_id(prefix):
    decoder=json.JSONDecoder();text=prefix.decode('utf8',errors='ignore');i=0
    try:
        while i<len(text) and text[i].isspace():i+=1
        if text[i]!='{':return None
        i+=1
        while i<len(text):
            while i<len(text) and (text[i].isspace() or text[i]==','):i+=1
            field,end=decoder.raw_decode(text,i);i=end
            while i<len(text) and text[i].isspace():i+=1
            if text[i]!=':':return None
            i+=1
            while i<len(text) and text[i].isspace():i+=1
            value,end=decoder.raw_decode(text,i);i=end
            if field=='id':return value if isinstance(value,str) and core.VIDEO_ID.fullmatch(value) else None
    except (ValueError,IndexError):return None
    return None


def resolve(runtime,inventory,index,target,header_budget=500_000_000):
    rows=[json.loads(line) for line in inventory.read_text(encoding='utf8').splitlines()]
    original=json.loads(index.read_text(encoding='utf8'));combined={(x['youtube_id'],x['language']):dict(x) for x in original}
    direct=defaultdict(set);db_names=defaultdict(set);metadata=defaultdict(list)
    known=set()
    with core.closing_database(core.connect(runtime.db,True)) as db:
        for row in db.execute('SELECT youtube_id,title,upload_date FROM videos'):
            known.add(row['youtube_id']);date=re.sub(r'\D','',str(row['upload_date'] or ''))[:8]
            if date:db_names[(date,key(row['title'])[1])].add(row['youtube_id'])
    for row in rows:
        if row['category'] in {'media','video_metadata'}:
            k=key(Path(row['path']).name)
            if row['youtube_id'] in known:direct[k].add(row['youtube_id'])
            if row['category']=='video_metadata':metadata[k].append(row)
    added=[];unresolved=[];counts=Counter();header_potential_bytes=0;header_read_bytes=0;header_cache={}
    for row in rows:
        if row['category']!='caption_source' or row['youtube_id']:continue
        path=Path(row['path']);k=key(path.name);ident=None;method=None;support=None
        candidates=direct.get(k,set())
        if len(candidates)==1:ident=next(iter(candidates));method='unique_local_media_or_info_filename'
        elif k[0] and len(db_names.get(k,set()))==1:
            ident=next(iter(db_names[k]));method='unique_database_title_and_upload_date'
        if not ident:
            for info in metadata.get(k,[]):
                info_path=info['path']
                if info_path in header_cache:value,proof=header_cache[info_path]
                else:
                    if info['size_bytes']>4_000_000 or header_potential_bytes+info['size_bytes']>header_budget:continue
                    header_potential_bytes+=info['size_bytes']
                    with Path(info_path).open('rb') as handle:prefix=handle.read(65536)
                    header_read_bytes+=len(prefix);value=top_level_video_id(prefix)
                    proof=dict(path=info_path,prefix_sha256=hashlib.sha256(prefix).hexdigest(),prefix_bytes=len(prefix),
                               file_size=info['size_bytes'],modified_ns=info['modified_ns'])
                    header_cache[info_path]=(value,proof)
                if value in known:ident=value;method='adjacent_ytdlp_top_level_id';support=proof;break
        if not ident:
            unresolved.append(dict(path=str(path),key=k));continue
        lang_match=re.search(r'\.([a-z]{2}(?:-[A-Za-z0-9]+)?)\.(?:vtt|srt)(?:\.gz)?$',path.name)
        language=lang_match[1] if lang_match else 'und'
        association=dict(method=method,title_date_key=k,metadata_header=support,
                         needs_wording_concordance=True,source_size=row['size_bytes'],source_modified_ns=row['modified_ns'])
        entry=combined.setdefault((ident,language),dict(youtube_id=ident,language=language,paths=[]))
        if str(path) not in entry['paths']:entry['paths'].append(str(path))
        entry.setdefault('associations',{})[str(path)]=association
        added.append(dict(youtube_id=ident,language=language,path=str(path),association=association));counts[method]+=1
    core.atomic_json(target/'RESOLVED_LOCAL_SOURCES.json',list(combined.values()))
    core.atomic_json(target/'LEGACY_SOURCE_ASSOCIATIONS.json',dict(added=added,counts=dict(counts),unresolved=unresolved,
                    metadata_header_bytes_read=header_read_bytes,upper_bound_metadata_hydration_bytes=header_potential_bytes,
                    captions_contents_read=False,network_calls=0))
    print(json.dumps(dict(resolved_caption_files=len(added),unresolved=len(unresolved),methods=counts,
                         metadata_header_bytes_read=header_read_bytes)),flush=True)


if __name__=='__main__':
    sys.stdout.reconfigure(encoding='utf8',errors='replace');p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,default=Path(__file__).resolve().parent.parent)
    p.add_argument('--inventory',type=Path,required=True);p.add_argument('--index',type=Path,required=True);p.add_argument('--report',type=Path,required=True)
    p.add_argument('--header-budget',type=int,default=500_000_000)
    args=p.parse_args();runtime=core.Runtime(args.root);target=args.report.resolve()
    if not target.is_relative_to((runtime.database_dir/'pilot_reports').resolve()):raise ValueError('Private reports required')
    target.mkdir(exist_ok=True,parents=True);resolve(runtime,args.inventory,args.index,target,args.header_budget)
