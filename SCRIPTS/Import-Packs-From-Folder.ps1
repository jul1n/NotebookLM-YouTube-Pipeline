# Import-Packs-From-Folder.ps1 (v14.8 - TRANSACTIONAL BATCH)
# Optimized for high-speed insertion without database locking.

$BaseDir = $PSScriptRoot
$ImportDir = Join-Path $BaseDir "IMPORT TEMP"
$DbDir = Join-Path $BaseDir "DATA_STORES"
$Sqlite = Join-Path $BaseDir "BIN\sqlite3.exe"

function Get-CleanTranscript {
    param($content)
    if (!$content) { return "" }
    $txt = $content -replace '(?s)<.*?>', '' -replace '(?m)^WEBVTT\s*$', '' -replace '(?m)^Kind:.*$', '' -replace '(?m)^Language:.*$', ''
    $txt = $txt -replace '(align|position|size|line|vertical|region|style):\S+', ' '
    $txt = $txt -replace '\d{8}\|\d{1,2}:\d{2}:\d{2}[\.,]\d{3}', ' '
    $txt = $txt -replace '\d{1,2}:\d{2}:\d{2}[\.,]\d{3}\s*-->\s*\d{1,2}:\d{2}:\d{2}[\.,]\d{3}', ' '
    $txt = $txt -replace '\b\d{1,2}:\d{2}\b', ' '
    $txt = $txt -replace '>>', ' ' -replace '\[.*?\]', ' '
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

Write-Host "--- IMPORTATION BATCH v14.8 (HAUTE PERFORMANCE) ---" -ForegroundColor Cyan

$files = Get-ChildItem $ImportDir -Filter "*.txt"
$totalImported = 0

foreach ($f in $files) {
    $chanName = $f.Name -replace "_\d+_.*", "" -replace "_\(.*\).*", ""
    $chanName = $chanName.Trim()
    $DbPath = Join-Path $DbDir "$($chanName).db"
    
    Write-Host "Traitement de $($f.Name) -> [$chanName]" -ForegroundColor White
    
    if (!(Test-Path $DbPath)) {
        $schema = "CREATE TABLE IF NOT EXISTS videos (youtube_id TEXT PRIMARY KEY, title TEXT, upload_date TEXT, duration INTEGER, view_count INTEGER, channel TEXT, description TEXT, transcript TEXT, status TEXT, last_updated DATETIME DEFAULT CURRENT_TIMESTAMP);"
        $schema | & $Sqlite $DbPath
    }

    $content = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    $entries = $content -split "################################### SOURCE:"
    
    $sqlBatchPath = [System.IO.Path]::GetTempFileName()
    "BEGIN TRANSACTION;" | Out-File $sqlBatchPath -Encoding utf8
    
    $countInFile = 0
    foreach ($entry in $entries) {
        if (!($entry -match "URL: https://www.youtube.com/watch\?v=([a-zA-Z0-9_-]{11})")) { 
            continue 
        }
        $id = $Matches[1]
        $title = ""; if ($entry -match "TITLE: (.*)") { $title = $Matches[1].Trim() }
        $date = ""; if ($entry -match "DATE: (\d{8})") { $date = $Matches[1] }
        
        $parts = $entry -split "===================================="
        if ($parts.Count -ge 3) {
            $transcript = $parts[2].Trim()
            
            # Si l'entree a une URL mais pas de texte (juste un header), on skip
            if ($transcript.Length -lt 10) { continue }
            
            $cleanTxt = Get-CleanTranscript -content $transcript
            if ($cleanTxt.Length -ge 100) {
                $sTitle = $title -replace "'", "''"
                $sTxt = $cleanTxt -replace "'", "''"
                "INSERT OR REPLACE INTO videos (youtube_id, title, upload_date, duration, view_count, channel, transcript, status) VALUES ('$id', '$sTitle', '$date', 0, 0, '$chanName', '$sTxt', 'SUCCESS (IMPORTED)');" | Out-File $sqlBatchPath -Append -Encoding utf8
                $countInFile++
                $totalImported++
            }
        }
    }
    
    "COMMIT;" | Out-File $sqlBatchPath -Append -Encoding utf8
    
    # Execution du batch en une seule fois
    if ($countInFile -gt 0) {
        & $Sqlite $DbPath ".read $sqlBatchPath"
        Write-Host "  [OK] $countInFile videos integrees." -ForegroundColor Green
    }
    Remove-Item $sqlBatchPath -ErrorAction SilentlyContinue
    
    # Micro-pause de sécurité pour Windows
    Start-Sleep -Milliseconds 200
}

Write-Host "--- IMPORTATION TERMINEE : $totalImported videos ajoutees ---" -ForegroundColor Cyan
