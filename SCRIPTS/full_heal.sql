-- full_heal.sql
BEGIN TRANSACTION;

-- Mapping des artefacts d'encodage (Mojibake)
-- ├ (UTF-8 lu en CP850)
UPDATE videos SET transcript = REPLACE(transcript, '├®', 'é'), title = REPLACE(title, '├®', 'é') WHERE transcript LIKE '%├®%' OR title LIKE '%├®%';
UPDATE videos SET transcript = REPLACE(transcript, '├¿', 'è'), title = REPLACE(title, '├¿', 'è') WHERE transcript LIKE '%├¿%' OR title LIKE '%├¿%';
UPDATE videos SET transcript = REPLACE(transcript, '├á', 'à'), title = REPLACE(title, '├á', 'à') WHERE transcript LIKE '%├á%' OR title LIKE '%├á%';
UPDATE videos SET transcript = REPLACE(transcript, '├ª', 'ê'), title = REPLACE(title, '├ª', 'ê') WHERE transcript LIKE '%├ª%' OR title LIKE '%├ª%';
UPDATE videos SET transcript = REPLACE(transcript, '├¬', 'ê'), title = REPLACE(title, '├¬', 'ê') WHERE transcript LIKE '%├¬%' OR title LIKE '%├¬%';
UPDATE videos SET transcript = REPLACE(transcript, '├┤', 'ô'), title = REPLACE(title, '├┤', 'ô') WHERE transcript LIKE '%├┤%' OR title LIKE '%├┤%';
UPDATE videos SET transcript = REPLACE(transcript, '├╗', 'û'), title = REPLACE(title, '├╗', 'û') WHERE transcript LIKE '%├╗%' OR title LIKE '%├╗%';
UPDATE videos SET transcript = REPLACE(transcript, '├╣', 'ù'), title = REPLACE(title, '├╣', 'ù') WHERE transcript LIKE '%├╣%' OR title LIKE '%├╣%';
UPDATE videos SET transcript = REPLACE(transcript, '├º', 'ç'), title = REPLACE(title, '├º', 'ç') WHERE transcript LIKE '%├º%' OR title LIKE '%├º%';
UPDATE videos SET transcript = REPLACE(transcript, '├î', 'î'), title = REPLACE(title, '├î', 'î') WHERE transcript LIKE '%├î%' OR title LIKE '%├î%';
UPDATE videos SET transcript = REPLACE(transcript, '├Ç', 'Ç'), title = REPLACE(title, '├Ç', 'Ç') WHERE transcript LIKE '%├Ç%' OR title LIKE '%├Ç%';
UPDATE videos SET transcript = REPLACE(transcript, '├ü', 'é'), title = REPLACE(title, '├ü', 'é') WHERE transcript LIKE '%├ü%' OR title LIKE '%├ü%';
UPDATE videos SET transcript = REPLACE(transcript, '├╝', 'ü'), title = REPLACE(title, '├╝', 'ü') WHERE transcript LIKE '%├╝%' OR title LIKE '%├╝%';
UPDATE videos SET transcript = REPLACE(transcript, '├½', 'ë'), title = REPLACE(title, '├½', 'ë') WHERE transcript LIKE '%├½%' OR title LIKE '%├½%';
UPDATE videos SET transcript = REPLACE(transcript, '├»', 'ï'), title = REPLACE(title, '├»', 'ï') WHERE transcript LIKE '%├»%' OR title LIKE '%├»%';

