# Industrial YouTube Transcription Pipeline v10.4
# Unified Industrial Suite for NotebookLM
# v10.4: Ultra-aggressive VTT cleaning & case-insensitive JSON support.

$PSDefaultParameterValues['*:Encoding'] = 'utf8'
$ErrorActionPreference = "Stop"

# ==============================================================================
# CONFIGURATION GLOBALE
# ==============================================================================
$BaseDir = $PSScriptRoot
$BinDir = Join-Path $BaseDir "BIN"
$YtDlp = Join-Path $BinDir "yt-dlp.exe"
$Ffmpeg = Join-Path $BinDir "ffmpeg.exe"
$ConfigPath = Join-Path $BaseDir "channels_config.csv"
$BlacklistPath = Join-Path $BaseDir "blacklist.txt"
$AllPacksDir = Join-Path $BaseDir "ALL_PACKS"
$LogsDir = Join-Path $BaseDir "_LOGS"
$ReSubDir = Join-Path $BaseDir "_RE_SUBTITLING_WORK"

# Directories for Re-Subtitling
$AudioDir = Join-Path $ReSubDir "1_AUDIO"
$ThumbDir = Join-Path $ReSubDir "2_THUMBS"
$OutputDir = Join-Path $ReSubDir "3_STATIC_VIDEOS"
$ReSubDir = Join-Path $BaseDir "_RE_SUBTITLING_WORK"
$SettingsPath = Join-Path $BaseDir "settings.json"

# Default Settings
$global:Settings = @{
    CookieSource = "firefox"
    MaxPlaylistEnd = 2000
    AutoClean = $true
}

if (Test-Path $SettingsPath) {
    try {
        $saved = Get-Content -LiteralPath $SettingsPath | ConvertFrom-Json -AsHashTable
        foreach ($k in $saved.Keys) { $global:Settings[$k] = $saved[$k] }
    } catch { }
}

function Save-Settings {
    $global:Settings | ConvertTo-Json | Out-File $SettingsPath -Encoding utf8
}

