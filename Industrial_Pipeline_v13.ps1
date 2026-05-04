# Industrial YouTube Transcription Pipeline v13.2.2
# Unified Industrial Suite for NotebookLM
# v13.2.2: Added [FORCE] category as a standalone option in re-subtitling.

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
$ErrorActionPreference = "Stop"
$global:CurrentBlacklistPath = $BlacklistPath
$global:pendingBlacklistUpdates = [System.Collections.Generic.List[PSObject]]::new()
$blacklistCandidates = [System.Collections.Generic.List[PSObject]]::new()

function Write-StepHeader {
    param ($Title, $StepNum = $null, $TotalSteps = $null, $Emoji = "📦")
    $line = "══════════════════════════════════════════════════════════"
    $fullTitle = if ($StepNum) { "[ETAPE $StepNum/$TotalSteps] $Title" } else { $Title }
    # Padding manuel pour eviter les artefacts de PadRight
    $rawTitle = "$Emoji $fullTitle"
    $padSize = 57 - $rawTitle.Length
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

function Update-BlacklistEntry($id, $marker, $metadata = "", $NoFlush = $false) {
    if (!(Test-Path $BlacklistPath)) { return }
    $global:pendingBlacklistUpdates.Add([PSCustomObject]@{ ID=$id; Marker=$marker; Metadata=$metadata })
    if (!$NoFlush) { Flush-BlacklistUpdates }
}

function Flush-BlacklistUpdates {
    if ($global:pendingBlacklistUpdates.Count -eq 0) { return }
    try {
        $path = $global:CurrentBlacklistPath
        $content = Get-SafeContent $path
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
        [System.IO.File]::WriteAllLines($path, $newContent)
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
                
                # Nettoyage radical des timestamps (on supprime toute ligne contenant '-->')
                $lines = $txt -split "\r?\n"
                $txt = ($lines | Where-Object { $_ -notmatch '-->' }) -join "`n"
                
                # Suppression des balises residuelles et entites HTML
                $txt = $txt -replace 'align:\S+|position:\S+|line:\S+|size:\S+|region:\S+|<.*?>', ' '
                $txt = $txt -replace '&\w+;', ' '

                
                # Nettoyage des indices numeriques seuls (souvent presents dans SRT/VTT)
                $txt = $txt -replace '(?m)^\d+\s*$', ''
                
                # Si le texte est "aplatit" (tout sur une ligne), on tente de dedupliquer les mots repetitifs (rolling captions)
                # On split par espace, on garde l'ordre mais on enleve les repetitions immediates
                $words = $txt -split "\s+" | Where-Object { $_ -ne "" }
                $uniqueWords = [System.Collections.Generic.List[string]]::new()
                $lastWord = ""
                foreach ($w in $words) {
                    if ($w -ne $lastWord) {
                        $uniqueWords.Add($w)
                        $lastWord = $w
                    }
                }
                $finalTxt = $uniqueWords -join " "
                
                if ($finalTxt.Trim().Length -gt 10) {
                    $finalTxt | Out-File -LiteralPath $txtPath -Encoding utf8
                    
                    # On ne garde que l'essentiel de la meta pour le fichier dense (evite les leaks de 2MB de JSON)
                    try {
                        $jsonMeta = (Get-SafeContent $json.FullName) -join "`r`n"
                        $meta = $jsonMeta | ConvertFrom-Json -AsHashTable
                        $compactMeta = @{
                            id = $meta.id
                            title = $meta.title
                            upload_date = $meta.upload_date
                            duration = $meta.duration
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
                $corruptedCount++
                
                # Identification de l'ID pour tout nettoyer d'un coup
                $id = if ($f.Name -match "\[([a-zA-Z0-9_-]{11})\]") { $Matches[1] }
                
                if ($id) {
                    # On supprime TOUTES les versions texte derivees pour cet ID (RAW TXT, DENSE, etc.)
                    # Cela forcera la reconstruction locale a partir du RAW existant (sans re-telecharger)
                    $derivedFiles = Get-ChildItem -Path $BaseDir -Recurse -File | Where-Object { $_.Name -match "\[$id\]" -and $_.Extension -eq ".txt" }
                    foreach ($df in $derivedFiles) { Remove-Item -LiteralPath $df.FullName -Force -ErrorAction SilentlyContinue }
                    
                    # On ne supprime le RAW que si c'est une fuite JSON (source probablement corrompue)
                    if ($reason -eq "Fuite JSON") {
                        Write-Host "      [!] Source corrompue suspectee. Marquage pour re-telechargement." -ForegroundColor Yellow
                        $needDownload = $true
                        Get-ChildItem -LiteralPath $rawDir | Where-Object { $_.Name.Contains($id) } | Remove-Item -LiteralPath { $_.FullName } -Force -ErrorAction SilentlyContinue
                    }
                } else {
                    # Si pas d'ID trouve dans le nom du fichier DENSE, on supprime au moins ce fichier corrompu
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                }
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
    Write-Host "  Pack Name".PadRight(34) + "Vids".PadLeft(5) + "Hours".PadLeft(8) + "Words".PadLeft(13) -ForegroundColor Gray
    
    $totalWords = 0; $totalVids = 0; $totalSecs = 0
    foreach ($p in $packs) {
        # Lecture securisee pour eviter les erreurs d'encodage
        $content = [System.IO.File]::ReadAllText($p.FullName)
        
        # Nombre de mots
        $words = ($content -split "\s+" | Where-Object { $_ -ne "" }).Count
        
        # Nombre de videos (on compte les marqueurs SOURCE:)
        $vids = ([regex]::Matches($content, "SOURCE:")).Count
        
        # Somme des durees (on extrait le champ duration du JSON compact)
        $secs = 0
        [regex]::Matches($content, '"duration":\s*(\d+)') | ForEach-Object { $secs += [int]$_.Groups[1].Value }
        $hrs = $secs / 3600
        
        $totalWords += $words; $totalVids += $vids; $totalSecs += $secs
        
        # NotebookLM a une limite de 500k mots. 
        # Vert si < 500k (Optimal), Orange si >= 500k (Risque de coupure)
        $color = if ($words -ge 500000) { "Yellow" } else { "Green" }
        $shortName = if ($p.Name.Length -gt 31) { $p.Name.Substring(0, 28) + "..." } else { $p.Name }
        
        Write-Host "  $($shortName.PadRight(34))" -NoNewline -ForegroundColor White
        Write-Host "$($vids.ToString().PadLeft(5))" -NoNewline -ForegroundColor Gray
        Write-Host "$($hrs.ToString('F1').PadLeft(7))h" -NoNewline -ForegroundColor Gray
        Write-Host " $($words.ToString('N0').PadLeft(11))" -ForegroundColor $color
    }
    Write-Host "  " + ("═" * 60) -ForegroundColor Cyan
    $totalHrs = $totalSecs / 3600
    Write-Host "  TOTAL : $($totalWords.ToString('N0')) mots | $($totalVids) vidéos | $($totalHrs.ToString('N1'))h dans $($packs.Count) packs." -ForegroundColor Gray
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
    
    $idsToCheck = [System.Collections.Generic.HashSet[string]]::new()
    $currentBL = Get-Content -LiteralPath $BlacklistPath
    
    if (!$SpecificChannelDir) {
        Write-Host "`n=================================================" -ForegroundColor Cyan
        Write-Host "   DIAGNOSTIC DE LANGUE ET FILTRAGE AUTO" -ForegroundColor Cyan
        Write-Host "=================================================" -ForegroundColor Cyan
        
        Write-Host "  Quelles vidéos analyser ?" -ForegroundColor White
        Write-Host "  1. Nouveaux IDs (missing_videos.txt, 429_errors.txt)"
        Write-Host "  2. Catégorie spécifique Blacklist (ex: [TO-REVIEW] ou [SUB-KO])"
        Write-Host "  3. Manuel (Saisir un ID)"
        $diagChoice = Read-Host "`n  Choix (1-3)"
        
        if ($diagChoice -eq "2") {
            $tag = Read-Host "  Saisir le tag exact (ex: [TO-REVIEW])"
            $currentBL | Where-Object { $_ -match [regex]::Escape($tag) } | ForEach-Object {
                $id = ($_ -split " #")[0].Trim()
                if ($id -match "^[a-zA-Z0-9_-]{11}$") { [void]$idsToCheck.Add($id) }
            }
            $idsToProcess = $idsToCheck # On autorise a traiter des IDs deja dans la BL si on demande explicitement une categorie
        }
        elseif ($diagChoice -eq "3") {
            $manualId = Read-Host "  Saisir l'ID YouTube"
            if ($manualId -match "^[a-zA-Z0-9_-]{11}$") { [void]$idsToCheck.Add($manualId) }
            $idsToProcess = $idsToCheck
        }
        else {
            $log429 = Join-Path $LogsDir "429_errors.txt"
            if (Test-Path -LiteralPath $log429) { foreach ($line in Get-Content -LiteralPath $log429) { if ($line -match "^([a-zA-Z0-9_-]{11})") { [void]$idsToCheck.Add($Matches[1]) } } }
            foreach ($f in Get-ChildItem -LiteralPath $BaseDir -Recurse -Filter "missing_videos.txt") { foreach ($id in Get-Content -LiteralPath $f.FullName) { if ($id -match "^[a-zA-Z0-9_-]{11}$") { [void]$idsToCheck.Add($id) } } }
            $idsToProcess = $idsToCheck | Where-Object { $currentBL -notmatch [regex]::Escape($_) }
        }
    } else {
        $missingPath = Join-Path $SpecificChannelDir "missing_videos.txt"
        if (Test-Path -LiteralPath $missingPath) {
            foreach ($id in Get-Content -LiteralPath $missingPath) {
                if ($id -match "^[a-zA-Z0-9_-]{11}$") { [void]$idsToCheck.Add($id) }
            }
        }
        $idsToProcess = $idsToCheck | Where-Object { $currentBL -notmatch [regex]::Escape($_) }
    }
    
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
    # Chemins dedies au Workflow de re-sous-titrage
    $AudioDir = Join-Path $BaseDir "_RE_SUBTITLING_WORK\1_AUDIO"
    $OutputDir = Join-Path $BaseDir "_RE_SUBTITLING_WORK\3_STATIC_VIDEOS"
    $ThumbDir = Join-Path $BaseDir "_RE_SUBTITLING_WORK\0_THUMBS"

    # S'assurer que les dossiers existent
    foreach ($dir in @($AudioDir, $OutputDir, $ThumbDir)) {
        if (!(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }

    Write-Host "`n=================================================" -ForegroundColor Cyan
    Write-Host "   WORKFLOW RE-SUBTITLING (1FPS STATIC VIDEOS)" -ForegroundColor Cyan
    Write-Host "=================================================" -ForegroundColor Cyan
    
    Write-Host "  Utilisation d'un buffer local pour la blacklist..." -ForegroundColor Gray
    $localBuffer = Join-Path $env:TEMP "blacklist_industrial.tmp"
    Copy-Item -LiteralPath $BlacklistPath -Destination $localBuffer -Force
    $global:CurrentBlacklistPath = $localBuffer

    Write-Host "  Chargement de la blacklist... (Patientez)" -ForegroundColor Gray
    $blContent = [System.IO.File]::ReadAllLines($localBuffer)
    
    Write-Host "`n  Quelles vidéos re-sous-titrer ?" -ForegroundColor White
    Write-Host "  1. [SUB-MISSING] uniquement (Absence de ST)"
    Write-Host "  2. [SUB-KO] uniquement (Mauvaise langue)"
    Write-Host "  3. [TO-REVIEW] uniquement (Vidéos à valeur ajoutée)"
    Write-Host "  4. [FORCE] uniquement (Forçage manuel)"
    Write-Host "  5. TOUT (Missing + KO + TO-REVIEW + FORCE)"
    Write-Host "  6. Manuel (Saisir un ID)"
    $resubChoice = Read-Host "`n  Choix (1-6)"
    
    $filter = switch ($resubChoice) {
        "1" { "\[SUB-MISSING\]" }
        "2" { "\[SUB-KO\]" }
        "3" { "\[TO-REVIEW\]" }
        "4" { "\[FORCE\]" }
        "5" { "Aucun sous-titre|no subtitles|\[SUB-MISSING\]|\[SUB-KO\]|\[TO-REVIEW\]|\[FORCE" }
        "6" { "MANUAL" }
        default { Write-Host "  [DEBUG] Choix invalide ($resubChoice). Retour."; return }
    }
    Write-Host "  [DEBUG] Filtre selectionne : $filter" -ForegroundColor Gray

    Write-Host "  Analyse des entrées... (Patientez)" -ForegroundColor Gray
    $idsToProcess = [System.Collections.Generic.List[string]]::new()
    if ($filter -eq "MANUAL") {
        $manualId = Read-Host "  Saisir l'ID YouTube"
        if ($manualId -match "^[a-zA-Z0-9_-]{11}$") { $idsToProcess.Add($manualId) } else { return }
    } else {
        foreach ($line in $blContent) {
            if ($line -match $filter -and $line -notmatch "\[RE-SUB-VIDEO\]|\[INACCESSIBLE") {
                $id = ($line -split " #")[0].Trim()
                if ($id -match "^[a-zA-Z0-9_-]{11}$") { $idsToProcess.Add($id) }
            }
        }
    }
    
    Write-Host "  [DEBUG] Nombre d'IDs detectes : $($idsToProcess.Count)" -ForegroundColor Gray
    if ($idsToProcess.Count -eq 0) { Write-Log "Aucune video correspondant aux criteres." "Green"; return }

    # Ajout d'une limite optionnelle pour eviter de saturer le systeme
    Write-Host "  $($idsToProcess.Count) vidéos détectées." -ForegroundColor Yellow
    Write-Host "  Combien de vidéos traiter dans cette session ? (Entrée pour TOUT)" -ForegroundColor White
    $limit = Read-Host "  Limite"
    if ($limit -as [int]) { 
        $limitVal = [int]$limit
        Write-Host "  [DEBUG] Application de la limite : $limitVal" -ForegroundColor Gray
        if ($limitVal -gt 0 -and $limitVal -lt $idsToProcess.Count) {
            $idsToProcess = $idsToProcess.GetRange(0, $limitVal)
        }
    }

    $finalIds = @($idsToProcess)
    Write-Host "  [DEBUG] Liste finale : $($finalIds.Count) elements. Type: $($finalIds.GetType().Name)" -ForegroundColor Gray
    if ($finalIds.Count -eq 0) { Write-Log "Aucun ID final a traiter." "Yellow"; return }

    Write-Host "`n  [DEMARRAGE] Traitement de $($finalIds.Count) vidéos..." -ForegroundColor Cyan
    Write-Host "  [DEBUG] AudioDir: $AudioDir (Exists: $(Test-Path $AudioDir))" -ForegroundColor Gray
    Write-Host "  [DEBUG] OutputDir: $OutputDir (Exists: $(Test-Path $OutputDir))" -ForegroundColor Gray
    Write-Host "  Dossier Audio : $AudioDir" -ForegroundColor Gray
    Write-Host "  Dossier Vidéo : $OutputDir" -ForegroundColor Gray
    
    $success = 0; $failed = 0; $idx = 0; $batchIdx = 0
    
    # Buffer pour la liste d'upload (a_uploader.txt)
    $toUpload = [System.Collections.Generic.List[string]]::new()
    $uploadFile = Join-Path $BaseDir "a_uploader.txt"
    if (Test-Path $uploadFile) { $toUpload.AddRange([System.IO.File]::ReadAllLines($uploadFile)) }

    # Dossier de travail local pour eviter les erreurs de buffer Drive
    $localWork = Join-Path $env:TEMP "Industrial_Work_Local"
    if (!(Test-Path $localWork)) { New-Item -ItemType Directory -Path $localWork -Force | Out-Null }

    $processedIds = [System.Collections.Generic.List[string]]::new()

    for ($i=0; $i -lt $finalIds.Count; $i++) {
        $id = $finalIds[$i]; $idx = $i + 1; $batchIdx = $idx
        $prefix = "  [$idx/$($finalIds.Count)]"
        
        try {
            $audioPath = Join-Path $AudioDir "$id.m4a"
            $videoPath = Join-Path $OutputDir "$id.mp4"
            $tmpAudio = Join-Path $localWork "$id.m4a"
            $tmpVideo = Join-Path $localWork "$id.mp4"
            
            # Securite Reprise : Si le MP4 existe deja, on considere comme traite
            if (Test-Path -LiteralPath $videoPath) {
                Write-Host "$prefix SKIP : $id (Déjà généré)" -ForegroundColor Green
                $processedIds.Add($id)
                if ($id -notin $toUpload) { $toUpload.Add($id) }
                $success++; continue
            }

            Write-Host "$prefix PROCESS : $id" -ForegroundColor Cyan
        
            # 1. Recuperation Audio (Local)
            if (Test-Path -LiteralPath $audioPath) {
                Copy-Item -LiteralPath $audioPath -Destination $tmpAudio -Force
            } else {
                & $YtDlp --user-agent $userAgent --quiet --no-warnings -f "bestaudio[ext=m4a]/bestaudio" -o $tmpAudio "https://www.youtube.com/watch?v=$id"
                if (Test-Path -LiteralPath $tmpAudio) { Copy-Item -LiteralPath $tmpAudio -Destination $audioPath -Force }
            }
            
            # 2. Video 1fps (Local)
            if (Test-Path -LiteralPath $tmpAudio) {
                & $ytDlp --user-agent $userAgent --quiet --no-warnings --write-thumbnail --skip-download -o (Join-Path $localWork $id) "https://www.youtube.com/watch?v=$id"
                $thumb = Get-ChildItem -LiteralPath $localWork -Filter "$id.*" | Where-Object { $_.Extension -match "jpg|png|webp|jpeg" } | Select-Object -First 1
                $tIn = if ($thumb) { $thumb.FullName } else { "color=c=black:s=1280x720:r=1" }
                
                if ($thumb) {
                    & $Ffmpeg -y -loglevel error -probesize 100M -analyzeduration 100M -loop 1 -framerate 1 -i $tIn -i $tmpAudio -c:v libx264 -tune stillimage -preset ultrafast -pix_fmt yuv420p -c:a copy -shortest $tmpVideo
                } else {
                    & $Ffmpeg -y -loglevel error -probesize 100M -analyzeduration 100M -f lavfi -i $tIn -i $tmpAudio -c:v libx264 -tune stillimage -preset ultrafast -pix_fmt yuv420p -c:a copy -shortest $tmpVideo
                }
            }
            
            # 3. Synchro finale vers Drive
            if (Test-Path -LiteralPath $tmpVideo) { 
                Move-Item -LiteralPath $tmpVideo -Destination $videoPath -Force
                $success++; $processedIds.Add($id)
                if ($id -notin $toUpload) { $toUpload.Add($id) }
            } else { 
                $failed++ 
                Write-Host "      [!] ECHEC : La video n'a pas pu être générée pour $id" -ForegroundColor Yellow
            }

            Get-ChildItem -LiteralPath $localWork -Filter "$id*" | Remove-Item -Force -ErrorAction SilentlyContinue
            if ($batchIdx % 10 -eq 0) { Flush-BlacklistUpdates }
        } catch {
            Write-Host "      [!!!] ERREUR FATALE ID $id : $($_.Exception.Message)" -ForegroundColor Red
            $failed++
        }
    }
    
    # Synchronisation finale et suppression de la blacklist
    Flush-BlacklistUpdates # Flush les updates en attente
    
    Write-Host "  [SYSTEME] Nettoyage de la blacklist..." -ForegroundColor Gray
    $currentBl = [System.IO.File]::ReadAllLines($localBuffer)
    $newBl = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $currentBl) {
        $idInLine = if ($line -match "^([a-zA-Z0-9_-]{11})") { $Matches[1] } else { $null }
        if ($idInLine -and $processedIds.Contains($idInLine)) {
            continue # On supprime l'ID traite
        }
        $newBl.Add($line)
    }
    [System.IO.File]::WriteAllLines($localBuffer, $newBl)
    
    # Copie finale vers Drive
    Copy-Item -LiteralPath $localBuffer -Destination $BlacklistPath -Force
    $global:CurrentBlacklistPath = $BlacklistPath
    
    # Sauvegarde de la liste d'upload
    $finalToUpload = @($toUpload | Select-Object -Unique)
    [System.IO.File]::WriteAllLines($uploadFile, $finalToUpload)
    
    Write-Host "`n  [OK] Blacklist mise à jour (vidéos traitées supprimées)." -ForegroundColor Green
    Write-Host "  [OK] Liste d'upload mise à jour : $($finalToUpload.Count) vidéos prêtes dans a_uploader.txt" -ForegroundColor Cyan
}

# ==============================================================================
# MODULE 4: INVENTAIRE ET TABLEAU DE BORD GLOBAL
# ==============================================================================

function Export-MasterInventory {
    $exportPath = Join-Path $BaseDir "MASTER_INVENTORY_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"
    Write-Host "`n[SYSTEME] Generation de l'inventaire global... (Patientez)" -ForegroundColor Cyan
    
    $channels = Import-Csv $ConfigPath -Delimiter ";"
    $totalChans = $channels.Count
    $cIdx = 0
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

    Write-Host "`n  Traitement de $totalChans chaînes configurées..." -ForegroundColor White
    foreach ($chan in $channels) {
        $cIdx++
        $logPrefix = $chan.Prefixe
        
        # On tente plusieurs variantes de nom de dossier pour etre sur de trouver la chaine
        $folderCandidates = @(
            $chan.Prefixe.Trim(),                                     # Original "Oussama Ammar"
            ($chan.Prefixe -replace "[^a-zA-Z0-9 ]", "").Trim(),      # "Oussama Ammar" (sanitized)
            ($chan.Prefixe -replace "[^a-zA-Z0-9]", "_").Trim(),      # "Oussama_Ammar"
            ($chan.Prefixe -replace "\s+", "_").Trim()                # "Oussama_Ammar"
        ) | Select-Object -Unique
        
        $cDir = $null
        foreach ($f in $folderCandidates) {
            $path = Join-Path $BaseDir $f
            if (Test-Path -LiteralPath $path) { $cDir = $path; break }
        }

        if (!$cDir) { 
            Write-Host "  [$cIdx/$totalChans] [!] Dossier absent pour : $logPrefix" -ForegroundColor Yellow
            continue 
        }
        
        Write-Host "  [$cIdx/$totalChans] Analyse : $logPrefix" -ForegroundColor Gray
        
        $masterPath = Join-Path $cDir "youtube_master_list.txt"
        $missingPath = Join-Path $cDir "missing_videos.txt"
        $rawPath = Join-Path $cDir "1_RAW"
        $densePath = Join-Path $cDir "3_TXT_dense"
        
        $masterIds = Get-SafeContent $masterPath
        
        $missingIds = @{}
        foreach ($mId in (Get-SafeContent $missingPath)) { if ($mId.Trim()) { $missingIds[$mId.Trim()] = $true } }
        
        # Cache des fichiers denses
        $denseFiles = @{}
        if (Test-Path $densePath) {
            Get-ChildItem -Path $densePath -Filter "*.txt" | ForEach-Object {
                if ($_.Name -match "\[([a-zA-Z0-9_-]{11})\]") { $denseFiles[$Matches[1]] = $_.FullName }
            }
        }

        # Cache des fichiers RAW pour metadonnees
        $rawFiles = @{}
        if (Test-Path $rawPath) {
            Get-ChildItem -Path $rawPath -Filter "*.info.json" | ForEach-Object {
                if ($_.Name -match "\[([a-zA-Z0-9_-]{11})\]") { $rawFiles[$Matches[1]] = $_.FullName }
            }
        }

        # Cache des packs pour savoir ou est chaque video
        $packMap = @{}
        $p4 = Join-Path $cDir "4_Packs"
        if (Test-Path $p4) {
            Get-ChildItem -Path $p4 -Filter "*.txt" | ForEach-Object {
                $pName = $_.BaseName
                $pContent = (Get-SafeContent $_.FullName) -join "`n"
                $matches = [regex]::Matches($pContent, "\[([a-zA-Z0-9_-]{11})\]")
                foreach ($m in $matches) { $packMap[$m.Groups[1].Value] = $pName }
            }
        }

        foreach ($id in $masterIds) {
            $id = $id.Trim()
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            
            $status = "DETECTED (ON YT)"
            $reason = ""; $wordCount = 0; $title = ""; $date = ""; $duration = ""; $lang = ""
            
            # Recuperation du Titre / Date / Duree via le RAW s'il existe
            if ($rawFiles.ContainsKey($id)) {
                $fPath = $rawFiles[$id]
                $fName = [System.IO.Path]::GetFileNameWithoutExtension($fPath)
                if ($fName -match "^(\d{8})\s*-\s*(.*)\s+\[$id\]") {
                    $date = $Matches[1]; $title = $Matches[2]
                } elseif ($fName -match "^(.*)\s+\[$id\]") {
                    $title = $Matches[1]
                }
                
                # Extraction ultra-rapide de la duree et langue du JSON (sans parse complet)
                try {
                    $jsonSample = (Get-SafeContent $fPath) -join "`r`n"
                    if ($jsonSample -match '"duration":\s*(\d+)') { $duration = $Matches[1] }
                    if ($jsonSample -match '"language":\s*"(.*?)"') { $lang = $Matches[1] }
                } catch {}
            }

            if ($blMap.ContainsKey($id)) {
                $status = "BLACKLISTED"
                $reason = $blMap[$id]
            } elseif ($denseFiles.ContainsKey($id)) {
                $status = "SUCCESS (DENSE)"
                try {
                    $content = (Get-SafeContent $denseFiles[$id]) -join "`r`n"
                    if (!$title -and $content -match "TITLE: (.*)") { $title = $Matches[1].Trim() }
                    $parts = $content -split "`r`n`r`n", 2
                    if ($parts.Count -gt 1) {
                        $wordCount = ($parts[1] -split "\s+" | Where-Object { $_ -ne "" }).Count
                    }
                } catch { }
            } elseif ($rawFiles.ContainsKey($id)) {
                $status = "DOWNLOADED (RAW ONLY)"
            } elseif ($missingIds.ContainsKey($id)) {
                $status = "FAILED/PENDING"
            }

            [void]$inventory.Add([PSCustomObject]@{
                Channel  = $logPrefix
                Date     = $date
                Title    = $title
                Duration = $duration
                Lang     = $lang
                VideoID  = $id
                Status   = $status
                Reason   = $reason
                Words    = $wordCount
                Pack     = if ($packMap.ContainsKey($id)) { $packMap[$id] } else { "" }
            })
        }
    }

    if ($inventory.Count -gt 0) {
        $inventory | Export-Csv -Path $exportPath -NoTypeInformation -Delimiter "," -Encoding utf8
        Write-Host "`n[SUCCES] Inventaire genere : $exportPath" -ForegroundColor Green
        Write-Host "Nombre total d'entrees : $($inventory.Count)" -ForegroundColor White
    } else {
        Write-Host "`n[!] Aucun donnee trouvee pour l'inventaire." -ForegroundColor Red
    }
}

while ($true) {
    Clear-Host
    Write-Host "`n  ============================================================" -ForegroundColor Magenta
    Write-Host "             INDUSTRIAL PIPELINE v13.2.2 UNIFIED" -ForegroundColor White
    Write-Host "  ============================================================`n" -ForegroundColor Magenta
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
        Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "  ║             Maintenance globale du pipeline              ║" -ForegroundColor White
        Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
        
        $mMode = Read-Host "`n  Mode de travail : (1) TOUTES les chaînes | (2) Une chaîne spécifique [Défaut: 1]"
        if ($mMode -eq "2") {
            Write-Host "`n  --- SELECTION DE LA CHAINE ---" -ForegroundColor Cyan
            for ($i=0; $i -lt $channels.Count; $i++) {
                Write-Host "  $($i+1). $($channels[$i].Prefixe)"
            }
            $cSel = Read-Host "`n  Choix (1-$($channels.Count))"
            if ($cSel -as [int] -and [int]$cSel -gt 0 -and [int]$cSel -le $channels.Count) {
                $channels = @($channels[[int]$cSel - 1])
                Write-Host "  [OK] Cible : $($channels[0].Prefixe)" -ForegroundColor Green
            }
        }

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
        
        # Etape 2: Diagnostic d'Intégrité
        if ($doIntegrity) {
            Write-StepHeader -Title "Diagnostic d'Intégrité" -StepNum 2 -TotalSteps $totalSteps -Emoji "🔍"
            $cIdx = 0; $cTotal = $channels.Count
            foreach ($c in $channels) {
                $cIdx++
                $folder = $c.Prefixe; $cDir = Join-Path $BaseDir $folder
                if (Test-Path -LiteralPath $cDir) {
                    Write-SubStep -Title "Analyse : $($c.Prefixe)" -StepNum $cIdx -TotalSteps $cTotal -Emoji "🔍"
                    $diag = Repair-Packs -BaseDir $cDir -Prefix $c.Prefixe
                    if ($diag.NeedDownload) {
                        Write-Host "      [AUTO-HEAL] Re-telechargement..." -ForegroundColor Cyan
                        $p1 = Join-Path $cDir "1_RAW"
                        $null = Sync-YouTube -Url $c.URL -RawDir $p1 -YtDlp $YtDlp -Ffmpeg $Ffmpeg -Cookies @() -Lang $c.Lang -BaseDir $cDir -LogPrefix $c.Prefixe -BlacklistPath $BlacklistPath -RetryOnly $true
                    }
                }
            }
        }

        # Etape 3: Nettoyage des Doublons
        if ($doDoublons) {
            Write-StepHeader -Title "Nettoyage des Doublons" -StepNum 3 -TotalSteps $totalSteps -Emoji "👯"
            $cIdx = 0; $cTotal = $channels.Count
            foreach ($c in $channels) {
                $cIdx++
                $folder = $c.Prefixe; $cDir = Join-Path $BaseDir $folder
                if (Test-Path -LiteralPath $cDir) {
                    Write-SubStep -Title "Analyse : $($c.Prefixe)" -StepNum $cIdx -TotalSteps $cTotal -Emoji "👯"
                    Maintenance-Doublons -chanDir $cDir -prefix $c.Prefixe
                }
            }
        }
        
        # Etape 4: Reconstruction des Packs
        if ($doPacks) {
            Write-StepHeader -Title "Reconstruction des Packs" -StepNum 4 -TotalSteps $totalSteps -Emoji "📦"
            $cIdx = 0; $cTotal = $channels.Count
            foreach ($c in $channels) {
                $cIdx++
                $folder = $c.Prefixe; $cDir = Join-Path $BaseDir $folder
                if (Test-Path -LiteralPath $cDir) {
                    Write-SubStep -Title "Analyse : $($c.Prefixe)" -StepNum $cIdx -TotalSteps $cTotal -Emoji "📦"
                    $p1 = Join-Path $cDir "1_RAW"; $p2 = Join-Path $cDir "2_TXT"; $p3 = Join-Path $cDir "3_TXT_dense"; $p4 = Join-Path $cDir "4_Packs"
                    $null = Process-LocalFiles -RawDir $p1 -TxtDir $p2 -DenseDir $p3 -Lang $c.Lang -Prefix $c.Prefixe
                    $null = Build-Packs -DenseDir $p3 -PacksDir $p4 -Prefix $c.Prefixe -LogPrefix $c.Prefixe -GlobalPacksDir $AllPacksDir
                }
            }
        }

        # Etape 5: Diagnostic de Langue
        if ($doLangues) {
            Write-StepHeader -Title "Filtrage des Langues" -StepNum 5 -TotalSteps $totalSteps -Emoji "🧪"
            $cIdx = 0; $cTotal = $channels.Count
            foreach ($c in $channels) {
                $cIdx++
                $folder = $c.Prefixe; $cDir = Join-Path $BaseDir $folder
                if (Test-Path -LiteralPath $cDir) {
                    Write-SubStep -Title "Analyse : $($c.Prefixe)" -StepNum $cIdx -TotalSteps $cTotal -Emoji "🧪"
                    Run-LanguageDiagnostic -SpecificChannelDir $cDir
                }
            }
        }
        
        # Etape 6: Verification Finale
        if ($doReview) {
            Write-StepHeader -Title "Bilan et Verification des Packs" -StepNum 6 -TotalSteps $totalSteps -Emoji "📊"
            Review-GlobalPacks -GlobalPacksDir $AllPacksDir
        }

        Write-Host "`n  [SUCCES] Maintenance Terminee." -ForegroundColor Green
    }
    elseif ($choice -eq "7") { Export-MasterInventory }
    
    if ($choice -ne "0") {
        Write-Host "`nAppuyez sur une touche pour continuer..."
        $null = [Console]::ReadKey()
    }
}
