import gzip
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch
import caption_spoken_dedup as spoken
import caption_maintenance as maintenance
import pipeline_core as core

class LocalRepairTest(unittest.TestCase):
    def test_resume_reuses_only_verified_candidates(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'DATABASE').mkdir();runtime=core.Runtime(root)
            with core.closing_database(sqlite3.connect(runtime.db)) as db:
                db.executescript('CREATE TABLE channels(id INTEGER PRIMARY KEY,prefix TEXT); INSERT INTO channels VALUES(1,"Test"); CREATE TABLE videos(id INTEGER PRIMARY KEY,youtube_id TEXT,title TEXT,transcript TEXT,channel_id INTEGER);')
                db.execute('INSERT INTO videos VALUES(1,?,?,?,1)',('abcdefghijk','Test','Hello hello world.'));db.commit()
            target=root/'job';spoken.plan(runtime,target)
            plan=(target/'PLAN.json').read_bytes();(target/'PLAN.json').unlink()
            with patch.object(spoken,'deduplicate',side_effect=AssertionError('Verified result recomputed')):spoken.plan(runtime,target)
            self.assertEqual(json.loads(plan)['entries'],json.loads((target/'PLAN.json').read_bytes())['entries'])
            (target/'PLAN.json').unlink();(target/'candidates/abcdefghijk.txt.gz').write_bytes(gzip.compress(b'Changed content'))
            spoken.plan(runtime,target)
            self.assertEqual(gzip.decompress((target/'candidates/abcdefghijk.txt.gz').read_bytes()),b'Hello world.')
    def test_originals_publish_then_change_journal_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);runtime=core.Runtime(root);archive=root/'cache';archive.mkdir();raw=b'Original text';sha=maintenance.digest(raw.decode());source=archive/'a.gz';source.write_bytes(gzip.compress(raw))
            with sqlite3.connect(':memory:') as db:
                db.row_factory=sqlite3.Row;db.execute('CREATE TABLE pipeline_revisions(id INTEGER,job_id TEXT,original_gzip TEXT,before_sha TEXT)');db.execute('INSERT INTO pipeline_revisions VALUES(1,?,?,?)',('test',str(source),sha));db.commit()
                maintenance.publish_local_originals(runtime,db,'test',archive)
                final=Path(db.execute('SELECT original_gzip FROM pipeline_revisions').fetchone()[0]);self.assertEqual(gzip.decompress(final.read_bytes()),raw);self.assertTrue(source.exists());self.assertNotEqual(final,source)
    def test_corrupt_original_does_not_repoint_journal(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);runtime=core.Runtime(root);archive=root/'cache';archive.mkdir();source=archive/'a.gz';source.write_bytes(gzip.compress(b'Wrong text'))
            with sqlite3.connect(':memory:') as db:
                db.row_factory=sqlite3.Row;db.execute('CREATE TABLE pipeline_revisions(id INTEGER,job_id TEXT,original_gzip TEXT,before_sha TEXT)');db.execute('INSERT INTO pipeline_revisions VALUES(1,?,?,?)',('test',str(source),maintenance.digest('Right text')));db.commit()
                with self.assertRaisesRegex(RuntimeError,'Invalid cached original'):maintenance.publish_local_originals(runtime,db,'test',archive)
                self.assertEqual(db.execute('SELECT original_gzip FROM pipeline_revisions').fetchone()[0],str(source))

if __name__=='__main__':unittest.main()
