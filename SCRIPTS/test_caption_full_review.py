import gzip
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch
import caption_deep_encoding as deep
import caption_encoding_repair as encoding
import caption_full_review as review
import caption_review_finalize as finalize
import caption_maintenance as maintenance
import caption_quality as quality
import pipeline_core as core


class DeepReviewTest(unittest.TestCase):
    def mapping(self,old,new):return [dict(before=old,after=new,occurrences=12,independent_videos=['a','b','c'])]

    def test_single_demonstrated_quote_is_restored(self):
        result,proof=deep.restore('Today Ôòùû▓hello.',self.mapping('Ôòùû▓',"'"))
        self.assertTrue(proof['accepted']);self.assertEqual(result,"Today 'hello.")

    def test_deep_ascii_carrier_does_not_change_ordinary_words_or_numbers(self):
        old='Ôòùû▓Ôòùû▓eÔö¼';text='I'+old+'m keeping 42 ordinary words.'
        result,proof=deep.restore(text,self.mapping(old,"'"))
        self.assertTrue(proof['accepted']);self.assertEqual(result,"I'm keeping 42 ordinary words.")
        self.assertEqual(proof['ascii_carriers_removed'],{'e':1})
        result,proof=deep.restore('caf'+old+'é 42',self.mapping(old,''))
        self.assertTrue(proof['accepted']);self.assertEqual(result,'café 42')

    def test_words_numbers_and_boundary_letters_cannot_be_templates(self):
        for old in ['Ôòùû▓ordinaryÔö¼Ôòù','Ôòùû▓42Ôö¼Ôòù','IÔòùû▓Ôö¼Ôòù','Ôòùû▓Ôö¼Ôòùa']:
            self.assertFalse(deep.allowed_artifact(old,"'"))

    def test_insufficient_support_and_partial_repairs_remain_unchanged(self):
        text='Today Ôòùû▓hello.'
        self.assertFalse(deep.restore(text,[dict(before='Ôòùû▓',after="'")])[1]['accepted'])
        text+=' Other Ôö¼ unknown'
        self.assertEqual(deep.restore(text,self.mapping('Ôòùû▓',"'"))[0],text)

    def test_ordinary_foreign_fragment_is_preserved(self):
        text='Un mot ûó isolé et un café.'
        self.assertEqual(deep.restore(text,self.mapping('ûó','â'))[0],text)

    def test_known_weak_artifact_cannot_remain_after_a_partial_repair(self):
        text='Ôòùû▓known quote and cafÃ©.'
        self.assertEqual(deep.restore(text,self.mapping('Ôòùû▓',"'"))[0],text)

    def test_protected_negations_and_numbers_block_source_restoration(self):
        before='We do not promise 42 results. '+' '.join('word'+chr(97+i) for i in range(20))
        q=quality.inspect_text(before);agreement=dict(accepted=True,old_coverage=1)
        self.assertFalse(review.restoration_proof(before,before.replace('not ','')+' additional words',q,q,agreement)['accepted'])
        self.assertFalse(review.restoration_proof(before,before.replace('42','43')+' additional words',q,q,agreement)['accepted'])
        self.assertTrue(review.restoration_proof(before,before+' additional words',q,q,agreement)['accepted'])

    def test_source_candidates_must_preserve_numbers_and_negations(self):
        item=dict(category='verified_local_text_source',local_text_source={})
        self.assertEqual(finalize.semantic_rejection(item,'We have 42 euros.','We have 43 euros.'),'source_changes_numeric_content')
        self.assertEqual(finalize.semantic_rejection(item,'We do not agree.','We do agree.'),'source_changes_negation')
        self.assertEqual(finalize.semantic_rejection(item,'We do not not agree.','We do not agree.'),'source_changes_negation')
        self.assertEqual(finalize.semantic_rejection(item,'42, 42 euros.','42 euros.'),'source_changes_numeric_content')
        self.assertIsNone(finalize.semantic_rejection(item,'cafÔòùû▓42 euros','café42 euros'))

    def test_json_source_repairs_encoding_with_plain_text_provenance(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'DATABASE').mkdir();(root/'assets/transcripts').mkdir(parents=True)
            old=' '.join(f'repere{chr(97+i//26)}{chr(97+i%26)} cafÔòùû▓ exemple resultat{chr(97+i//26)}{chr(97+i%26)}.' for i in range(60))
            clean=old.replace('Ôòùû▓','é');path=root/'DATABASE/PIPELINE_V15.db'
            with core.closing_database(sqlite3.connect(path)) as db:
                db.executescript('CREATE TABLE channels(id INTEGER PRIMARY KEY,prefix TEXT,lang_config TEXT); CREATE TABLE videos(id INTEGER PRIMARY KEY,youtube_id TEXT,title TEXT,transcript TEXT,channel_id INTEGER); INSERT INTO channels VALUES(1,"Example","fr");')
                db.execute('INSERT INTO videos VALUES(1,?,?,?,1)',('abcdefghijk','Talk',old));core.init_state(db)
            q=quality.inspect_text(old);baseline=root/'audit.json';baseline.write_text(json.dumps(dict(flagged=[dict(youtube_id='abcdefghijk',quality=q)],transcript_hashes={'abcdefghijk':maintenance.digest(old)})),encoding='utf8')
            inventory=root/'inventory.jsonl';inventory.write_text('',encoding='utf8');index=root/'index.json';index.write_text('[]',encoding='utf8')
            (root/'assets/transcripts/Example.json').write_text(json.dumps([dict(youtube_id='abcdefghijk',transcript=clean)]),encoding='utf8')
            runtime=core.Runtime(root);target=root/'DATABASE/pilot_reports/review'
            with patch.object(core,'run_yt',side_effect=AssertionError('network called')):review.Review(runtime,target,baseline,inventory,index).run()
            plan=json.loads((target/'PLAN.json').read_text(encoding='utf8'));self.assertEqual(plan['changes'],1)
            item=plan['entries'][0];self.assertIn('local_text_source',item);self.assertNotIn('timed_source',item)
            self.assertTrue(item['local_text_source']['raw_path'].endswith('.txt.gz'))
            self.assertEqual(gzip.decompress((target/'candidates/abcdefghijk.txt.gz').read_bytes()).decode(),clean)
            budget=json.loads((runtime.work/('full-review-'+__import__('hashlib').sha256(str(target).encode()).hexdigest()[:12]+'.json')).read_text())['source_bytes_read']
            review.Review(runtime,target,baseline,inventory,index).run()
            self.assertEqual(json.loads((target/'PLAN.json').read_text(encoding='utf8'))['changes'],1)
            self.assertEqual(json.loads((runtime.work/('full-review-'+__import__('hashlib').sha256(str(target).encode()).hexdigest()[:12]+'.json')).read_text())['source_bytes_read'],budget)
            finalize.finalize(runtime,target)
            self.assertEqual(json.loads((target/'PLAN_VALIDATED.json').read_text(encoding='utf8'))['changes'],1)
            with core.closing_database(core.connect(path,True)) as db:self.assertEqual(db.execute('SELECT transcript FROM videos').fetchone()[0],old)
            (root/'assets/transcripts/Example.json').unlink()
            inventory.write_text(json.dumps(dict(path=item['local_text_source']['raw_path'],category='canonical_text_source_protected'))+'\n',encoding='utf8')
            second=root/'DATABASE/pilot_reports/second'
            review.Review(runtime,second,baseline,inventory,index).run()
            self.assertEqual(json.loads((second/'PLAN.json').read_text(encoding='utf8'))['changes'],1)


if __name__=='__main__':unittest.main()
