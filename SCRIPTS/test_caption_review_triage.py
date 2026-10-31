import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

import caption_quality as quality
import caption_review_triage as triage
import dashboard_export
import pipeline_core as core


class TriageTest(unittest.TestCase):
    def test_uniform_loop_is_excluded_only_with_explicit_non_speech_context(self):
        text="I'm going to do a little bit of the same. "*120
        self.assertTrue(triage.non_speech_loop('Lofi Fireplace (No Talking)',text)['accepted'])
        self.assertFalse(triage.non_speech_loop('Interview about a business',text)['accepted'])
        speech=' '.join(f'Different point {i} explaining another story.' for i in range(200))
        self.assertFalse(triage.non_speech_loop('Lofi Fireplace (No Talking)',speech)['accepted'])

    def test_annotations_and_fillers_are_not_mandatory_human_review(self):
        self.assertEqual(triage.classify(quality.inspect_text('[Music] '*8)),'annotations_or_short_oral_fillers')
        self.assertEqual(triage.classify(quality.inspect_text('you know '*6)),'annotations_or_short_oral_fillers')
        phrase='this is a long repeated phrase with substantive words '
        self.assertEqual(triage.classify(quality.inspect_text(phrase*8)),'priority_long_repetitions')

    def test_packs_and_dashboard_exclude_exact_checked_text_without_deleting_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'DATABASE').mkdir();path=root/'DATABASE'/'PIPELINE_V15.db'
            bad='Repeated non speech loop. '*50;good='A useful explanation.'
            with core.closing_database(sqlite3.connect(path)) as db:
                db.executescript('''CREATE TABLE channels(id INTEGER PRIMARY KEY,prefix TEXT);
                CREATE TABLE videos(id INTEGER PRIMARY KEY,youtube_id TEXT,channel_id INTEGER,title TEXT,upload_date TEXT,transcript TEXT,duration REAL,status TEXT);
                INSERT INTO channels VALUES(1,'Test');
                CREATE TABLE pipeline_quality_exclusions(youtube_id TEXT,transcript_sha256 TEXT,reason TEXT,evidence TEXT,created_at TEXT);''')
                db.execute('INSERT INTO videos VALUES(1,?,1,?,?,?,60,?)',('abcdefghijk','Bad','20261030',bad,'SUCCESS'))
                db.execute('INSERT INTO videos VALUES(2,?,1,?,?,?,60,?)',('xxxxxxxxxxx','Good','20261031',good,'SUCCESS'))
                db.execute('INSERT INTO pipeline_quality_exclusions VALUES(?,?,?,?,?)',('abcdefghijk',hashlib.sha256(bad.encode()).hexdigest(),'No useful speech','{}','date'))
            runtime=core.Runtime(root);core.packs(runtime)
            manifest=json.loads((root/'assets/packs/manifest.json').read_text())
            self.assertEqual({v for p in manifest['packs'] for v in p['videos']},{'xxxxxxxxxxx'})
            self.assertEqual(len(manifest['quality_exclusions']),1)
            template=root/'template.ps1'
            template.write_text('''$statsSql = @"
SELECT COUNT(*) AS totalVids,0 AS totalHours,SUM(LENGTH(transcript)-LENGTH(REPLACE(transcript,' ',''))+1) AS totalWords FROM videos;
"@
$searchSql = "SELECT youtube_id,title,transcript FROM videos;"
$healthSql = @"
SELECT 'Test' AS Chaine,COUNT(*) AS Total_Local,COUNT(*) AS Total_YouTube,SUM(LENGTH(transcript)-LENGTH(REPLACE(transcript,' ',''))+1) AS Word_Count,1 AS Est_Packs FROM videos;
"@
$recoverySql = "SELECT status FROM videos;"
''',encoding='utf8')
            result=dashboard_export.export_dashboard(runtime,template)
            self.assertEqual(result['transcripts'],1);self.assertEqual(result['quality_excluded'],1)
            self.assertNotIn('abcdefghijk',(root/'assets/data.js').read_text())
            with core.closing_database(core.connect(path)) as db:
                self.assertEqual(db.execute('SELECT transcript FROM videos WHERE id=1').fetchone()[0],bad)
                db.execute('UPDATE videos SET transcript=? WHERE id=1',('Now corrected and useful.',))
            core.packs(runtime)
            manifest=json.loads((root/'assets/packs/manifest.json').read_text())
            self.assertEqual({v for p in manifest['packs'] for v in p['videos']},{'abcdefghijk','xxxxxxxxxxx'})
            self.assertEqual(manifest['quality_exclusions'],[])


if __name__=='__main__':unittest.main()
