# Fix-Integrity-SQLite.ps1
# Massive cleanup for existing transcripts: 
# 1. Eradicate inline timestamps
# 2. Fix encoding artifacts (???? -> special chars if possible, or just cleanup)
# 3. Fix metadata (Date vs Title)

$BaseDir = $PSScriptRoot
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
    $txt = $txt -replace '(?m)^\d+\s*$', '' -replace '&\w+;', ' ' -replace '\s+', ' '
    
    # 4. Reparation des artifacts d'encodage et normalisation Unicode
    $txt = $txt -replace '[\u2018\u2019\u201A\u201B]', "'" # Apostrophes courbes -> droite
    $txt = $txt -replace '[\u201C\u201D\u201E\u201F]', '"' # Guillemets courbes -> droits
    
    # Reparation des '?' mal places (ex: D?Agostino, don?t)
    $txt = $txt -replace '([a-zA-Z])\?([a-zA-Z])', '$1''$2'
    $txt = $txt -replace '(?i)m\?taphore', 'métaphore'
    
    $words = $txt -split "\s+" | Where-Object { $_ -ne "" }
    $uniqueWords = [System.Collections.Generic.List[string]]::new(); $lastW = ""
    foreach ($w in $words) { if ($w -ne $lastW) { $uniqueWords.Add($w); $lastW = $w } }
    return $uniqueWords -join " "
}

Write-Host "--- REPARATION MASSIVE DE L'INTEGRITE (v14.5) ---" -ForegroundColor Cyan

$dbs = Get-ChildItem $DbDir -Filter "*.db"
foreach ($db in $dbs) {
    Write-Host "Traitement de $($db.BaseName)..." -ForegroundColor White
    
    # 1. Recuperation des videos avec timestamps ou artifacts
    $csvTmp = [System.IO.Path]::GetTempFileName()
    & $Sqlite -header -csv $db.FullName "SELECT youtube_id, transcript, title, upload_date FROM videos WHERE transcript LIKE '%-->%' OR transcript LIKE '%|00:%' OR title LIKE '%?%' OR transcript LIKE '%?%';" | Out-File $csvTmp -Encoding utf8
    
    $videos = Import-Csv $csvTmp -Delimiter ","
    Remove-Item $csvTmp -ErrorAction SilentlyContinue
    
    if (!$videos) { continue }
    
    Write-Host "  [!] $($videos.Count) videos a corriger." -ForegroundColor Yellow
    
    foreach ($v in $videos) {
        $id = $v.youtube_id
        $newTxt = Get-CleanTranscript -content $v.transcript
        
        # Reparation des titres (ex: D?Agostino)
        $newTitle = $v.title -replace '([a-zA-Z])\?([a-zA-Z])', '$1''$2'
        $newTitle = $newTitle -replace '[\u2018\u2019\u201A\u201B]', "'"
        
        # Correction Date
        $newDate = $v.upload_date
        if ($newDate -match "[a-zA-Z]") { $newDate = "INCONNUE" }
        
        $sTxt = $newTxt -replace "'", "''"
        $sTitle = $newTitle -replace "'", "''"
        
        $sqlTmp = [System.IO.Path]::GetTempFileName()
        "UPDATE videos SET transcript = '$sTxt', title = '$sTitle', upload_date = '$newDate' WHERE youtube_id = '$id';" | Out-File $sqlTmp -Encoding utf8
        & $Sqlite $db.FullName ".read $sqlTmp"
        Remove-Item $sqlTmp -ErrorAction SilentlyContinue
    }
    Write-Host "  [OK] $($videos.Count) videos reparees." -ForegroundColor Green
}

Write-Host "--- REPARATION TERMINEE ---" -ForegroundColor Cyan
