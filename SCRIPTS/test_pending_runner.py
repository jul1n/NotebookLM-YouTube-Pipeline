import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch
import pipeline_core as core
import pending_runner as pending


class PendingTest(unittest.TestCase):
    def setUp(self):
        temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup)
        self.root=Path(temp.name);(self.root/'DATABASE').mkdir()
        self.runtime=core.Runtime(self.root);self.folder=self.root/'DATABASE/pending_runs/test'
        with core.closing_database(sqlite3.connect(self.runtime.db)) as db:
            db.executescript("""CREATE TABLE channels(id INTEGER PRIMARY KEY,prefix TEXT);
              CREATE TABLE videos(id INTEGER PRIMARY KEY,channel_id INTEGER,youtube_id TEXT,title TEXT,upload_date TEXT,status TEXT,transcript TEXT);
              INSERT INTO channels VALUES(1,'Naj'); INSERT INTO channels VALUES(2,'ScienceEtonnante');
              INSERT INTO videos VALUES(1,1,'abcdefghijk','One','20261101','PENDING',NULL);
              INSERT INTO videos VALUES(2,2,'lmnopqrstuv','Two','20260101','PENDING',NULL);
              INSERT INTO videos VALUES(3,1,'12345678901','Error','20261103','ERR_DL_FAIL',NULL);
              INSERT INTO videos VALUES(4,1,'23456789012','Text','20261104','PENDING','Already here');""")
            core.init_state(db)

    def test_queue_is_exact_and_immutable_after_database_changes(self):
        state=pending.prepare(self.runtime,self.folder)
        self.assertEqual(state['total'],2)
        queue=json.loads((self.folder/'QUEUE.json').read_text())
        self.assertEqual([r['youtube_id'] for r in queue],['lmnopqrstuv','abcdefghijk'])
        with core.closing_database(core.connect(self.runtime.db)) as db:
            db.execute("INSERT INTO videos VALUES(5,1,'34567890123','Later','20261105','PENDING',NULL)")
        self.assertEqual(pending.prepare(self.runtime,self.folder)['total'],2)
        self.assertEqual(json.loads((self.folder/'QUEUE.json').read_text()),queue)

    def test_successful_request_clears_inflight_and_keeps_counter(self):
        batch=pending.PendingBatch(self.runtime,self.folder)
        with core.closing_database(core.connect(self.runtime.db)) as db:
            self.assertEqual(batch.network_call(lambda *a:'ok',self.runtime,db,['--dump-single-json'],'abcdefghijk'),'ok')
        self.assertEqual(batch.state['network']['calls'],1)
        self.assertNotIn('request_in_flight',batch.state)

    def test_failed_request_is_recorded_and_stops_batch(self):
        batch=pending.PendingBatch(self.runtime,self.folder)
        def fail(*args):raise RuntimeError('page reload')
        with core.closing_database(core.connect(self.runtime.db)) as db:
            with self.assertRaises(pending.BatchStopped):batch.network_call(fail,self.runtime,db,['--dump-single-json'],'abcdefghijk')
            row=db.execute("SELECT attempts,last_error FROM pipeline_attempts WHERE youtube_id='abcdefghijk'").fetchone()
            self.assertEqual(tuple(row),(1,'ERR_DL_FAIL'))
        self.assertIn('request_in_flight',batch.state)
        self.assertEqual(batch.state['network']['calls'],1)

    def test_interrupted_request_never_replayed(self):
        batch=pending.PendingBatch(self.runtime,self.folder)
        batch.state['request_in_flight']={'youtube_id':'abcdefghijk'};batch.save()
        with patch.object(core,'sync',side_effect=AssertionError('replayed')):batch.run()
        self.assertEqual(batch.state['status'],'blocked')
        self.assertEqual(batch.state['network']['calls'],0)

    def test_blocked_job_does_not_restart(self):
        batch=pending.PendingBatch(self.runtime,self.folder);batch.state['status']='blocked';batch.save()
        with patch.object(core,'acquisition_lock',side_effect=AssertionError('restarted')):batch.run()

    def test_requests_wait_for_minute_interval(self):
        batch=pending.PendingBatch(self.runtime,self.folder);batch.state['network']['last_call']=100
        with core.closing_database(core.connect(self.runtime.db)) as db:
            with patch.object(pending.time,'time',side_effect=[110,160,160]),patch.object(pending.time,'sleep') as sleep:
                batch.network_call(lambda *a:'ok',self.runtime,db,['--dump-single-json'],'abcdefghijk')
        sleep.assert_called_once_with(5)


if __name__=='__main__':unittest.main()
