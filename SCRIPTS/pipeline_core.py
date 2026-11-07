"""Incremental acquisition helpers. No network or database writes on import."""
import argparse
import gzip
import hashlib
import html
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import tempfile
import time
import sys
import urllib.request
import urllib.error
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from contextlib import contextmanager

GIB = 1024 ** 3
BUDGET_BYTES = 10_000_000_000
VIDEO_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")
CAPTION_VERSION = "timed-display-carry-v3"


@contextmanager
def closing_database(connection):
    try:
        with connection:
            yield connection
    finally:
        connection.close()


def video_id(name):
    match = re.search(r"\[([A-Za-z0-9_-]{11})\](?:\.[^.]+)*$", name)
    if not match:
        match = re.fullmatch(r"([A-Za-z0-9_-]{11})(?:\.[^.]+)+", name)
    return match[1] if match else None


def strip_caption_markup(text):
    """Strip known caption markup, preserving literal comparisons such as <ami>."""
    if '<' not in text and '&' not in text:
        return text
    timestamp = r'<(?:\d+:)?\d{2}:\d{2}[.,]\d{3}>'
    tags = r'</?(?:c(?:\.[\w.-]+)*|v|lang|b|i|u|ruby|rt|font|span)(?:\s[^<>]*)?>'
    for _ in range(3):
        text=html.unescape(text)
        text=re.sub(r'</?(?:br|p|div)\b[^>]*>', ' ', text, flags=re.I)
        text=re.sub(timestamp,'',text)
        text=re.sub(tags,'',text,flags=re.I)
    return text


def clean_captions_detailed(raw):
    """Keep newly spoken lines, proving adjacent YouTube display carry locally.

    Ordinary adjacent identical cues are preserved. A rolling file must contain
    at least two contiguous carry transitions with fresh inline word timestamps.
    Only a matching plain leading line or its <=51 ms display snapshot is removed.
    """
    # Some legacy Windows copies contain CR CR LF after repeated text writes.
    # Normalize line boundaries before parsing; never change payload words.
    raw=raw.replace('\r\n','\n').replace('\r','\n')
    cues=[]
    timing=r'(?:(?:\d{2,}:)?\d{2}:\d{2}[.,]\d{3})'
    boundaries=list(re.finditer(r'(?m)^'+timing+r'\s*-->\s*'+timing+r'[^\r\n]*(?:\r?\n|$)',raw))
    prefix=raw[:boundaries[0].start()].strip() if boundaries else ''
    numbered=prefix.isdigit() and all(
        raw[a.end():b.start()].strip().splitlines()[-1:]==[str(int(prefix)+n+1)]
        for n,(a,b) in enumerate(zip(boundaries[:3],boundaries[1:4])))
    for n,boundary in enumerate(boundaries):
        lines=raw[boundary.end():boundaries[n+1].start() if n+1<len(boundaries) else len(raw)].splitlines()
        if numbered and n+1<len(boundaries):
            while lines and not lines[-1].strip():lines.pop()
            if lines and lines[-1].strip()==str(int(prefix)+n+1):lines.pop()
        matches = re.findall(r"(?:(\d{2,}):)?(\d{2}):(\d{2})[.,](\d{3})", boundary[0])
        if len(matches) != 2:
            continue
        start, end = [int(h or 0)*3600 + int(m)*60 + int(s) + int(ms)/1000
                      for h, m, s, ms in matches]
        payload=[]
        for line in lines:
            text=' '.join(strip_caption_markup(line).split())
            if text:payload.append(dict(raw=line,text=text,stamped=bool(re.search(r'<(?:\d+:)?\d{2}:\d{2}[.,]\d{3}>',html.unescape(line)))))
        cues.append(dict(start=start,end=end,lines=payload))

    def adjacent(a,b):
        return a['start']<=b['start'] and abs(a['end']-b['start'])<=.051

    def carried(i):
        if i==0:return False
        previous,current=cues[i-1],cues[i]
        return (adjacent(previous,current) and bool(previous['lines']) and len(current['lines'])>=2
                and not current['lines'][0]['stamped']
                and previous['lines'][-1]['text']==current['lines'][0]['text'])

    def snapshot(i):
        if not 0<i<len(cues)-1:return False
        cue=cues[i];payload=cue['lines']
        return (len(payload)==1 and not payload[0]['stamped'] and 0<=cue['end']-cue['start']<=.051
                and cues[i-1]['lines'] and adjacent(cues[i-1],cue) and adjacent(cue,cues[i+1])
                and carried(i+1) and payload[0]['text']==cues[i-1]['lines'][-1]['text'])

    anchors=sum(carried(i) and any(line['stamped'] for line in cue['lines'][1:]) for i,cue in enumerate(cues))
    snapshots=[i for i in range(len(cues)) if snapshot(i)]
    snapshot_texts={cues[i]['lines'][0]['text'] for i in snapshots}
    regressions=sum(b['start']<a['start'] for a,b in zip(cues,cues[1:]))
    rolling=(anchors>=2 or len(snapshot_texts)>=3) and not regressions
    removed=[];output=[];previous=[];previous_end=-1
    for i,cue in enumerate(cues):
        payload=cue['lines']
        if rolling and carried(i):
            removed.append(dict(kind='leading_display_carry',cue=i,start=cue['start'],text=payload[0]['text']))
            payload=payload[1:]
        elif rolling and snapshot(i):
            removed.append(dict(kind='brief_display_snapshot',cue=i,start=cue['start'],text=payload[0]['text']))
            payload=[]
        elif (rolling and i==len(cues)-1 and i>0 and len(payload)==1 and not payload[0]['stamped']
              and 0<=cue['end']-cue['start']<=.051 and cues[i-1]['lines'] and adjacent(cues[i-1],cue)
              and payload[0]['text']==cues[i-1]['lines'][-1]['text']):
            removed.append(dict(kind='terminal_brief_display_snapshot',cue=i,start=cue['start'],text=payload[0]['text']))
            payload=[]
        words=' '.join(line['text'] for line in payload).split()
        overlap = 0
        if cue['start'] < previous_end:
            for n in range(min(len(previous), len(words)), 0, -1):
                if previous[-n:] == words[:n]:
                    overlap = n
                    break
        output.extend(words[overlap:])
        previous, previous_end = words, cue['end']
    return " ".join(output),dict(cues=len(cues),rolling_anchors=anchors,snapshot_anchors=len(snapshots),timestamp_regressions=regressions,
                                 removed_display_lines=len(removed),removed=removed)


def clean_captions(raw):
    return clean_captions_detailed(raw)[0]


def atomic_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    try:
        temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def connect(path, readonly=False):
    # mode=rw avoids silently creating an empty database at an incorrect path.
    db = sqlite3.connect(path.resolve().as_uri() + ("?mode=ro" if readonly else "?mode=rw"), uri=True, timeout=10)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys=ON")
    return db


