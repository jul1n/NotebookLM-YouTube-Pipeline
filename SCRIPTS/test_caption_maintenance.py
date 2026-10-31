import unittest
from pathlib import Path
import gzip
import json
import sqlite3
import tempfile
from unittest.mock import patch
import caption_maintenance as m
import pipeline_core as core


class MaintenanceTest(unittest.TestCase):
    def test_paired_header_and_settings_only(self):
        source='Kind: captions Language: en align:start position:0% line:0% Welcome. The word Language: en stays.'
        result,proof=m.technical_candidate(source)
        self.assertEqual(result,'Welcome. The word Language: en stays.')
        self.assertTrue(source.startswith(proof['removed_header']))
        self.assertEqual(m.technical_candidate('We discuss align:start and Language: en.')[0],'We discuss align:start and Language: en.')

    def test_caption_markup_keeps_words_and_literal_tags(self):
        result,_=m.technical_candidate('My<00:00:01.000><c> name</c> is <ami> and 2 < 3.')
        self.assertEqual(result,'My name is <ami> and 2 < 3.')

    def test_natural_repetitions_and_isolated_triplets_unchanged(self):
        for text in ['I want to I want to go home.', 'Go go go go go go.', 'one two three four five six '*3]:
            self.assertEqual(m.triplicates(text)[0],text)

    def test_partial_timed_file_removes_only_exact_anchored_copies(self):
        groups=[]
        for i in range(12):
            groups.append(f'Word<00:00:{i:02d}.000><c> {i}</c>\n\nWord {i}\n\nWord {i}\n')
        source=''.join(groups)+'Untimed.\nUntimed.\nUntimed.\nOther<00:01:00.000><c> words</c>\n'
        result,proof=m.technical_candidate(source)
        self.assertEqual(len(proof['independently_anchored_groups']),12)
        self.assertEqual(result.count('Word 5'),1)
        self.assertEqual(result.count('Untimed.'),3)
        self.assertIn('Other words',result)

    def test_systemic_triplets_preserve_internal_speech(self):
        blocks=[f'Clause {i} I want to I want to finish.' for i in range(120)]
        source=' '.join(' '.join([block]*3) for block in blocks)
        result,proof=m.triplicates(source)
        self.assertTrue(proof['eligible'])
        self.assertEqual(result.split(),' '.join(blocks).split())
        self.assertEqual(proof['removed_groups'],120)
        self.assertEqual(proof['coverage'],1)

    def test_distant_or_partial_repetition_not_repaired(self):
        blocks=[f'Clause {i} this is a different story.' for i in range(120)]
        ordinary=' '.join(blocks)
        self.assertEqual(m.triplicates(ordinary+' '+ordinary)[0],ordinary+' '+ordinary)
        mixed=' '.join(' '.join([block]*3) for block in blocks[:60])+' '+ordinary
        self.assertEqual(m.triplicates(mixed)[0],mixed)

    def test_case_and_punctuation_are_not_normalized(self):
        blocks=[f'Clause {i} this is a different story.' for i in range(120)]
        text=' '.join(' '.join([b,b.upper(),b]) for b in blocks)
        self.assertEqual(m.triplicates(text)[0],text)

    def test_short_blocks_survive_within_corrupted_document(self):
        blocks=[f'Clause {i} I want to finish this story.' for i in range(120)]
        source=' '.join(' '.join([b]*3) for b in blocks)+' yes yes yes'
        result,proof=m.triplicates(source)
        self.assertTrue(proof['eligible'])
        self.assertTrue(result.endswith('yes yes yes'))

    def test_apply_journals_original_and_preserves_source_metadata(self):
        from contextlib import ExitStack
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/'DATABASE').mkdir()
            path=root/'DATABASE'/'PIPELINE_V15.db'
            original='Kind: captions Language: en This is the spoken text.'
            with core.closing_database(sqlite3.connect(path)) as db:
                db.executescript('CREATE TABLE channels(id INTEGER PRIMARY KEY,prefix TEXT); CREATE TABLE videos(id INTEGER PRIMARY KEY,youtube_id TEXT,title TEXT,channel_id INTEGER,transcript TEXT); INSERT INTO channels VALUES(1,"Test"); CREATE TABLE pipeline_revisions(id INTEGER PRIMARY KEY,job_id TEXT,youtube_id TEXT,before_sha TEXT,after_sha TEXT,original_gzip TEXT,old_metadata TEXT,proof TEXT,changed_at TEXT,UNIQUE(job_id,youtube_id,before_sha));')
                core.init_state(db)
                db.execute('INSERT INTO videos VALUES(1,?,?,1,?)',('abcdefghijk','Title',original))
                db.execute('INSERT INTO pipeline_transcripts VALUES(?,?,?,?,?,?,?)',('abcdefghijk','en','cached-captions','source.vtt.gz','rawhash','old','date'))
            runtime=core.Runtime(root);target=root/'DATABASE'/'pilot_reports'/'test'
            m.plan(runtime,target)
            with ExitStack() as stack:
                for name in ('backup','packs'):stack.enter_context(patch.object(core,name))
                stack.enter_context(patch.object(m,'integrity',return_value={'sqlite':'ok','fts':'ok'}))
                stack.enter_context(patch.object(m.quality,'audit_quality',return_value=({'status_counts':{},'texts_scanned':1},target)))
                stack.enter_context(patch('dashboard_export.export_dashboard'))
                stack.enter_context(patch.object(core,'run_yt',side_effect=AssertionError('network used')))
                m.apply(runtime,target);m.apply(runtime,target)
            with core.closing_database(core.connect(path,True)) as db:
                self.assertEqual(db.execute('SELECT transcript FROM videos').fetchone()[0],'This is the spoken text.')
                rows=db.execute('SELECT * FROM pipeline_revisions').fetchall()
                self.assertEqual(len(rows),1)
                self.assertEqual(gzip.decompress(Path(rows[0]['original_gzip']).read_bytes()).decode(),original)
                self.assertEqual(db.execute('SELECT raw_path FROM pipeline_transcripts').fetchone()[0],'source.vtt.gz')
                self.assertEqual(json.loads(rows[0]['old_metadata'])['sha256'],'rawhash')


if __name__=='__main__':unittest.main()
