-- SQL-Heal-v15.sql
-- Modular version to avoid parser stack overflow.

BEGIN TRANSACTION;

-- 1. Mojibake Cleanup (Transcript) - Group 1 (Lower case accents)
UPDATE videos SET transcript = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(transcript, 
    'Ã©', 'é'), 'Ã¨', 'è'), 'Ã ', 'à'), 'Ãª', 'ê'), 'Ã´', 'ô'), 'Ã§', 'ç'), 'Ã»', 'û'), 'Ã¹', 'ù'), 'Ã®', 'î'), 'Ã¯', 'ï'), 'Ã«', 'ë')
WHERE transcript LIKE '%Ã%';

-- Group 2 (├ patterns)
UPDATE videos SET transcript = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(transcript, 
    '├®', 'é'), '├¿', 'è'), '├ ', 'à'), '├ª', 'ê'), '├┤', 'ô'), '├º', 'ç'), '├╗', 'û'), '├╣', 'ù'), '├«', 'î'), '├»', 'ï'), '├½', 'ë')
WHERE transcript LIKE '%├%';

-- Group 3 (Capitals & Misc)
UPDATE videos SET transcript = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(transcript, 
    'Ã‰', 'É'), 'Ã€', 'À'), 'Ãˆ', 'È'), 'ÃŽ', 'Î'), 'Ã_', 'í'), 'Ã¦', 'æ'), 'Ã¶', 'ö'), 'Ã¡', 'á'), 'Ã±', 'ñ'), 'Ã¼', 'ü'), 'ûºa', 'ça'), 'ûº', 'ç'), 'oû╣', 'où')
WHERE transcript LIKE '%Ã%' OR transcript LIKE '%ûº%' OR transcript LIKE '%oû╣%';

-- 2. Titles Cleanup
UPDATE videos SET title = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(title, 
    'Ã©', 'é'), 'Ã¨', 'è'), 'Ã ', 'à'), 'Ãª', 'ê'), 'Ã´', 'ô'), 'Ã§', 'ç'), 'Ã»', 'û'), 'Ã¹', 'ù'), 'Ã®', 'î'), 'Ã¯', 'ï'), 'Ã«', 'ë')
WHERE title LIKE '%Ã%';

UPDATE videos SET title = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(title, 
    '├®', 'é'), '├¿', 'è'), '├ ', 'à'), '├ª', 'ê'), '├┤', 'ô'), '├º', 'ç'), '├╗', 'û'), '├╣', 'ù'), '├«', 'î'), '├»', 'ï'), '├½', 'ë')
WHERE title LIKE '%├%';

UPDATE videos SET title = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(title, 
    'Ã‰', 'É'), 'Ã€', 'À'), 'Ãˆ', 'È'), 'ÃŽ', 'Î'), 'Ã_', 'í'), 'Ã¦', 'æ'), 'Ã¶', 'ö'), 'Ã¡', 'á'), 'Ã±', 'ñ'), 'Ã¼', 'ü'), 'ûºa', 'ça'), 'ûº', 'ç'), 'oû╣', 'où')
WHERE title LIKE '%Ã%' OR title LIKE '%ûº%' OR title LIKE '%oû╣%';

-- 3. Specific Mojibake for Apostrophes (Æ, etc.)
UPDATE videos SET transcript = REPLACE(REPLACE(transcript, 'Æ', ''''), 'Â', '') WHERE transcript LIKE '%Æ%' OR transcript LIKE '%Â%';
UPDATE videos SET title = REPLACE(REPLACE(title, 'Æ', ''''), 'Â', '') WHERE title LIKE '%Æ%' OR title LIKE '%Â%';

-- 4. Noise Cleanup (Case Variations)
UPDATE videos SET transcript = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(transcript, 
    '[Music]', ''), '[MUSIC]', ''), '[music]', ''), '[Musique]', ''), '[MUSIQUE]', ''), '[musique]', ''),
    '[Applause]', ''), '[APPLAUSE]', ''), '[applause]', ''), '[Applaudissements]', ''), '[APPLAUDISSEMENTS]', ''), '[applaudissements]', ''),
    '(Rires)', ''), '(Laughter)', ''), '[Silence]', ''), '[Rires]', '')
WHERE transcript LIKE '%[%' OR transcript LIKE '%(%';

-- 5. Space Normalization
UPDATE videos SET transcript = REPLACE(transcript, '  ', ' ') WHERE transcript LIKE '%  %';

COMMIT;
