# Tag-Retroactive-429.ps1
# Scans logs for 429 errors and tags the database accordingly
$BaseDir = $PSScriptRoot
$LogFile = Join-Path $BaseDir "_LOGS\pipeline.log"
$DbDir = Join-Path $BaseDir "DATA_STORES"
$SqliteExe = Join-Path $BaseDir "BIN\sqlite3.exe"

if (!(Test-Path $LogFile)) { Write-Host "Pas de log." -ForegroundColor Red; exit }

Write-Host "--- MARQUAGE RETROACTIF DES ERREURS 429 ---" -ForegroundColor Cyan

# On cherche les lignes avec 429 et on recupere l'ID dans la ligne precédente
$matches = Select-String -Path $LogFile -Pattern "HTTP Error 429" -Context 1,0
Write-Host "Trouve $($matches.Count) occurrences d'erreurs 429 dans les logs." -ForegroundColor Gray

foreach ($m in $matches) {
    $prevLine = $m.Context.PreContext[0]
    if ($prevLine -match "\[([a-zA-Z0-9_-]{11})\]") {
        $id = $Matches[1]
        
        # On doit trouver a quelle chaine appartient cet ID pour savoir quel DB updater
        # On va scanner les DBs une par une pour cet ID
        $dbFiles = Get-ChildItem $DbDir -Filter "*.db"
        foreach ($db in $dbFiles) {
            $check = & $SqliteExe $db.FullName "SELECT youtube_id FROM videos WHERE youtube_id='$id';"
            if ($check) {
                & $SqliteExe $db.FullName "UPDATE videos SET status='RETRY_429' WHERE youtube_id='$id' AND (transcript IS NULL OR transcript='');"
                Write-Host "  [OK] Tagged $id dans $($db.BaseName)" -ForegroundColor Green
                break
            }
        }
    }
}
Write-Host "--- FIN DU MARQUAGE ---" -ForegroundColor Cyan