-- Ã (UTF-8 lu en CP1252)
UPDATE videos SET transcript = REPLACE(transcript, 'Ã©', 'é'), title = REPLACE(title, 'Ã©', 'é') WHERE transcript LIKE '%Ã©%' OR title LIKE '%Ã©%';
UPDATE videos SET transcript = REPLACE(transcript, 'Ã¨', 'è'), title = REPLACE(title, 'Ã¨', 'è') WHERE transcript LIKE '%Ã¨%' OR title LIKE '%Ã¨%';
UPDATE videos SET transcript = REPLACE(transcript, 'Ã ', 'à'), title = REPLACE(title, 'Ã ', 'à') WHERE transcript LIKE '%Ã %' OR title LIKE '%Ã %';
UPDATE videos SET transcript = REPLACE(transcript, 'Ãª', 'ê'), title = REPLACE(title, 'Ãª', 'ê') WHERE transcript LIKE '%Ãª%' OR title LIKE '%Ãª%';
UPDATE videos SET transcript = REPLACE(transcript, 'Ã´', 'ô'), title = REPLACE(title, 'Ã´', 'ô') WHERE transcript LIKE '%Ã´%' OR title LIKE '%Ã´%';
UPDATE videos SET transcript = REPLACE(transcript, 'Ã§', 'ç'), title = REPLACE(title, 'Ã§', 'ç') WHERE transcript LIKE '%Ã§%' OR title LIKE '%Ã§%';
UPDATE videos SET transcript = REPLACE(transcript, 'Ã»', 'û'), title = REPLACE(title, 'Ã»', 'û') WHERE transcript LIKE '%Ã»%' OR title LIKE '%Ã»%';
UPDATE videos SET transcript = REPLACE(transcript, 'Ã¹', 'ù'), title = REPLACE(title, 'Ã¹', 'ù') WHERE transcript LIKE '%Ã¹%' OR title LIKE '%Ã¹%';
UPDATE videos SET transcript = REPLACE(transcript, 'Ã®', 'î'), title = REPLACE(title, 'Ã®', 'î') WHERE transcript LIKE '%Ã®%' OR title LIKE '%Ã®%';
UPDATE videos SET transcript = REPLACE(transcript, 'Ã¯', 'ï'), title = REPLACE(title, 'Ã¯', 'ï') WHERE transcript LIKE '%Ã¯%' OR title LIKE '%Ã¯%';
UPDATE videos SET transcript = REPLACE(transcript, 'Ã«', 'ë'), title = REPLACE(title, 'Ã«', 'ë') WHERE transcript LIKE '%Ã«%' OR title LIKE '%Ã«%';
UPDATE videos SET transcript = REPLACE(transcript, 'Ã‰', 'É'), title = REPLACE(title, 'Ã‰', 'É') WHERE transcript LIKE '%Ã‰%' OR title LIKE '%Ã‰%';
UPDATE videos SET transcript = REPLACE(transcript, 'Ã€', 'À'), title = REPLACE(title, 'Ã€', 'À') WHERE transcript LIKE '%Ã€%' OR title LIKE '%Ã€%';
UPDATE videos SET transcript = REPLACE(transcript, 'Ãˆ', 'È'), title = REPLACE(title, 'Ãˆ', 'È') WHERE transcript LIKE '%Ãˆ%' OR title LIKE '%Ãˆ%';
UPDATE videos SET transcript = REPLACE(transcript, 'ÃŽ', 'Î'), title = REPLACE(title, 'ÃŽ', 'Î') WHERE transcript LIKE '%ÃŽ%' OR title LIKE '%ÃŽ%';

-- Autres
UPDATE videos SET transcript = REPLACE(transcript, 'Æ', ''''), title = REPLACE(title, 'Æ', '''') WHERE transcript LIKE '%Æ%' OR title LIKE '%Æ%';
UPDATE videos SET transcript = REPLACE(transcript, 'Â', ''), title = REPLACE(title, 'Â', '') WHERE transcript LIKE '%Â%' OR title LIKE '%Â%';
UPDATE videos SET transcript = REPLACE(transcript, 'Ã_', 'í'), title = REPLACE(title, 'Ã_', 'í') WHERE transcript LIKE '%Ã_%' OR title LIKE '%Ã_%';

-- Normalisation
UPDATE videos SET transcript = REPLACE(transcript, '  ', ' ') WHERE transcript LIKE '%  %';

COMMIT;

-- Rebuild FTS5 index
INSERT INTO videos_fts(videos_fts) VALUES('rebuild');
