from collections import Counter
import unittest
import caption_encoding_repair as e


class EncodingRepairTest(unittest.TestCase):
    def test_templates_are_learned_between_matching_intact_words(self):
        before=[];after=[]
        for i in range(25):
            word='repere'+chr(97+i)
            before.append(f'{word} cafÔòùû▓ exemple autre{word}.')
            after.append(f'{word} café exemple autre{word}.')
        learned=e.pair_artifacts(' '.join(before),' '.join(after))
        self.assertGreaterEqual(learned[('Ôòùû▓','é')],10)

    def test_independent_videos_and_support_are_required(self):
        pair=Counter({('Ôòùû▓','é'):4})
        self.assertEqual(e.supported_mapping([('a',pair),('b',pair)]),[])
        mapping=e.supported_mapping([('a',pair),('b',pair),('c',pair)])
        self.assertEqual(len(mapping),1)
        self.assertEqual(mapping[0]['occurrences'],12)

    def test_ambiguous_character_mapping_is_rejected(self):
        first=Counter({('Ôòùû▓','é'):20});other=Counter({('Ôòùû▓','à'):1})
        self.assertEqual(e.supported_mapping([('a',first),('b',first),('c',first),('d',other)]),[])

    def test_restore_keeps_ascii_words_and_numbers_exactly(self):
        mapping=[dict(before='Ôòùû▓',after='é')]
        text='Le cafÔòùû▓ vaut 42 euros. '*8
        result,proof=e.restore(text,mapping)
        self.assertTrue(proof['accepted']);self.assertEqual(result,'Le café vaut 42 euros. '*8)
        self.assertTrue(proof['ascii_letters_and_digits_preserved'])

    def test_partially_restored_garbage_is_not_applied(self):
        text='cafÔòùû▓ '*8+'autre Ôö¼ inconnu'
        result,proof=e.restore(text,[dict(before='Ôòùû▓',after='é')])
        self.assertFalse(proof['accepted']);self.assertEqual(result,text)

    def test_legitimate_accents_and_isolated_foreign_fragment_stay(self):
        text='Un café, une expérience et un mot ûó isolé.'
        result,proof=e.restore(text,[dict(before='ûó',after='â')])
        self.assertFalse(proof['accepted']);self.assertEqual(result,text)

    def test_no_template_can_replace_an_ascii_word(self):
        self.assertFalse(e.allowed_artifact('wrong word','é'))
        self.assertFalse(e.allowed_artifact('Ôòùû▓','word'))

    def test_only_demonstrated_nonlinguistic_wrappers_can_be_deleted(self):
        self.assertTrue(e.allowed_artifact('Ôòùû▓Ôòùû▓',''))
        self.assertFalse(e.allowed_artifact('éééééééé',''))
        self.assertFalse(e.allowed_artifact('a word Ôòùû▓Ôòùû▓',''))


if __name__=='__main__':unittest.main()
