import unittest
import resolve_legacy_sources as r


class LegacySourceTest(unittest.TestCase):
    def test_media_and_caption_name_resolve_to_same_date_title(self):
        a=r.key('20250701 - How to Manage Your Emotions, Solved [OBg5sEmRDPc].f251.webm')
        b=r.key('20250701 - How to Manage Your Emotions, Solved.en.srt')
        self.assertEqual(a,b)
        self.assertNotEqual(a,r.key('20250702 - How to Manage Your Emotions, Solved.en.srt'))

    def test_fullwidth_filename_punctuation_is_normalized(self):
        self.assertEqual(r.key('20240101 - Are You Too Self-Aware？.en.vtt'),r.key('20240101 - Are You Too Self-Aware? [abcdefghijk].mp4'))

    def test_only_top_level_id_is_accepted(self):
        self.assertEqual(r.top_level_video_id(b'{"id":"abcdefghijk","large":"unfinished'), 'abcdefghijk')
        self.assertIsNone(r.top_level_video_id(b'{"nested":{"id":"abcdefghijk"},"id":"notvalid"}'))
        self.assertIsNone(r.top_level_video_id(b'{"id":"a/channel/path"}'))


if __name__=='__main__':unittest.main()
