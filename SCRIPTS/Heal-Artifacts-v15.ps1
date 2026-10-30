# Heal-Artifacts-v15.ps1 (v15.0 Industrial Center)
# Repare les artefacts d'encodage et regenere les fichiers statiques.

$PSScriptDir = Split-Path $PSCommandPath -Parent
. (Join-Path $PSScriptDir "Global-Paths.ps1")

Write-Host "--- REPARATION DES ARTEFACTS v15 ---" -ForegroundColor Cyan

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# 1. Définition des remplacements (Artéfact -> Caractère correct)
$replacements = @{
    "├®" = "é"
    "├á" = "à"
    "├¿" = "è"
    "├┤" = "ô"
    "├¬" = "ê"
    "├º" = "ç"
    "├Ç" = "À"
    "├╗" = "û"
    "├«" = "î"
    "├"  = " " # Fallback pour les restes de box drawing
    "╠ü" = ""  # Le combining accent sera géré par la normalisation si possible, ou supprimé si parasite
}

# 2. Correction dans la Base de Données
Write-Host "[1/2] Correction des textes dans la base de données..." -ForegroundColor Gray
$q = "SELECT id, youtube_id, title, transcript FROM videos WHERE transcript IS NOT NULL;"
$videos = & $Sqlite -header -json $DbFile $q | ConvertFrom-Json

$fixedCount = 0
foreach ($v in $videos) {
    $changed = $false
    $t = $v.title
    $tr = $v.transcript

    foreach ($key in $replacements.Keys) {
        if ($t -and $t.Contains($key)) {
            $t = $t.Replace($key, $replacements[$key])
            $changed = $true
        }
        if ($tr -and $tr.Contains($key)) {
            $tr = $tr.Replace($key, $replacements[$key])
            $changed = $true
        }
    }

    # Toujours tenter une normalisation NFC pour transformer "e + accent" en "é"
    if ($t) { $newT = $t.Normalize([System.Text.NormalizationForm]::FormC); if ($newT -ne $t) { $t = $newT; $changed = $true } }
    if ($tr) { $newTr = $tr.Normalize([System.Text.NormalizationForm]::FormC); if ($newTr -ne $tr) { $tr = $newTr; $changed = $true } }

    if ($changed) {
        $st = $t -replace "'", "''"
        $str = $tr -replace "'", "''"
        $updateSql = "UPDATE videos SET title = '$st', transcript = '$str' WHERE id = $($v.id);"
        $updateSql | & $Sqlite $DbFile
        $fixedCount++
    }
}
Write-Host " [OK] $fixedCount vidéos corrigées/normalisées dans la base." -ForegroundColor Green

# 3. Régénération des fichiers statiques
Write-Host "[2/2] Régénération des fichiers .txt dans assets/transcripts/..." -ForegroundColor Gray
$transcriptDir = Join-Path $ProjectRoot "assets\transcripts"
if (!(Test-Path $transcriptDir)) { New-Item $transcriptDir -ItemType Directory | Out-Null }

$tempCsv = Join-Path $env:TEMP "videos_export_$([guid]::NewGuid().ToString().Substring(0,8)).csv"
Write-Host " [>] Exportation des données vers CSV temporaire..." -ForegroundColor Gray

# Force UTF8 for the session to avoid pipe corruption
$oldOutputEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Use redirection instead of pipe if possible, or Out-File with explicit encoding
& $Sqlite -header -csv $DbFile "SELECT youtube_id, transcript FROM videos WHERE transcript IS NOT NULL AND transcript != '';" | Out-File $tempCsv -Encoding utf8

[Console]::OutputEncoding = $oldOutputEncoding

$fixedFiles = 0
$csvData = Import-Csv $tempCsv
foreach ($row in $csvData) {
    $id = $row.youtube_id
    $tr = $row.transcript
    if (!$tr) { continue }
    
    # Normalisation NFC (e+accent -> é)
    $tr = $tr.Normalize([System.Text.NormalizationForm]::FormC)
    
    $filePath = Join-Path $transcriptDir "$id.txt"
    [System.IO.File]::WriteAllText($filePath, $tr, $utf8NoBom)
    $fixedFiles++
}
Remove-Item $tempCsv -ErrorAction SilentlyContinue

Write-Host " [OK] $fixedFiles fichiers .txt ont été régénérés proprement (UTF-8 NFC)." -ForegroundColor Green

# 4. Mise à jour du Dashboard
Write-Host "`nLancement de la synchronisation finale..." -ForegroundColor Cyan
& (Join-Path $PSScriptDir "Sync-Dashboard-v15.ps1")

Write-Host "`nRéparation terminée !" -ForegroundColor Green
