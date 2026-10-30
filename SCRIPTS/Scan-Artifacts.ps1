# Scan-Artifacts.ps1 (v15.0 Industrial Center)
# Scans the database and transcript files for encoding artifacts like |—®, ├®, ╠ü, etc.

$PSScriptDir = Split-Path $PSCommandPath -Parent
. (Join-Path $PSScriptDir "Global-Paths.ps1")

Write-Host "--- SCAN DES ARTEFACTS D'ENCODAGE ---" -ForegroundColor Cyan

# Patterns to look for
$patterns = @('├', '╠', 'Ã©', 'Ã', 'â', '€', '|—')

# 1. Scan Database
Write-Host "[1/2] Scan de la base de données..." -ForegroundColor Gray
$corruptedInDb = @()

foreach ($p in $patterns) {
    $q = "SELECT youtube_id, title FROM videos WHERE (transcript LIKE '%$p%' OR title LIKE '%$p%') AND transcript IS NOT NULL;"
    $results = & $Sqlite -header -json $DbFile $q | ConvertFrom-Json
    if ($results) {
        foreach ($r in $results) {
            $corruptedInDb += [PSCustomObject]@{
                ID = $r.youtube_id
                Title = $r.title
                Pattern = $p
            }
        }
    }
}

$corruptedInDb = $corruptedInDb | Select-Object -Unique ID, Title, Pattern

if ($corruptedInDb) {
    Write-Host " [!] $($corruptedInDb.Count) vidéos avec artéfacts détectées dans la base." -ForegroundColor Yellow
    $corruptedInDb | Format-Table -AutoSize
} else {
    Write-Host " [OK] Aucun artéfact détecté dans les textes de la base." -ForegroundColor Green
}

# 2. Scan Transcript Files
Write-Host "[2/2] Scan des fichiers transcripts statiques..." -ForegroundColor Gray
$transcriptDir = Join-Path $ProjectRoot "assets\transcripts"
$corruptedFiles = @()

if (Test-Path $transcriptDir) {
    $files = Get-ChildItem $transcriptDir -Filter "*.txt"
    foreach ($f in $files) {
        $content = Get-Content $f.FullName -Raw -Encoding utf8
        foreach ($p in $patterns) {
            if ($content.Contains($p)) {
                $corruptedFiles += $f.Name
                break
            }
        }
    }
}

if ($corruptedFiles) {
    Write-Host " [!] $($corruptedFiles.Count) fichiers .txt corrompus détectés dans assets/transcripts/." -ForegroundColor Yellow
    Write-Host " (Exemple: $($corruptedFiles[0]))"
} else {
    Write-Host " [OK] Tous les fichiers transcripts sont propres." -ForegroundColor Green
}

Write-Host "`nTerminé." -ForegroundColor Cyan
