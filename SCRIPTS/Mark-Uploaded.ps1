# Mark-Uploaded.ps1
# Usage: pwsh Mark-Uploaded.ps1 -IDs "ID1,ID2,ID3"

param(
    [string]$IDs
)

$BaseDir = "c:\NoteBookLM"
$DbFile = Join-Path $BaseDir "PIPELINE_V15.db"
$BinDir = Join-Path $BaseDir "BIN"
$Sqlite = Join-Path $BinDir "sqlite3.exe"

if (!$IDs) {
    Write-Host "Veuillez fournir une liste d'IDs séparés par des virgules." -ForegroundColor Red
    exit
}

$idList = $IDs.Split(",").Trim()

foreach ($id in $idList) {
    Write-Host "Marquage de $id comme PUBLIÉ..." -ForegroundColor Cyan
    & $Sqlite $DbFile "UPDATE videos SET recovery_status = 'UPLOADED' WHERE youtube_id = '$id';"
}

Write-Host "Mise à jour terminée. Lancez Sync-Dashboard-v15.ps1 pour voir les changements." -ForegroundColor Green
