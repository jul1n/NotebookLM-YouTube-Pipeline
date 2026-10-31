"""Preserve private non-media Git history before authorized history pruning."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def run(root,*args,**kwargs):
    return subprocess.run(['git','-C',str(root),*args],check=True,**kwargs)


def preserve(root):
    folder=root/'DATABASE/history_safeguards';folder.mkdir(parents=True,exist_ok=True)
    listing=run(root,'-c','core.quotePath=false','rev-list','--objects','--all',capture_output=True).stdout.decode('utf8')
    (folder/'ORIGINAL_OBJECT_PATHS.txt').write_text(listing,encoding='utf8')
    media={'.mp4','.mkv','.webm','.mov','.m4a','.mp3','.opus','.wav','.ogg','.flac','.aac'}
    paths=sorted({line.split(' ',1)[1] for line in listing.splitlines() if ' ' in line and Path(line.split(' ',1)[1]).suffix.lower() not in media})
    # Paths may include trees; positive file paths only, based on a batch object type check.
    pairs=[line.split(' ',1) for line in listing.splitlines() if ' ' in line and Path(line.split(' ',1)[1]).suffix.lower() not in media]
    objects='\n'.join(x[0] for x in pairs)+'\n'
    checks=run(root,'cat-file','--batch-check=%(objectname) %(objecttype) %(objectsize)',input=objects.encode(),capture_output=True).stdout.decode().splitlines()
    kept=[];excluded=[]
    for (_,path),check in zip(pairs,checks):
        oid,kind,size=check.split();size=int(size)
        if kind!='blob':continue
        row=dict(oid=oid,path=path,size=size)
        (excluded if Path(path).suffix.lower() in media else kept).append(row)
    paths=sorted({x['path'] for x in kept})
    print(json.dumps(dict(nonmedia_bytes=sum(x['size'] for x in kept),media_bytes=sum(x['size'] for x in excluded),paths=len(paths))),flush=True)
    if sum(x['size'] for x in kept)>3_000_000_000:raise RuntimeError('Non-media history exceeds 3GB safeguard budget; stop for diagnosis')
    bare=folder/'nonmedia-history.git'
    if bare.exists():raise RuntimeError('Existing safeguard: inspect instead of overwrite')
    run(root,'init','--bare',str(bare),capture_output=True)
    exporter=subprocess.Popen(['git','-C',str(root),'fast-export','--all','--',*paths],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    importer=subprocess.run(['git','-C',str(bare),'fast-import','--quiet'],stdin=exporter.stdout,capture_output=True)
    exporter.stdout.close();error=exporter.stderr.read();status=exporter.wait()
    if status or importer.returncode:raise RuntimeError('History export/import failed: '+error.decode(errors='replace')+importer.stderr.decode(errors='replace'))
    run(bare,'fsck','--full',capture_output=True)
    bundle=folder/'nonmedia-history-20261031.bundle'
    run(bare,'bundle','create',str(bundle),'--all',capture_output=True)
    run(root,'bundle','verify',str(bundle),capture_output=True)
    # Confirm every selected original blob is preserved, including old captions/text/database objects.
    present=set(run(bare,'rev-list','--objects','--all',capture_output=True).stdout.decode('utf8').split())
    missing=[x for x in kept if x['oid'] not in present]
    if missing:raise RuntimeError('Missing original non-media objects in safeguard')
    h=hashlib.sha256(bundle.read_bytes()).hexdigest()
    proof=dict(bundle=str(bundle),sha256=h,size=bundle.stat().st_size,verified=True,
               original_refs=run(root,'show-ref',capture_output=True).stdout.decode(),preserved_nonmedia=kept,discardable_media=excluded,
               note='Private non-media history; contains private configuration, never publish this bundle.')
    (folder/'VERIFIED.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2),encoding='utf8')
    print(json.dumps(dict(bundle=str(bundle),size=proof['size'],verified=True,preserved_objects=len(kept))),flush=True)


if __name__=='__main__':
    sys.stdout.reconfigure(encoding='utf8');preserve(Path(__file__).resolve().parent.parent)
