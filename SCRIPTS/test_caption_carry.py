import unittest
import pipeline_core as core


def rolling():
    return '''WEBVTT

00:00:00.000 --> 00:00:02.000
We<00:00:00.100><c> can do this</c>

00:00:02.000 --> 00:00:02.010
We can do this

00:00:02.010 --> 00:00:04.000
We can do this
Yes<00:00:02.200><c> yes yes really</c>

00:00:04.000 --> 00:00:04.010
Yes yes yes really

00:00:04.010 --> 00:00:06.000
Yes yes yes really
Again<00:00:04.200><c> we can do this</c>
'''


class CarryTest(unittest.TestCase):
    def test_adjacent_rolling_copies_are_removed_but_speech_survives(self):
        text,proof=core.clean_captions_detailed(rolling())
        self.assertEqual(text,'We can do this Yes yes yes really Again we can do this')
        self.assertEqual(proof['removed_display_lines'],4)
        self.assertEqual(proof['rolling_anchors'],2)

    def test_fresh_timestamps_keep_repeated_speech(self):
        raw=rolling()+'''\n00:00:06.000 --> 00:00:08.000
Again<00:00:06.100><c> we can do this</c>\n'''
        self.assertTrue(core.clean_captions(raw).endswith('Again we can do this Again we can do this'))

    def test_plain_human_captions_are_never_inferred_as_rolling(self):
        raw='00:00.000 --> 00:01.000\nYes\n\n00:01.000 --> 00:02.000\nYes\nMore\n\n00:02.000 --> 00:03.000\nMore\nNew'
        self.assertEqual(core.clean_captions(raw),'Yes Yes More More New')

    def test_long_gap_keeps_the_same_line(self):
        raw=rolling()+'''\n00:00:20.000 --> 00:00:22.000
Again we can do this
Later<00:00:20.100><c> in the talk</c>\n'''
        self.assertIn('Again we can do this Again we can do this Later',core.clean_captions(raw))

    def test_single_coincidence_does_not_enable_the_format(self):
        self.assertEqual(core.clean_captions_detailed(rolling().split('00:00:04.000')[0])[1]['removed_display_lines'],0)

    def test_converted_srt_without_word_tags_and_blank_after_timing(self):
        raw='';counter=1
        for i,word in enumerate(['First words','Second phrase','Third sentence','Last line']):
            start=i*2
            payload=word if i==0 else ['First words','Second phrase','Third sentence'][i-1]+'\n'+word
            raw+=f'{counter}\n00:00:{start:02d},010 --> 00:00:{start+1:02d},990\n\n{payload}\n\n';counter+=1
            raw+=f'{counter}\n00:00:{start+1:02d},990 --> 00:00:{start+2:02d},010\n{word}\n\n';counter+=1
        result,proof=core.clean_captions_detailed(raw)
        self.assertTrue(result.startswith('First words Second phrase Third sentence Last line'))
        self.assertEqual(result.count('First words'),1)
        self.assertEqual(result.count('Last line'),1)
        self.assertEqual(proof['rolling_anchors'],0)
        self.assertGreaterEqual(proof['snapshot_anchors'],3)

    def test_spoken_numeric_line_preserved_in_vtt(self):
        raw='WEBVTT\n\n00:00.000 --> 00:01.000\nThe answer is\n2\n\n00:01.000 --> 00:02.000\nNow three'
        self.assertEqual(core.clean_captions(raw),'The answer is 2 Now three')

    def test_legacy_windows_double_cr_keeps_all_payload(self):
        self.assertEqual(core.clean_captions(rolling().replace('\n','\r\r\n')),core.clean_captions(rolling()))


if __name__=='__main__':unittest.main()
