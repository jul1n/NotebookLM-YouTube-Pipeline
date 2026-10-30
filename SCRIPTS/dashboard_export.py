"""Generate existing dashboard assets with Python, without executing PowerShell."""
import csv
from datetime import datetime
import json
import os
from pathlib import Path
import re

import pipeline_core as core


def query_template(text,name):
    match=re.search(r'\$'+re.escape(name)+r'\s*=\s*@"\s*\n(.*?)\n"@',text,re.S)
    if not match:match=re.search(r'\$'+re.escape(name)+r'\s*=\s*"(.*?)"',text,re.S)
    if not match:raise ValueError(f'Dashboard query missing: {name}')
    query=match[1].strip()
    if not query.upper().startswith('SELECT') or '$' in query:raise ValueError('Only static SELECT dashboard templates are supported')
    return query


def export_dashboard(runtime,template=None):
    # The existing file is read as a data contract, never evaluated as a script.
    template=Path(template) if template else runtime.root/'SCRIPTS'/'Sync-Dashboard-v15.ps1'
    source=template.read_text(encoding='utf-8-sig')
    with core.closing_database(core.connect(runtime.db,True)) as db:
        fetch=lambda name:[dict(row) for row in db.execute(query_template(source,name))]
        stats=fetch('statsSql')[0]
        search=fetch('searchSql');health=fetch('healthSql');recovery=fetch('recoverySql')
        count=lambda where:db.execute('SELECT count(*) FROM videos WHERE '+where).fetchone()[0]
        words=stats.get('totalWords') or 0;hours=stats.get('totalHours') or 0
        if hours<1 and words:hours=round(words/9000)
        config_path=runtime.database_dir/'channels_config.csv'
        if config_path.exists():
            with config_path.open(encoding='utf-8-sig',newline='') as handle:channels=list(csv.DictReader(handle,delimiter=';'))
        else:channels=[]
        values=dict(totalVids=stats.get('totalVids') or 0,totalHours=round(hours,1),totalWords=words,
                    lastSync=datetime.now().strftime('%H:%M (%d/%m)'),channelCount=db.execute('SELECT count(*) FROM channels').fetchone()[0],
                    totalMissing=count("status IN ('MISSING','PENDING')"),totalFailed=count("status LIKE 'ERR_DL_FAIL%'"),
                    totalPremium=count("status='PREMIUM'"),totalNoSubs=count("status LIKE 'ERR_NO_EN_FR%' OR status LIKE 'ERR_TOO_SHORT%' OR status='NO_SUBS'"),channelsConfig=channels)
    assets=runtime.root/'assets';assets.mkdir(exist_ok=True)
    serialize=lambda value:json.dumps(value,ensure_ascii=True,separators=(',',':'))
    files={'stats.js':'const GLOBAL_STATS = '+serialize(values)+';',
           'data.js':'const GLOBAL_DATA = '+serialize(search)+';',
           'health.js':'const HEALTH_DATA = '+serialize(health)+'; const GLOBAL_RECOVERY = '+serialize(recovery)+';'}
    for name,content in files.items():
        temporary=assets/(name+'.tmp')
        temporary.write_text(content,encoding='utf-8');os.replace(temporary,assets/name)
    core.atomic_json(runtime.database_dir/'health_report.json',health)
    return dict(refreshed=True,engine='python',channels=len(health),transcripts=values['totalVids'])
