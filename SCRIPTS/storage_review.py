"""Read-only project inventory and reviewable deletion batches. Never deletes."""
import argparse
from collections import Counter,defaultdict
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

import pipeline_core as core

MEDIA={'.mp4','.mkv','.webm','.mov','.m4a','.mp3','.opus','.wav','.ogg','.flac','.aac'}


def kind(path,root):
    relative=path.relative_to(root);parts=[p.casefold() for p in relative.parts];name=path.name.casefold()
    if '.git' in parts:return 'git_history'
    if name.endswith(('-wal','-shm','-journal')):return 'sqlite_journal_protected'
    if path.suffix.lower() in MEDIA:return 'media'
    if '_captions_gz' in parts:return 'canonical_timed_source_protected'
    if '_text_sources_gz' in parts or '_verified_text_gz' in parts:return 'canonical_text_source_protected'
    if '_legacy_rendered_gz' in parts:return 'revision_original_protected'
    if path.suffix.lower() in {'.db','.sqlite','.sqlite3'}:return 'database'
    if 'snapshots' in parts or name.endswith('.verified.json'):return 'backup_protected'
    if re.search(r'\.(?:vtt|srt|ass|ttml|json3)(?:\.gz)?$',name):return 'caption_source'
    if name.endswith('.txt'):
        if any('pack' in p for p in parts[:-1]):return 'generated_pack'
        if any(p in {'transcripts','2_clean_txt','2_txt','clean_txt','txt'} for p in parts[:-1]):return 'generated_transcript'
        return 'other_text'
    if name.endswith('.info.json'):return 'video_metadata'
    if path.suffix.lower() in {'.py','.ps1','.html','.js','.css','.md','.toml','.exe','.dll'}:return 'code_or_runtime'
    return 'other'


def allocated_bytes(path):
    if os.name!='nt':return None
    kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    fn=kernel.GetCompressedFileSizeW;fn.argtypes=[ctypes.c_wchar_p,ctypes.POINTER(ctypes.c_ulong)];fn.restype=ctypes.c_ulong
    high=ctypes.c_ulong();ctypes.set_last_error(0);low=fn(str(path),ctypes.byref(high))
    if low==0xffffffff and ctypes.get_last_error():return None
    return (high.value<<32)|low


def inventory(runtime,scope,target):
    scope=scope.resolve();target.mkdir(parents=True,exist_ok=False)
    if not runtime.root.is_relative_to(scope):raise ValueError('Scope must contain the repository')
    tracked_result=subprocess.run(['git','-C',str(runtime.root),'ls-files','-z'],capture_output=True,check=True)
    tracked=set(tracked_result.stdout.decode('utf8').split('\0'))
    sizes=Counter();counts=Counter();folders=Counter();errors=[];visited=0;pending=[scope]
    with (target/'INVENTORY.jsonl').open('w',encoding='utf8',newline='\n') as output:
        while pending:
            folder=pending.pop()
            try:
                with os.scandir(folder) as children:
                    for entry in children:
                        if entry.is_symlink() or getattr(entry,'is_junction',lambda:False)():continue
                        if entry.is_dir(follow_symlinks=False):pending.append(Path(entry.path));continue
                        if not entry.is_file(follow_symlinks=False):continue
                        stat=entry.stat(follow_symlinks=False);path=Path(entry.path);relative=path.relative_to(scope)
                        category=kind(path,scope);repo_relative=path.relative_to(runtime.root).as_posix() if path.is_relative_to(runtime.root) else None
                        attrs=getattr(stat,'st_file_attributes',0)
                        item=dict(path=str(path),relative_path=relative.as_posix(),repository_relative=repo_relative,
                                  size_bytes=stat.st_size,modified_ns=stat.st_mtime_ns,category=category,
                                  youtube_id=core.video_id(path.name),git_tracked=repo_relative in tracked,
                                  windows_attributes=attrs,cloud_recall_flag=bool(attrs&(0x1000|0x400000|0x40000)))
                        output.write(json.dumps(item,ensure_ascii=False)+'\n')
                        sizes[category]+=stat.st_size;counts[category]+=1
                        bucket='/'.join(relative.parts[:2]) if len(relative.parts)>1 else relative.parts[0]
                        folders[bucket]+=stat.st_size;visited+=1
                        if visited%10000==0:
                            output.flush();print(json.dumps(dict(inventoried=visited,logical_gb=round(sum(sizes.values())/1e9,2))),flush=True)
            except OSError as error:errors.append(dict(path=str(folder),error=str(error)))
    local_files=[p for p in runtime.local_root.rglob('*') if p.is_file()] if runtime.local_root else []
    allocations=[allocated_bytes(p) for p in local_files]
    result=dict(scope=str(scope),repository=str(runtime.root),generated_at=core.now(),files=visited,
                total_logical_bytes=sum(sizes.values()),category_bytes=dict(sizes),category_files=dict(counts),
                folder_bytes=dict(folders),errors=errors,complete=not errors,
                managed_local_logical_bytes=runtime.usage(),managed_local_allocated_bytes=sum(allocations) if all(x is not None for x in allocations) else None,
                managed_local_budget=runtime.budget,media_contents_read=False,deletions=0,
                physical_scope_note='Drive logical sizes describe stored data. H: does not reliably expose this project’s physical Google Drive cache allocation.')
    core.atomic_json(target/'TOTALS.json',result)
    text='# Empreinte du dossier projet — inventaire sans suppression\n\n'
    text+=f"Périmètre : `{scope}`. Fichiers : {visited}. Taille logique totale : **{sum(sizes.values())/1e9:.2f} Go**.\n\n"
    text+='Aucun contenu vidéo ou audio lu. Aucun fichier supprimé. Le cache physique de Google Drive ne peut pas être attribué fidèlement au projet à partir du lecteur H:.\n\n'
    text+=f"Base/cache local géré : {result['managed_local_logical_bytes']/1e9:.2f} Go / {runtime.budget/1e9:g} Go.\n\n"
    text+='## Répartition logique\n\n| Catégorie | Fichiers | Go |\n|---|---:|---:|\n'
    for category,size in sizes.most_common():text+=f'| {category} | {counts[category]} | {size/1e9:.3f} |\n'
    text+='\n## Dossiers les plus volumineux\n\n| Dossier | Go |\n|---|---:|\n'
    for name,size in folders.most_common(35):text+=f'| {name.replace("|","/")} | {size/1e9:.3f} |\n'
    text+='\nLes médias associés à un texte ne sont pas automatiquement supprimables : il faut encore vérifier la qualité actuelle, une source horodatée compressée et une sauvegarde identique. Git, les journaux SQLite, les sources canoniques et les originaux de révision restent protégés.\n'
    if errors:text+='\nInventaire incomplet : certains dossiers n’ont pas pu être lus ; consulter TOTALS.json.\n'
    (target/'INVENTORY.md').write_text(text,encoding='utf8')
    print(json.dumps(dict(files=visited,total_gb=round(sum(sizes.values())/1e9,3),complete=not errors)),flush=True)


if __name__=='__main__':
    sys.stdout.reconfigure(encoding='utf8',errors='replace');p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,default=Path(__file__).resolve().parent.parent)
    p.add_argument('--scope',type=Path,required=True);p.add_argument('--report',type=Path,required=True)
    args=p.parse_args();runtime=core.Runtime(args.root)
    if not args.report.resolve().is_relative_to((runtime.database_dir/'pilot_reports').resolve()):raise ValueError('Private report required')
    inventory(runtime,args.scope,args.report.resolve())
