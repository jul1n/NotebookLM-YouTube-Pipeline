# Import-Surgical-v15.ps1 (v15.0 Industrial Center)
# Migration chirurgicale des données depuis l'ancienne structure (DATA_STORES).
# Utilise des fichiers SQL temporaires pour éviter les limites de ligne de commande Windows.

$PSScriptDir = Split-Path $PSCommandPath -Parent
. (Join-Path $PSScriptDir "Global-Paths.ps1")

$OldStoresDir = Join-Path $OldDir "DATA_STORES"
$TempSqlFile = Join-Path $TempDir "temp_import.sql"

if (!(Test-Path $OldStoresDir)) {
    Write-Host "Info : Dossier OLD/DATA_STORES non trouvé. Migration ignorée." -ForegroundColor Yellow
    exit
}

Write-Host "--- IMPORTATION CHIRURGICALE v15 (INDUSTRIAL CENTER) ---" -ForegroundColor Cyan

$oldDbs = Get-ChildItem $OldStoresDir -Filter "*.db"

foreach ($oldDb in $oldDbs) {
    $prefix = $oldDb.BaseName
    Write-Host "Migration de $prefix..." -ForegroundColor Gray
    
    # Trouver le channel_id en base v15
    $chanIdSql = "SELECT id FROM channels WHERE prefix = '$($prefix -replace "'", "''")';"
    $chanId = & $Sqlite $DbFile $chanIdSql
    if (!$chanId) {
        & $Sqlite $DbFile "INSERT INTO channels (prefix) VALUES ('$($prefix -replace "'", "''")');"
        $chanId = & $Sqlite $DbFile $chanIdSql
    }

    # Extraction CSV des anciennes données
    $exportSql = "SELECT youtube_id, title, transcript, status, upload_date, duration FROM videos;"
    $data = & $Sqlite $oldDb.FullName -header -csv $exportSql | ConvertFrom-Csv
    
    if ($data) {
        $batchSql = "BEGIN TRANSACTION;`n"
        foreach ($row in $data) {
            $batchSql += "INSERT OR IGNORE INTO videos (channel_id, youtube_id, title, transcript, status, upload_date, duration) 
                          VALUES ($chanId, '$($row.youtube_id)', '$($row.title -replace "'", "''")', '$($row.transcript -replace "'", "''")', '$($row.status)', '$($row.upload_date)', '$($row.duration)');`n"
            
            # Flush every 100 videos to keep file size manageable and avoid extreme string concatenation
            if ($batchSql.Length -gt 1000000) {
                $batchSql += "COMMIT;"
                $batchSql | Out-File $TempSqlFile -Encoding utf8
                & $Sqlite $DbFile ".read $TempSqlFile"
                $batchSql = "BEGIN TRANSACTION;`n"
            }
        }
        $batchSql += "COMMIT;"
        $batchSql | Out-File $TempSqlFile -Encoding utf8
        & $Sqlite $DbFile ".read $TempSqlFile"
    }
}

if (Test-Path $TempSqlFile) { Remove-Item $TempSqlFile }
Write-Host "Terminé !" -ForegroundColor Green
