-- super_heal.sql
-- Réparation profonde des artefacts d'encodage (Mojibake) utilisant des séquences hexadécimales.

BEGIN TRANSACTION;

-- 1. Réparation des patterns "├" (UTF-8 bytes insérés comme caractères CP850)
-- ├® (C3 A9 -> é)
UPDATE videos SET 
    transcript = REPLACE(transcript, X'E2949CC2AE', X'C3A9'),
    title = REPLACE(title, X'E2949CC2AE', X'C3A9')
WHERE transcript LIKE '%' || X'E2949CC2AE' || '%' OR title LIKE '%' || X'E2949CC2AE' || '%';

-- ├¿ (C3 A8 -> è)
UPDATE videos SET 
    transcript = REPLACE(transcript, X'E2949CC2A8', X'C3A8'),
    title = REPLACE(title, X'E2949CC2A8', X'C3A8')
WHERE transcript LIKE '%' || X'E2949CC2A8' || '%' OR title LIKE '%' || X'E2949CC2A8' || '%';

-- ├á (C3 A0 -> à)
UPDATE videos SET 
    transcript = REPLACE(transcript, X'E2949CC3A1', X'C3A0'),
    title = REPLACE(title, X'E2949CC3A1', X'C3A0')
WHERE transcript LIKE '%' || X'E2949CC3A1' || '%' OR title LIKE '%' || X'E2949CC3A1' || '%';

-- ├¬ (C3 AA -> ê)
UPDATE videos SET 
    transcript = REPLACE(transcript, X'E2949CC2AA', X'C3AA'),
    title = REPLACE(title, X'E2949CC2AA', X'C3AA')
WHERE transcript LIKE '%' || X'E2949CC2AA' || '%' OR title LIKE '%' || X'E2949CC2AA' || '%';

-- ├┤ (C3 B4 -> ô)
UPDATE videos SET 
    transcript = REPLACE(transcript, X'E2949CC2B4', X'C3B4'),
    title = REPLACE(title, X'E2949CC2B4', X'C3B4')
WHERE transcript LIKE '%' || X'E2949CC2B4' || '%' OR title LIKE '%' || X'E2949CC2B4' || '%';

-- ├╗ (C3 BB -> û)
UPDATE videos SET 
    transcript = REPLACE(transcript, X'E2949CC2BB', X'C3BB'),
    title = REPLACE(title, X'E2949CC2BB', X'C3BB')
WHERE transcript LIKE '%' || X'E2949CC2BB' || '%' OR title LIKE '%' || X'E2949CC2BB' || '%';

-- ├╣ (C3 B9 -> ù)
UPDATE videos SET 
    transcript = REPLACE(transcript, X'E2949CC2B9', X'C3B9'),
    title = REPLACE(title, X'E2949CC2B9', X'C3B9')
WHERE transcript LIKE '%' || X'E2949CC2B9' || '%' OR title LIKE '%' || X'E2949CC2B9' || '%';

-- ├º (C3 A7 -> ç)
UPDATE videos SET 
    transcript = REPLACE(transcript, X'E2949CC2BA', X'C3A7'),
    title = REPLACE(title, X'E2949CC2BA', X'C3A7')
WHERE transcript LIKE '%' || X'E2949CC2BA' || '%' OR title LIKE '%' || X'E2949CC2BA' || '%';

-- ├Ç (C3 87 -> Ç)
UPDATE videos SET 
    transcript = REPLACE(transcript, X'E2949CC387', X'C387'),
    title = REPLACE(title, X'E2949CC387', X'C387')
WHERE transcript LIKE '%' || X'E2949CC387' || '%' OR title LIKE '%' || X'E2949CC387' || '%';

-- ├ü (C3 81 -> é dans certains titres)
UPDATE videos SET 
    transcript = REPLACE(transcript, X'E2949CC381', X'C3A9'),
    title = REPLACE(title, X'E2949CC381', X'C3A9')
WHERE transcript LIKE '%' || X'E2949CC381' || '%' OR title LIKE '%' || X'E2949CC381' || '%';


-- 2. Réparation des formes décomposées (NFD -> NFC)
-- e + ╠ü (65 CC 81 -> é C3 A9)
UPDATE videos SET 
    transcript = REPLACE(transcript, X'65CC81', X'C3A9'),
    title = REPLACE(title, X'65CC81', X'C3A9')
WHERE transcript LIKE '%' || X'65CC81' || '%' OR title LIKE '%' || X'65CC81' || '%';

-- a + ╠Ç (61CC80 -> à C3A0)
UPDATE videos SET transcript = REPLACE(transcript, X'61CC80', X'C3A0'), title = REPLACE(title, X'61CC80', X'C3A0') WHERE transcript LIKE '%' || X'61CC80' || '%';
-- e + ╠Ç (65CC80 -> è C3A8)
UPDATE videos SET transcript = REPLACE(transcript, X'65CC80', X'C3A8'), title = REPLACE(title, X'65CC80', X'C3A8') WHERE transcript LIKE '%' || X'65CC80' || '%';
-- e + ╠é (65CC82 -> ê C3AA)
UPDATE videos SET transcript = REPLACE(transcript, X'65CC82', X'C3AA'), title = REPLACE(title, X'65CC82', X'C3AA') WHERE transcript LIKE '%' || X'65CC82' || '%';


-- 3. Réparation des tirets et autres
-- ÔÇö (E28094 -> — E28094) -- Si inséré comme caractères littéraux UTF-8 de Ô, Ç, ö
-- En fait, si c'est déjà E2 80 94 dans la DB, c'est correct pour UTF-8.
-- Si le dashboard affiche ÔÇö, c'est que la DB contient les CARACTÈRES Ô, Ç, ö.
-- Ô (C394), Ç (C387), ö (C3B6)
UPDATE videos SET 
    transcript = REPLACE(transcript, X'C394C387C3B6', X'E28094'),
    title = REPLACE(title, X'C394C387C3B6', X'E28094')
WHERE transcript LIKE '%' || X'C394C387C3B6' || '%' OR title LIKE '%' || X'C394C387C3B6' || '%';

-- 4. Cas particuliers du screenshot
-- "trompe╠ü" -> "trompé"
-- On a déjà fait 65CC81 -> C3A9, ce qui couvre "e╠ü" -> "é".

COMMIT;

-- Rebuild FTS5
INSERT INTO videos_fts(videos_fts) VALUES('rebuild');
