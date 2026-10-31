import unittest
import caption_quality as q


class ReviewSignalsTest(unittest.TestCase):
    def test_sound_annotations_are_counted_separately_without_rewriting(self):
        text='[Music] [Music] [Music] [Music]'
        result=q.inspect_text(text)
        self.assertEqual(result['suspected_repetitions'],1)
        self.assertEqual(result['review_signals']['nonverbal_only_alerts'],1)
        self.assertEqual(text,'[Music] [Music] [Music] [Music]')

    def test_oral_fillers_are_distinguished_from_long_copies(self):
        result=q.inspect_text('you know you know you know')
        self.assertEqual(result['review_signals']['short_filler_alerts'],1)
        result=q.inspect_text('we shall demonstrate how this experiment works we shall demonstrate how this experiment works')
        self.assertEqual(result['review_signals']['long_repetition_alerts'],1)
        self.assertEqual(result['review_signals']['short_filler_alerts'],0)

    def test_speech_between_annotations_is_not_nonverbal(self):
        result=q.inspect_text('hello there [Music] hello there [Music] hello there [Music]')
        self.assertEqual(result['review_signals']['nonverbal_only_alerts'],0)


if __name__=='__main__':unittest.main()
