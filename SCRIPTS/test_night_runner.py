from datetime import datetime,timedelta,timezone
import gzip
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

import night_runner as night
import pipeline_core as core
from test_caption_reconstruction import rendered


class NightTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);(self.root/'DATABASE').mkdir()
        self.raw=rendered('most<00:00:00.280><c> people think you need to spend</c>',
                          'thousands<00:00:01.640><c> of dollars</c>')
        self.db=self.root/'DATABASE'/'PIPELINE_V15.db'
        with core.closing_database(sqlite3.connect(self.db)) as db:
            db.executescript('''CREATE TABLE channels(id INTEGER PRIMARY KEY,prefix TEXT,lang_config TEXT);
            CREATE TABLE videos(id INTEGER PRIMARY KEY,youtube_id TEXT UNIQUE,transcript TEXT,status TEXT,channel_id INTEGER);
            INSERT INTO channels VALUES(1,'Test','en');''')
            db.execute('INSERT INTO videos VALUES(?,?,?,?,?)',(1,'abcdefghijk',self.raw,'SUCCESS (en)',1))
        self.runtime=core.Runtime(self.root)

    def test_apply_is_reversible_and_idempotent(self):
        first=night.apply_repairs(self.runtime,'night-test')
        self.assertEqual(first['changed'],1)
        with core.closing_database(core.connect(self.db,True)) as db:
            self.assertEqual(db.execute('SELECT transcript FROM videos').fetchone()[0],'most people think you need to spend thousands of dollars')
            revision=db.execute('SELECT original_gzip,before_sha,after_sha FROM pipeline_revisions').fetchone()
            self.assertEqual(gzip.decompress(Path(revision[0]).read_bytes()).decode(),self.raw)
            self.assertEqual(revision[1],night.sha(self.raw))
            self.assertEqual(db.execute('SELECT language FROM pipeline_transcripts').fetchone()[0],'en')
        second=night.apply_repairs(self.runtime,'night-test')
        self.assertEqual(second['changed'],1)
        with core.closing_database(core.connect(self.db,True)) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM pipeline_revisions').fetchone()[0],1)

    def test_arbitrary_repetition_is_not_modified(self):
        with core.closing_database(core.connect(self.db)) as db:db.execute("UPDATE videos SET transcript='We can do this We can do this'")
        self.assertEqual(night.apply_repairs(self.runtime,'test')['changed'],0)

    def test_regressing_timestamps_are_not_applied(self):
        raw=rendered('One<00:00:10.000><c> thing</c>','Second<00:00:01.000><c> thing</c>')
        with core.closing_database(core.connect(self.db)) as db:db.execute('UPDATE videos SET transcript=?',(raw,))
        result=night.apply_repairs(self.runtime,'test')
        self.assertEqual(result['changed'],0)
        self.assertEqual(result['skipped'][0]['reason'],'timestamp_regression')

    def job(self):
        job=night.NightJob(self.runtime,self.root/'DATABASE'/'night_runs'/'test')
        job.state['deadline']=(datetime.now(timezone.utc)+timedelta(hours=1)).isoformat()
        job.save();return job

    def test_network_budget_stops_before_extra_request(self):
        job=self.job();job.state['network']['metadata']=6
        with core.closing_database(core.connect(self.db)) as db:
            core.init_state(db)
            with patch.object(core,'pause_guard'):
                with self.assertRaises(night.NetworkStop):job.network_call(lambda *a: self.fail('extra request'),self.runtime,db,['--dump-single-json','url'])

    def test_network_error_blocks_remaining_channels(self):
        job=self.job()
        with patch.object(core,'discover',side_effect=RuntimeError('HTTP 429')) as discover,patch.object(core,'sync') as sync:
            result=job.updates()
        self.assertEqual(discover.call_count,1);sync.assert_not_called()
        self.assertTrue(result['blocked'])

    def test_completed_stage_not_repeated(self):
        job=self.job();calls=[]
        job.stage('one',lambda:calls.append(1))
        job.stage('one',lambda:calls.append(2))
        self.assertEqual(calls,[1])

    def test_integrity_returns_counts(self):
        result=night.integrity(self.runtime)
        self.assertEqual(result['sqlite'],'ok');self.assertEqual(result['videos'],1)

    def test_resume_preserves_completed_steps_and_records_recovered_error(self):
        job=self.job();job.state.update(error='Old local failure',failed_at=core.now(),current_stage='dashboard')
        job.state['stages']['apply']={'status':'done','result':{'changed':1}}
        with patch.object(job,'backup',return_value={}),patch('night_runner.integrity',return_value={}),patch.object(job,'quality_audit',return_value={}),patch.object(job,'updates',return_value={}),patch.object(job,'build_packs',return_value={}),patch.object(job,'dashboard',return_value={}),patch('night_runner.apply_repairs',side_effect=AssertionError('replayed')):
            job.run()
        self.assertEqual(job.state['status'],'done')
        self.assertNotIn('error',job.state)
        self.assertEqual(job.state['recovered_errors'][0]['error'],'Old local failure')
        self.assertEqual(job.state['stages']['apply']['result']['changed'],1)


if __name__=='__main__':unittest.main()