class Runtime:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.database_dir = self.root / "DATABASE"
        self.config_path = self.database_dir / "local-runtime.json"
        self.config = json.loads(self.config_path.read_text(encoding="utf-8-sig")) if self.config_path.exists() else {}
        self.db = Path(self.config.get("DatabasePath", self.database_dir / "PIPELINE_V15.db"))
        # Until explicitly migrated, preserve the existing Drive working directory.
        self.work = Path(self.config.get("TempPath", self.root / "WORKING_ZONE" / "_TEMP"))
        self.local_root = Path(self.config["LocalRoot"]) if self.config.get("LocalRoot") else None
        self.budget = int(self.config.get("BudgetBytes", BUDGET_BYTES))
        self.archive = self.root / "WORKING_ZONE" / "_CAPTIONS_GZ"
        self.bin = self.root / "RESOURCES" / "BIN"
        policy_file = self.root/'pipeline_policy.json'
        self.policy = json.loads(policy_file.read_text(encoding='utf-8-sig')) if policy_file.exists() else {}

    def usage(self):
        if not self.local_root or not self.local_root.exists():return 0
        # Windows directory enumeration supplies cached file sizes. Avoid three
        # separate filesystem queries per file during every budget check.
        total=0;pending=[self.local_root]
        while pending:
            with os.scandir(pending.pop()) as entries:
                for entry in entries:
                    if entry.is_dir(follow_symlinks=False):pending.append(entry.path)
                    elif entry.is_file():total+=entry.stat().st_size
        return total

    def check_space(self, reservation=0):
        if self.local_root and self.usage() + reservation > self.budget:
            raise RuntimeError("Budget local de 10 Go dépassé : acquisition arrêtée, aucune donnée supprimée.")
        anchor = self.local_root or self.work
        anchor.mkdir(parents=True, exist_ok=True)
        if shutil.disk_usage(anchor).free < reservation + GIB:
            raise RuntimeError("Réserve de 1 Gio indisponible sur le disque de travail.")


def init_state(db):
    db.executescript("""
    CREATE TABLE IF NOT EXISTS pipeline_attempts (
      youtube_id TEXT PRIMARY KEY, attempts INTEGER NOT NULL DEFAULT 0,
      last_error TEXT, next_attempt_at TEXT, updated_at TEXT);
    CREATE TABLE IF NOT EXISTS pipeline_control (key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE IF NOT EXISTS pipeline_channels (
      channel_id INTEGER PRIMARY KEY, youtube_channel_id TEXT, last_discovered_at TEXT);
    CREATE TABLE IF NOT EXISTS pipeline_transcripts (
      youtube_id TEXT PRIMARY KEY, language TEXT, source TEXT, raw_path TEXT,
      sha256 TEXT, cleaner_version TEXT, acquired_at TEXT);
    """)


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


@contextmanager
def acquisition_lock(runtime):
    # OS lock releases automatically after a crash; no process killing or stale
    # PID deletion, and only one network worker per installation.
    runtime.work.mkdir(parents=True, exist_ok=True)
    handle = (runtime.work/"acquisition.lock").open("a+b")
    try:
        if handle.seek(0, 2) == 0:
            handle.write(b"0")
            handle.flush()
        handle.seek(0)
        if os.name == "nt":
            import msvcrt
            msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.close()
        raise RuntimeError("Un autre traitement d'acquisition est actif ; aucun appel YouTube lancé.")
    try:
        yield
    finally:
        handle.close()


def pause_guard(db):
    row = db.execute("SELECT value FROM pipeline_control WHERE key='youtube_pause_until'").fetchone()
    if row and row[0] > now():
        raise RuntimeError(f"YouTube suspendu jusqu'à {row[0]} UTC (HTTP 429).")


def record_failure(db, ident, status, hours):
    due = (datetime.now(timezone.utc) + timedelta(hours=hours)).strftime("%Y-%m-%d %H:%M:%S")
    with db:
        db.execute("UPDATE videos SET status=? WHERE youtube_id=? AND COALESCE(transcript,'')=''", (status, ident))
        db.execute("""INSERT INTO pipeline_attempts VALUES (?,1,?,?,?)
        ON CONFLICT(youtube_id) DO UPDATE SET attempts=attempts+1,
        last_error=excluded.last_error,next_attempt_at=excluded.next_attempt_at,updated_at=excluded.updated_at""",
                   (ident, status, due, now()))


def rate_limit(db, output, ident=None):
    if re.search(r"HTTP(?: Error)?\s*429|Too Many Requests", output, re.I):
        due = (datetime.now(timezone.utc)+timedelta(hours=6)).strftime("%Y-%m-%d %H:%M:%S")
        if ident:
            record_failure(db, ident, "ERR_429_BLOCK", 6)
        with db:
            db.execute("INSERT OR REPLACE INTO pipeline_control VALUES ('youtube_pause_until',?)", (due,))
        raise RuntimeError(f"HTTP 429 : arrêt global, reprise après {due} UTC.")


def yt_args(runtime):
    cookie = runtime.root / "RESOURCES" / "cookie.txt"
    return ["--cookies", str(cookie)] if cookie.exists() else ["--cookies-from-browser", "firefox"]


def run_yt(runtime, db, args, ident=None):
    pause_guard(db)
    process = subprocess.Popen([str(runtime.bin/"yt-dlp.exe"), *yt_args(runtime),
                                "--sleep-requests", "2", "--retries", "2", *args],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, encoding="utf-8", errors="replace")
    deadline = time.monotonic() + getattr(runtime,'network_timeout_seconds',1800)
    try:
        while True:
            try:
                output, errors = process.communicate(timeout=1)
                break
            except subprocess.TimeoutExpired:
                runtime.check_space()
                if time.monotonic() > deadline:
                    raise RuntimeError("Délai yt-dlp dépassé")
    except BaseException:
        process.kill()
        process.communicate()
        raise
    runtime.check_space()
    rate_limit(db, output + errors, ident)
    if process.returncode:
        # Do not echo signed URLs or cookie paths in logs.
        raise RuntimeError("Échec yt-dlp ; tentative différée, détails réseau non publiés.")
    return output


def caption_inventory(runtime):
    """Index legacy filenames once; do not hydrate caption contents during scan."""
    index = {}
    for folder, dirs, files in os.walk(runtime.root):
        dirs[:] = [d for d in dirs if d not in {'.git', 'RESOURCES', '__pycache__'}]
        for name in files:
            match = re.search(r'\.([a-z]{2}(?:-[A-Za-z0-9]+)?)\.(vtt|srt)(\.gz)?$', name)
            ident = video_id(name)
            if ident and re.search(r'\.(vtt|srt)(\.gz)?$',name,re.I):
                index.setdefault((ident, match[1] if match else 'und'), []).append(Path(folder)/name)
    return index


def local_caption(index, ident, languages):
    for lang in languages:
        for path in index.get((ident, lang), []):
            try:
                payload = path.read_bytes()
                raw = (gzip.decompress(payload) if path.suffix == '.gz' else payload).decode('utf-8-sig')
                if clean_captions(raw):
                    return lang, raw, 'srt' if '.srt' in path.suffixes else 'vtt'
            except (OSError, UnicodeError, EOFError):
                # A damaged local source is retained; try another source or network.
                continue
    return None


