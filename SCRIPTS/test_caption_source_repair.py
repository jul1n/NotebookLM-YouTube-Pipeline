import unittest
import caption_source_repair as repair


class SourceRepairTest(unittest.TestCase):
    def test_varied_short_document_is_recovered(self):
        units=[f'This is phrase number {i} in the source.' for i in range(35)]
        text=' '.join(' '.join([unit]*3) for unit in units)
        result,proof=repair.complete_triplicates(text)
        self.assertTrue(proof['accepted'])
        self.assertEqual(result,' '.join(units))

    def test_music_or_hallucination_loop_is_not_format_evidence(self):
        text="I'm going to do a little bit of the same. "*150
        result,proof=repair.complete_triplicates(text)
        self.assertFalse(proof['accepted']);self.assertEqual(result,text)

    def test_short_cues_and_internal_repetitions_are_kept_once(self):
        units=[]
        for i in range(40):
            units.extend([f'Long phrase number {i} we can we can finish.',f'Short {i}'])
        text=' '.join(' '.join([unit]*3) for unit in units)
        result,proof=repair.complete_triplicates(text)
        self.assertTrue(proof['accepted']);self.assertEqual(result,' '.join(units))
        self.assertIn('we can we can',result)

    def test_isolated_spoken_repetition_is_preserved(self):
        text='Please, please, please, listen. We can do this We can do this.'
        self.assertEqual(repair.complete_triplicates(text)[0],text)

    def test_wording_match_preserves_accents_and_rejects_other_video(self):
        text=' '.join(f'Une expérience numéro {i} permet une conclusion différente résultat{chr(97+i//26)}{chr(97+i%26)}.' for i in range(80))
        plain=''.join(c for c in __import__('unicodedata').normalize('NFKD',text) if not __import__('unicodedata').combining(c))
        self.assertTrue(repair.concordance(plain,text)['accepted'])
        other=' '.join(f'Other distinct argument {i} about birds flying around planet{i}.' for i in range(80))
        self.assertFalse(repair.concordance(text,other)['accepted'])


if __name__=='__main__':unittest.main()
