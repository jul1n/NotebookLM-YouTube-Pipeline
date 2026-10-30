import gzip
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

import caption_quality as quality
import pipeline_core as core


class QualityTest(unittest.TestCase):
    def test_inline_and_encoded_time_tags_removed(self):
        text='What<00:00:00.800><c> is</c>&amp;lt;00:00:01.000&amp;gt;&lt;c&gt; next&lt;/c&gt;'
        self.assertTrue(quality.inspect_text(text)['technical_markers'])
        cleaned=core.strip_caption_markup(text)
        self.assertEqual(cleaned,'What is next')
        self.assertEqual(quality.inspect_text(cleaned)['technical_markers'],{})

    def test_literal_angles_and_natural_clock_preserved(self):
        text='Bonjour &lt;ami&gt;, x &lt; 3, rendez-vous à 12:30.'
        self.assertEqual(core.strip_caption_markup(text),'Bonjour <ami>, x < 3, rendez-vous à 12:30.')
        self.assertFalse(quality.inspect_text(core.strip_caption_markup(text))['technical_markers'])

    def test_phrase_repetition_flagged_not_deleted(self):
        text='Nous allons regarder cette expérience Nous allons regarder cette expérience puis conclure.'
        self.assertGreater(quality.inspect_text(text)['suspected_repetitions'],0)
        self.assertEqual(core.strip_caption_markup(text),text)

    def test_real_emphasis_requires_review_not_automatic_deletion(self):
        text='C’est très très très très important.'
        result=quality.inspect_text(text)
        self.assertEqual(result['status'],'repetition_review')
        self.assertEqual(core.strip_caption_markup(text),text)

    def test_later_repeated_sentence_is_not_adjacent_repeat(self):
        text='Nous pouvons le faire. Voici une autre étape très différente. Nous pouvons le faire.'
        self.assertEqual(quality.inspect_text(text)['suspected_repetitions'],0)

    def test_cues_with_encoded_tags_cleaned(self):
        raw='WEBVTT\n\n00:00.000 --> 00:01.000\nBonjour&lt;00:00:00.500&gt;&lt;c&gt; le monde&lt;/c&gt;'
        self.assertEqual(core.clean_captions(raw),'Bonjour le monde')

    def test_audit_is_read_only_and_saves_review_sources(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/'DATABASE').mkdir()
            dbpath=root/'DATABASE'/'PIPELINE_V15.db'
            before='What<00:00:00.800><c> is</c> next What is next'
            with core.closing_database(sqlite3.connect(dbpath)) as db:
                db.executescript('''CREATE TABLE channels(id INTEGER PRIMARY KEY,prefix TEXT,lang_config TEXT);
                CREATE TABLE videos(youtube_id TEXT,title TEXT,transcript TEXT,status TEXT,channel_id INTEGER,id INTEGER PRIMARY KEY);
                INSERT INTO channels VALUES(1,'Test','en');''')
                db.execute('INSERT INTO videos VALUES(?,?,?,?,?,?)',('abcdefghijk','Example',before,'SUCCESS',1,1))
            runtime=core.Runtime(root)
            with patch.object(core,'run_yt',side_effect=AssertionError('network used')):
                report,target=quality.audit_quality(runtime,sample_limit=1)
            self.assertEqual(report['texts_scanned'],1)
            self.assertEqual(report['previews'][0]['reprocessing_mode'],'text_markup_only')
            self.assertEqual((target/'abcdefghijk'/'before.txt').read_text(),before)
            self.assertEqual(gzip.decompress(next((target/'abcdefghijk').glob('original.*.gz')).read_bytes()),before.encode())
            self.assertFalse(report['previews'][0]['after_quality']['technical_markers'])
            with core.closing_database(core.connect(dbpath,True)) as db:
                self.assertEqual(db.execute('SELECT transcript FROM videos').fetchone()[0],before)

    def test_purge_refuses_missing_source_or_missing_quality_approval(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/'DATABASE').mkdir()
            with core.closing_database(sqlite3.connect(root/'DATABASE'/'PIPELINE_V15.db')) as db:
                db.execute('CREATE TABLE videos(youtube_id TEXT UNIQUE,status TEXT,transcript TEXT)')
                db.execute('INSERT INTO videos VALUES(?,?,?)',('abcdefghijk','SUCCESS (fr)','Bonjour le monde'))
            media=root/'abcdefghijk.mp4';media.write_bytes(b'test media')
            runtime=core.Runtime(root)
            core.audit(runtime);core.backup(runtime)
            runtime.policy['deletion_requires_reprocessable_source']=True
            with self.assertRaisesRegex(ValueError,'Source horodatée'):
                core.purge(runtime,media)
            self.assertTrue(media.exists())
            runtime.policy={'deletion_requires_quality_review':True}
            with self.assertRaisesRegex(ValueError,'Validation humaine'):
                core.purge(runtime,media)
            self.assertTrue(media.exists())

    def test_long_nonrepeating_input_uses_bounded_comparisons(self):
        text=' '.join(f'word{i}' for i in range(10000))
        self.assertEqual(quality.inspect_text(text)['suspected_repetitions'],0)

    def test_report_reconstruction_uses_matching_source_blocks(self):
        from test_caption_reconstruction import rendered
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/'DATABASE').mkdir()
            before=rendered('most<00:00:00.280><c> people think you need to spend</c>',
                            'thousands<00:00:01.640><c> of dollars</c>')
            with core.closing_database(sqlite3.connect(root/'DATABASE'/'PIPELINE_V15.db')) as db:
                db.executescript('CREATE TABLE channels(id INTEGER PRIMARY KEY,prefix TEXT,lang_config TEXT); CREATE TABLE videos(youtube_id TEXT,title TEXT,transcript TEXT,status TEXT,channel_id INTEGER,id INTEGER PRIMARY KEY); INSERT INTO channels VALUES(1,"Test","en");')
                db.execute('INSERT INTO videos VALUES(?,?,?,?,?,?)',('abcdefghijk','Example',before,'SUCCESS',1,1))
            report,target=quality.audit_quality(core.Runtime(root),sample_limit=1)
            item=report['previews'][0]
            self.assertEqual(item['reprocessing_mode'],'rendered_triplet_reconstruction')
            self.assertEqual(item['snippet_scope'],'same_source_block')
            self.assertEqual(item['snippets'][0]['after'],'most people think you need to spend')
            self.assertEqual((target/'abcdefghijk'/'after.txt').read_text(),'most people think you need to spend thousands of dollars')
            with core.closing_database(core.connect(root/'DATABASE'/'PIPELINE_V15.db',True)) as db:
                self.assertEqual(db.execute('SELECT transcript FROM videos').fetchone()[0],before)


if __name__=='__main__':unittest.main()