# Ensure core directories exist
foreach ($p in @($BinDir, $AllPacksDir, $LogsDir, $ReSubDir, $AudioDir, $ThumbDir, $OutputDir)) {
    if (!(Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
}

$threadLimit = 16
$userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36"
$global:pendingBlacklistUpdates = [System.Collections.Generic.List[PSObject]]::new()
$blacklistCandidates = [System.Collections.Generic.List[PSObject]]::new()

function Write-StepHeader {
    param ($Title, $StepNum = $null, $TotalSteps = $null, $Emoji = "📦")
    $line = "══════════════════════════════════════════════"
    $fullTitle = if ($StepNum) { "[ETAPE $StepNum/$TotalSteps] $Title" } else { $Title }
    # Padding manuel pour eviter les artefacts de PadRight
    $rawTitle = "$Emoji $fullTitle"
    $padSize = 44 - $rawTitle.Length
    if ($padSize -lt 0) { $padSize = 0 }
    $padding = " " * $padSize
    Write-Host "`n  ╔$line╗" -ForegroundColor Cyan
    Write-Host "  ║ $rawTitle$padding║" -ForegroundColor White
    Write-Host "  ╚$line╝" -ForegroundColor Cyan
}

function Write-SubStep {
    param ($Title, $StepNum, $TotalSteps, $Emoji = "🔹", $Status = "")
    $prefix = "  [$StepNum/$TotalSteps] $Emoji $Title"
    Write-Host $prefix.PadRight(40) -NoNewline -ForegroundColor Gray
    if ($Status) { Write-Host " : $Status" -ForegroundColor White }
    else { Write-Host "" }
}

function Write-Log {
    param ($msg, $color = "White", $prefix = "SYSTEM")
    $timestamp = Get-Date -Format "HH:mm:ss"
    $logMsg = "[$timestamp] [$prefix] $msg"
    $logFile = Join-Path $LogsDir "pipeline.log"
    
    $success = $false; $attempts = 0
    while (-not $success -and $attempts -lt 5) {
        try {
            $attempts++
            $logMsg | Add-Content -LiteralPath $logFile -ErrorAction Stop
            $success = $true
        } catch { Start-Sleep -Milliseconds 200 }
    }

    if ($msg -notmatch $noisePattern) {
        $shortMsg = $msg -replace "^\[.*?\]\s*", ""
        if ($shortMsg.Trim() -ne "") {
            if ($prefix -eq "SYSTEM" -or $prefix -eq "DIAG" -or $prefix -eq "LOCK") {
                Write-Host "[$timestamp] " -NoNewline -ForegroundColor DarkGray
                Write-Host "[$prefix] " -NoNewline -ForegroundColor Gray
                Write-Host $shortMsg -ForegroundColor $color
            } else {
                Write-Host "    $shortMsg" -ForegroundColor $color
            }
        }
    }
}

function Get-SafeContent {
    param($Path)
    if (!(Test-Path -LiteralPath $Path)) { return @() }
    try {
        return [System.IO.File]::ReadAllLines($Path)
    } catch {
        return Get-Content -LiteralPath $Path
    }
}

function Update-BlacklistEntry($id, $marker, $metadata = "") {
    if (!(Test-Path $BlacklistPath)) { return }
    $global:pendingBlacklistUpdates.Add([PSCustomObject]@{ ID=$id; Marker=$marker; Metadata=$metadata })
    Flush-BlacklistUpdates
}

function Flush-BlacklistUpdates {
    if ($global:pendingBlacklistUpdates.Count -eq 0) { return }
    try {
        $content = Get-Content -LiteralPath $BlacklistPath -ErrorAction Stop
        $newContent = [System.Collections.Generic.List[string]]::new($content)
        foreach ($update in $global:pendingBlacklistUpdates) {
            $found = $false
            for ($lineIdx = 0; $lineIdx -lt $newContent.Count; $lineIdx++) {
                if ($newContent[$lineIdx].Trim().StartsWith($update.ID)) {
                    $line = $newContent[$lineIdx]
                    $base = ($line -split "#")[0].Trim()
                    $existingComment = if ($line -match "#") { ($line -split "#", 2)[1].Trim() } else { "" }
                    $cleanComment = $existingComment -replace "\[RE-SUB-AUDIO\]", "" -replace "\[RE-SUB-VIDEO\]", "" -replace "\[INACCESSIBLE-PREMIUM-CONTENT\]", "" -replace "\[AUTO-LANG:.*?\]", ""
                    $finalMeta = if (![string]::IsNullOrWhiteSpace($update.Metadata)) { $update.Metadata } else { $cleanComment.Trim() }
                    $newComment = "$($finalMeta.Trim()) $($update.Marker)".Trim()
                    $newContent[$lineIdx] = "$base # $newComment"
                    $found = $true; break
                }
            }
            if (!$found) { $newContent.Add("$($update.ID) # $($update.Metadata) $($update.Marker)".Trim()) }
        }
        $newContent | Out-File $BlacklistPath -Encoding utf8 -ErrorAction Stop
        $global:pendingBlacklistUpdates.Clear()
    } catch { }
}

function Get-ChannelLock($chanDir) {
    $lockFile = Join-Path $chanDir "process.lock"
    if (Test-Path -LiteralPath $lockFile) {
        try {
            $oldPid = Get-Content -LiteralPath $lockFile -ErrorAction SilentlyContinue
            if ($oldPid) {
                $proc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
                # On ne bloque QUE si le processus existe ET que c'est du PowerShell
                if ($proc -and ($proc.ProcessName -match "pwsh|powershell") -and ($oldPid -ne $PID)) {
                    return $false 
                }
            }
            # Si on arrive ici, le verrou est "mort" ou appartient a une autre application
            Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
            Write-Log "Verrou obsolet soigne." "Yellow" "LOCK"
        } catch { }
    }
    $PID | Out-File -LiteralPath $lockFile -Encoding utf8 -Force
    return $true
}

function Get-YouTubeName($Url) {
    try {
        # On force la recuperation d'une seule ligne proprement
        $name = & $YtDlp --user-agent $userAgent --get-filename -o "%(uploader)s" --quiet --no-warnings --playlist-items 1 $Url 2>$null | Select-Object -First 1
        if ($name) { return $name.Trim() }
    } catch { }
    return ""
}

filter Count-Progress { $global:itemCount++; $_ }

# ==============================================================================
# MODULE 1: PIPELINE PRINCIPAL (SYNC & PACKS)
# ==============================================================================

function Sync-YouTube {
    param ($Url, $RawDir, $YtDlp, $Ffmpeg, $Cookies, $Lang, $BaseDir, $LogPrefix, $BlacklistPath, $RetryOnly)
    
    $masterListPath = Join-Path $BaseDir "youtube_master_list.txt"
    $missingListPath = Join-Path $BaseDir "missing_videos.txt"
    
    # Gestion des Cookies persistee via Settings
    $useCookies = @()
    if ($global:Settings.CookieSource -eq "txt") {
        $cookieFile = Join-Path $PSScriptRoot "cookies.txt"
        if (Test-Path $cookieFile) { $useCookies = @("--cookies", $cookieFile) }
    } elseif ($global:Settings.CookieSource -match "firefox|chrome|edge") {
        $useCookies = @("--cookies-from-browser", $global:Settings.CookieSource)
    }

    $blacklist = @()
    $blacklistReasons = @{}
    if (Test-Path -LiteralPath $BlacklistPath) {
        $blRaw = Get-Content -LiteralPath $BlacklistPath -Encoding utf8
        foreach ($line in $blRaw) {
            if ($line -match "^([a-zA-Z0-9_-]{11})\s*(?:#\s*(.*))?") { 
                $id = $Matches[1]
                $rawReason = if ($Matches[2]) { $Matches[2].Trim() } else { "Inconnu" }
                # On extrait juste le tag entre crochets s'il existe pour le groupement (ex: [FR] Titre -> FR)
                $marker = if ($rawReason -match "^\[(.*?)\]") { $Matches[1] } else { $rawReason.Split(' ')[0] }
                $blacklist += $id
                $blacklistReasons[$id] = $marker
            }
        }
    }

    $masterData = @()
    $titlesMap = @{}
    if ($RetryOnly -and (Test-Path -LiteralPath $missingListPath)) {
        # Auto-reparation : on extrait l'ID meme si la ligne est corrompue (Titre|ID)
        $masterIds = Get-Content -LiteralPath $missingListPath | ForEach-Object {
            $line = $_.Trim()
            if ($line -match "\|") { ($line -split "\|")[-1].Trim() } else { $line }
        } | Where-Object { $_ -match "^[a-zA-Z0-9_-]{11}$" }
    } else {
        Write-Host "  [PATIENCE] Scan de la playlist en cours ($($global:Settings.MaxPlaylistEnd) videos max)..." -ForegroundColor Gray
        Write-Log "Extraction de la liste (IDs + Titres)..." "Gray" $LogPrefix
        
        $masterIds = [System.Collections.Generic.List[string]]::new()
        $scanCount = 0
        
        # Extraction en flux pour afficher la progression
        & $YtDlp --flat-playlist --playlist-end $($global:Settings.MaxPlaylistEnd) --print "%(title)s|%(id)s" --quiet --no-warnings $Url | ForEach-Object {
            $scanCount++
            if ($scanCount % 20 -eq 0) {
                Write-Host "`r  [SYNC] Scan en cours : $scanCount videos... " -NoNewline -ForegroundColor Gray
            }
            if ($_ -match "\|") {
                $parts = $_ -split "\|", 2
                $vTitle = $parts[0].Trim()
                $vId = $parts[1].Trim()
                if ($vId -match "^[a-zA-Z0-9_-]{11}$") {
                    $masterIds.Add($vId)
                    $titlesMap[$vId] = $vTitle
                }
            }
        }
        Write-Host "`r  [SUCCES] Scan termine : $scanCount videos trouves.          " -ForegroundColor Green
        $masterIds | Out-File -LiteralPath $masterListPath -Encoding utf8
    }

    if ($null -eq $masterIds) { return @{ Ignored = 0; Detail = "" } }
    
    $originalMasterIds = [string[]]$masterIds
    $originalMasterCount = $originalMasterIds.Count
    $masterIds = $masterIds | Where-Object { $_ -notin $blacklist }
    $ignoredByBlacklist = $originalMasterCount - $masterIds.Count
    if ($ignoredByBlacklist -gt 0) { Write-Log "$ignoredByBlacklist video(s) ignoree(s) (Blacklist)." "Gray" $LogPrefix }

    $localIds = [System.Collections.Generic.HashSet[string]]::new()
    "[$LogPrefix] Scan des fichiers locaux (Methode Ultra-Robuste)..." | Add-Content (Join-Path $LogsDir "pipeline.log")
    
    Write-Host "  [PATIENCE] Lecture du dossier local (Plusieurs milliers de fichiers)..." -ForegroundColor Gray
    $allFiles = [System.IO.Directory]::GetFiles($RawDir)
    $totalLocal = $allFiles.Count
    $localScanCount = 0
    Write-Host "  [SCAN] Analyse des fichiers locaux ($totalLocal fichiers)..." -ForegroundColor Gray
    
    # Parallélisation du Scan Local (Multi-Coeur)
    $localIds = [System.Collections.Generic.HashSet[string]]::new()
    $results = $allFiles | ForEach-Object -Parallel {
        $fName = [System.IO.Path]::GetFileName($_)
        $fExt = [System.IO.Path]::GetExtension($_)
        $foundId = $null
        
        if ($fName -match "\[([a-zA-Z0-9_-]{11})\]") {
            $foundId = $Matches[1]
        } elseif ($fExt -eq ".json") {
            try {
                $content = [System.IO.File]::ReadAllText($_)
                if ($content -match '"id":\s*"([a-zA-Z0-9_-]{11})"') { $foundId = $Matches[1] }
            } catch { }
        }
        if ($foundId) { $foundId }
    } -ThrottleLimit 8 # On utilise 8 threads en parallèle

    foreach ($id in $results) { [void]$localIds.Add($id) }
    Write-Host "`r  [SUCCES] Scan local termine ($($localIds.Count) IDs trouves).          " -ForegroundColor Gray

    $toDownload = [System.Collections.Generic.List[string]]::new()
    foreach ($mid in $masterIds) { 
        if (!($localIds.Contains($mid))) { $toDownload.Add($mid) } 
    }
    
    # On met a jour le fichier seulement si on a fait un scan YouTube complet (pour ne pas vider la liste par erreur)
    if (!$RetryOnly) {
        $toDownload | Out-File -LiteralPath $missingListPath -Encoding utf8
    }

    if ($toDownload.Count -gt 0) {
        Write-Log "$($toDownload.Count) videos manquantes." "Yellow" $LogPrefix
        $errorCount = 0; $currentIndex = 1; $totalVideos = $toDownload.Count

        foreach ($id in $toDownload.ToArray()) {
            $isPremium = $false
            $vTitle = if ($titlesMap.ContainsKey($id)) { $titlesMap[$id] } else { "Titre inconnu" }
            Write-Host "[$LogPrefix] [DOWNLOAD $currentIndex/$totalVideos] $id - $vTitle" -ForegroundColor White
            $vidUrl = "https://www.youtube.com/watch?v=" + $id
            $noSubsFound = $false; $currentTitle = "ID: $id"

            $dlpCmd = {
                & $YtDlp --user-agent $userAgent @useCookies `
                    --ffmpeg-location $Ffmpeg --quiet --no-warnings `
                    --write-auto-sub --write-info-json --ignore-errors `
                    --sub-langs ($Lang -eq "auto" ? "fr,en" : $Lang) --skip-download --convert-subs srt `
                    --min-sleep-interval 5 --max-sleep-interval 15 --sleep-requests 1 `
                    --download-archive (Join-Path $BaseDir "archive.txt") `
                    -o (Join-Path $RawDir "%(upload_date)s - %(title)s [%(id)s].%(ext)s") $vidUrl 2>&1
            }
            
            $outputLines = $dlpCmd.Invoke() | ForEach-Object {
                $line = $_.ToString()
                if ($line -match "Writing video metadata as JSON to: .*\\(\d{8} - .*)\.info\.json") { $currentTitle = $Matches[1] }
                elseif ($line -match "(?i)ERROR: (.*)") { Write-Host "  [!] $($Matches[1])" -ForegroundColor Red }
                
                # DETECTION AUTOMATIQUE DE BLACKLIST (Premium/Members-Only)
                if ($line -match "Join this channel|members-only") {
                    $isPremium = $true
                }
                
                Write-Log $line "White" $LogPrefix -ErrorAction SilentlyContinue
                $line
            }

            if ($isPremium) {
                Write-Host "  [!] Video réservée aux membres. Auto-blacklistage..." -ForegroundColor Yellow
                $id + " # Members-only (Auto-Detected)" | Add-Content -LiteralPath $BlacklistPath -Encoding utf8
                $toDownload.Remove($id) | Out-Null
                $toDownload | Out-File -LiteralPath $missingListPath -Encoding utf8
                $currentIndex++; continue
            }

            if ($noSubsFound) {
                Write-Host "  [!] Aucun sous-titre trouve pour cette video." -ForegroundColor Yellow
                $blacklistCandidates.Add([PSCustomObject]@{ ID=$id; Title=$currentTitle; Prefix=$LogPrefix })
            }

            $newFiles = Get-ChildItem -Path $RawDir -Filter "*$id*" -Include "*.srt", "*.vtt" -Recurse
            if ($newFiles.Count -gt 0) {
                $errorCount = 0; $toDownload.Remove($id)
                $toDownload | Out-File -LiteralPath $missingListPath -Encoding utf8
            } else {
                $errorCount++; $errorMsg = "Echec de telechargement sur $id ($errorCount/3)"
                if ($outputLines -match "429") {
                    $errorMsg += " [HTTP 429: Too Many Requests]"
                    if (!(Test-Path $LogsDir)) { New-Item -ItemType Directory -Path $LogsDir | Out-Null }
                    $log429 = Join-Path $LogsDir "429_errors.txt"
                    "$id | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $LogPrefix" | Add-Content -Path $log429
                }
                Write-Log $errorMsg "Red" $LogPrefix
                if ($errorCount -ge 3) { Write-Log "3 echecs consecutifs. Pause de 15 minutes..." "Yellow" $LogPrefix; Start-Sleep -Seconds 900; $errorCount = 0 }
            }
            $currentIndex++
        }
    }
    # Calcul du detail de la blacklist pour le bilan
    $blDetail = ""
    if ($ignoredByBlacklist -gt 0) {
        $reasonsCount = @{}
        foreach ($mid in $originalMasterIds) {
            if ($mid -in $blacklist) {
                $r = $blacklistReasons[$mid]
                $reasonsCount[$r]++
            }
        }
        $details = foreach ($k in $reasonsCount.Keys) { "$($reasonsCount[$k]) $k" }
        $blDetail = if ($details) { " (" + ($details -join ", ") + ")" } else { "" }
    }

    return @{ Playlist = $originalMasterIds.Count; Local = $rawIdsCount; Ignored = $ignoredByBlacklist; Detail = $blDetail; Missing = $toDownload.Count }
}

function Process-LocalFiles {
    param ($RawDir, $TxtDir, $DenseDir, $Lang, $Prefix)
    
    $rawFiles = Get-ChildItem -LiteralPath $RawDir -Filter "*.info.json"
    $newDenseCount = 0
    $results = $rawFiles | ForEach-Object -Parallel {
        $json = $_
        $RawDir = $using:RawDir
        $TxtDir = $using:TxtDir
        $DenseDir = $using:DenseDir
        $Lang = $using:Lang
        $Settings = $using:global:Settings
        
        $id = ""; if ($json.Name -match "\[([a-zA-Z0-9_-]{11})\]\.info\.json$") { $id = $Matches[1] }
        if (!$id) { return $false }
        
        $baseName = $json.Name -replace '\.info\.json$', ''
        $txtPath = Join-Path $TxtDir ($baseName + ".txt")
        $densePath = Join-Path $DenseDir ($baseName + ".dense.txt")
        
        if (Test-Path -LiteralPath $densePath) { 
            if ($Settings.AutoClean) {
                Get-ChildItem -LiteralPath $RawDir | Where-Object { $_.Name.StartsWith($baseName + ".") -and $_.Extension -match "vtt|srt" } | Remove-Item -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $txtPath) { Remove-Item -LiteralPath $txtPath -Force -ErrorAction SilentlyContinue }
            }
            return $false 
        }

        $subFile = $null
        $checkSuffixes = if ($Lang -eq "auto") { @(".fr", ".en", "") } else { @(".$Lang", "") }
        foreach ($suffix in $checkSuffixes) {
            $f = Join-Path $RawDir ($baseName + $suffix + ".srt")
            if (Test-Path -LiteralPath $f) { $subFile = $f; break }
            $f = Join-Path $RawDir ($baseName + $suffix + ".vtt")
            if (Test-Path -LiteralPath $f) { $subFile = $f; break }
        }

        if ($subFile) {
            try {
                $content = Get-Content -LiteralPath $subFile -Raw
                # Nettoyage ultra-agressif des VTT et artifacts
                $txt = $content
                $txt = $txt -replace '(?s)<.*?>', '' # Tags HTML/VTT
                $txt = $txt -replace 'WEBVTT|Kind: captions|Language: \S+', '' # Headers
                
                # Suppression globale des timestamps (meme au milieu d'une ligne)
                $tsRegex = '\d{1,2}:\d{2}(?::\d{2})?[.,]\d{3}\s+-->\s+\d{1,2}:\d{2}(?::\d{2})?[.,]\d{3}'
                $txt = $txt -replace $tsRegex, ''
                
                # Suppression des infos de positionnement et meta-data VTT
                $txt = $txt -replace 'align:\S+|position:\S+|line:\S+|size:\S+|region:\S+', ''
                $txt = $txt -replace '(?m)^\d+\s*$', '' # Index
                $txt = $txt -replace '(?m)^\s*$', '' # Lignes vides
                
                $lines = $txt -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
                $cleanTxt = [System.Collections.Generic.HashSet[string]]::new()
                foreach ($l in $lines) { [void]$cleanTxt.Add($l) }
                $finalTxt = $cleanTxt -join " "
                
                if ($finalTxt.Trim().Length -gt 10) {
                    $finalTxt | Out-File -LiteralPath $txtPath -Encoding utf8
                    
                    # On ne garde que l'essentiel de la meta pour le fichier dense (evite les leaks de 2MB de JSON)
                    try {
                        $meta = $jsonMeta | ConvertFrom-Json -AsHashTable
                        $compactMeta = @{
                            id = $meta.id
                            title = $meta.title
                            upload_date = $meta.upload_date
                            channel = $meta.channel
                            description = $meta.description
                            view_count = $meta.view_count
                        } | ConvertTo-Json -Compress
                        $denseContent = "[METADATA]" + $compactMeta + "[/METADATA]" + "`r`n`r`n" + $finalTxt
                    } catch {
                        $denseContent = "[METADATA_RAW]" + ($jsonMeta.Substring(0, [Math]::Min(1000, $jsonMeta.Length))) + "[/METADATA_RAW]" + "`r`n`r`n" + $finalTxt
                    }
                    
                    $denseContent | Out-File -LiteralPath $densePath -Encoding utf8
                    
                    if ($Settings.AutoClean) {
                        Remove-Item -LiteralPath $subFile -Force -ErrorAction SilentlyContinue
                        if (Test-Path -LiteralPath $txtPath) { Remove-Item -LiteralPath $txtPath -Force -ErrorAction SilentlyContinue }
                    }
                    return $true
                }
            } catch { }
        }
        return $false
    } -ThrottleLimit 8
    
    $newDenseCount = ($results | Where-Object { $_ -eq $true }).Count
    return $newDenseCount
}

function Build-Packs {
    param ($DenseDir, $PacksDir, $Prefix, $LogPrefix, $GlobalPacksDir)
    
    if (!(Test-Path -LiteralPath $DenseDir)) { 
        New-Item -ItemType Directory -Force -Path $DenseDir | Out-Null
        return 
    }
    if (!(Test-Path -LiteralPath $PacksDir)) { New-Item -ItemType Directory -Force -Path $PacksDir | Out-Null }
    
    $denseFiles = Get-ChildItem -LiteralPath $DenseDir -Filter "*.txt" | Sort-Object Name
    $packsPlan = [System.Collections.Generic.List[PSObject]]::new()
    $currentBatch = [System.Collections.Generic.List[PSObject]]::new(); $currentWords = 0; $packNum = 1

    foreach ($file in $denseFiles) {
        $content = Get-Content -LiteralPath $file.FullName -Raw
        $txtOnly = if ($content -match "\[/METADATA.*?\](?:\r?\n){2}(.*)") { $Matches[1] } else { $content }
        $wordCount = ($txtOnly -split "\s+" | Where-Object { $_ -ne "" }).Count
        if (($currentWords + $wordCount) -gt 500000 -and $currentBatch.Count -gt 0) {
            $packsPlan.Add([PSCustomObject]@{ ID=$packNum; Files=$currentBatch.ToArray(); TotalWords=$currentWords; Start=$currentBatch[0].Name.Substring(0,8); End=$currentBatch[-1].Name.Substring(0,8) })
            $packNum++; $currentBatch = [System.Collections.Generic.List[PSObject]]::new(); $currentWords = 0
        }
        $currentBatch.Add($file); $currentWords += $wordCount
    }
    if ($currentBatch.Count -gt 0) {
        $packsPlan.Add([PSCustomObject]@{ ID=$packNum; Files=$currentBatch.ToArray(); TotalWords=$currentWords; Start=$currentBatch[0].Name.Substring(0,8); End=$currentBatch[-1].Name.Substring(0,8) })
    }

    Get-ChildItem -Path $GlobalPacksDir -Filter ($Prefix + "_*.txt") | Where-Object { $_.Name -match "^$Prefix(_ULTRA)?_\d{2}_\(" } | Remove-Item -Force
    if ($packsPlan.Count -gt 0) {
        foreach ($plan in $packsPlan) {
            $sFmt = $plan.Start -replace '^(\d{4})(\d{2})(\d{2})$', '$1.$2.$3'; $eFmt = $plan.End -replace '^(\d{4})(\d{2})(\d{2})$', '$1.$2.$3'
            $pName = $Prefix + "_" + $plan.ID.ToString("00") + "_(" + $sFmt + "-au-" + $eFmt + ").txt"
            $pPath = Join-Path $PacksDir $pName
            $sb = New-Object System.Text.StringBuilder
            foreach ($b in $plan.Files) { 
                $content = Get-Content -LiteralPath $b.FullName -Raw
                $txtOnly = if ($content -match "\[/METADATA.*?\](?:\r?\n){2}(.*)") { $Matches[1] } else { $content }
                [void]$sb.AppendLine($txtOnly)
                [void]$sb.AppendLine("`r`n################################### SOURCE: $($b.BaseName) ###################################`r`n") 
            }
            $sb.ToString() | Out-File -LiteralPath $pPath -Encoding utf8
            
            # Export securise vers ALL_PACKS
            if ($GlobalPacksDir -and (Test-Path $GlobalPacksDir)) {
                $globalTarget = Join-Path $GlobalPacksDir $pName
                try {
                    if (Test-Path $globalTarget) { Remove-Item -LiteralPath $globalTarget -Force -ErrorAction SilentlyContinue }
                    Copy-Item -LiteralPath $pPath -Destination $globalTarget -Force
                } catch { }
            }
        }
    }
}

function Repair-Packs {
    param ($BaseDir, $Prefix)
    
    $rawDir = Join-Path $BaseDir "1_RAW"
    $denseDir = Join-Path $BaseDir "3_TXT_dense"
    $corruptedCount = 0
    $needDownload = $false
    
    # 1. Verification des fichiers RAW (0-octets ou JSON casses)
    if (Test-Path -LiteralPath $rawDir) {
        $files = Get-ChildItem -LiteralPath $rawDir -Recurse
        foreach ($f in $files) {
            if ($f.Length -eq 0) {
                Write-Host "  [!] Suppression fichier vide : $($f.Name)" -ForegroundColor Yellow
                Remove-Item -LiteralPath $f.FullName -Force; $corruptedCount++; $needDownload = $true
            }
            elseif ($f.Extension -eq ".json") {
                try {
                    # Utilisation de -LiteralPath pour eviter les erreurs sur les []
                    $content = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop
                    $null = $content | ConvertFrom-Json -AsHashTable -ErrorAction Stop
                } catch {
                    $reason = $_.Exception.Message
                    Write-Host "    [!] JSON corrompu : $($f.Name) ($reason)" -ForegroundColor Red
                    $base = $f.FullName -replace '\.info\.json$', ''
                    # On supprime tous les fichiers lies en filtrant sur le chemin complet literal (evite les erreurs de wildcard [ ])
                    Get-ChildItem -LiteralPath $f.DirectoryName | Where-Object { $_.FullName.StartsWith($base) } | Remove-Item -LiteralPath { $_.FullName } -Force -ErrorAction SilentlyContinue
                    $corruptedCount++; $needDownload = $true
                }
            }
        }
    }
    
    # 2. Verification des fichiers Dense (Fuites de JSON dans le texte)
    if (Test-Path -LiteralPath $denseDir) {
        $files = Get-ChildItem -LiteralPath $denseDir -Filter "*.txt"
        foreach ($f in $files) {
            $content = [System.IO.File]::ReadAllText($f.FullName)
            # Detection de fuite JSON : si on trouve des cles JSON en dehors du bloc METADATA
            $textContent = if ($content -match "\[/METADATA.*?\](?:\r?\n){2}(.*)") { $Matches[1] } else { $content }
            
            $isDirty = $false
            $reason = ""
            if ($textContent -match '"formats":' -or $textContent -match '"url":' -or $textContent -match '"downloader_options":') {
                $isDirty = $true; $reason = "Fuite JSON"
            } elseif ($textContent -match '-->') {
                $isDirty = $true; $reason = "Artifacts VTT (Timestamps)"
            }

            if ($isDirty) {
                Write-Host "    [!] $reason dans le texte : $($f.Name)" -ForegroundColor Red
                Remove-Item -LiteralPath $f.FullName -Force; $corruptedCount++
                # On supprime aussi le RAW correspondant pour forcer le retraitement
                $id = if ($f.Name -match "\[([a-zA-Z0-9_-]{11})\]") { $Matches[1] }
                if ($id) { Get-ChildItem -LiteralPath $rawDir | Where-Object { $_.Name.Contains($id) } | Remove-Item -LiteralPath { $_.FullName } -Force -ErrorAction SilentlyContinue }
            }
        }
    }
    
    if ($corruptedCount -gt 0) {
        Write-Host "  [SUCCES] $corruptedCount fichiers nettoyes." -ForegroundColor Green
    } else {
        Write-Host "  [OK] Aucun probleme detecte." -ForegroundColor Gray
    }
    return [PSCustomObject]@{ Total=$corruptedCount; NeedDownload=$needDownload }
}

function Maintenance-Doublons($chanDir, $prefix) {
    $rawDir = Join-Path $chanDir "1_RAW"
    if (!(Test-Path $rawDir)) { return }
    
    $localFiles = Get-ChildItem -LiteralPath $rawDir -Filter "*.info.json"
    $idMap = @{}
    $deletedCount = 0

    foreach ($f in $localFiles) {
        $id = ""
        if ($f.Name -match "\[([a-zA-Z0-9_-]{11})\]") { $id = $Matches[1] }
        else {
            try {
                $c = [System.IO.File]::ReadAllText($f.FullName)
                if ($c -match '"id":\s*"([a-zA-Z0-9_-]{11})"') { $id = $Matches[1] }
            } catch { }
        }
        
        if ($id) {
            if ($idMap.ContainsKey($id)) {
                # Doublon ! On decide lequel garder.
                $existingFile = $idMap[$id]
                $toDelete = $null
                # On garde celui qui a l'ID dans le nom
                if ($f.Name -match "\[$id\]") { $toDelete = $existingFile; $idMap[$id] = $f.Name }
                else { $toDelete = $f.Name }
                
                if ($toDelete) {
                    $base = $toDelete -replace '\.info\.json$', ''
                    Get-ChildItem -LiteralPath $rawDir -Filter "$base*" | Remove-Item -Force -ErrorAction SilentlyContinue
                    $deletedCount++
                }
            } else { $idMap[$id] = $f.Name }
        }
    }
    if ($deletedCount -gt 0) { Write-Log "Nettoyage de $deletedCount doublon(s)." "Green" $prefix }
}

function Maintenance-Migration($channels) {
    Write-Host "`n[MIGRATION] Analyse des noms de chaines sur YouTube..." -ForegroundColor Cyan
    $newChannels = [System.Collections.Generic.List[PSObject]]::new()
    $changed = $false

    $total = $channels.Count
    $count = 0
    foreach ($chan in $channels) {
        $count++
        Write-Host "  [$count/$total] Verif: $($chan.Prefixe)... " -NoNewline -ForegroundColor Gray
        $realName = Get-YouTubeName $chan.URL
        if ($realName -and $realName -ne $chan.Prefixe) {
            $oldFolder = ($chan.Prefixe -replace "[^a-zA-Z0-9]", "_").Trim()
            if (!(Test-Path (Join-Path $BaseDir $oldFolder))) { $oldFolder = $chan.Prefixe } # Fallback si deja migre partiellement
            
            $oldPath = Join-Path $BaseDir $oldFolder
            $newPath = Join-Path $BaseDir $realName
            
            if (Test-Path $oldPath) {
                Write-Host "Rename to [$realName]" -ForegroundColor Yellow
                try {
                    Rename-Item -Path $oldPath -NewName $realName -Force -ErrorAction Stop
                    $chan.Prefixe = $realName
                    $changed = $true
                } catch { Write-Host " (Locked)" -ForegroundColor Red }
            } else { Write-Host "OK" -ForegroundColor Green }
        } else { Write-Host "OK" -ForegroundColor Green }
        $newChannels.Add($chan)
    }

    if ($changed) {
        $newChannels | Export-Csv $ConfigPath -Delimiter ";" -NoTypeInformation -Encoding utf8
        Write-Host "`n[SUCCES] Migration terminee. CSV et dossiers synchronises." -ForegroundColor Green
        return $true
    }
    return $false
}

function Review-GlobalPacks($GlobalPacksDir) {
    if (!(Test-Path -LiteralPath $GlobalPacksDir)) { 
        Write-Host "  [!] Dossier global ALL_PACKS introuvable." -ForegroundColor Yellow
        return 
    }
    
    $packs = Get-ChildItem -LiteralPath $GlobalPacksDir -Filter "*.txt" | Where-Object { $_.Name -notmatch "^_" } | Sort-Object Name
    if ($packs.Count -eq 0) { Write-Host "  [!] Aucun pack detecte dans ALL_PACKS." -ForegroundColor Gray; return }
    
    Write-Host "`n  📊  BILAN DES PACKS GENERES" -ForegroundColor Cyan
    Write-Host "  " + ("═" * 60) -ForegroundColor Cyan
    Write-Host "  Pack Name".PadRight(45) + "Words".PadLeft(12) -ForegroundColor Gray
    
    $totalWords = 0
    foreach ($p in $packs) {
        # Lecture securisee pour eviter les erreurs d'encodage
        $content = [System.IO.File]::ReadAllText($p.FullName)
        $words = ($content -split "\s+" | Where-Object { $_ -ne "" }).Count
        $totalWords += $words
        
        # NotebookLM a une limite de 500k mots. 
        # Vert si < 500k (Optimal), Orange si >= 500k (Risque de coupure)
        $color = if ($words -ge 500000) { "Yellow" } else { "Green" }
        $shortName = if ($p.Name.Length -gt 42) { $p.Name.Substring(0, 39) + "..." } else { $p.Name }
        
        Write-Host "  $($shortName.PadRight(45))" -NoNewline -ForegroundColor White
        Write-Host " $($words.ToString('N0').PadLeft(11))" -ForegroundColor $color
    }
    Write-Host "  " + ("═" * 60) -ForegroundColor Cyan
    Write-Host "  TOTAL : $($totalWords.ToString('N0')) mots dans $($packs.Count) packs." -ForegroundColor Gray
}

function Clean-GlobalPacks {
    param ($GlobalPacksDir, $ValidPrefixes)
    if (!(Test-Path -LiteralPath $GlobalPacksDir)) { return }
    Write-Host "[SYSTEME] Nettoyage du dossier global ALL_PACKS..." -ForegroundColor Gray
    Repair-Packs -BaseDir $GlobalPacksDir -Prefix "GLOBAL"
    $deprecatedDir = Join-Path $GlobalPacksDir "_OLD_OR_DEPRECATED"
    foreach ($f in Get-ChildItem -Path $GlobalPacksDir -Filter "*.txt") {
        $prefix = ($f.Name -split "_")[0]
        if ($ValidPrefixes -notcontains $prefix -and $f.Name -notmatch "^_") {
            if (!(Test-Path $deprecatedDir)) { New-Item -ItemType Directory -Path $deprecatedDir | Out-Null }
            $targetPath = Join-Path $deprecatedDir $f.Name
            try {
                if (Test-Path $targetPath) { Remove-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue }
                Move-Item -LiteralPath $f.FullName -Destination $targetPath -Force -ErrorAction SilentlyContinue
            } catch {
                # Si le deplacement echoue (fichier verrouille), on supprime simplement l'original
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ==============================================================================
# MODULE 2: DIAGNOSTIC DE LANGUE
# ==============================================================================

function Run-LanguageDiagnostic {
    param ($SpecificChannelDir = $null)
    
    if (!$SpecificChannelDir) {
        Write-Host "`n=================================================" -ForegroundColor Cyan
        Write-Host "   DIAGNOSTIC DE LANGUE ET FILTRAGE AUTO" -ForegroundColor Cyan
        Write-Host "=================================================" -ForegroundColor Cyan
    }
    
    $idsToCheck = [System.Collections.Generic.HashSet[string]]::new()
    
    if ($SpecificChannelDir) {
        $missingPath = Join-Path $SpecificChannelDir "missing_videos.txt"
        if (Test-Path -LiteralPath $missingPath) {
            foreach ($id in Get-Content -LiteralPath $missingPath) {
                if ($id -match "^[a-zA-Z0-9_-]{11}$") { [void]$idsToCheck.Add($id) }
            }
        }
    } else {
        $log429 = Join-Path $LogsDir "429_errors.txt"
        if (Test-Path -LiteralPath $log429) { foreach ($line in Get-Content -LiteralPath $log429) { if ($line -match "^([a-zA-Z0-9_-]{11})") { [void]$idsToCheck.Add($Matches[1]) } } }
        foreach ($f in Get-ChildItem -LiteralPath $BaseDir -Recurse -Filter "missing_videos.txt") { foreach ($id in Get-Content -LiteralPath $f.FullName) { if ($id -match "^[a-zA-Z0-9_-]{11}$") { [void]$idsToCheck.Add($id) } } }
    }

    if ($idsToCheck.Count -eq 0) { return }

    $currentBL = Get-Content -LiteralPath $BlacklistPath
    $idsToProcess = $idsToCheck | Where-Object { $currentBL -notmatch [regex]::Escape($_) }
    
    $idsToProcess | ForEach-Object -Parallel {
        $id = $_
        $userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"
        $YtDlp = $using:YtDlp
        $BlacklistPath = $using:BlacklistPath
        
        try {
            $info = & $YtDlp --user-agent $userAgent --print "%(language)s|%(title)s" --no-warnings "https://www.youtube.com/watch?v=$id" 2>$null
            if ($info) {
                $parts = $info -split '\|'; $lang = $parts[0]; $title = $parts[1]
                if ($lang -and !($lang.StartsWith("fr") -or $lang.StartsWith("en"))) {
                    Write-Host "      [REJECT] $id ($lang) - $title" -ForegroundColor Red
                    "$id # [AUTO-LANG: $lang] $title" | Add-Content -LiteralPath $BlacklistPath -Encoding utf8
                }
            }
        } catch { }
    } -ThrottleLimit 4
}

# ==============================================================================
# MODULE 3: RE-SUBTITLING WORKFLOW
# ==============================================================================

function Run-ReSubtitling {
    Write-Host "`n=================================================" -ForegroundColor Cyan
    Write-Host "   WORKFLOW RE-SUBTITLING (1FPS STATIC VIDEOS)" -ForegroundColor Cyan
    Write-Host "=================================================" -ForegroundColor Cyan
    
    $blContent = Get-Content -LiteralPath $BlacklistPath
    $idsToProcess = $blContent | Where-Object { $_ -match "Aucun sous-titre|no subtitles|\[FORCE RE-SUB" -and $_ -notmatch "\[RE-SUB-VIDEO\]|\[INACCESSIBLE" } | ForEach-Object { ($_ -split " #")[0].Trim() }
    
    if ($idsToProcess.Count -eq 0) { Write-Log "Aucune video a re-sous-titrer." "Green"; return }
    
    Write-Log "$($idsToProcess.Count) videos detectees pour re-subtitling." "Yellow"
    $success = 0; $failed = 0; $idx = 0
    
    foreach ($id in $idsToProcess) {
        $idx++; $stats = "[$idx/$($idsToProcess.Count)] [OK: $success | KO: $failed]"
        Write-Log "$stats Traitement : $id" "Cyan"
        
        $audioPath = Join-Path $AudioDir "$id.m4a"
        $videoPath = Join-Path $OutputDir "$id.mp4"
        
        # Audio
        if (!(Test-Path -LiteralPath $audioPath)) {
            & $YtDlp --user-agent $userAgent --quiet --no-warnings -f "bestaudio[ext=m4a]/bestaudio" -o $audioPath "https://www.youtube.com/watch?v=$id"
            if (Test-Path -LiteralPath $audioPath) { Update-BlacklistEntry -id $id -marker "[RE-SUB-AUDIO]" }
        }
        
        # Video 1fps
        if (Test-Path -LiteralPath $audioPath -and !(Test-Path -LiteralPath $videoPath)) {
            # On recupere la vignette
            & $ytDlp --user-agent $userAgent --quiet --no-warnings --write-thumbnail --skip-download -o (Join-Path $ThumbDir $id) "https://www.youtube.com/watch?v=$id"
            $thumb = Get-ChildItem -LiteralPath $ThumbDir -Filter "$id.*" | Where-Object { $_.Extension -ne ".m4a" } | Select-Object -First 1
            $tIn = if ($thumb) { $thumb.FullName } else { "color=c=black:s=1280x720:r=1" }
            
            if ($thumb) {
                & $Ffmpeg -y -loglevel error -probesize 100M -analyzeduration 100M -loop 1 -framerate 1 -i $tIn -i $audioPath -c:v libx264 -tune stillimage -preset ultrafast -pix_fmt yuv420p -c:a copy -shortest $videoPath
            } else {
                & $Ffmpeg -y -loglevel error -probesize 100M -analyzeduration 100M -f lavfi -i $tIn -i $audioPath -c:v libx264 -tune stillimage -preset ultrafast -pix_fmt yuv420p -c:a copy -shortest $videoPath
            }
        }
        
        if (Test-Path -LiteralPath $videoPath) { $success++; Update-BlacklistEntry -id $id -marker "[RE-SUB-VIDEO]" } else { $failed++ }
    }
}

# ==============================================================================
# MODULE 4: INVENTAIRE ET TABLEAU DE BORD GLOBAL
# ==============================================================================

function Export-MasterInventory {
    $exportPath = Join-Path $BaseDir "MASTER_INVENTORY_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"
    Write-Host "`n[SYSTEME] Generation de l'inventaire global... (Patientez)" -ForegroundColor Cyan
    
    $channels = Import-Csv $ConfigPath -Delimiter ";"
    $inventory = [System.Collections.Generic.List[PSObject]]::new()
    
    # Charger la blacklist une seule fois pour la vitesse
    $blContent = Get-SafeContent $BlacklistPath
    $blMap = @{}
    foreach ($line in $blContent) {
        if ($line -match "^([a-zA-Z0-9_-]{11})") {
            $id = $Matches[1]
            $reason = "BLACKLIST"
            if ($line -match "\[(.*?)\]") { $reason = $Matches[1] }
            elseif ($line -match "Aucun sous-titre") { $reason = "NO-SUBS" }
            $blMap[$id] = $reason
        }
    }

    foreach ($chan in $channels) {
        $logPrefix = $chan.Prefixe
        $folder = ($chan.Prefixe -replace "[^a-zA-Z0-9]", "_").Trim()
        $cDir = Join-Path $BaseDir $folder
        if (!(Test-Path $cDir)) { continue }
        
        Write-Host "  > Analyse : $logPrefix" -ForegroundColor Gray
        
        $masterPath = Join-Path $cDir "youtube_master_list.txt"
        $missingPath = Join-Path $cDir "missing_videos.txt"
        $rawPath = Join-Path $cDir "1_RAW"
        $densePath = Join-Path $cDir "3_TXT_dense"
        
        $masterIds = Get-SafeContent $masterPath
        $missingIds = Get-SafeContent $missingPath
        
        # Cache des fichiers denses pour le compte de mots
        $denseFiles = @{}
        if (Test-Path $densePath) {
            Get-ChildItem -Path $densePath -Filter "*.txt" | ForEach-Object {
                if ($_.Name -match "\[([a-zA-Z0-9_-]{11})\]") { $denseFiles[$Matches[1]] = $_.FullName }
            }
        }

        foreach ($id in $masterIds) {
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            
            $status = "UNKNOWN"
            $reason = ""
            $wordCount = 0
            
            if ($blMap.ContainsKey($id)) {
                $status = "BLACKLISTED"
                $reason = $blMap[$id]
            } elseif ($denseFiles.ContainsKey($id)) {
                $status = "SUCCESS"
                # Calcul rapide du nombre de mots
                try {
                    $content = [System.IO.File]::ReadAllText($denseFiles[$id])
                    $txtPart = ($content -split "`r`n`r`n", 2)[1]
                    $wordCount = ($txtPart -split "\s+" | Where-Object { $_ -ne "" }).Count
                } catch { }
            } elseif ($missingIds -contains $id) {
                $status = "FAILED/PENDING"
            }

            [void]$inventory.Add([PSCustomObject]@{
                Channel = $logPrefix
                VideoID = $id
                Status  = $status
                Reason  = $reason
                Words   = $wordCount
                Folder  = $folder
            })
        }
    }

    $inventory | Export-Csv -Path $exportPath -NoTypeInformation -Delimiter "," -Encoding utf8
    Write-Host "`n[SUCCES] Inventaire genere : $exportPath" -ForegroundColor Green
    Write-Host "Vous pouvez l'ouvrir avec Excel ou Google Sheets." -ForegroundColor Gray
}

while ($true) {
    Clear-Host
    Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "  ║             Industrial Pipeline v10.4 Unified            ║" -ForegroundColor White
    Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
    Write-Host "  1. ➕ Ajouter et traiter une chaîne (manuel)"
    Write-Host "  2. 🔄 Rafraîchir toutes les chaînes (auto)"
    Write-Host "  3. 🔁 Retenter uniquement les échecs (rapide)"
    Write-Host "  4. 🌐 Lancer le diagnostic de langue (filtrage)"
    Write-Host "  5. 📽️ Lancer le workflow de re-sous-titrage (1 fps)"
    Write-Host "  6. 🛠️ Maintenance globale (nettoyage + diagnostic)"
    Write-Host "  7. 📊 Générer l'inventaire global (fichier CSV)"
    Write-Host "  8. ⚙️ Paramètres (cookies, délais, etc.)"
    Write-Host "  0. 👋 Quitter"
    Write-Host "  ────────────────────────────────────────────────────────────" -ForegroundColor Gray
    
    $choice = ""
    while ($choice -notmatch "^[0-8]$") {
        Write-Host "  Votre choix: " -NoNewline -ForegroundColor Cyan
        $choice = Read-Host
        if ($choice -notmatch "^[0-8]$") { Write-Host "  [!] Choix invalide." -ForegroundColor Red }
    }

    if ($choice -eq "0") { break }
    
    # Configuration Load
    $channels = Import-Csv $ConfigPath -Delimiter ";"
    
    if ($choice -eq "8") {
        Clear-Host
        Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "  ║           PARAMETRES DU PIPELINE             ║" -ForegroundColor White
        Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host "  1. Source des Cookies (Actuel: $($global:Settings.CookieSource))"
        Write-Host "  2. Limite de scan playlist (Actuel: $($global:Settings.MaxPlaylistEnd))"
        Write-Host "  0. Retour"
        $sChoice = Read-Host "  Modifier quel parametre ?"
        if ($sChoice -eq "1") {
            Write-Host "  Sources: firefox, chrome, edge, txt, none"
            $newC = Read-Host "  Nouvelle source"
            if ($newC -match "firefox|chrome|edge|txt|none") { $global:Settings.CookieSource = $newC; Save-Settings }
        } elseif ($sChoice -eq "2") {
            $newL = Read-Host "  Nouvelle limite"
            if ($newL -match "^\d+$") { $global:Settings.MaxPlaylistEnd = [int]$newL; Save-Settings }
        }
        continue
    }
    $channels = Import-Csv $ConfigPath -Delimiter ";"
    
    if ($choice -match "[123]") {
        $mode = $choice
        $targets = if ($choice -eq "1") { 
            $url = ""; while ($url -notmatch "youtube\.com") { $url = Read-Host "  URL de la chaine"; if ($url -notmatch "youtube\.com") { Write-Host "  [!] URL invalide." -ForegroundColor Red } }
            Write-Host "  [SYSTEME] Recuperation du nom de la chaine..." -ForegroundColor Gray
            $suggested = Get-YouTubeName $url
            $pref = Read-Host "  Prefixe (Tag) [$suggested]"
            if ($pref -eq "") { $pref = $suggested }
            if ($pref -eq "") { $pref = "NewChannel" }
            $lang = Read-Host "  Langue (fr, en, ou auto) [auto]"
            if ($lang -eq "") { $lang = "auto" }
            @([PSCustomObject]@{ URL=$url; Prefixe=$pref; Lang=$lang })
        } else { $channels }

        # 1. Nettoyage GLOBAL des verrous morts
        Write-Host "`n[SYSTEME] Audit des verrous de securite..." -ForegroundColor Gray
        foreach ($c in $channels) {
            $lock = Join-Path $BaseDir $c.Prefixe "process.lock"
            if (Test-Path $lock) {
                $pidVal = Get-Content $lock -ErrorAction SilentlyContinue
                if ($pidVal -and ($pidVal -ne $PID)) {
                    $p = Get-Process -Id $pidVal -ErrorAction SilentlyContinue
                    if (!$p -or ($p.Name -notmatch "pwsh|powershell")) {
                        Remove-Item $lock -Force -ErrorAction SilentlyContinue
                        Write-Host "  🔓 Verrou libere pour $($c.Prefixe)" -ForegroundColor Yellow
                    }
                }
            }
        }

        # Cleanup packs
        $validPrefixes = $channels | ForEach-Object { $_.Prefixe }
        Clean-GlobalPacks -GlobalPacksDir $AllPacksDir -ValidPrefixes $validPrefixes | Out-Null
        
        # Boucle de traitement principale
        while ($targets.Count -gt 0) {
            $chanIndex = 0
            $totalChans = $targets.Count
            $skippedChannels = [System.Collections.Generic.List[string]]::new()

            foreach ($chan in $targets) {
                $chanIndex++
                $folder = $chan.Prefixe 
                $cDir = Join-Path $BaseDir $folder
                if (!(Test-Path -LiteralPath $cDir)) { New-Item -ItemType Directory -Force -Path $cDir | Out-Null }
                
                if (!(Get-ChannelLock $cDir)) {
                    Write-Host "  🔒 [BUSY] Skip: $($chan.Prefixe)" -ForegroundColor Yellow
                    $skippedChannels.Add($chan.Prefixe)
                    continue
                }
                
                try {
                    Write-Host "`n  ─── 📡 SYNC [$chanIndex/$totalChans] : $($chan.Prefixe) ───" -ForegroundColor Cyan
                    
                    $p1 = Join-Path $cDir "1_RAW"; $p2 = Join-Path $cDir "2_TXT"; $p3 = Join-Path $cDir "3_TXT_dense"; $p4 = Join-Path $cDir "4_Packs"
                    foreach ($p in @($p1,$p2,$p3,$p4)) { if (!(Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null } }

                    $syncResult = Sync-YouTube -Url $chan.URL -RawDir $p1 -YtDlp $YtDlp -Ffmpeg $Ffmpeg -Cookies @() -Lang $chan.Lang -BaseDir $cDir -LogPrefix $chan.Prefixe -BlacklistPath $BlacklistPath -RetryOnly ($mode -eq "3")
                    $ignored = $syncResult.Ignored
                    $blDetail = $syncResult.Detail
                    
                    $newTxt = Process-LocalFiles -RawDir $p1 -TxtDir $p2 -DenseDir $p3 -Lang $chan.Lang -Prefix $chan.Prefixe
                    $null = Build-Packs -DenseDir $p3 -PacksDir $p4 -Prefix $chan.Prefixe -LogPrefix $chan.Prefixe -GlobalPacksDir $AllPacksDir
                    
                    $statusIcon = if ($syncResult.Missing -eq 0) { "✅" } else { "⏳" }
                    Write-Host "`n  $statusIcon BILAN : " -NoNewline -ForegroundColor Green
                    Write-Host "Playlist: $($syncResult.Playlist) " -NoNewline -ForegroundColor White
                    Write-Host "| Local: $($syncResult.Local) " -NoNewline -ForegroundColor Green
                    Write-Host "| Blacklist: $($syncResult.Ignored)$($syncResult.Detail) " -NoNewline -ForegroundColor Gray
                    Write-Host "| Manquantes: $($syncResult.Missing)" -ForegroundColor ($syncResult.Missing -gt 0 ? "Yellow" : "Gray")

                } finally {
                    $lockFile = Join-Path $cDir "process.lock"
                    if (Test-Path $lockFile) { Remove-Item $lockFile -Force -ErrorAction SilentlyContinue }
                }
            }

            if ($skippedChannels.Count -gt 0) {
                Write-Host "`n  ⚠️  ATTENTION : $($skippedChannels.Count) chaine(s) sautee(s) (Verrouillees) : " -ForegroundColor Yellow -NoNewline
                Write-Host ($skippedChannels -join ", ") -ForegroundColor White
                $retry = Read-Host "`n  [QUESTION] Voulez-vous retenter ces $($skippedChannels.Count) chaines maintenant ? (O/N)"
                if ($retry -match "o|y|O|Y") {
                    $targets = $channels | Where-Object { $skippedChannels -contains $_.Prefixe }
                    $skippedChannels.Clear()
                } else { break }
            } else { break }
        }
    }
    elseif ($choice -eq "4") { Run-LanguageDiagnostic }
    elseif ($choice -eq "5") { Run-ReSubtitling }
    elseif ($choice -eq "6") {
        Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "  ║       Maintenance globale du pipeline        ║" -ForegroundColor White
        Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
        
        $steps = @("Migration", "Integrite", "Doublons", "Packs", "Langues", "Verification")
        $totalSteps = $steps.Count

        $doMigration = (Read-Host "  [1/$totalSteps] Lancer la migration ? [O/N] (Défaut: N)").ToUpper() -eq "O"
        $doIntegrity = (Read-Host "  [2/$totalSteps] Lancer le diagnostic d'intégrité ? [O/N] (Défaut: O)").ToUpper() -ne "N"
        $doDoublons  = (Read-Host "  [3/$totalSteps] Lancer le nettoyage des doublons ? [O/N] (Défaut: O)").ToUpper() -ne "N"
        $doPacks     = (Read-Host "  [4/$totalSteps] Lancer la reconstruction des packs ? [O/N] (Défaut: O)").ToUpper() -ne "N"
        $doLangues   = (Read-Host "  [5/$totalSteps] Lancer le filtrage des langues ? [O/N] (Défaut: N)").ToUpper() -eq "O"
        $doReview    = (Read-Host "  [6/$totalSteps] Lancer la vérification finale des packs ? [O/N] (Défaut: O)").ToUpper() -ne "N"

        # Etape 1: Migration
        if ($doMigration) {
            Write-StepHeader -Title "Migration et Nomenclature" -StepNum 1 -TotalSteps $totalSteps -Emoji "🚚"
            $migrated = Maintenance-Migration -channels $channels
            if ($migrated) { $channels = Import-Csv $ConfigPath -Delimiter ";" }
        }
        
        $chanCount = 0; $totalChans = $channels.Count
        foreach ($c in $channels) {
            $chanCount++
            $folder = $c.Prefixe 
            $cDir = Join-Path $BaseDir $folder
            if (!(Test-Path -LiteralPath $cDir)) { continue }
            Write-Host "`n  ─── [$chanCount/$totalChans] 🛠️  ANALYSE : $($c.Prefixe) ───" -ForegroundColor Cyan
            
            # Etape 2: Integrite
            if ($doIntegrity) {
                Write-SubStep -Title "INTEGRITE" -StepNum 2 -TotalSteps $totalSteps -Emoji "🔍"
                $diag = Repair-Packs -BaseDir $cDir -Prefix $c.Prefixe
                
                if ($diag.NeedDownload) {
                    Write-Host "      [AUTO-HEAL] Re-telechargement..." -ForegroundColor Cyan
                    $p1 = Join-Path $cDir "1_RAW"
                    $null = Sync-YouTube -Url $c.URL -RawDir $p1 -YtDlp $YtDlp -Ffmpeg $Ffmpeg -Cookies @() -Lang $c.Lang -BaseDir $cDir -LogPrefix $c.Prefixe -BlacklistPath $BlacklistPath -RetryOnly $true
                }
            }

            # Etape 3: Doublons
            if ($doDoublons) {
                Write-SubStep -Title "DOUBLONS" -StepNum 3 -TotalSteps $totalSteps -Emoji "👯"
                Maintenance-Doublons -chanDir $cDir -prefix $c.Prefixe
            }
            
            # Etape 4: Reconstruction
            if ($doPacks) {
                Write-SubStep -Title "PACKS" -StepNum 4 -TotalSteps $totalSteps -Emoji "📦"
                $p1 = Join-Path $cDir "1_RAW"; $p2 = Join-Path $cDir "2_TXT"; $p3 = Join-Path $cDir "3_TXT_dense"; $p4 = Join-Path $cDir "4_Packs"
                $null = Process-LocalFiles -RawDir $p1 -TxtDir $p2 -DenseDir $p3 -Lang $c.Lang -Prefix $c.Prefixe
                $null = Build-Packs -DenseDir $p3 -PacksDir $p4 -Prefix $c.Prefixe -LogPrefix $c.Prefixe -GlobalPacksDir $AllPacksDir
            }

            # Etape 5: Langue
            if ($doLangues) {
                Write-SubStep -Title "LANGUES" -StepNum 5 -TotalSteps $totalSteps -Emoji "🧪"
                Run-LanguageDiagnostic -SpecificChannelDir $cDir
            }
        }
        
        # Etape 6: Verification Finale
        if ($doReview) {
            Write-StepHeader -Title "Bilan et Verification des Packs" -StepNum 6 -TotalSteps $totalSteps -Emoji "📊"
            Review-GlobalPacks -GlobalPacksDir $AllPacksDir
        }

        Write-Host "`n  [SUCCES] Maintenance Globale Terminee." -ForegroundColor Green
    }
    elseif ($choice -eq "7") { Export-MasterInventory }
    
    if ($choice -ne "0") {
        Write-Host "`nAppuyez sur une touche pour continuer..."
        $null = [Console]::ReadKey()
    }
}
