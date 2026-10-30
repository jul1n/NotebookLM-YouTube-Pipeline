
$dbPath = "c:\NoteBookLM\PIPELINE_V15.db"
$uploadDir = "c:\NoteBookLM\_UPLOAD_FOR_SUBS"
$sqlitePath = "c:\NoteBookLM\BIN\sqlite3.exe"

if (!(Test-Path $uploadDir)) {
    Write-Host "Dossier non trouvé : $uploadDir" -ForegroundColor Red
    exit
}

$files = Get-ChildItem $uploadDir -Filter "*.mp4"
Write-Host "Analyse de $($files.Count) fichiers dans $uploadDir..." -ForegroundColor Cyan

$deletedCount = 0
foreach ($f in $files) {
    if ($f.Name -match "\[([a-zA-Z0-9_-]{11})\]") {
        $id = $Matches[1]
        $status = & $sqlitePath $dbPath "SELECT status FROM videos WHERE youtube_id = '$id';"
        
        if ($status -like "*SUCCESS*") {
            Write-Host "Suppression de $($f.Name) (Statut DB: $status)" -ForegroundColor Yellow
            Remove-Item -LiteralPath $f.FullName -Force
            $deletedCount++
        }
    }
}

Write-Host "Nettoyage terminé. $deletedCount fichiers supprimés." -ForegroundColor Green
