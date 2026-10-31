import gzip
import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

import pipeline_core as core
import storage_cleanup as cleanup


class CleanupTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)/'repo';(self.root/'DATABASE').mkdir(parents=True)
        self.runtime=core.Runtime(self.root);self.target=self.root/'DATABASE/pilot_reports/test';self.target.mkdir(parents=True)
        with core.closing_database(sqlite3.connect(self.runtime.db)) as db:
            db.executescript('CREATE TABLE videos(youtube_id TEXT PRIMARY KEY,title TEXT,channel_id INTEGER,upload_date TEXT,duration INTEGER,transcript TEXT);')
            db.execute('INSERT INTO videos VALUES(?,?,?,?,?,?)',('abcdefghijk','Titre',1,'20261031',10,'Bonjour le monde.'))
            core.init_state(db)

    def item(self,name):
        path=self.root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_text('{"id":"abcdefghijk","formats":[]}',encoding='utf8')
        st=path.stat()
        return dict(path=str(path),size_bytes=st.st_size,modified_ns=st.st_mtime_ns,youtube_id='abcdefghijk',category='video_metadata',git_tracked=False)

    def plan(self,item):
        backup=self.root/'DATABASE/backup.db'
        with core.closing_database(core.connect(self.runtime.db,True)) as src,core.closing_database(sqlite3.connect(backup)) as dst:src.backup(dst)
        item['evidence']=dict(text_sha256=cleanup.digest('Bonjour le monde.'))
        core.atomic_json(self.target/'DELETE_PLAN.json',dict(root=str(self.root),database=str(self.runtime.db),entries=[item]))
        return backup

    def test_protected_paths_and_changed_file(self):
        item=self.item('abcdefghijk.info.json');Path(item['path']).write_text('changed',encoding='utf8')
        with self.assertRaises(ValueError):cleanup.checked_path(self.root,item)
        item=self.item('.git/abcdefghijk.info.json')
        with self.assertRaises(ValueError):cleanup.checked_path(self.root,item)
        item=self.item('DATABASE/snapshots/abcdefghijk.info.json')
        with self.assertRaises(ValueError):cleanup.checked_path(self.root,item)
        item=self.item('abcdefghijk.db-wal')
        with self.assertRaises(ValueError):cleanup.checked_path(self.root,item)

    def test_changed_text_never_deleted(self):
        item=self.item('abcdefghijk.info.json');backup=self.plan(item)
        with core.closing_database(core.connect(self.runtime.db)) as db:db.execute("UPDATE videos SET transcript='Different'")
        with patch.object(cleanup,'verified_backup',return_value=(backup,{})):cleanup.apply(self.runtime,self.target)
        self.assertTrue(Path(item['path']).exists())

    def test_metadata_id_conflict_never_deleted(self):
        item=self.item('abcdefghijk.info.json');Path(item['path']).write_text('{"id":"xxxxxxxxxxx","formats":[]}',encoding='utf8')
        st=Path(item['path']).stat();item.update(size_bytes=st.st_size,modified_ns=st.st_mtime_ns);backup=self.plan(item)
        with patch.object(cleanup,'verified_backup',return_value=(backup,{})):cleanup.apply(self.runtime,self.target)
        self.assertTrue(Path(item['path']).exists())

    def test_verified_metadata_deleted_once_and_journaled(self):
        item=self.item('abcdefghijk.info.json');backup=self.plan(item)
        with patch.object(cleanup,'verified_backup',return_value=(backup,{})):
            cleanup.apply(self.runtime,self.target);cleanup.apply(self.runtime,self.target)
        self.assertFalse(Path(item['path']).exists())
        records=[json.loads(x) for x in (self.target/'DELETION_JOURNAL.jsonl').read_text(encoding='utf8').splitlines()]
        self.assertEqual([x['action'] for x in records],['intent','deleted'])

    def test_media_requires_matching_source_checksum_and_body(self):
        raw=b'WEBVTT\n\n00:00.000 --> 00:01.000\nBonjour le monde.'
        self.runtime.archive.mkdir(parents=True);source=self.runtime.archive/'abcdefghijk.fr.vtt.gz';source.write_bytes(gzip.compress(raw))
        with core.closing_database(core.connect(self.runtime.db)) as db:
            db.execute('INSERT INTO pipeline_transcripts VALUES(?,?,?,?,?,?,?)',('abcdefghijk','fr','cached-captions',str(source),hashlib.sha256(raw).hexdigest(),core.CAPTION_VERSION,core.now()))
            self.assertIsNone(cleanup.media_proof(self.runtime,db,'abcdefghijk','Bonjour le monde.')[0])
            q=cleanup.quality.inspect_text('Bonjour le monde.');q['review_signals']['word_count']=100
            with patch.object(cleanup.quality,'inspect_text',return_value=q):
                proof=cleanup.media_proof(self.runtime,db,'abcdefghijk','Bonjour le monde.')[0]
                self.assertEqual(proof['source_kind'],'exact_final_text_not_timed_source')
                q['status']='repetition_review'
                self.assertIsNotNone(cleanup.media_proof(self.runtime,db,'abcdefghijk','Bonjour le monde.')[0])
                self.assertIsNone(cleanup.media_proof(self.runtime,db,'abcdefghijk','A different complete sentence.')[0])
                source.write_bytes(gzip.compress(b'bad source'))
                self.assertIsNone(cleanup.media_proof(self.runtime,db,'abcdefghijk','Bonjour le monde.')[0])

    def test_legacy_requires_complete_varied_triplicates_and_matching_text(self):
        units=[' '.join(f'word{n}_{k}' for k in range(6)) for n in range(30)]
        raw=' '.join(unit+' '+unit+' '+unit for unit in units).encode('utf8');text=' '.join(units)
        folder=self.root/'WORKING_ZONE/_LEGACY_RENDERED_GZ';folder.mkdir(parents=True)
        source=folder/'abcdefghijk.rendered.txt.gz';source.write_bytes(gzip.compress(raw))
        q=cleanup.quality.inspect_text(text);q['status']='repetition_review'
        with core.closing_database(core.connect(self.runtime.db)) as db,patch.object(cleanup.quality,'inspect_text',return_value=q):
            db.execute('INSERT INTO pipeline_transcripts VALUES(?,?,?,?,?,?,?)',('abcdefghijk','en','legacy-rendered-captions',str(source),hashlib.sha256(raw).hexdigest(),'old',core.now()))
            proof=cleanup.media_proof(self.runtime,db,'abcdefghijk',text)[0]
            self.assertEqual(proof['source_kind'],'verified_systematic_triplicate_original')
            self.assertIsNone(cleanup.media_proof(self.runtime,db,'abcdefghijk',text+' extra words')[0])
            raw=b'repeat repeat repeat repeat repeat repeat';source.write_bytes(gzip.compress(raw))
            db.execute('UPDATE pipeline_transcripts SET sha256=?',(hashlib.sha256(raw).hexdigest(),))
            self.assertIsNone(cleanup.media_proof(self.runtime,db,'abcdefghijk',text)[0])


if __name__=='__main__':unittest.main()
