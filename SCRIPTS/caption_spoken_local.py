"""Run the authorized transcript repair from a bounded local cache."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import sys
import traceback
import caption_spoken_dedup as spoken
import caption_maintenance as maintenance
import pipeline_core as core

def publish_reports(source,destination):
    destination.mkdir(parents=True,exist_ok=True)
    files=[p for p in source.iterdir() if p.is_file() and p.suffix in {'.json','.jsonl','.md','.log'}]
    def copy(path):
        data=path.read_bytes();final=destination/path.name;temp=final.with_name(final.name+'.copying');temp.write_bytes(data)
        if hashlib.sha256(temp.read_bytes()).digest()!=hashlib.sha256(data).digest():raise RuntimeError('Report publication mismatch')
        temp.replace(final)
    with ThreadPoolExecutor(max_workers=4) as pool:list(pool.map(copy,files))

def main():
    sys.stdout.reconfigure(encoding='utf8',errors='replace')
    parser=argparse.ArgumentParser();parser.add_argument('--root',type=Path,required=True);parser.add_argument('--name',default='spoken-dedup-20261101');args=parser.parse_args()
    if Path(args.name).name!=args.name:raise ValueError('Invalid job name')
    runtime=core.Runtime(args.root);target=runtime.work/'repair_jobs'/args.name;target.mkdir(parents=True,exist_ok=True)
    final=runtime.database_dir/'pilot_reports'/args.name
    def state(stage,**details):
        data=dict(stage=stage,updated_at=core.now(),local_target=str(target),network_calls=0,audio_calls=0,**details)
        core.atomic_json(target/'STATE.json',data);print(json.dumps(data),flush=True)
    try:
        runtime.check_space(1024**3);state('preparing_locally')
        spoken.plan(runtime,target)
        plan=json.loads((target/'PLAN.json').read_text(encoding='utf8'));plan['local_original_archive']=str(target/'canonical_originals');core.atomic_json(target/'PLAN.json',plan)
        state('applying_and_verifying',reviewed=plan['texts_scanned'],changes=plan['changes'])
        if not (target/'DONE.json').exists():maintenance.apply(runtime,target)
        done=json.loads((target/'DONE.json').read_text(encoding='utf8'))
        state('publishing_reports',changed=done['changed'])
        publish_reports(target,final)
        state('done',changed=done['changed'],managed_local_bytes=runtime.usage(),report=str(final/'SUMMARY.md'))
        core.atomic_json(final/'STATE.json',json.loads((target/'STATE.json').read_text(encoding='utf8')))
    except Exception as error:
        state('failed',error=str(error));traceback.print_exc();raise

if __name__=='__main__':main()