def sync(runtime, channel=None, force=False, limit=500, offline=False):
    if not 1 <= limit <= 500:
        raise ValueError('La synchronisation est limitée à 1–500 vidéos par lancement')
    with closing_database(connect(runtime.db)) as db:
        init_state(db)
        pause_guard(db)
        sql = """SELECT v.youtube_id,c.lang_config FROM videos v JOIN channels c ON c.id=v.channel_id
        LEFT JOIN pipeline_attempts a ON a.youtube_id=v.youtube_id
        WHERE COALESCE(v.transcript,'')='' AND COALESCE(v.status,'')!='PREMIUM' """
        args = []
        if channel:
            sql += " AND c.prefix=?"
            args.append(channel)
        if not force:
            sql += " AND (a.next_attempt_at IS NULL OR a.next_attempt_at<=?)"
            args.append(now())
        rows = db.execute(sql + " ORDER BY v.upload_date DESC,v.id LIMIT ?", [*args,limit]).fetchall()
        runtime.archive.mkdir(parents=True, exist_ok=True)
        runtime.work.mkdir(parents=True, exist_ok=True)
        captions = caption_inventory(runtime) if rows else {}
        for row in rows:
            ident = row["youtube_id"]
            if not VIDEO_ID.fullmatch(ident):
                raise ValueError("ID YouTube invalide dans la base")
            langs = ["en-orig", "en", "fr-orig", "fr"] if row["lang_config"] == "en" else ["fr-orig", "fr", "en-orig", "en"]
            cached = local_caption(captions, ident, langs)
            if offline and not cached:
                raise RuntimeError(f'{ident}: aucun sous-titre local exploitable ; aucun appel réseau en mode hors ligne')
            try:
                if cached:
                    lang, raw, caption_format = cached
                    archive = runtime.archive/f"{ident}.{lang}.{caption_format}.gz"
                    source = "cached-captions"
                else:
                    runtime.check_space(64*1024**2)
                    url = f"https://www.youtube.com/watch?v={ident}"
                    info = json.loads(run_yt(runtime, db, ["--skip-download", "--dump-single-json", url], ident))
                    human, automatic = info.get("subtitles", {}), info.get("automatic_captions", {})
                    selected = next(((lang, human[lang], "youtube-human") for lang in langs if human.get(lang)), None)
                    if not selected:
                        selected = next(((lang, automatic[lang], "youtube-auto") for lang in langs if automatic.get(lang)), None)
                    if not selected:
                        record_failure(db, ident, "ERR_NO_EN_FR", 168)
                        continue
                    lang, formats, source = selected
                    fmt = next((f for f in formats if f.get("ext") == "vtt"), None)
                    if not fmt:
                        record_failure(db, ident, "ERR_NO_EN_FR", 168)
                        continue
                    # Reuse already extracted metadata in yt-dlp, avoiding a second video extraction.
                    info["subtitles"] = {lang: formats}
                    info["automatic_captions"] = {}
                    with tempfile.TemporaryDirectory(dir=runtime.work, prefix="subs-") as work:
                        metadata = Path(work)/"info.json"
                        metadata.write_text(json.dumps(info), encoding="utf-8")
                        run_yt(runtime, db, ["--load-info-json", str(metadata), "--skip-download", "--write-subs",
                                           "--sub-langs", lang, "--sub-format", "vtt", "--sleep-subtitles", "5",
                                           "--output", str(Path(work)/"caption.%(ext)s")], ident)
                        files = list(Path(work).glob("*.vtt"))
                        if len(files) != 1:
                            raise RuntimeError("Sous-titres VTT absents ou ambigus")
                        raw = files[0].read_text(encoding="utf-8-sig")
                    archive = runtime.archive/f"{ident}.{lang}.vtt.gz"
                temporary = archive.with_suffix(".gz.tmp")
                temporary.write_bytes(gzip.compress(raw.encode("utf-8"), mtime=0))
                if gzip.decompress(temporary.read_bytes()).decode("utf-8") != raw:
                    raise RuntimeError("Vérification de l'archive impossible")
                os.replace(temporary, archive)
                text = clean_captions(raw)
                if not text.strip():
                    record_failure(db, ident, "ERR_TOO_SHORT", 168)
                    continue
                with db:
                    updated = db.execute("UPDATE videos SET transcript=?,status=? WHERE youtube_id=? AND COALESCE(transcript,'')=''",
                                         (text, f"SUCCESS ({lang})", ident)).rowcount
                    if updated:
                        db.execute("INSERT OR REPLACE INTO pipeline_transcripts VALUES (?,?,?,?,?,?,?)",
                                   (ident, lang, source, str(archive), hashlib.sha256(raw.encode()).hexdigest(), CAPTION_VERSION, now()))
                    db.execute("DELETE FROM pipeline_attempts WHERE youtube_id=?", (ident,))
                print(f"{ident}: transcription enregistrée, source compressée conservée")
            except (OSError, ValueError, subprocess.TimeoutExpired, RuntimeError) as error:
                # A global rate limit must stop the entire queue.
                pause_guard(db)
                record_failure(db, ident, "ERR_DL_FAIL", 24)
                print(f"{ident}: {error}")
            runtime.check_space()
            time.sleep(5)


def discover(runtime, channel=None, playlist_limit=50):
    if not 1<=playlist_limit<=50:raise ValueError('Discovery limit must be between 1 and 50')
    with closing_database(connect(runtime.db)) as db:
        init_state(db)
        pause_guard(db)
        channels = db.execute("SELECT * FROM channels" + (" WHERE prefix=?" if channel else ""), (channel,) if channel else ()).fetchall()
        for chan in channels:
            stored = db.execute("SELECT youtube_channel_id FROM pipeline_channels WHERE channel_id=?", (chan["id"],)).fetchone()
            match = re.search(r"channel/(UC[A-Za-z0-9_-]{22})", chan["yt_url"] or "")
            cid = stored[0] if stored and stored[0] else match[1] if match else None
            entries = None
            if cid:
                try:
                    request = urllib.request.Request(f"https://www.youtube.com/feeds/videos.xml?channel_id={cid}", headers={"User-Agent": "NotebookLM-Pipeline/16"})
                    with urllib.request.urlopen(request, timeout=30) as response:
                        feed = ET.fromstring(response.read(2*1024**2))
                    entries = [{"id": e.findtext("{http://www.youtube.com/xml/schemas/2015}videoId"),
                                "title": e.findtext("{http://www.w3.org/2005/Atom}title"),
                                "upload_date": (e.findtext("{http://www.w3.org/2005/Atom}published") or "")[:10].replace("-", "")}
                               for e in feed.findall("{http://www.w3.org/2005/Atom}entry")]
                except urllib.error.HTTPError as error:
                    rate_limit(db, f"HTTP {error.code}")
                except (OSError, ET.ParseError):
                    pass
            if entries is None:
                # Bounded catch-up, not a complete historical inventory.
                output = run_yt(runtime, db, ["--flat-playlist", "--playlist-end", str(playlist_limit), "--dump-single-json", chan["yt_url"]])
                info = json.loads(output)
                cid = info.get("channel_id") or cid
                entries = info.get("entries", [])
            inserted = 0
            with db:
                for entry in entries:
                    ident = entry.get("id") or ""
                    if not VIDEO_ID.fullmatch(ident):
                        continue
                    inserted += db.execute("INSERT OR IGNORE INTO videos(channel_id,youtube_id,title,upload_date,status) VALUES(?,?,?,?, 'PENDING')",
                                           (chan["id"], ident, entry.get("title") or "", entry.get("upload_date") or "")).rowcount
                db.execute("INSERT OR REPLACE INTO pipeline_channels VALUES (?,?,?)", (chan["id"], cid, now()))
            print(f"{chan['prefix']}: {inserted} nouvelles vidéos")
            time.sleep(2)


