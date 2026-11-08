import gzip
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
import io
import sys
from unittest.mock import patch

import pipeline_core as core

CAPTIONS = '''WEBVTT

00:00:00.000 --> 00:00:02.000
Bonjour le monde

00:00:01.000 --> 00:00:03.000
le monde &amp; vous

00:00:04.000 --> 00:00:05.000
Bonjour le monde
'''


class PipelineTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base/'drive'
        (self.root/'DATABASE').mkdir(parents=True)
        self.dbpath = self.root/'DATABASE'/'PIPELINE_V15.db'
        with core.closing_database(sqlite3.connect(self.dbpath)) as db:
            db.executescript('''CREATE TABLE channels(id INTEGER PRIMARY KEY,prefix TEXT,yt_url TEXT,lang_config TEXT);
            CREATE TABLE videos(id INTEGER PRIMARY KEY,channel_id INTEGER,youtube_id TEXT UNIQUE,title TEXT,transcript TEXT,status TEXT,upload_date TEXT);
            INSERT INTO channels VALUES(1,'Test','https://www.youtube.com/channel/UCaaaaaaaaaaaaaaaaaaaaaa','fr');
            INSERT INTO videos VALUES(1,1,'abcdefghijk','Titre | spécial',NULL,NULL,'20261030');''')
        self.runtime = core.Runtime(self.root)

    def test_network_diagnostic_never_saves_raw_secrets(self):
        raw = 'ERROR: page needs to be reloaded https://example.test/?token=SECRET Cookie: SECRET C:\\private\\SECRET'
        target, categories = core.youtube_failure_diagnostic(self.runtime,raw,1,['--dump-single-json'],'abcdefghijk')
        stored=target.read_text(encoding='utf-8')
        self.assertEqual(categories,['page_reload_required'])
        self.assertNotIn('SECRET',stored)
        self.assertNotIn('example.test',stored)
        self.assertEqual(json.loads(stored)['youtube_id'],'abcdefghijk')

    def test_unclassified_network_error_remains_private(self):
        target,categories=core.youtube_failure_diagnostic(self.runtime,'arbitrary sensitive output',1,[], 'not-an-id')
        self.assertEqual(categories,['unclassified_extractor_error'])
        self.assertIsNone(json.loads(target.read_text())['youtube_id'])
        self.assertNotIn('sensitive',target.read_text())

    def test_timed_overlap_preserves_later_repetition(self):
        self.assertEqual(core.clean_captions(CAPTIONS), 'Bonjour le monde & vous Bonjour le monde')

    def test_adjacent_identical_cues_are_not_removed(self):
        raw = '00:00.000 --> 00:01.000\nOui\n\n00:01.000 --> 00:02.000\nOui'
        self.assertEqual(core.clean_captions(raw), 'Oui Oui')

    def test_srt_numbers_and_inline_tags_are_not_text(self):
        raw = '1\n00:00:00,000 --> 00:00:01,000\n<c>Bonjour</c> &lt;ami&gt;'
        self.assertEqual(core.clean_captions(raw), 'Bonjour <ami>')

    def test_id_anchored_not_title_word(self):
        self.assertEqual(core.video_id('[PARTENARIAT] vidéo [abcdefghijk].fr.vtt'), 'abcdefghijk')
        self.assertEqual(core.video_id('abcdefghijk.mp4'), 'abcdefghijk')
        self.assertIsNone(core.video_id('PARTENARIAT vidéo.mp4'))

    def test_targeted_sync_reuses_index_and_leaves_other_video_pending(self):
        self.runtime.archive.mkdir(parents=True)
        source=self.runtime.archive/'abcdefghijk.fr.vtt.gz'
        source.write_bytes(gzip.compress(b'WEBVTT\n\n00:00.000 --> 00:01.000\nOui'))
        with core.closing_database(core.connect(self.dbpath)) as db:
            db.execute("INSERT INTO videos VALUES(2,1,'lmnopqrstuv','Other',NULL,'PENDING','20261101')")
        with patch.object(core,'caption_inventory',side_effect=AssertionError('rescanned')),patch.object(core,'run_yt',side_effect=AssertionError('network')),patch.object(core.time,'sleep'):
            core.sync(self.runtime,youtube_ids=['abcdefghijk'],captions={('abcdefghijk','fr'):[source]})
        with core.closing_database(core.connect(self.dbpath,True)) as db:
            self.assertEqual(db.execute("SELECT transcript FROM videos WHERE youtube_id='abcdefghijk'").fetchone()[0],'Oui')
            self.assertIsNone(db.execute("SELECT transcript FROM videos WHERE youtube_id='lmnopqrstuv'").fetchone()[0])

    def test_empty_target_list_never_selects_all_videos(self):
        with patch.object(core,'connect',side_effect=AssertionError('database accessed')):
            core.sync(self.runtime,youtube_ids=[])
        with self.assertRaises(ValueError):core.sync(self.runtime,youtube_ids=['bad-id'])

    def test_cached_sync_short_caption_no_network(self):
        self.runtime.archive.mkdir(parents=True)
        (self.runtime.archive/'abcdefghijk.fr.vtt.gz').write_bytes(gzip.compress(b'WEBVTT\n\n00:00.000 --> 00:01.000\nOui'))
        with patch.object(core, 'run_yt', side_effect=AssertionError('network called')), patch.object(core.time, 'sleep'):
            core.sync(self.runtime)
        with core.closing_database(core.connect(self.dbpath, True)) as db:
            self.assertEqual(db.execute('SELECT transcript FROM videos').fetchone()[0], 'Oui')
            self.assertEqual(db.execute('SELECT cleaner_version FROM pipeline_transcripts').fetchone()[0], core.CAPTION_VERSION)
        self.assertTrue((self.runtime.archive/'abcdefghijk.fr.vtt.gz').exists())

    def test_negative_cache_and_null_status(self):
        with core.closing_database(core.connect(self.dbpath)) as db:
            core.init_state(db)
            core.record_failure(db, 'abcdefghijk', 'ERR_NO_EN_FR', 168)
        with patch.object(core, 'run_yt', side_effect=AssertionError('retry too soon')):
            core.sync(self.runtime)

    def test_429_pause_and_video_delay_are_62_minutes(self):
        from datetime import datetime,timezone
        before=datetime.now(timezone.utc)
        with core.closing_database(core.connect(self.dbpath)) as db:
            core.init_state(db)
            with self.assertRaises(RuntimeError):core.rate_limit(db,'HTTP Error 429','abcdefghijk')
            global_due=db.execute("SELECT value FROM pipeline_control WHERE key='youtube_pause_until'").fetchone()[0]
            video_due=db.execute("SELECT next_attempt_at FROM pipeline_attempts WHERE youtube_id='abcdefghijk'").fetchone()[0]
        for value in [global_due,video_due]:
            seconds=(datetime.strptime(value,'%Y-%m-%d %H:%M:%S').replace(tzinfo=timezone.utc)-before).total_seconds()
            self.assertGreater(seconds,62*60-2)
            self.assertLess(seconds,62*60+2)

    def test_429_persists_global_pause(self):
        with core.closing_database(core.connect(self.dbpath)) as db:
            core.init_state(db)
            with self.assertRaises(RuntimeError):
                core.rate_limit(db, 'HTTP Error 429: Too Many Requests', 'abcdefghijk')
        with core.closing_database(core.connect(self.dbpath)) as db:
            with self.assertRaises(RuntimeError):
                core.pause_guard(db)

    def test_pack_limit_and_source_links(self):
        with core.closing_database(core.connect(self.dbpath)) as db:
            db.execute("UPDATE videos SET transcript=?,status='SUCCESS (fr)'", (' '.join(['mot']*57),))
        core.packs(self.runtime, 20)
        folder = self.root/'assets'/'packs'
        manifest = json.loads((folder/'manifest.json').read_text())
        self.assertGreater(len(manifest['packs']), 1)
        for entry in manifest['packs']:
            text = (folder/entry['file']).read_text()
            self.assertLessEqual(len(text.split()), 20)
            self.assertIn('https://www.youtube.com/watch?v=abcdefghijk', text)

    def test_failed_pack_build_keeps_previous(self):
        folder = self.root/'assets'/'packs'
        folder.mkdir(parents=True)
        (folder/'old.txt').write_text('old')
        with core.closing_database(core.connect(self.dbpath)) as db:
            db.execute("UPDATE videos SET transcript='Bonjour'")
        with self.assertRaises(ValueError):
            core.packs(self.runtime, 1)
        self.assertEqual((folder/'old.txt').read_text(), 'old')

    def test_audit_does_not_trust_success_without_text(self):
        media = self.root/'[PARTENARIAT] vidéo [abcdefghijk].mp4'
        media.write_bytes(b'not real media')
        with core.closing_database(core.connect(self.dbpath)) as db:
            db.execute("UPDATE videos SET status='SUCCESS (fr)'")
        core.audit(self.runtime)
        report = json.loads((self.root/'DATABASE'/'storage_report.json').read_text())
        self.assertEqual(report['Candidates'][0]['YoutubeId'], 'abcdefghijk')
        self.assertFalse(report['Candidates'][0]['SafeToPurge'])
        self.assertTrue(media.exists())

    def test_budget_stops_without_deleting(self):
        self.runtime.local_root = self.base/'local'
        self.runtime.local_root.mkdir()
        sample = self.runtime.local_root/'data.bin'
        sample.write_bytes(b'1234')
        self.runtime.budget = 5
        with self.assertRaises(RuntimeError):
            self.runtime.check_space(2)
        self.assertTrue(sample.exists())

    def test_migration_preserves_source_and_configures_budget(self):
        core.migrate(self.runtime, self.base/'local')
        migrated = core.Runtime(self.root)
        self.assertEqual(migrated.budget, 10_000_000_000)
        self.assertTrue(self.dbpath.exists())
        self.assertNotEqual(migrated.db, self.dbpath)
        with core.closing_database(core.connect(migrated.db, True)) as db:
            self.assertEqual(db.execute('PRAGMA quick_check').fetchone()[0], 'ok')
            self.assertEqual(db.execute('SELECT count(*) FROM videos').fetchone()[0], 1)

    def test_backup_verified(self):
        core.backup(self.runtime)
        files = list((self.root/'DATABASE'/'snapshots').glob('*.db'))
        self.assertEqual(len(files), 1)
        with core.closing_database(core.connect(files[0], True)) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM videos').fetchone()[0], 1)

    def test_compressed_snapshot_restores_and_retention_counts_it(self):
        core.backup(self.runtime)
        folder = self.root/'DATABASE'/'snapshots'
        marker = next(folder.glob('*.verified.json'))
        proof = json.loads(marker.read_text(encoding='utf8'))
        original = folder/proof['filename']
        compressed = original.with_suffix('.db.gz')
        compressed.write_bytes(gzip.compress(original.read_bytes()))
        original.unlink()
        proof.update(filename=compressed.name, compressed_size=compressed.stat().st_size)
        core.atomic_json(marker, proof)
        restored = core.snapshot_database(self.runtime, marker)
        with core.closing_database(core.connect(restored, True)) as db:
            self.assertEqual(db.execute('PRAGMA quick_check').fetchone()[0], 'ok')
        for _ in range(3):
            core.backup(self.runtime)
        self.assertEqual(len(list(folder.glob('*.verified.json'))), 3)
        self.assertFalse(compressed.exists())

    def test_backup_prunes_only_orphan_validation_caches_without_journals(self):
        core.backup(self.runtime)
        orphan = self.runtime.work/('deletion-verified-'+'0'*64+'.db')
        guarded = self.runtime.work/('deletion-verified-'+'1'*64+'.db')
        orphan.write_bytes(b'regenerable cache')
        guarded.write_bytes(b'cache with journal')
        journal = Path(str(guarded)+'-journal')
        journal.write_bytes(b'preserve')
        core.backup(self.runtime)
        self.assertFalse(orphan.exists())
        self.assertTrue(guarded.exists())
        self.assertEqual(journal.read_bytes(), b'preserve')

    def test_backup_compression_policy_preserves_restorable_snapshot(self):
        self.runtime.policy['compress_verified_backups'] = True
        core.backup(self.runtime)
        folder = self.root/'DATABASE'/'snapshots'
        self.assertEqual(len(list(folder.glob('*.db.gz'))), 1)
        self.assertEqual(len(list(folder.glob('*.db'))), 0)
        marker = next(folder.glob('*.verified.json'))
        restored = core.snapshot_database(self.runtime, marker)
        with core.closing_database(core.connect(restored, True)) as db:
            self.assertEqual(db.execute('PRAGMA quick_check').fetchone()[0], 'ok')

    def test_compressed_snapshot_rejects_wrong_restored_hash(self):
        core.backup(self.runtime)
        folder = self.root/'DATABASE'/'snapshots'
        marker = next(folder.glob('*.verified.json'))
        proof = json.loads(marker.read_text(encoding='utf8'))
        original = folder/proof['filename']
        compressed = original.with_suffix('.db.gz')
        compressed.write_bytes(gzip.compress(b'wrong contents'))
        proof.update(filename=compressed.name, compressed_size=compressed.stat().st_size)
        core.atomic_json(marker, proof)
        with self.assertRaisesRegex(ValueError, 'différente'):
            core.snapshot_database(self.runtime, marker)

    def test_import_rejects_downloader_metadata_and_keeps_source(self):
        folder = self.root/'_RECOVERY_TRANSCRIPTS'
        folder.mkdir()
        source = folder/'[abcdefghijk].txt'
        source.write_text(json.dumps(dict(id='abcdefghijk',title='Video',formats=[])),encoding='utf8')
        core.import_transcripts(self.runtime)
        self.assertTrue(source.exists())
        with core.closing_database(core.connect(self.dbpath,True)) as db:
            self.assertIsNone(db.execute('SELECT transcript FROM videos').fetchone()[0])

    def test_import_rejects_metadata_before_caption_parsing(self):
        folder = self.root/'_RECOVERY_TRANSCRIPTS'
        folder.mkdir()
        source = folder/'[abcdefghijk].vtt'
        source.write_text(json.dumps(dict(id='abcdefghijk',title='Video',formats=[]))+'\n00:00:00.000 --> 00:00:01.000\nUnrelated payload.',encoding='utf8')
        core.import_transcripts(self.runtime)
        self.assertTrue(source.exists())
        with core.closing_database(core.connect(self.dbpath,True)) as db:
            self.assertIsNone(db.execute('SELECT transcript FROM videos').fetchone()[0])

    def test_packs_exclude_downloader_metadata(self):
        with core.closing_database(core.connect(self.dbpath)) as db:
            db.execute('UPDATE videos SET transcript=?',(json.dumps(dict(id='abcdefghijk',title='Video',formats=[])),))
        core.packs(self.runtime)
        manifest = json.loads((self.root/'assets/packs/manifest.json').read_text(encoding='utf8'))
        self.assertEqual(manifest['packs'], [])
        self.assertEqual(manifest['quality_exclusions'][0]['youtube_id'], 'abcdefghijk')

    def test_import_unknown_id_keeps_source_and_media(self):
        source = self.root/'_RECOVERY_TRANSCRIPTS'
        source.mkdir()
        transcript = source/'[xxxxxxxxxxx].txt'
        transcript.write_text('court mais valide')
        media = self.root/'xxxxxxxxxxx.mp4'
        media.write_bytes(b'media')
        core.import_transcripts(self.runtime)
        self.assertTrue(transcript.exists())
        self.assertTrue(media.exists())

    def test_import_short_text_and_skip_archive(self):
        source = self.root/'_RECOVERY_TRANSCRIPTS'
        (source/'_ARCHIVE').mkdir(parents=True)
        (source/'[abcdefghijk].txt').write_text('Oui')
        (source/'_ARCHIVE'/'[xxxxxxxxxxx].txt').write_text('ancien')
        core.import_transcripts(self.runtime)
        with core.closing_database(core.connect(self.dbpath, True)) as db:
            self.assertEqual(db.execute('SELECT transcript FROM videos').fetchone()[0], 'Oui')
        self.assertTrue((source/'_ARCHIVE'/'[xxxxxxxxxxx].txt').exists())

    def test_purge_requires_matching_backup(self):
        media = self.root/'abcdefghijk.mp4'
        media.write_bytes(b'media')
        with core.closing_database(core.connect(self.dbpath)) as db:
            db.execute("UPDATE videos SET transcript='Bonjour',status='SUCCESS (fr)'")
        core.audit(self.runtime)
        with self.assertRaises(ValueError):
            core.purge(self.runtime, media)
        self.assertTrue(media.exists())
        core.backup(self.runtime)
        core.purge(self.runtime, media)
        self.assertFalse(media.exists())

    def test_purge_rejects_outside_project(self):
        media = self.base/'abcdefghijk.mp4'
        media.write_bytes(b'media')
        with self.assertRaises(ValueError):
            core.purge(self.runtime, media)
        self.assertTrue(media.exists())

    def test_discovery_rss_all_channels_without_yt(self):
        feed = b'''<feed xmlns="http://www.w3.org/2005/Atom" xmlns:yt="http://www.youtube.com/xml/schemas/2015">
        <entry><yt:videoId>xxxxxxxxxxx</yt:videoId><title>O'Brien | sujet</title><published>2026-10-30T10:00:00Z</published></entry></feed>'''
        with patch.object(core.urllib.request, 'urlopen', return_value=io.BytesIO(feed)), patch.object(core, 'run_yt', side_effect=AssertionError('unexpected fallback')), patch.object(core.time, 'sleep'):
            core.discover(self.runtime)
        with core.closing_database(core.connect(self.dbpath, True)) as db:
            self.assertEqual(db.execute("SELECT title FROM videos WHERE youtube_id='xxxxxxxxxxx'").fetchone()[0], "O'Brien | sujet")

    def test_network_lock_blocks_second_worker(self):
        with core.acquisition_lock(self.runtime):
            with self.assertRaises(RuntimeError):
                with core.acquisition_lock(self.runtime):
                    self.fail('second worker acquired lock')

    def test_existing_audio_transcribed_without_network_or_deletion(self):
        media = self.root/'abcdefghijk.m4a'
        media.write_bytes(b'synthetic audio')
        with core.closing_database(core.connect(self.dbpath)) as db:
            db.execute("UPDATE videos SET status='ERR_NO_EN_FR'")
        from types import SimpleNamespace
        fake = SimpleNamespace(load_model=lambda *a, **k: SimpleNamespace(transcribe=lambda *a, **k: dict(text='Oui',language='fr',segments=[])))
        with patch.dict(sys.modules, {'whisper':fake}), patch.object(core, 'run_yt', side_effect=AssertionError('network called')):
            core.transcribe(self.runtime)
        self.assertTrue(media.exists())
        with core.closing_database(core.connect(self.dbpath, True)) as db:
            self.assertEqual(db.execute('SELECT transcript FROM videos').fetchone()[0], 'Oui')

    def test_fresh_sync_extracts_metadata_once_and_downloads_human_caption(self):
        calls = []
        def fake_yt(runtime, db, args, ident=None):
            calls.append(args)
            if '--dump-single-json' in args:
                return json.dumps(dict(subtitles={'en':[dict(ext='vtt',url='synthetic')]},automatic_captions={'fr':[dict(ext='vtt',url='synthetic')]}))
            self.assertIn('--load-info-json',args)
            self.assertNotIn('https://www.youtube.com/watch?v=abcdefghijk',args)
            template = Path(args[args.index('--output')+1])
            template.with_name('caption.en.vtt').write_text(CAPTIONS)
            return ''
        with patch.object(core, 'run_yt', side_effect=fake_yt), patch.object(core.time, 'sleep'):
            core.sync(self.runtime)
        self.assertEqual(len(calls),2)
        with core.closing_database(core.connect(self.dbpath, True)) as db:
            self.assertEqual(db.execute('SELECT source,language FROM pipeline_transcripts').fetchone()[:], ('youtube-human','en'))

    def test_wal_migration_uses_sqlite_snapshot(self):
        with core.closing_database(core.connect(self.dbpath)) as db:
            db.execute('PRAGMA journal_mode=WAL')
        core.migrate(self.runtime,self.base/'local')
        runtime = core.Runtime(self.root)
        with core.closing_database(core.connect(runtime.db,True)) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM videos').fetchone()[0],1)

    def test_legacy_vtt_prevents_redownload(self):
        legacy = self.root/'backups'/'channel'/'1_RAW'
        legacy.mkdir(parents=True)
        (legacy/'Ancien titre [abcdefghijk].fr.vtt').write_text(CAPTIONS,encoding='utf-8')
        with patch.object(core, 'run_yt', side_effect=AssertionError('legacy source ignored')), patch.object(core.time, 'sleep'):
            core.sync(self.runtime)
        self.assertTrue((self.runtime.archive/'abcdefghijk.fr.vtt.gz').exists())
        self.assertTrue((legacy/'Ancien titre [abcdefghijk].fr.vtt').exists())

    def test_retention_keeps_three_verified_and_unmanaged_files(self):
        folder=self.root/'DATABASE'/'snapshots'
        folder.mkdir()
        (folder/'manual.db').write_bytes(b'old unmanaged file')
        for _ in range(4):
            core.backup(self.runtime)
        self.assertEqual(len(list(folder.glob('PIPELINE_*.db'))),3)
        self.assertEqual(len(list(folder.glob('*.verified.json'))),3)
        self.assertTrue((folder/'manual.db').exists())

    def test_policy_blocks_media_purge_until_batch_review(self):
        self.runtime.policy['media_deletion_requires_batch_approval']=True
        with self.assertRaisesRegex(ValueError,'lot'):
            core.purge(self.runtime,self.root/'abcdefghijk.mp4')

    def test_pilot_packs_preserve_global_packs(self):
        global_folder=self.root/'assets'/'packs'
        global_folder.mkdir(parents=True)
        (global_folder/'global.txt').write_text('global')
        with core.closing_database(core.connect(self.dbpath)) as db:
            db.execute("UPDATE videos SET transcript='Bonjour le monde'")
        core.packs(self.runtime,200000,'Test')
        self.assertEqual((global_folder/'global.txt').read_text(),'global')
        self.assertEqual(len(list((self.root/'assets'/'pilot-packs').rglob('manifest.json'))),1)

    def test_deferred_audio_stops_before_loading_whisper(self):
        self.runtime.policy['audio_transcription_mode']='deferred'
        with self.assertRaisesRegex(RuntimeError,'différée'):
            core.transcribe(self.runtime)

    def test_followup_distinguishes_network_failure_from_no_subtitles(self):
        with core.closing_database(core.connect(self.dbpath)) as db:
            db.execute("UPDATE videos SET status='ERR_DL_FAIL'")
            db.execute("INSERT INTO videos VALUES(2,1,'xxxxxxxxxxx','No subs',NULL,'ERR_NO_EN_FR','20261029')")
        core.list_caption_followup(self.runtime)
        report=json.loads((self.root/'DATABASE'/'pilot_reports'/'caption-followup-all.json').read_text())
        self.assertEqual(report['counts']['download_failed'],1)
        self.assertEqual(report['counts']['no_fr_en_subtitles_reported'],1)
        self.assertEqual(sum(item['action']=='defer_audio_test' for item in report['items']),1)

    def test_offline_mode_never_calls_youtube(self):
        with patch.object(core,'run_yt',side_effect=AssertionError('network called')):
            with self.assertRaisesRegex(RuntimeError,'hors ligne'):
                core.sync(self.runtime,offline=True)

    def test_real_captions_pipeline_in_isolated_pilot(self):
        legacy=self.root/'legacy';legacy.mkdir()
        (legacy/'abcdefghijk.fr.vtt').write_text(CAPTIONS,encoding='utf-8')
        with core.closing_database(core.connect(self.dbpath)) as db:
            db.execute("UPDATE videos SET transcript='Previous text'")
            db.executescript('''CREATE VIRTUAL TABLE videos_fts USING fts5(youtube_id UNINDEXED,title,transcript,content='videos',content_rowid='id');
            CREATE TRIGGER videos_ai AFTER INSERT ON videos BEGIN INSERT INTO videos_fts(rowid,youtube_id,title,transcript) VALUES(new.id,new.youtube_id,new.title,new.transcript); END;
            CREATE TRIGGER videos_au AFTER UPDATE ON videos BEGIN INSERT INTO videos_fts(videos_fts,rowid,youtube_id,title,transcript) VALUES('delete',old.id,old.youtube_id,old.title,old.transcript); INSERT INTO videos_fts(rowid,youtube_id,title,transcript) VALUES(new.id,new.youtube_id,new.title,new.transcript); END;''')
        with patch.object(core,'run_yt',side_effect=AssertionError('network called')),patch.object(core.time,'sleep'):
            core.validate_channel(self.runtime,'Test',1)
        results=list((self.root/'DATABASE'/'pilot_reports').rglob('RESULT.json'))
        self.assertEqual(len(results),1)
        report=json.loads(results[0].read_text())
        self.assertTrue(report['checks'][0]['production_unchanged'])
        self.assertEqual(report['audio_transcriptions'],0)



if __name__ == '__main__':
    unittest.main()
