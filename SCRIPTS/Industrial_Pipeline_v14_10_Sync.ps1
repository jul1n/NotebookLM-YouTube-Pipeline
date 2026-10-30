# Industrial_Pipeline_v14_10_Sync.ps1
# Specialized script for Intelligent YouTube Synchronization and Tagging.
# v14.10: Metadata Probing, Premium Detection, and "Zero Waste" Subtitle Checking.

param(
    [string]$SpecificChannel = $null,
    [int]$BatchSize = 10,
    [int]$PauseSeconds = 5
)

$BaseDir = $PSScriptRoot
$BinDir = Join-Path $BaseDir "BIN"
$YtDlp = Join-Path $BinDir "yt-dlp.exe"
$Sqlite = Join-Path $BinDir "sqlite3.exe"
$DbDir = Join-Path $BaseDir "DATA_STORES"
$HealthReportPath = Join-Path $BaseDir "health_report.json"
$SyncLogPath = Join-Path $BaseDir "sync_history_log.csv"

# Configuration de l'agent utilisateur pour eviter les 429
$UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

# Initialisation du Log CSV si inexistant
if (!(Test-Path $SyncLogPath)) {
    "Timestamp,Channel,VideoID,Title,Status,Reason" | Out-File $SyncLogPath -Encoding utf8
}

function Write-SyncLog {
    param($chan, $id, $title, $status, $reason)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts,$chan,$id,""$title"",$status,$reason" | Add-Content $SyncLogPath -Encoding utf8
}

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
    $txt = $txt -replace '[\u2018\u2019\u201A\u201B]', "'"
    $txt = $txt -replace '[\u201C\u201D\u201E\u201F]', '"'
    $txt = $txt -replace '([a-zA-Z])\?([a-zA-Z])', '$1''$2'
    $words = $txt -split "\s+" | Where-Object { $_ -ne "" }
    $uniqueWords = [System.Collections.Generic.List[string]]::new(); $lastW = ""
    foreach ($w in $words) { if ($w -ne $lastW) { $uniqueWords.Add($w); $lastW = $w } }
    return $uniqueWords -join " "
}

if (!(Test-Path $HealthReportPath)) {
    Write-Host "Erreur : health_report.json introuvable. Veuillez lancer Audit-DataHealth.ps1 d'abord." -ForegroundColor Red
    exit
}

Write-Host "`n=== SYNCHRONISATION INTELLIGENTE v14.10 ===" -ForegroundColor Cyan
$report = Get-Content $HealthReportPath | ConvertFrom-Json

foreach ($chanData in $report) {
    if ($SpecificChannel -and $chanData.Chaine -ne $SpecificChannel) { continue }
    if ($chanData.Missing_Count -eq 0) { continue }

    $chanName = $chanData.Chaine
    $dbPath = Join-Path $DbDir "$($chanName).db"
    
    Write-Host "`n--- [$chanName] : $($chanData.Missing_Count) videos a synchroniser ---" -ForegroundColor Yellow
    
    # Conversion de Missing_List en tableau si c'est un objet unique
    $missingVids = if ($chanData.Missing_List.PSObject.BaseObject -is [System.Array]) { $chanData.Missing_List } else { @($chanData.Missing_List) }

    $processedInBatch = 0
    foreach ($vid in $missingVids) {
        $id = $vid.id
        $title = $vid.t
        
        Write-Host "  [SYNC] SONDAGE : $id ($title)..." -NoNewline -ForegroundColor Gray
        
        # --- APPROCHE ULTRA-DISCRETE (Profil Bas + Délais Longs) ---
        Write-Host " [SYNCING]..." -NoNewline -ForegroundColor Cyan
        $tempSubDir = Join-Path $BaseDir "_TEMP\subs_$id"
        if (Test-Path $tempSubDir) { Remove-Item $tempSubDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item $tempSubDir -ItemType Directory -Force | Out-Null
        
        $dlArgs = @(
            "--cookies-from-browser", "firefox",
            "--quiet", "--no-warnings",
            "--skip-download",
            "--write-sub", "--write-auto-sub",
            "--sub-langs", "fr.*,en.*",
            "--print-json",
            "-o", (Join-Path $tempSubDir "sub"),
            "https://www.youtube.com/watch?v=$id"
        )
        
        $dlOut = & $YtDlp @dlArgs 2>&1 | Out-String
        
        if ($dlOut -match "429: Too Many Requests") {
            Write-Host " [!] 429 Detecte. Pause de REFROIDISSEMENT de 300s (5 min)." -ForegroundColor Red
            Write-SyncLog $chanName $id $title "FAILED" "429 Rate Limit - Cooling Down"
            Start-Sleep -Seconds 300
            continue
        }


        # Analyse du JSON de sortie (qui est aussi dans le flux)
        if ($dlOut.Trim().StartsWith("{")) {
            try { $meta = $dlOut | ConvertFrom-Json } catch { $meta = $null }
        }

        $subFile = Get-ChildItem $tempSubDir -Filter "sub.*" | Where-Object { $_.Extension -match "srt|vtt" } | Select-Object -First 1
        
        if ($subFile) {
            $rawText = [System.IO.File]::ReadAllText($subFile.FullName, [System.Text.Encoding]::UTF8)
            $cleanText = Get-CleanTranscript -content $rawText
            if ($cleanText.Length -gt 100) {
                $sTitle = $title -replace "'", "''"
                $header = "====================================`nSOURCE: YouTube - $chanName`nTITLE: $title`nURL: https://www.youtube.com/watch?v=$id`nDATE: $(Get-Date -Format 'dd/MM/yyyy')`n====================================`n`n"
                $fullText = ($header + $cleanText) -replace "'", "''"
                
                $sql = "INSERT OR REPLACE INTO videos (youtube_id, title, transcript, status) VALUES ('$id', '$sTitle', '$fullText', 'SUCCESS (SYNC)');"
                $sql | & $Sqlite $dbPath
                Write-Host " OK." -ForegroundColor Green
                Write-SyncLog $chanName $id $title "SUCCESS" "Synced with subs"
            } else {
                Write-Host " [!] Texte trop court." -ForegroundColor Red
                Write-SyncLog $chanName $id $title "FAILED" "Clean text too short"
            }
        } else {
            # Si pas de fichier, on verifie si c'est Premium ou NoSubs
            if ($dlOut -match "Private video|Sign in|Members only") {
                $statusTag = "PREMIUM"
            } else {
                $statusTag = "NO_SUBS"
            }
            Write-Host " [$statusTag]" -ForegroundColor Yellow
            $sTitle = $title -replace "'", "''"
            $sql = "INSERT OR REPLACE INTO videos (youtube_id, title, status) VALUES ('$id', '$sTitle', '$statusTag');"
            $sql | & $Sqlite $dbPath
            Write-SyncLog $chanName $id $title "TAGGED" $statusTag
        }

        Remove-Item $tempSubDir -Recurse -Force -ErrorAction SilentlyContinue
        
        # Pause Aleatoire LONGUE
        $randPause = Get-Random -Minimum 30 -Maximum 60
        Start-Sleep -Seconds $randPause

    }
}

Write-Host "`n=== SYNCHRONISATION TERMINEE ===" -ForegroundColor Cyan