def audit(runtime):
    # A single DB scan, no content hydration of media, no deletion.
    with closing_database(connect(runtime.db, readonly=True)) as db:
        videos = {r[0]: (r[1], r[2]) for r in db.execute("SELECT youtube_id,status,length(trim(COALESCE(transcript,''))) FROM videos")}
    candidates, sizes = [], {}
    scan_errors = []
    pending = [runtime.root]
    visited = 0
    while pending:
        folder = pending.pop()
        try:
            with os.scandir(folder) as entries:
                files = []
                for entry in entries:
                    if entry.is_symlink():
                        continue
                    if entry.is_dir(follow_symlinks=False):
                        if entry.name not in {'.git','__pycache__'}:
                            pending.append(Path(entry.path))
                    elif entry.is_file(follow_symlinks=False):
                        # Windows caches size and timestamps in the directory entry;
                        # avoid one remote stat request per file on Drive.
                        files.append((Path(entry.path), entry.stat(follow_symlinks=False)))
        except OSError as error:
            scan_errors.append(str(error))
            continue
        for path, stat in files:
            name = path.name
            size = stat.st_size
            visited += 1
            if visited % 10000 == 0:
                print(f"Inventaire : {visited} fichiers, aucune lecture de contenu média", flush=True)
            top = path.relative_to(runtime.root).parts[0]
            sizes[top] = sizes.get(top, 0) + size
            if path.suffix.lower() not in {".mp4", ".webm", ".mp3", ".m4a", ".mkv", ".opus", ".wav"}:
                continue
            ident = video_id(name)
            status, length = videos.get(ident, (None, 0))
            candidate = bool(length and status and status.startswith("SUCCESS"))
            candidates.append(dict(FileName=name, SizeMB=round(size/1024**2, 2), Path=path.as_posix(),
                                   YoutubeId=ident, SafeToPurge=candidate, DbStatus=status, TranscriptLen=length,
                                   RequiresBackupVerification=True, SizeBytes=size, ModifiedNs=stat.st_mtime_ns))
    stats = {name: round(size/1024**2, 2) for name, size in sizes.items()}
    stats["Total_Project_MB"] = round(sum(sizes.values())/1024**2, 2)
    stats["Wasted_MB"] = round(sum(c["SizeMB"] for c in candidates if c["SafeToPurge"]), 2)
    atomic_json(runtime.database_dir/"storage_report.json", dict(Stats=stats, Candidates=candidates,
                GeneratedAt=now(), Complete=not scan_errors, Errors=scan_errors,
                Scope="Logical file sizes on Drive, not physical local disk usage. Candidates require verified backup before deletion."))
    print(f"Audit terminé : {len(candidates)} médias ; aucune suppression.")


