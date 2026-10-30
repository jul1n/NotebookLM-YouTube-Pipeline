import unittest

import caption_reconstruction as reconstruction
import pipeline_core as core


def rendered(*cues):
    groups=[]
    for cue in cues:
        plain=' '.join(core.strip_caption_markup(cue).split())
        groups.append(cue+'\n\n\n'+plain+'\n \n\n\n'+plain)
    return '\n'.join(groups)


class ReconstructionTest(unittest.TestCase):
    def test_user_spend_example(self):
        raw=rendered('most<00:00:00.280><c> people think you need to spend</c>',
                     'thousands<00:00:01.640><c> of dollars in ads or have a</c>')
        result=reconstruction.reconstruct(raw)
        self.assertEqual(result['text'],'most people think you need to spend thousands of dollars in ads or have a')
        self.assertEqual(result['removed_copy_lines'],4)
        self.assertTrue(result['evidence']['all_lines_accounted_for'])

    def test_user_free_tool_example(self):
        raw=rendered('so<00:00:00.240><c> this is how I made $5,000 us with a</c>',
                     'free<00:00:02.720><c> tool I built in 3</c>')
        self.assertEqual(reconstruction.reconstruct(raw)['text'],'so this is how I made $5,000 us with a free tool I built in 3')

    def test_user_software_businesses_example(self):
        raw=rendered('I<00:00:00.560><c> have built these 10 software</c>',
                     'businesses.<00:00:02.480><c> Altogether, they made over</c>')
        self.assertEqual(reconstruction.reconstruct(raw)['text'],'I have built these 10 software businesses. Altogether, they made over')

    def test_user_stripe_example(self):
        raw=rendered('even<00:00:00.240><c> though the stripe API documentation</c>',
                     'is<00:00:02.399><c> longer than Lord of the Rings there</c>')
        self.assertEqual(reconstruction.reconstruct(raw)['text'],'even though the stripe API documentation is longer than Lord of the Rings there')

    def test_user_forever_example(self):
        raw=rendered('pick<00:00:00.320><c> one text tag and stick to it</c>',
                     'forever.<00:00:02.320><c> 3 years ago, I made the</c>')
        self.assertEqual(reconstruction.reconstruct(raw)['text'],'pick one text tag and stick to it forever. 3 years ago, I made the')

    def test_repetition_inside_spoken_cue_is_preserved(self):
        raw=rendered('This<00:00:00.240><c> is very very very important</c>',
                     'Yes,<00:00:02.000><c> yes, I mean that</c>')
        self.assertEqual(reconstruction.reconstruct(raw)['text'],'This is very very very important Yes, yes, I mean that')

    def test_identical_speech_at_different_times_is_preserved(self):
        raw=rendered('We<00:00:00.240><c> can do this</c>',
                     'We<00:00:10.240><c> can do this</c>')
        self.assertEqual(reconstruction.reconstruct(raw)['text'],'We can do this We can do this')

    def test_arbitrary_prose_repetition_is_never_deduplicated(self):
        raw='Never give up.\n\nNever give up.\n\nNever give up.'
        result=reconstruction.reconstruct(raw)
        self.assertEqual(result['mode'],'markup_only')
        self.assertEqual(result['text'],raw)

    def test_one_group_is_insufficient_format_evidence(self):
        raw=rendered('We<00:00:00.240><c> can do this</c>')
        result=reconstruction.reconstruct(raw)
        self.assertEqual(result['removed_copy_lines'],0)

    def test_untimed_cue_is_inferred_only_with_confirmed_format(self):
        raw=rendered('One<00:00:00.240><c> timed block</c>',
                     'Another<00:00:02.240><c> timed block</c>','[Music]','product')
        result=reconstruction.reconstruct(raw)
        self.assertEqual(result['text'],'One timed block Another timed block [Music] product')
        self.assertEqual(result['evidence']['inferred_untimed_groups'],2)
        self.assertTrue(result['requires_review'])

    def test_six_untimed_copies_represent_two_utterances(self):
        raw=rendered('One<00:00:00.240><c> timed block</c>',
                     'Another<00:00:02.240><c> timed block</c>','yes','yes')
        self.assertTrue(reconstruction.reconstruct(raw)['text'].endswith('yes yes'))

    def test_untimed_repetition_without_rendering_separators_is_kept(self):
        raw=rendered('One<00:00:00.240><c> timed block</c>',
                     'Another<00:00:02.240><c> timed block</c>')+'\nno\nno\nno'
        self.assertTrue(reconstruction.reconstruct(raw)['text'].endswith('no no no'))

    def test_nonconforming_timed_material_does_not_get_format_inference(self):
        raw=rendered('One<00:00:00.240><c> block</c>',
                     'Another<00:00:02.240><c> block</c>')+'\nOther<00:00:03.000> words\nMore<00:00:04.000> words'
        self.assertEqual(reconstruction.reconstruct(raw)['mode'],'markup_only')


if __name__=='__main__':unittest.main()
