
$DbPath = "C:\NoteBookLM\DATABASE\PIPELINE_V15.db"
$Sqlite = "C:\NoteBookLM\RESOURCES\BIN\sqlite3.exe"

Write-Host "--- REVERSION : SUPPRESSION DE L'INDEX FTS5 ---" -ForegroundColor Yellow

$cleanupSql = @"
DROP TRIGGER IF EXISTS videos_ai;
DROP TRIGGER IF EXISTS videos_ad;
DROP TRIGGER IF EXISTS videos_au;
DROP TABLE IF EXISTS videos_fts;
"@

& $Sqlite $DbPath $cleanupSql

Write-Host "L'index et les triggers ont été supprimés. La base est revenue à son état initial." -ForegroundColor Green