def migrate(runtime, local_root=None):
    if runtime.config:
        raise RuntimeError("Une configuration locale existe déjà ; migration non répétée.")
    key = hashlib.sha256(str(runtime.root).casefold().encode()).hexdigest()[:12]
    target = Path(local_root) if local_root else Path(os.environ["LOCALAPPDATA"])/"NotebookLM-Pipeline"/key
    target = target.resolve()
    if target == runtime.root or runtime.root in target.parents:
        raise ValueError("Le répertoire local doit être distinct du projet Drive")
    source = runtime.db
    source_size = source.stat().st_size
    required = source_size * 2 + GIB
    if required > BUDGET_BYTES:
        raise RuntimeError("Base trop volumineuse pour migrer avec vérification dans le budget de 10 Go")
    target.mkdir(parents=True, exist_ok=True)
    if any(target.iterdir()):
        raise RuntimeError("Le répertoire de migration doit être vide")
    if shutil.disk_usage(target).free < required:
        raise RuntimeError("Espace insuffisant pour la migration")
    temporary = target/"PIPELINE_V15.migrating.db"
    destination = target/"PIPELINE_V15.db"
    # Caller must first stop project workers. Do not reserve a write lock on
    # Drive: some providers block a second reader while such a lock is held.
    last_progress = [time.monotonic()]
    started = time.monotonic()
    def progress(status, remaining, total):
        if time.monotonic()-started > 1800:
            raise RuntimeError("Migration trop lente : arrêt après 30 minutes, source conservée")
        if status in (sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED) and time.monotonic()-started > 30:
            raise RuntimeError("Base verrouillée : migration annulée sans activer la copie")
        if time.monotonic()-last_progress[0] >= 5:
            print(f"Copie SQLite : {total-remaining}/{total} pages", flush=True)
            last_progress[0] = time.monotonic()
    try:
        with closing_database(connect(source, readonly=True)) as src:
            revision = src.execute("PRAGMA data_version").fetchone()[0]
            journal = src.execute("PRAGMA journal_mode").fetchone()[0]
            if journal.lower() == "wal":
                # Main-file copying is unsafe in WAL mode: use SQLite's API.
                with closing_database(sqlite3.connect(temporary)) as dst:
                    src.backup(dst, pages=8192, progress=progress)
            else:
                # In rollback-journal mode, a SQLite SHARED read transaction
                # prevents main-file commits while a sequential Drive read avoids
                # thousands of small remote page reads. Never copy a WAL database.
                src.execute("BEGIN")
                src.execute("SELECT count(*) FROM sqlite_master").fetchone()
                with source.open("rb") as incoming, temporary.open("xb") as outgoing:
                    transferred = 0
                    while block := incoming.read(4*1024**2):
                        outgoing.write(block)
                        transferred += len(block)
                        progress(0, max(0, (source_size-transferred)//4096), source_size//4096)
                    outgoing.flush()
                    os.fsync(outgoing.fileno())
                src.rollback()
            with closing_database(connect(temporary, readonly=True)) as dst:
                if dst.execute("PRAGMA quick_check").fetchone()[0] != "ok":
                    raise RuntimeError("La sauvegarde SQLite ne passe pas quick_check")
                for table in ("videos", "channels"):
                    if src.execute(f"SELECT count(*) FROM {table}").fetchone()[0] != dst.execute(f"SELECT count(*) FROM {table}").fetchone()[0]:
                        raise RuntimeError("Comptages différents après sauvegarde")
            if src.execute("PRAGMA data_version").fetchone()[0] != revision:
                raise RuntimeError("La source a changé pendant la migration : activation annulée")
        os.replace(temporary, destination)
        (target/"cache").mkdir()
        config = dict(DatabasePath=str(destination), TempPath=str(target/"cache"),
                      LocalRoot=str(target), BudgetBytes=BUDGET_BYTES,
                      SourceDatabase=str(source), ActivatedAt=now())
        atomic_json(runtime.config_path, config)
        print(f"Base locale vérifiée : {destination}. Source conservée sur Drive. Budget : 10 Go.")
    finally:
        temporary.unlink(missing_ok=True)


def snapshot_database(runtime, marker):
    proof = json.loads(marker.read_text(encoding="utf-8"))
    name = proof.get("filename", "")
    if Path(name).name != name or not name:
        raise ValueError("Nom de sauvegarde invalide")
    source = marker.with_name(name)
    if not proof.get("verified") or proof.get("owner") != "notebooklm-pipeline":
        raise ValueError("Sauvegarde non vérifiée")
    if not name.endswith(".gz"):
        return source
    runtime.work.mkdir(parents=True, exist_ok=True)
    cached = runtime.work/("deletion-verified-"+proof["sha256"]+".db")
    def digest(path):
        h = hashlib.sha256()
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(8*1024**2), b""): h.update(block)
        return h.hexdigest()
    if cached.exists() and cached.stat().st_size == proof["size"] and digest(cached) == proof["sha256"]:
        return cached
    runtime.check_space(proof["size"]+64*1024**2)
    with tempfile.NamedTemporaryFile(dir=runtime.work, suffix=".restoring", delete=False) as output:
        temporary = Path(output.name)
        try:
            with gzip.open(source,"rb") as incoming:
                shutil.copyfileobj(incoming,output,8*1024**2)
        except BaseException:
            output.close(); temporary.unlink(missing_ok=True); raise
    try:
        if temporary.stat().st_size != proof["size"] or digest(temporary) != proof["sha256"]:
            raise ValueError("Sauvegarde restaurée différente")
        os.replace(temporary,cached)
    finally:
        temporary.unlink(missing_ok=True)
    return cached


def backup(runtime):
    folder = runtime.database_dir/"snapshots"
    folder.mkdir(parents=True, exist_ok=True)
    path = folder/("PIPELINE_"+datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%f")+".db")
    temporary = path.with_suffix(".db.tmp")
    runtime.work.mkdir(parents=True,exist_ok=True)
    runtime.check_space(runtime.db.stat().st_size+64*1024**2)
    try:
        # Build and check locally, then stream to Drive in large blocks. This
        # avoids thousands of small remote SQLite writes.
        with tempfile.TemporaryDirectory(dir=runtime.work,prefix='snapshot-') as work:
            staged=Path(work)/'snapshot.db'
            with closing_database(connect(runtime.db, readonly=True)) as src, closing_database(sqlite3.connect(staged)) as dst:
                src.backup(dst,pages=8192)
                if dst.execute("PRAGMA quick_check").fetchone()[0] != "ok":
                    raise RuntimeError("Échec de vérification de la sauvegarde")
            digest=hashlib.sha256()
            with staged.open('rb') as incoming,temporary.open('xb') as outgoing:
                for block in iter(lambda:incoming.read(4*1024**2),b''):
                    outgoing.write(block);digest.update(block)
                outgoing.flush();os.fsync(outgoing.fileno())
            copied=hashlib.sha256()
            with temporary.open('rb') as incoming:
                for block in iter(lambda:incoming.read(4*1024**2),b''):copied.update(block)
            if copied.digest()!=digest.digest():raise RuntimeError('La copie Drive diffère de la sauvegarde vérifiée')
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)
    atomic_json(path.with_suffix('.verified.json'), dict(owner='notebooklm-pipeline', verified=True,
                filename=path.name, size=path.stat().st_size, sha256=digest.hexdigest(), verified_at=now()))
    if runtime.policy.get('compress_verified_backups', False):
        marker = path.with_suffix('.verified.json')
        compressed = path.with_suffix('.db.gz')
        partial = compressed.with_suffix('.gz.tmp')
        try:
            with path.open('rb') as incoming, gzip.open(partial, 'wb') as outgoing:
                shutil.copyfileobj(incoming, outgoing, 8*1024**2)
            restored_digest = hashlib.sha256()
            with gzip.open(partial, 'rb') as incoming:
                for block in iter(lambda: incoming.read(8*1024**2), b''):
                    restored_digest.update(block)
            if restored_digest.hexdigest() != digest.hexdigest():
                raise ValueError('Sauvegarde compressée différente')
            os.replace(partial, compressed)
            proof = json.loads(marker.read_text(encoding='utf8'))
            proof.update(filename=compressed.name, compressed_size=compressed.stat().st_size, compression='gzip')
            atomic_json(marker, proof)
            path.unlink()
            path = compressed
        finally:
            partial.unlink(missing_ok=True)
    retention = int(runtime.policy.get('verified_backup_retention', 3))
    if retention < 1:
        raise ValueError('Au moins une sauvegarde vérifiée doit être conservée')
    verified = []
    for marker in folder.glob('PIPELINE_*.verified.json'):
        try:
            proof = json.loads(marker.read_text(encoding='utf-8'))
            candidate = marker.with_name(proof.get('filename','invalid'))
            if (proof.get('owner') == 'notebooklm-pipeline' and proof.get('verified') is True
                    and candidate.parent == folder and proof.get('filename') == candidate.name and candidate.is_file()
                    and not candidate.is_symlink() and candidate.stat().st_size == proof.get('compressed_size',proof.get('size'))
                    and re.fullmatch(r'[a-f0-9]{64}', proof.get('sha256',''))):
                verified.append((candidate,marker))
        except (OSError,ValueError):
            continue
    for old, marker in sorted(verified,reverse=True)[retention:]:
        old.unlink()
        marker.unlink()
    retained_hashes = {json.loads(marker.read_text(encoding='utf8'))['sha256']
                       for _, marker in sorted(verified, reverse=True)[:retention]}
    for cached in runtime.work.glob('deletion-verified-*.db'):
        match = re.fullmatch(r'deletion-verified-([a-f0-9]{64})\.db', cached.name)
        if not match or match[1] in retained_hashes or cached.is_symlink():
            continue
        if cached.resolve().parent != runtime.work.resolve():
            continue
        if any(Path(str(cached)+suffix).exists() for suffix in ('-wal', '-shm', '-journal')):
            continue
        try:
            cached.unlink()
        except OSError:
            pass
    print(f"Sauvegarde SQLite vérifiée : {path}. Rétention : {retention} sauvegardes gérées.")


def quality_exclusions(runtime, db):
    """Only exclude the exact checked text; a later corrected text is eligible."""
    if not db.execute("SELECT 1 FROM sqlite_master WHERE name='pipeline_quality_exclusions'").fetchone():return {}
    rules=db.execute('SELECT * FROM pipeline_quality_exclusions').fetchall()
    result={}
    for rule in rules:
        ident=rule['youtube_id']
        if not VIDEO_ID.fullmatch(ident) or not re.fullmatch(r'[a-f0-9]{64}',rule['transcript_sha256']):
            raise ValueError('Invalid quality exclusion')
        row=db.execute('SELECT * FROM videos WHERE youtube_id=?',(ident,)).fetchone()
        if row and hashlib.sha256((row['transcript'] or '').encode('utf8')).hexdigest()==rule['transcript_sha256']:
            result[ident]=dict(row,quality_reason=rule['reason'])
    return result


def packs(runtime, word_limit=200000, channel=None):
    from caption_quality import MARKERS
    if word_limit < 1:
        raise ValueError("La limite de mots doit être positive")
    base = runtime.root/"assets"
    if channel:
        base = base/'pilot-packs'/hashlib.sha256(channel.encode()).hexdigest()[:12]
    base.mkdir(parents=True,exist_ok=True)
    output = base/"packs"
    generation = base/("packs-build-"+str(time.time_ns()))
    generation.mkdir()
    manifest = []
    try:
        with closing_database(connect(runtime.db, readonly=True)) as db:
            excluded=quality_exclusions(runtime,db)
            channels = db.execute("SELECT id,prefix FROM channels"+(' WHERE prefix=?' if channel else '')+' ORDER BY id', (channel,) if channel else ()).fetchall()
            if channel and not channels:
                raise ValueError('Chaîne inconnue')
            for chan in channels:
                # Numeric channel ID prevents filename collisions and path traversal.
                label = re.sub(r"[^\w.-]+", "_", chan["prefix"]).strip(". ")[:80] or "channel"
                count, number, buffer, ids = 0, 1, [], []
                def flush():
                    name = f"{chan['id']}_{label}_PACK_{number}.txt"
                    (generation/name).write_text("\n\n".join(buffer)+"\n", encoding="utf-8")
                    manifest.append(dict(file=name, videos=list(ids), words=count))
                rows = db.execute("SELECT youtube_id,title,upload_date,transcript FROM videos WHERE channel_id=? AND trim(COALESCE(transcript,''))!='' ORDER BY upload_date,id", (chan["id"],))
                for row in rows:
                    if row['youtube_id'] in excluded:continue
                    if MARKERS['downloader_metadata'].search(row['transcript']):
                        excluded[row['youtube_id']] = dict(quality_reason='Downloader metadata instead of spoken transcript')
                        continue
                    header = f"--- VIDEO: {row['title']} ({row['upload_date']}) https://www.youtube.com/watch?v={row['youtube_id']} ---"
                    # Split long videos, count headers as well, keep exact source IDs.
                    words = row["transcript"].split()
                    header_words = len(header.split())
                    if header_words >= word_limit:
                        raise ValueError("Titre plus long que la limite du pack")
                    while words:
                        capacity = word_limit-count-header_words
                        if capacity <= 0:
                            flush(); number += 1; buffer, ids, count = [], [], 0
                            capacity = word_limit-header_words
                        take = min(capacity, len(words))
                        buffer.append(header+"\n"+" ".join(words[:take]))
                        ids.append(row["youtube_id"])
                        count += header_words+take
                        words = words[take:]
                if buffer:
                    flush()
        atomic_json(generation/"manifest.json", dict(generated_by="pipeline_core", generated_at=now(), packs=manifest,
                    quality_exclusions=[dict(youtube_id=k,reason=v['quality_reason']) for k,v in excluded.items()]))
        # Old packs remain available if any generation or DB query failed above.
        previous = base/("packs-previous-"+str(time.time_ns()))
        if output.exists():
            output.rename(previous)
        try:
            generation.rename(output)
        except BaseException:
            if previous.exists():
                previous.rename(output)
            raise
        print(f"{len(manifest)} packs générés ; version précédente conservée sur Drive.")
    finally:
        if generation.exists():
            shutil.rmtree(generation)


def transcribe(runtime, model_name="base", limit=1):
    """Audio-first, one bounded download at a time, no intermediate video."""
    if runtime.policy.get('audio_transcription_mode') == 'deferred':
        raise RuntimeError('Transcription audio différée : noter les vidéos concernées pour un test ultérieur.')
    if limit < 1:
        raise ValueError("La limite doit être positive")
    try:
        import whisper
    except ImportError as error:
        raise RuntimeError("Whisper n'est pas installé. Voir STORAGE_AND_PIPELINE.md avant d'installer les dépendances audio.") from error
    ffmpeg_dir = str(runtime.bin)
    os.environ["PATH"] = ffmpeg_dir+os.pathsep+os.environ.get("PATH", "")
    runtime.work.mkdir(parents=True, exist_ok=True)
    model_dir = runtime.root/"RESOURCES"/"whisper-models"
    model_dir.mkdir(parents=True, exist_ok=True)
    # Model files stay on Drive rather than consuming an untracked local cache.
    model = whisper.load_model(model_name, download_root=str(model_dir))
    recovery = runtime.root/"_RECOVERY_TRANSCRIPTS"
    recovery.mkdir(exist_ok=True)
    # Inventory filenames once, without copying or reading media content.
    media = {}
    for folder, dirs, files in os.walk(runtime.root):
        dirs[:] = [d for d in dirs if d not in {".git", "RESOURCES"}]
        for name in files:
            if Path(name).suffix.lower() in {".m4a", ".mp3", ".opus", ".wav", ".mp4", ".webm", ".mkv"}:
                ident = video_id(name)
                if ident:
                    candidate = Path(folder)/name
                    def preference(file):
                        return (file.suffix.lower() not in {'.m4a','.mp3','.opus','.wav'}, file.stat().st_size)
                    if ident not in media or preference(candidate) < preference(media[ident]):
                        media[ident] = candidate
    with closing_database(connect(runtime.db)) as db:
        init_state(db)
        rows = db.execute("SELECT youtube_id FROM videos WHERE COALESCE(transcript,'')='' AND COALESCE(status,'') IN ('NO_SUBS','ERR_NO_EN_FR','ERR_TOO_SHORT','ERR_DL_FAIL') ORDER BY upload_date DESC LIMIT ?", (limit,)).fetchall()
        for row in rows:
            ident = row[0]
            if not VIDEO_ID.fullmatch(ident):
                raise ValueError("ID invalide")
            # 512 MiB maximum download, plus DB headroom under the shared budget.
            runtime.check_space(768*1024**2)
            with tempfile.TemporaryDirectory(dir=runtime.work, prefix="audio-") as work:
                source = media.get(ident)
                if source and source.stat().st_size > 512*1024**2:
                    print(f"{ident}: média existant >512 Mio ; traitement différé, préférez un audio plus léger.")
                    continue
                if source is None:
                    run_yt(runtime, db, ["--format", "bestaudio[filesize<=512M]/bestaudio[filesize_approx<=512M]",
                           "--max-filesize", "512M", "--no-playlist", "--output", str(Path(work)/f"{ident}.%(ext)s"),
                           f"https://www.youtube.com/watch?v={ident}"], ident)
                    found = [f for f in Path(work).iterdir() if f.suffix.lower() in {".m4a", ".mp3", ".opus", ".webm", ".ogg"}]
                    if len(found) != 1:
                        raise RuntimeError("Audio absent, trop volumineux ou ambigu")
                    source = found[0]
                result = model.transcribe(str(source), fp16=False, verbose=False)
                text = result["text"].strip()
                if not text:
                    record_failure(db, ident, "ERR_TOO_SHORT", 168)
                    continue
                # Preserve timestamped result on Drive before committing to SQLite.
                artifact = recovery/f"[{ident}].whisper.json"
                atomic_json(artifact, dict(result, model=model_name, acquired_at=now()))
                with db:
                    updated = db.execute("UPDATE videos SET transcript=?,status='SUCCESS (WHISPER)' WHERE youtube_id=? AND COALESCE(transcript,'')=''", (text, ident)).rowcount
                    if updated:
                        db.execute("INSERT OR REPLACE INTO pipeline_transcripts VALUES (?,?,?,?,?,?,?)", (ident, result.get("language"), "whisper-"+model_name, str(artifact), hashlib.sha256(text.encode()).hexdigest(), "whisper-v1", now()))
                        db.execute("DELETE FROM pipeline_attempts WHERE youtube_id=?", (ident,))
                print(f"{ident}: transcription audio enregistrée ; média existant conservé.")


def import_transcripts(runtime):
    from caption_quality import MARKERS
    source = runtime.root/"_RECOVERY_TRANSCRIPTS"
    source.mkdir(exist_ok=True)
    archive = source/"_ARCHIVE"
    with closing_database(connect(runtime.db)) as db:
        init_state(db)
        # Only immediate files; never recursively re-import archived results.
        for path in source.iterdir():
            if not path.is_file() or path.suffix.lower() not in {".txt", ".srt", ".vtt"}:
                continue
            ident = video_id(path.name)
            if not ident:
                continue
            text = path.read_text(encoding="utf-8-sig")
            if MARKERS['downloader_metadata'].search(text):
                print(f'{ident}: métadonnées détectées ; source conservée pour examen.')
                continue
            if path.suffix.lower() in {".srt", ".vtt"}:
                text = clean_captions(text)
            text = text.strip()
            if not text:
                print(f"{ident}: texte vide, fichier conservé")
                continue
            with db:
                changed = db.execute("UPDATE videos SET transcript=?,status='SUCCESS (RECOVERY)' WHERE youtube_id=? AND COALESCE(transcript,'')=''", (text, ident)).rowcount
                if changed:
                    db.execute("DELETE FROM pipeline_attempts WHERE youtube_id=?", (ident,))
            if changed:
                archive.mkdir(exist_ok=True)
                destination = archive/path.name
                if destination.exists():
                    destination = archive/(path.stem+"-"+str(time.time_ns())+path.suffix)
                # Source transcript and media are never deleted on a zero-row UPDATE.
                path.rename(destination)
                print(f"{ident}: importé ; média conservé")
            else:
                print(f"{ident}: absent du catalogue ou déjà transcrit ; fichier conservé")


def purge(runtime, file):
    """Explicit single-file action: fresh inventory plus matching SQLite snapshot."""
    if runtime.policy.get('media_deletion_requires_batch_approval',False):
        raise ValueError('Suppression désactivée : présenter un lot et obtenir son accord explicite avant toute purge')
    requested = Path(file)
    if not requested.is_absolute() or not requested.is_file() or requested.is_symlink():
        raise ValueError("Fichier média absent ou lien interdit")
    resolved = requested.resolve()
    if not resolved.is_relative_to(runtime.root):
        raise ValueError("Fichier hors du projet")
    if resolved.suffix.lower() not in {".mp4", ".webm", ".mp3", ".m4a", ".mkv", ".opus", ".wav"}:
        raise ValueError("Extension interdite")
    report_path = runtime.database_dir/"storage_report.json"
    report = json.loads(report_path.read_text(encoding="utf-8-sig"))
    if not report.get("Complete") or time.time()-report_path.stat().st_mtime > 3600:
        raise ValueError("Relancez un audit complet avant de purger (validité : une heure)")
    candidate = next((c for c in report["Candidates"] if Path(c["Path"]).resolve() == resolved and c["SafeToPurge"]), None)
    ident = video_id(resolved.name)
    if not candidate or candidate["YoutubeId"] != ident:
        raise ValueError("Fichier absent des candidats vérifiés")
    snapshots = sorted((runtime.database_dir/"snapshots").glob("*.verified.json"), reverse=True)
    if not snapshots:
        raise ValueError("Créez une sauvegarde SQLite vérifiée avant la purge")
    with closing_database(connect(runtime.db, True)) as db, closing_database(connect(snapshot_database(runtime,snapshots[0]), True)) as saved:
        current = db.execute("SELECT transcript FROM videos WHERE youtube_id=?", (ident,)).fetchone()
        previous = saved.execute("SELECT transcript FROM videos WHERE youtube_id=?", (ident,)).fetchone()
        if not current or not previous or not current[0] or current[0] != previous[0]:
            raise ValueError("La sauvegarde ne contient pas la transcription active à l'identique")
        raw_digest=None
        if runtime.policy.get('deletion_requires_reprocessable_source',False):
            metadata_exists=db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='pipeline_transcripts'").fetchone()
            metadata=db.execute('SELECT raw_path,sha256 FROM pipeline_transcripts WHERE youtube_id=?',(ident,)).fetchone() if metadata_exists else None
            if not metadata or not metadata[0]:raise ValueError('Source horodatée et provenance non vérifiées : média conservé')
            source=Path(metadata[0])
            if not source.is_file() or not source.name.lower().endswith(('.vtt','.srt','.vtt.gz','.srt.gz')):
                raise ValueError('Source VTT/SRT retraitable introuvable : média conservé')
            payload=source.read_bytes()
            raw=gzip.decompress(payload) if source.suffix=='.gz' else payload
            raw_digest=hashlib.sha256(raw).hexdigest()
            if raw_digest!=metadata[1] or not clean_captions(raw.decode('utf-8-sig')):
                raise ValueError('Source horodatée invalide ou empreinte différente : média conservé')
        if runtime.policy.get('deletion_requires_quality_review',False):
            receipt_path=runtime.database_dir/'quality_approvals'/f'{ident}.json'
            if not receipt_path.is_file():raise ValueError('Validation humaine de la qualité manquante : média conservé')
            receipt=json.loads(receipt_path.read_text(encoding='utf-8-sig'))
            if (receipt.get('approved_by_user') is not True or receipt.get('transcript_sha256')!=hashlib.sha256(current[0].encode('utf-8')).hexdigest()
                    or (raw_digest and receipt.get('raw_sha256')!=raw_digest)):
                raise ValueError('La validation qualité ne correspond plus aux données actives : média conservé')
    # Reject changed media since inventory without reading/hydrating its contents.
    current_stat = resolved.stat()
    if current_stat.st_size != candidate.get("SizeBytes") or current_stat.st_mtime_ns != candidate.get("ModifiedNs"):
        raise ValueError("Le fichier a changé depuis l'audit")
    resolved.unlink()
    print(json.dumps(dict(status="success", message="Média supprimé ; transcription active et sauvegardée conservées."), ensure_ascii=False))


def list_caption_followup(runtime, channel=None):
    query='''SELECT v.youtube_id,v.title,v.status,c.prefix AS channel FROM videos v
    JOIN channels c ON c.id=v.channel_id WHERE trim(COALESCE(v.transcript,''))='' '''
    with closing_database(connect(runtime.db,True)) as db:
        rows=db.execute(query+(' AND c.prefix=?' if channel else '')+' ORDER BY c.prefix,v.upload_date DESC',(channel,) if channel else ()).fetchall()
    counts={};items=[]
    for row in rows:
        status=row['status'] or 'PENDING'
        if status=='NO_SUBS': category='no_subtitles_reported'
        elif status.startswith('ERR_NO_EN_FR'): category='no_fr_en_subtitles_reported'
        elif status.startswith('ERR_TOO_SHORT'): category='caption_content_to_review'
        elif status=='PREMIUM': category='restricted_access'
        elif '429' in status: category='rate_limited'
        elif status.startswith('ERR_DL_FAIL'): category='download_failed'
        else: category='not_yet_verified'
        counts[category]=counts.get(category,0)+1
        items.append(dict(row,category=category,action='defer_audio_test' if category in ('no_subtitles_reported','no_fr_en_subtitles_reported') else 'check_subtitles_first'))
    report=dict(generated_at=now(),channel=channel,counts=counts,items=items,audio_transcription='deferred',
                note='Un échec de récupération ne prouve pas une absence de sous-titres. ERR_NO_EN_FR ne concerne que les langues FR/EN.')
    destination=runtime.database_dir/'pilot_reports'
    destination.mkdir(parents=True,exist_ok=True)
    suffix=hashlib.sha256(channel.encode()).hexdigest()[:12] if channel else 'all'
    atomic_json(destination/f'caption-followup-{suffix}.json',report)
    markdown='# Suivi des vidéos sans transcription\n\nAucune transcription audio déclenchée. Les états historiques restent à confirmer ; un échec réseau n’est pas une absence de sous-titres.\n\n| Catégorie | Vidéos |\n|---|---:|\n'
    for key,count in sorted(counts.items()):markdown+=f'| {key} | {count} |\n'
    markdown+='\n## Tests audio différés\n\n'
    deferred=[item for item in items if item['action']=='defer_audio_test']
    for item in deferred:
        title=item['title'].replace('\n',' ').replace('|','\\|')
        markdown+=f"- [{item['youtube_id']}](https://www.youtube.com/watch?v={item['youtube_id']}) — {item['channel']} — {title} ({item['status']})\n"
    if not deferred:markdown+='Aucune vidéo signalée sans sous-titres FR/EN dans ce périmètre.\n'
    (destination/f'caption-followup-{suffix}.md').write_text(markdown,encoding='utf-8')
    print(json.dumps(dict(counts=counts,deferred_audio_tests=len(deferred),report=str(destination/f'caption-followup-{suffix}.md')),ensure_ascii=False))


def validate_channel(runtime, channel, limit=2):
    if not channel or not 1<=limit<=3:raise ValueError('Choisir une chaîne et 1–3 vidéos')
    inventory=caption_inventory(runtime)
    selected=[]
    with closing_database(connect(runtime.db,True)) as source:
        chan=source.execute('SELECT * FROM channels WHERE prefix=?',(channel,)).fetchone()
        if not chan:raise ValueError('Chaîne inconnue')
        for row in source.execute("SELECT * FROM videos WHERE channel_id=? AND trim(COALESCE(transcript,''))!='' ORDER BY upload_date DESC",(chan['id'],)):
            caption=local_caption(inventory,row['youtube_id'],['fr-orig','fr','en-orig','en'])
            if caption:
                selected.append((dict(row),caption))
                if len(selected)>=limit:break
        schema=[row[0] for row in source.execute("SELECT sql FROM sqlite_master WHERE type='table' AND name IN ('channels','videos','videos_fts') ORDER BY CASE name WHEN 'channels' THEN 1 WHEN 'videos' THEN 2 ELSE 3 END")]
        triggers=[row[0] for row in source.execute("SELECT sql FROM sqlite_master WHERE type='trigger' AND tbl_name='videos'")]
    if not selected:raise RuntimeError('Aucun sous-titre local exploitable pour le pilote')
    target=runtime.database_dir/'pilot_reports'/('channel-validation-'+str(time.time_ns()))
    database_dir=target/'workspace'/'DATABASE';database_dir.mkdir(parents=True)
    caption_dir=target/'workspace'/'legacy-captions';caption_dir.mkdir()
    db_path=database_dir/'PIPELINE_V15.db'
    with closing_database(sqlite3.connect(db_path)) as fixture:
        for sql in schema+triggers:fixture.execute(sql)
        columns=list(dict(chan));fixture.execute('INSERT INTO channels('+','.join(columns)+') VALUES('+','.join('?' for _ in columns)+')',[chan[k] for k in columns])
        for row,(lang,raw,ext) in selected:
            (caption_dir/f"{row['youtube_id']}.{lang}.{ext}").write_text(raw,encoding='utf-8',newline='')
            columns=list(row);values=dict(row,transcript=None,status='PENDING')
            fixture.execute('INSERT INTO videos('+','.join(columns)+') VALUES('+','.join('?' for _ in columns)+')',[values[k] for k in columns])
    pilot=Runtime(target/'workspace')
    sync(pilot,channel,limit=limit,offline=True)
    packs(pilot,channel=channel)
    checks=[]
    with closing_database(connect(pilot.db,True)) as fixture,closing_database(connect(runtime.db,True)) as source:
        if fixture.execute('PRAGMA quick_check').fetchone()[0]!='ok':raise RuntimeError('Base pilote invalide')
        for before,caption in selected:
            ident=before['youtube_id'];after=fixture.execute('SELECT transcript FROM videos WHERE youtube_id=?',(ident,)).fetchone()[0]
            if not after:raise RuntimeError('Import pilote vide')
            term=re.search(r'[A-Za-zÀ-ÖØ-öø-ÿ]{4,}',after)
            matches=fixture.execute('SELECT count(*) FROM videos_fts WHERE videos_fts MATCH ?',('"'+term[0]+'"',)).fetchone()[0] if term else 0
            if term and not matches:raise RuntimeError('Index FTS pilote non synchronisé')
            production=source.execute('SELECT transcript FROM videos WHERE youtube_id=?',(ident,)).fetchone()[0]
            if production!=before['transcript']:raise RuntimeError('La transcription de production a changé pendant le pilote')
            checks.append(dict(youtube_id=ident,language=caption[0],characters=len(after),fts_matches=matches,production_unchanged=True))
    atomic_json(target/'RESULT.json',dict(channel=channel,checks=checks,network_requests=0,audio_transcriptions=0,validated_at=now()))
    (target/'REPORT.md').write_text(f'# Validation hors ligne : {channel}\n\n{len(checks)} vidéos réimportées depuis leurs sous-titres existants dans une base pilote isolée.\n\nIntégrité SQLite, recherche FTS, génération de packs et conservation des transcriptions de production : vérifiées. Aucun accès YouTube et aucune transcription audio.\n',encoding='utf-8')
    print(f'Pilote validé : {target / "REPORT.md"}')


def main():
    if hasattr(sys.stdout,'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8',errors='replace')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["discover", "sync", "audit", "migrate", "backup", "packs", "transcribe", "import-transcripts", "purge", "missing-captions", "validate-channel"])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--channel")
    parser.add_argument("--force-retry", action="store_true")
    parser.add_argument('--offline',action='store_true')
    parser.add_argument("--local-root", type=Path)
    parser.add_argument("--word-limit", type=int, default=200000)
    parser.add_argument("--model", choices=["tiny", "base", "small"], default="base")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--file", type=Path)
    args = parser.parse_args()
    runtime = Runtime(args.root)
    if args.command == "sync":
        with acquisition_lock(runtime):
            sync(runtime, args.channel, args.force_retry,args.limit or 500,args.offline)
    elif args.command == "discover":
        with acquisition_lock(runtime):
            discover(runtime, args.channel)
    elif args.command == "audit":
        audit(runtime)
    elif args.command == "migrate":
        migrate(runtime, args.local_root)
    elif args.command == "backup":
        backup(runtime)
    elif args.command == "packs":
        packs(runtime, args.word_limit, args.channel)
    elif args.command == "transcribe":
        with acquisition_lock(runtime):
            transcribe(runtime, args.model, args.limit or 1)
    elif args.command == "import-transcripts":
        import_transcripts(runtime)
    elif args.command=='missing-captions':
        list_caption_followup(runtime,args.channel)
    elif args.command=='validate-channel':
        validate_channel(runtime,args.channel,args.limit or 2)
    elif args.command == "purge":
        if not args.file:
            parser.error("--file obligatoire pour la purge")
        try:
            purge(runtime, args.file)
        except (ValueError, OSError, KeyError, sqlite3.Error) as error:
            print(json.dumps(dict(status="error", message=str(error)), ensure_ascii=False))
            raise SystemExit(1)


if __name__ == "__main__":
    main()
