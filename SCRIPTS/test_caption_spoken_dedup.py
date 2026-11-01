import unittest
from caption_spoken_dedup import deduplicate

class SpokenDedupTest(unittest.TestCase):
    def test_tics_and_emphasis(self):
        self.assertEqual(deduplicate('I I really really want to go want to go home.')[0],'I really want to go home.')
        self.assertEqual(deduplicate('No, no, no, this works.')[0],'No, this works.')
    def test_cascading_repeats(self):
        self.assertEqual(deduplicate('one two one two two one two end')[0],'one two end')
    def test_punctuation(self):
        self.assertEqual(deduplicate('Go home. Go home! Next.')[0],'Go home! Next.')
    def test_numbers_preserved(self):
        for text in ['1 1 1', 'In 2020 in 2020 sales rose.', '10.10 10.10']:
            self.assertEqual(deduplicate(text)[0],text)
    def test_grammatical_doubles(self):
        for text in ['Nous nous sommes vus.', 'Vous vous souvenez.', 'I had had enough.', 'I think that that works.', 'It is not not true.']:
            self.assertEqual(deduplicate(text)[0],text)
        self.assertEqual(deduplicate('Nous nous sommes vus nous nous sommes vus hier.')[0],'Nous nous sommes vus hier.')

    def test_nonadjacent_and_different_words(self):
        for text in ['I want this but I want that.', 'I do not agree. I agree.', 'Bonjour tout le monde.']:
            self.assertEqual(deduplicate(text)[0],text)
    def test_long_and_idempotent(self):
        unit=' '.join('word'+chr(97+i//26)+chr(97+i%26) for i in range(80))
        text=unit+' '+unit+' ending';result,_=deduplicate(text)
        self.assertEqual(result,unit+' ending');self.assertEqual(deduplicate(result)[0],result)
    def test_unicode_and_annotations(self):
        self.assertEqual(deduplicate('Écoute écoute, voilà.')[0],'Écoute, voilà.')
        self.assertEqual(deduplicate('[Music] [Music] End')[0],'[Music] End')

if __name__=='__main__':unittest.main()
