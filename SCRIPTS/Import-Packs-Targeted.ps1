# Import-Packs-Targeted.ps1
# Imports concatenated transcripts from IMPORT TEMP into the SQLite DB.

$BaseDir = $PSScriptRoot
$ImportDir = Join-Path $BaseDir "IMPORT TEMP"
$TargetChannel = "Example Channel"
$DbPath = Join-Path $BaseDir "DATA_STORES\$TargetChannel.db"
$Sqlite = Join-Path $BaseDir "BIN\sqlite3.exe"

function Get-CleanTranscript {
    param($content)
    if (!$content) { return "" }
    $txt = $content -replace '(?s)<.*?>', '' -replace '(?m)^WEBVTT\s*$', '' -replace '(?m)^Kind:.*$', '' -replace '(?m)^Language:.*$', ''
    $txt = $txt -replace '(align|position|size|line|vertical|region|style):\S+', ' '
    $txt = $txt -replace '\d{8}\|\d{1,2}:\d{2}:\d{2}[\.,]\d{3}', ' '
    $txt = $txt -replace '\d{1,2}:\d{2}:\d{2}[\.,]\d{3}\s*-->\s*\d{1,2}:\d{2}:\d{2}[\.,]\d{3}', ' '
    $txt = $txt -replace '\b\d{1,2}:\d{2}\b', ' '
    $txt = $txt -replace '(?m)^\d+\s*$', '' -replace '&\w+;', ' ' -replace '\s+', ' '
    
    # Unicode Normalization
    $txt = $txt -replace '[\u2018\u2019\u201A\u201B]', "'"
    $txt = $txt -replace '[\u201C\u201D\u201E\u201F]', '"'
    $txt = $txt -replace '([a-zA-Z])\?([a-zA-Z])', '$1''$2'
    
    $words = $txt -split "\s+" | Where-Object { $_ -ne "" }
    $uniqueWords = [System.Collections.Generic.List[string]]::new(); $lastW = ""
    foreach ($w in $words) { if ($w -ne $lastW) { $uniqueWords.Add($w); $lastW = $w } }
    return $uniqueWords -join " "
}

Write-Host "--- IMPORTATION DES PACKS $TargetChannel ---" -ForegroundColor Cyan

if (!(Test-Path $DbPath)) {
    Write-Host "  [!] Base de donnees introuvable. Creation..." -ForegroundColor Yellow
    $schema = "CREATE TABLE IF NOT EXISTS videos (youtube_id TEXT PRIMARY KEY, title TEXT, upload_date TEXT, duration INTEGER, view_count INTEGER, channel TEXT, description TEXT, transcript TEXT, status TEXT, last_updated DATETIME DEFAULT CURRENT_TIMESTAMP);"
    $schema | & $Sqlite $DbPath
}

$files = Get-ChildItem $ImportDir -Filter "*.txt"
$totalImported = 0

foreach ($f in $files) {
    Write-Host "Analyse de $($f.Name)..." -ForegroundColor White
    $content = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    
    # Split by the end-marker
    $entries = $content -split "################################### SOURCE:"
    Write-Host "  > $($entries.Count - 1) entrees detectees." -ForegroundColor Gray
    
    foreach ($entry in $entries) {
        if (!($entry -match "URL: https://www.youtube.com/watch\?v=([a-zA-Z0-9_-]{11})")) { continue }
        
        $id = $Matches[1]
        $title = ""; if ($entry -match "TITLE: (.*)") { $title = $Matches[1].Trim() }
        $date = ""; if ($entry -match "DATE: (\d{8})") { $date = $Matches[1] }
        
        # Extract transcript: Everything after the second ====================================
        # and before the end of the entry (which was the split marker)
        $transcript = ""
        if ($entry -match "====================================\s*(.*)") {
            # We need to find the SECOND occurrence of the separator if it's there, 
            # but our regex above matches from the first one. 
            # Let's be more precise.
            $parts = $entry -split "===================================="
            if ($parts.Count -ge 3) {
                $transcript = $parts[2].Trim()
            }
        }
        
        if (!$transcript) { continue }
        
        $cleanTxt = Get-CleanTranscript -content $transcript
        if ($cleanTxt.Length -lt 100) { continue }
        
        $sTitle = $title -replace "'", "''"
        $sTxt = $cleanTxt -replace "'", "''"
        $sChannel = $TargetChannel
        
        # Insert using temp SQL file
        $sqlTmp = [System.IO.Path]::GetTempFileName()
        "INSERT OR REPLACE INTO videos (youtube_id, title, upload_date, duration, view_count, channel, transcript, status) VALUES ('$id', '$sTitle', '$date', 0, 0, '$sChannel', '$sTxt', 'SUCCESS (IMPORTED)');" | Out-File $sqlTmp -Encoding utf8
        & $Sqlite $DbPath ".read $sqlTmp"
        Remove-Item $sqlTmp -ErrorAction SilentlyContinue
        
        $totalImported++
    }
}

Write-Host "--- IMPORTATION TERMINEE : $totalImported videos ajoutees ---" -ForegroundColor Green
