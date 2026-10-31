"""Preserve code and historical source history before authorized Git pruning."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def run(root,*args,**kwargs):
    return subprocess.run(['git','-C',str(root),*args],check=True,**kwargs)


def preserve(root):
    folder=root/'DATABASE/history_safeguards';folder.mkdir(parents=True,exist_ok=True)
    listing=run(root,'-c','core.quotePath=false','rev-list','--objects','--all',capture_output=True).stdout.decode('utf8')
    (folder/'ORIGINAL_OBJECT_PATHS.txt').write_text(listing,encoding='utf8')
    media={'.mp4','.mkv','.webm','.mov','.m4a','.mp3','.opus','.wav','.ogg','.flac','.aac'}
    def preserve_path(path):
        value=Path(path);name=value.name.lower()
        if value.suffix.lower() in media|{'.exe','.dll','.title'}:return False
        if name.endswith('.info.json') or name in {'data.js','health.js','stats.js'}:return False
        if value.suffix.lower()=='.txt' and any('pack' in part.casefold() for part in value.parts[:-1]):return False
        return True
    paths=sorted({line.split(' ',1)[1] for line in listing.splitlines() if ' ' in line and Path(line.split(' ',1)[1]).suffix.lower() not in media})
    # Paths may include trees; positive file paths only, based on a batch object type check.
    pairs=[line.split(' ',1) for line in listing.splitlines() if ' ' in line and preserve_path(line.split(' ',1)[1])]
    checks=[]
    for start in range(0,len(pairs),100):
        objects='\n'.join(x[0] for x in pairs[start:start+100])+'\n'
        with tempfile.TemporaryFile() as incoming,tempfile.TemporaryFile() as outgoing:
            incoming.write(objects.encode());incoming.seek(0)
            run(root,'cat-file','--batch-check=%(objectname) %(objecttype) %(objectsize)',stdin=incoming,stdout=outgoing,stderr=subprocess.PIPE)
            outgoing.seek(0);checks.extend(outgoing.read().decode().splitlines())
        print(json.dumps(dict(objects_checked=len(checks),total=len(pairs))),flush=True)
    kept=[];excluded=[]
    for (_,path),check in zip(pairs,checks):
        oid,kind,size=check.split();size=int(size)
        if kind!='blob':continue
        row=dict(oid=oid,path=path,size=size)
        (excluded if Path(path).suffix.lower() in media else kept).append(row)
    paths=sorted({x['path'] for x in kept})
    print(json.dumps(dict(nonmedia_bytes=sum(x['size'] for x in kept),media_bytes=sum(x['size'] for x in excluded),paths=len(paths))),flush=True)
    # This is uncompressed input streamed through Git, never an on-disk export.
    # The resulting compressed bundle and the temporary bare repository stay on Drive.
    if sum(x['size'] for x in kept)>20_000_000_000:raise RuntimeError('Unexpected non-media history volume; stop for diagnosis')
    bare=folder/'nonmedia-history.git'
    if not bare.exists():
        run(root,'init','--bare',str(bare),capture_output=True)
        # Literal pathspecs preserve historical filenames containing square brackets.
        exporter=subprocess.Popen(['git','-C',str(root),'fast-export','--all','--','--',*[':(literal)'+p for p in paths]],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        importer=subprocess.run(['git','--git-dir',str(bare),'fast-import','--quiet'],stdin=exporter.stdout,capture_output=True)
        exporter.stdout.close();error=exporter.stderr.read();exporter.stderr.close();status=exporter.wait()
        if status or importer.returncode:raise RuntimeError('History export/import failed: '+error.decode(errors='replace')+importer.stderr.decode(errors='replace'))
    present=set(run(bare,'rev-list','--objects','--all',capture_output=True).stdout.decode('utf8').split())
    missing=[x for x in kept if x['oid'] not in present]
    core_manifest=folder/'PRESERVED_OBJECTS.json'
    core_manifest.write_text(json.dumps(dict(kept=kept,recovered=missing),ensure_ascii=False,indent=2),encoding='utf8')
    if missing:
        print(json.dumps(dict(recovering_original_blobs=len(missing))),flush=True)
        unique={x['oid']:x for x in missing}
        for oid in unique:
            source=subprocess.Popen(['git','-C',str(root),'cat-file','blob',oid],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            copied=subprocess.run(['git','--git-dir',str(bare),'hash-object','-w','--stdin'],stdin=source.stdout,capture_output=True,check=True)
            source.stdout.close();error=source.stderr.read();source.stderr.close()
            if source.wait() or copied.stdout.decode().strip()!=oid:raise RuntimeError('Original blob recovery failed')
        tree_input=b''.join(('100644 blob '+oid+'\t'+oid+'.source').encode()+b'\0' for oid in unique)
        tree=run(bare,'mktree','-z',input=tree_input,capture_output=True).stdout.decode().strip()
        prior=subprocess.run(['git','-C',str(bare),'rev-parse','--verify','refs/heads/recovered-original-blobs'],capture_output=True)
        parents=['-p',prior.stdout.decode().strip()] if prior.returncode==0 else []
        commit=run(bare,'-c','user.name=History safeguard','-c','user.email=safeguard@localhost','commit-tree',tree,*parents,'-m','Preserve original source blobs and their original paths in the private manifest',capture_output=True).stdout.decode().strip()
        run(bare,'update-ref','refs/heads/recovered-original-blobs',commit,capture_output=True)
    run(bare,'fsck','--full',capture_output=True)
    bundle=folder/'nonmedia-history-20261031.bundle'
    run(bare,'bundle','create',str(bundle),'--all',capture_output=True)
    run(root,'bundle','verify',str(bundle),capture_output=True)
    # Confirm every selected original blob is preserved, including old captions/text/database objects.
    present=set(run(bare,'rev-list','--objects','--all',capture_output=True).stdout.decode('utf8').split())
    missing=[x for x in kept if x['oid'] not in present]
    if missing:raise RuntimeError('Missing original source objects in safeguard')
    h=hashlib.sha256(bundle.read_bytes()).hexdigest()
    proof=dict(bundle=str(bundle),sha256=h,size=bundle.stat().st_size,verified=True,
               original_refs=run(root,'show-ref',capture_output=True).stdout.decode(),preserved_nonmedia=kept,discardable_media=excluded,
               excluded_paths=[line.split(' ',1)[1] for line in listing.splitlines() if ' ' in line and not preserve_path(line.split(' ',1)[1])],
               note='Private code and historical sources. Excludes media, generated packs and dashboards, obsolete metadata and runtime binaries. Contains private configuration; never publish this bundle.')
    (folder/'VERIFIED.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2),encoding='utf8')
    print(json.dumps(dict(bundle=str(bundle),size=proof['size'],verified=True,preserved_objects=len(kept))),flush=True)


if __name__=='__main__':
    sys.stdout.reconfigure(encoding='utf8');preserve(Path(__file__).resolve().parent.parent)
