# Industrial YouTube Transcription Pipeline v14.0.0 (SQLITE)
param(
    [string]$ChannelName = $null,
    [string]$Action = $null,
    [switch]$AutoLoop = $false,
    [string]$ReverseAll = "n"
)
Write-Host "  [DEBUG] Parametre ChannelName recu : [$ChannelName]" -ForegroundColor Yellow
# Hardened for Google Drive stability and scalability with SQLite DB storage.
# v14.0.0: Architecture "DB-First" to reduce file count and I/O latency.

$PSDefaultParameterValues['*:Encoding'] = 'utf8'
$ErrorActionPreference = "Stop"
$OutputEncoding = [System.Text.Encoding]::UTF8
if ($null -ne [Console]::OutputEncoding) { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 }
if ($null -ne [Console]::InputEncoding) { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 }

# ==============================================================================
# CONFIGURATION GLOBALE
# ==============================================================================
$BaseDir = $PSScriptRoot
$BinDir = Join-Path $BaseDir "BIN"
$global:YtDlp = Join-Path $BinDir "yt-dlp.exe"
$global:Ffmpeg = Join-Path $BinDir "ffmpeg.exe"
$global:Sqlite = Join-Path $BinDir "sqlite3.exe"
$global:ConfigPath = Join-Path $BaseDir "channels_config.csv"
$global:BlacklistPath = Join-Path $BaseDir "blacklist.txt"
$global:AllPacksDir = Join-Path $BaseDir "ALL_PACKS"
$global:DbDir = Join-Path $BaseDir "DATA_STORES"
$global:LogsDir = Join-Path $BaseDir "_LOGS"
$global:ReSubDir = Join-Path $BaseDir "_RE_SUBTITLING_WORK"

# Directories for Re-Subtitling
$AudioDir = Join-Path $ReSubDir "1_AUDIO"
$ThumbDir = Join-Path $ReSubDir "2_THUMBS"
$OutputDir = Join-Path $ReSubDir "3_STATIC_VIDEOS"
$SettingsPath = Join-Path $BaseDir "settings.json"

# Default Settings
$global:Settings = @{
    CookieSource = "firefox"
    MaxPlaylistEnd = 2000
    AutoClean = $true
    UseDatabase = $true
}

if (Test-Path $SettingsPath) {
    try {
        $saved = Get-Content -LiteralPath $SettingsPath | ConvertFrom-Json -AsHashTable
        foreach ($k in $saved.Keys) { $global:Settings[$k] = $saved[$k] }
    } catch { }
}

$global:useCookies = @()
$global:userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36"

function Save-Settings {
    $global:Settings | ConvertTo-Json | Out-File $SettingsPath -Encoding utf8
}

# Ensure core directories exist
foreach ($p in @($BinDir, $global:AllPacksDir, $LogsDir, $ReSubDir, $AudioDir, $ThumbDir, $OutputDir, $global:DbDir)) {
    if (!(Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
}

$threadLimit = 16
$userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36"
$ErrorActionPreference = "Stop"
$global:CurrentBlacklistPath = $BlacklistPath
$global:pendingBlacklistUpdates = [System.Collections.Generic.List[PSObject]]::new()
$blacklistCandidates = [System.Collections.Generic.List[PSObject]]::new()

# --- HELPER: SQLite Engine ---
function Invoke-Sqlite {
    param (
        [Parameter(Mandatory=$true)] [string]$DbPath,
        [Parameter(Mandatory=$true)] [string]$Query,
        [switch]$Silent
    )
    if (!(Test-Path $Sqlite)) {
        throw "Erreur : BIN\sqlite3.exe introuvable. Veuillez l'installer."
    }
    
    # Envoi de la requête via stdin (plus robuste pour les gros textes)
    $exe = if ($global:Sqlite) { $global:Sqlite } else { $Sqlite }
    if (!(Test-Path $exe)) { throw "SQLite executable introuvable: $exe" }
    
    if (!$Silent) { Write-Host "    [SQL] Executing on $DbPath" -ForegroundColor Gray }
    $result = $Query | & $exe $DbPath 2>&1
    if ($result -match "Error:") { throw "SQLite Error: $result" }
    return $result
}

function Ensure-ChannelDb {
    param ([string]$ChannelName)
    $DbPath = Join-Path $global:DbDir "$($ChannelName).db"
    if (!(Test-Path $DbPath)) {
        Write-Host "  [DB] Creation de la base pour $ChannelName..." -ForegroundColor Cyan
        $schema = "CREATE TABLE IF NOT EXISTS videos (youtube_id TEXT PRIMARY KEY, title TEXT, upload_date TEXT, duration INTEGER, view_count INTEGER, channel TEXT, description TEXT, transcript TEXT, status TEXT, last_updated DATETIME DEFAULT CURRENT_TIMESTAMP);"
        Invoke-Sqlite -DbPath $DbPath -Query $schema
    }
    return $DbPath
}

function Write-StepHeader {
    param ($Title, $StepNum = $null, $TotalSteps = $null, $Emoji = "[*]")
    $line = "a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??"
    $fullTitle = if ($StepNum) { "[ETAPE $StepNum/$TotalSteps] $Title" } else { $Title }
    $rawTitle = "$Emoji $fullTitle"
    $padSize = 56 - $rawTitle.Length
    if ($padSize -lt 0) { $padSize = 0 }
    $padding = " " * $padSize
    Write-Host "`n  a??$linea??" -ForegroundColor Cyan
    Write-Host "  a?? $rawTitle$padding a??" -ForegroundColor White
    Write-Host "  a??$linea??" -ForegroundColor Cyan
}

function Write-SubStep {
    param ($Title, $StepNum, $TotalSteps, $Emoji = "[+]", $Status = "")
    $prefix = "  [$StepNum/$TotalSteps] $Emoji $Title"
    Write-Host $prefix.PadRight(40) -NoNewline -ForegroundColor Gray
    if ($Status) { Write-Host " : $Status" -ForegroundColor White }
    else { Write-Host "" }
}

function Get-DurationStr {
    param($StartTime)
    $elapsed = (Get-Date) - $StartTime
    if ($elapsed.TotalHours -ge 1) { return "$([Math]::Floor($elapsed.TotalHours))h $($elapsed.Minutes)m" }
    return "$($elapsed.Minutes)m $($elapsed.Seconds)s"
}

# ==============================================================================
# ENCODAGE ET AFFICHAGE
# ==============================================================================
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['*:Encoding'] = 'utf8'

function Write-Header {
    param($Title)
    $w = 80
    $line = "=" * $w
    Write-Host "`n$line" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor White -Bold
    Write-Host "$line" -ForegroundColor Cyan
}

function Invoke-Sqlite {
    param($DbPath, $Query)
    # Nettoyage radical des guillemets
    $cleanPath = $DbPath.Replace('"', '')
    $tmpSql = [System.IO.Path]::GetTempFileName()
    $Query | Out-File $tmpSql -Encoding utf8
    $res = & $Sqlite -header -json "$cleanPath" ".read $tmpSql" | Out-String
    Remove-Item $tmpSql -ErrorAction SilentlyContinue
    if ($res -and $res.Trim()) { return $res | ConvertFrom-Json }
    return @()
}

function Write-Log {
    param ($msg, $color = "White", $prefix = "SYSTEM")
    $timestamp = Get-Date -Format "HH:mm:ss"
    $logMsg = "[$timestamp] [$prefix] $msg"
    try {
        $logFile = Join-Path $global:LogsDir "pipeline.log"
        $logMsg | Add-Content -LiteralPath $logFile -ErrorAction SilentlyContinue
    } catch { }

    if ($msg -notmatch $noisePattern) {
        $shortMsg = $msg -replace "^\[.*?\]\s*", ""
        if ($shortMsg.Trim() -ne "") {
            $pCol = switch($prefix) { "SYSTEM" {"Cyan"} "DIAG" {"Yellow"} "LOCK" {"Red"} default {"Gray"} }
            Write-Host "[$timestamp] " -NoNewline -ForegroundColor DarkGray
            Write-Host "[$prefix] " -NoNewline -ForegroundColor $pCol
            Write-Host $shortMsg -ForegroundColor $color
        }
    }
}


function Get-CleanTranscript {
    param($content)
    if (!$content) { return "" }
    # 1. Suppression des tags HTML et artifacts VTT (align/position/region)
    $txt = $content -replace '(?s)<.*?>', '' -replace '(?m)^WEBVTT\s*$', '' -replace '(?m)^Kind:.*$', '' -replace '(?m)^Language:.*$', ''
    $txt = $txt -replace '(align|position|size|line|vertical|region|style):\S+', ' '
    
    # 2. Suppression des timestamps (Complexes: 20181004|00:00:00, Classiques: 00:00:00.000)
    $txt = $txt -replace '\d{8}\|\d{1,2}:\d{2}:\d{2}[\.,]\d{3}', ' '
    $txt = $txt -replace '\d{1,2}:\d{2}:\d{2}[\.,]\d{3}\s*-->\s*\d{1,2}:\d{2}:\d{2}[\.,]\d{3}', ' '
    $txt = $txt -replace '\b\d{1,2}:\d{2}\b', ' ' # Timestamps simples mm:ss
    
    # 3. Nettoyage final (artifacts numeriques et espaces)
    $txt = $txt -replace '(?m)^\d+\s*$', '' -replace '&\w+;', ' ' -replace '\s+', ' '
    
    # 4. Normalisation Unicode (Apostrophes et Guillemets)
    $txt = $txt -replace '[\u2018\u2019\u201A\u201B]', "'"
    $txt = $txt -replace '[\u201C\u201D\u201E\u201F]', '"'
    # Reparation des '?' mal places (ex: don?t, it?s, D?Agostino)
    $txt = $txt -replace '([a-zA-Z])\?([a-zA-Z])', '$1''$2'
    
    # 5. Suppression des doublons consecutifs (Stuttering des auto-subs)
    $words = $txt -split "\s+" | Where-Object { $_ -ne "" }
    $uniqueWords = [System.Collections.Generic.List[string]]::new(); $lastW = ""
    foreach ($w in $words) { if ($w -ne $lastW) { $uniqueWords.Add($w); $lastW = $w } }
    return $uniqueWords -join " "
}

function Get-SafeContent {
    param($Path, $Raw = $false)
    if (!(Test-Path -LiteralPath $Path)) { return if ($Raw) { "" } else { @() } }
    $maxRetries = 5; $retryCount = 0
    while ($retryCount -lt $maxRetries) {
        try {
            $encoding = [System.Text.Encoding]::UTF8
            if ($Raw) { return [System.IO.File]::ReadAllText($Path, $encoding) }
            return [System.IO.File]::ReadAllLines($Path, $encoding)
        } catch {
            $retryCount++
            $err = $_.Exception.Message
            if ($retryCount -lt $maxRetries) { 
                # On log seulement si c'est une erreur de type "Drive busy" ou "Semaphore"
                if ($err -match "temporisation|semaphore|occupe|busy|locked") {
                    Write-Host "  [RETRY $retryCount/$maxRetries] Acca?s disque differe : $err" -ForegroundColor Yellow
                }
                Start-Sleep -Milliseconds (500 * $retryCount) 
            }
            else { 
                try { return if ($Raw) { Get-Content -LiteralPath $Path -Raw } else { Get-Content -LiteralPath $Path } } catch { return if ($Raw) { "" } else { @() } }
            }
        }
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
    param ($Url, $LogPrefix, $Lang, $RetryOnly, $Reverse = $false)
    
    $cDir = Join-Path $global:BaseDir $LogPrefix
    $RawDir = Join-Path $cDir "1_RAW"
    
    $masterListPath = Join-Path $cDir "youtube_master_list.txt"
    $missingListPath = Join-Path $cDir "missing_videos.txt"
    
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
        $rawContent = Get-Content -LiteralPath $missingListPath -ErrorAction SilentlyContinue
        $masterIds = if ($rawContent) {
            $rawContent | ForEach-Object {
                $line = $_.Trim()
                if ($line -match "\|") { ($line -split "\|")[-1].Trim() } else { $line }
            } | Where-Object { $_ -match "^[a-zA-Z0-9_-]{11}$" }
        } else { @() }
    } else {
        Write-Host "  [PATIENCE] Scan de la playlist en cours ($($global:Settings.MaxPlaylistEnd) videos max)..." -ForegroundColor Gray
        Write-Log "Extraction de la liste (IDs + Titres)..." "Gray" $LogPrefix
        
        $masterIds = [System.Collections.Generic.List[string]]::new()
        $scanCount = 0
        
        $reverseArg = if ($Reverse) { "--playlist-reverse" } else { "" }
        # Extraction en flux pour afficher la progression
        & $global:YtDlp --flat-playlist --playlist-end $($global:Settings.MaxPlaylistEnd) $reverseArg --print "%(title)s|%(id)s" --quiet --no-warnings $Url | ForEach-Object {
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

    if ($null -eq $masterIds) { return @{ Playlist = 0; Local = 0; Ignored = 0; Detail = ""; Missing = 0 } }
    
    $originalMasterIds = [string[]]$masterIds
    $originalMasterCount = $originalMasterIds.Count
    $masterIds = $masterIds | Where-Object { $_ -notin $blacklist }
    $ignoredByBlacklist = $originalMasterCount - $masterIds.Count
    if ($ignoredByBlacklist -gt 0) {
        $i = 0; while ($i -lt 5) { try { "[$LogPrefix] $(Get-Date -Format 'HH:mm:ss') $ignoredByBlacklist video(s) ignoree(s) (Blacklist)." | Add-Content (Join-Path $global:LogsDir "pipeline.log") -ErrorAction Stop; break } catch { $i++; Start-Sleep -Milliseconds 100 } }
    }

    $localIds = [System.Collections.Generic.HashSet[string]]::new()
    
    # --- PHASE 1 : Consultation de la Base de Donnees (Ultra-Rapide) ---
    if ($global:Settings.UseDatabase) {
        $dbPath = Ensure-ChannelDb -ChannelName $LogPrefix
        $dbIds = Invoke-Sqlite -DbPath $dbPath -Query "SELECT youtube_id FROM videos;"
        if ($dbIds) {
            foreach ($row in $dbIds) {
                $id = $row.youtube_id.Trim()
                if ($id -match "^[a-zA-Z0-9_-]{11}$") { [void]$localIds.Add($id) }
            }
        }
        Write-Host "  [DB] $($localIds.Count) videos trouvees en base de donnees." -ForegroundColor Gray
    }

# --- HELPER: Reading Files with UTF8 and Retry ---
function Get-SafeContent {
    param($p)
    $i = 0
    while ($i -lt 3) {
        try {
            return [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
        } catch {
            $i++
            Start-Sleep -Milliseconds 200
        }
    }
    return ""
}

    # --- PHASE 2 : Scan du dossier local (pour les nouveaux fichiers non encore en base) ---
    Write-Host "  [SCAN] Recherche de nouveaux fichiers dans 1_RAW..." -ForegroundColor Gray
    $allFiles = [System.IO.Directory]::GetFiles($RawDir)
    $totalLocal = $allFiles.Count
    if ($totalLocal -gt 0) {
        $results = $allFiles | ForEach-Object {
            $fName = [System.IO.Path]::GetFileName($_)
            $fExt = [System.IO.Path]::GetExtension($_)
            $foundId = $null
            if ($fName -match "\[([a-zA-Z0-9_-]{11})\]") {
                $foundId = $Matches[1]
            } elseif ($fExt -eq ".json") {
                $content = Get-SafeContent $_
                if ($content -match '"id":\s*"([a-zA-Z0-9_-]{11})"') { $foundId = $Matches[1] }
            }
            if ($foundId) { $foundId }
        }
        foreach ($id in $results) { [void]$localIds.Add($id) }
    }
    Write-Host "  [SUCCES] Inventaire complet : $($localIds.Count) videos locales.          " -ForegroundColor Gray

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
        $consecutive429 = 0
        foreach ($id in $toDownload.ToArray()) {
            $vTitle = if ($titlesMap.ContainsKey($id)) { $titlesMap[$id] } else { "Titre inconnu" }
            Write-Host "[$LogPrefix] [INGEST $currentIndex/$totalVideos] $id - $vTitle" -ForegroundColor White
            
            # 1. Fetch Metadata (with 429 Strike Tracking)
            $meta = $null
            $retryCount = 0; $maxRetries = 2
            $found429 = $false
            while ($retryCount -lt $maxRetries) {
                $rawMeta = & $global:YtDlp --user-agent $global:userAgent @global:useCookies --quiet --no-warnings -j "https://www.youtube.com/watch?v=$id" 2>&1 | Out-String
                if ($rawMeta -match "429: Too Many Requests") {
                    $found429 = $true; break
                } elseif ($rawMeta.Trim().StartsWith("{")) {
                    try { $meta = $rawMeta | ConvertFrom-Json; break } catch { $retryCount++; Start-Sleep -Seconds 5 }
                } else { break }
            }

            if ($found429) {
                $consecutive429++
                Write-Host "    [!] Strike $consecutive429/3 (Rate Limit 429)" -ForegroundColor Yellow
                if ($consecutive429 -ge 3) {
                    Write-Host "    [!!!] 3 Strikes! Mise en pause de cette chaine pour 1 HEURE." -ForegroundColor Red
                    return @{ Playlist = $originalMasterIds.Count; Local = $localIds.Count; Ignored = $ignoredByBlacklist; Status = "BACKOFF_1H" }
                }
                $currentIndex++; continue
            }
            $consecutive429 = 0 # Reset si succes

            if (!$meta) {
                Write-Host "    [!] Impossible de recuperer les metadonnees." -ForegroundColor Yellow
                $currentIndex++; continue
            }
            
            # 2. Identification (Premium / No-Subs)
            $statusTag = "DONE"
            $isPremium = $meta.availability -ne "public" -and $meta.availability -ne "unlisted"
            if ($isPremium) {
                $statusTag = "PREMIUM"
                Write-Host "    [!] Video Premium. Skip." -ForegroundColor Yellow
            } else {
                $hasSubs = $meta.subtitles.PSObject.Properties.Name.Count -gt 0 -or $meta.automatic_captions.PSObject.Properties.Name.Count -gt 0
                if (!$hasSubs) {
                    $statusTag = "NO_SUBS"
                    Write-Host "    [!] Aucun sous-titre. Skip." -ForegroundColor Yellow
                }
            }

            if ($statusTag -ne "DONE") {
                $dbPath = Ensure-ChannelDb -ChannelName $LogPrefix
                $eTitle = $meta.title -replace "'", "''"
                $sql = "INSERT OR REPLACE INTO videos (youtube_id, title, upload_date, duration, view_count, channel, status) VALUES ('$id', '$eTitle', '$($meta.upload_date)', $($meta.duration), $($meta.view_count), '$($meta.channel)', '$statusTag');"
                Invoke-Sqlite -DbPath $dbPath -Query $sql | Out-Null
                $currentIndex++; continue
            }
            
            # 3. Download Subtitles
            $tempSubDir = Join-Path $global:BaseDir "_TEMP\subs_$id"
            if (Test-Path $tempSubDir) { Remove-Item -Path $tempSubDir -Recurse -Force -ErrorAction SilentlyContinue }
            New-Item -ItemType Directory -Path $tempSubDir -Force | Out-Null
            
            # On cherche FR ou EN
            $targetLang = if ($Lang -eq "auto") { "fr", "en" } else { @($Lang) }
            $foundFile = $null
            foreach ($l in $targetLang) {
                $dlpArgs = @("--skip-download", "--no-playlist", "--no-warnings", "--write-sub", "--write-auto-sub", "--sub-langs", $l, "-o", (Join-Path $tempSubDir "sub"), "https://www.youtube.com/watch?v=$id")
                $dlpOut = & $global:YtDlp @dlpArgs 2>&1
                $subFile = Get-ChildItem -Path $tempSubDir -Filter "sub.*" | Where-Object { $_.Extension -match "srt|vtt" } | Select-Object -First 1
                if ($subFile) { $foundFile = $subFile; break }
            }

            if ($foundFile) {
                $rawText = [System.IO.File]::ReadAllText($foundFile.FullName, [System.Text.Encoding]::UTF8)
                $cleanText = Get-CleanTranscript -content $rawText
                if ($cleanText.Length -gt 100) {
                    $dbPath = Ensure-ChannelDb -ChannelName $LogPrefix
                    $sTitle = $meta.title -replace '\?{3,}', "'"
                    $eTitle = $sTitle -replace "'", "''"
                    $eDesc = $meta.description -replace "'", "''"
                    $cleanDate = $meta.upload_date -replace '^(\d{4})(\d{2})(\d{2})$', '$3/$2/$1'
                    
                    $header = "====================================`nSOURCE: YouTube - $LogPrefix`nTITLE: $sTitle`nURL: https://www.youtube.com/watch?v=$id`nDATE: $cleanDate`n====================================`n`n"
                    $eText = ($header + $cleanText) -replace "'", "''"
                    
                    $sql = "INSERT OR REPLACE INTO videos (youtube_id, title, upload_date, duration, view_count, channel, description, transcript, status) VALUES ('$id', '$eTitle', '$($meta.upload_date)', $($meta.duration), $($meta.view_count), '$($meta.channel)', '$eDesc', '$eText', 'DONE');"
                    Invoke-Sqlite -DbPath $dbPath -Query $sql | Out-Null
                    Write-Host "    [SUCCES] Ingestion reussie." -ForegroundColor Green
                    $toDownload.Remove($id) | Out-Null
                    $toDownload | Out-File -LiteralPath $missingListPath -Encoding utf8
                $dlpStr = $dlpOut | Out-String
                if ($dlpStr -match "429|Too Many Requests") { $reason = "RETRY_429" }
                elseif ($dlpStr -match "Premium|copyright|Music|protected") { $reason = "PREMIUM" }
                elseif ($dlpStr -match "available|subtitles") { $reason = "NO_SUBS" }
                
                # On insere en base avec le statut d'erreur pour que l'audit le voit
                $dbPath = Ensure-ChannelDb -ChannelName $LogPrefix
                $sTitle = $meta.title -replace "'", "''"
                $sql = "INSERT OR REPLACE INTO videos (youtube_id, title, upload_date, duration, view_count, channel, status) VALUES ('$id', '$sTitle', '$($meta.upload_date)', $($meta.duration), $($meta.view_count), '$($meta.channel)', '$reason');"
                Invoke-Sqlite -DbPath $dbPath -Query $sql | Out-Null
                Write-Host "  [!] Echec du telechargement ($reason)." -ForegroundColor Red
            }
            
            # Cleanup temp
            Remove-Item -Path $tempSubDir -Recurse -Force -ErrorAction SilentlyContinue
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

    return @{ Playlist = $originalMasterIds.Count; Local = $localIds.Count; Ignored = $ignoredByBlacklist; Detail = $blDetail; Missing = $toDownload.Count }
}

function Process-LocalFiles {
    param ($RawDir, $TxtDir, $DenseDir, $Lang, $Prefix)
    
    $rawFiles = Get-ChildItem -LiteralPath $RawDir -Filter "*.info.json"
    $newCount = 0
    $dbPath = Ensure-ChannelDb -ChannelName $Prefix
    
    # On pre-verifie la base pour ne pas re-traiter ce qui y est deja
    $dbIds = [System.Collections.Generic.HashSet[string]]::new()
    $existing = Invoke-Sqlite -DbPath $dbPath -Query "SELECT youtube_id FROM videos;"
    if ($existing) { foreach ($row in $existing) { [void]$dbIds.Add($row.youtube_id.Trim()) } }

    Write-Host "  [DEBUG] $Prefix : $($rawFiles.Count) JSON trouves, $($dbIds.Count) en base." -ForegroundColor Cyan

    $results = $rawFiles | ForEach-Object {
        $json = $_
        
        $id = ""; if ($json.Name -match "\[([a-zA-Z0-9_-]{11})\]\.info\.json$") { $id = $Matches[1] }
        if (!$id) {
            try {
                $content = Get-SafeContent -Path $json.FullName -Raw $true
                if ($content -match '"id":\s*"([a-zA-Z0-9_-]{11})"') { $id = $Matches[1] }
            } catch {}
        }
        
        if (!$id) { Write-Host "    [DEBUG] ID non trouve pour $($json.Name)" -ForegroundColor Yellow; return $null }
        if ($dbIds.Contains($id)) { 
            if ($global:Settings.AutoClean) {
                $base = $json.Name -replace '\.info\.json$', ''
                Get-ChildItem -LiteralPath $RawDir | Where-Object { $_.Name.StartsWith($base) } | Remove-Item -Force -ErrorAction SilentlyContinue
            }
            return $null 
        }
        
        Write-Host "    [DEBUG] Traitement de ID: $id ($($json.Name))" -ForegroundColor Gray
        
        $subFile = $null
        # 1. Recherche par ID (robuste aux accents)
        $potentialSubs = Get-ChildItem -LiteralPath $RawDir -Filter "*$id*.srt"
        if (!$potentialSubs) { $potentialSubs = Get-ChildItem -LiteralPath $RawDir -Filter "*$id*.vtt" }
        
        # 2. Fallback : Correspondance stricte par nom de base (si pas d'ID dans le nom)
        if (!$potentialSubs) {
            $baseName = $json.Name -replace '\.info\.json$', ''
            $potentialSubs = Get-ChildItem -LiteralPath $RawDir -Filter "$baseName*.srt"
            if (!$potentialSubs) { $potentialSubs = Get-ChildItem -LiteralPath $RawDir -Filter "$baseName*.vtt" }
        }

        if ($potentialSubs) {
            # Priorite a la langue demandee
            $subFile = $potentialSubs | Where-Object { $_.Name -match "\.$Lang\.(srt|vtt)$" } | Select-Object -First 1 -ExpandProperty FullName
            if (!$subFile) { $subFile = $potentialSubs | Select-Object -First 1 -ExpandProperty FullName }
        }

        if ($subFile) {
            try {
                $content = Get-SafeContent -p $subFile
                $finalTxt = Get-CleanTranscript -content $content
                
                # Verification de qualite avant insertion
                if ($finalTxt -match "\?\?\?\?" -or $finalTxt -match "-->") {
                    Write-Host "    [!] Erreur fatale de nettoyage/encodage. Ingestion annulee pour cet ID." -ForegroundColor Red
                    return $null
                }
                
                if ($finalTxt.Trim().Length -gt 10) {
                    $jsonContent = Get-SafeContent -Path $json.FullName -Raw $true | ConvertFrom-Json
                    Write-Host "    [DEBUG] OK: $($jsonContent.title)" -ForegroundColor Green
                    return [PSCustomObject]@{
                        Id = $id
                        Title = $jsonContent.title
                        Date = $jsonContent.upload_date
                        Duration = [int]$jsonContent.duration
                        Views = [int]$jsonContent.view_count
                        Channel = $jsonContent.channel
                        Description = $jsonContent.description
                        Transcript = $finalTxt
                        FilesToDelete = @($json.FullName, $subFile)
                    }
                } else {
                    Write-Host "    [DEBUG] Transcript trop court ($($finalTxt.Length) chars)" -ForegroundColor Yellow
                }
            } catch {
                Write-Host "    [DEBUG] Erreur lecture: $($_.Exception.Message)" -ForegroundColor Red
            }
        } else {
            Write-Host "    [DEBUG] Aucun fichier sous-titre trouve pour $id" -ForegroundColor Yellow
        }
        return $null
    }
    
    # Insertion groupee en base
    $toInsert = $results | Where-Object { $_ -ne $null }
    Write-Host "  [DEBUG] Nombre d'objets a inserer : $($toInsert.Count)" -ForegroundColor Cyan
    if ($toInsert) {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("BEGIN TRANSACTION;")
        foreach ($res in $toInsert) {
            $eTitle = $res.Title -replace "'", "''"
            $eTranscript = $res.Transcript -replace "'", "''"
            $eDesc = $res.Description -replace "'", "''"
            $eChannel = $res.Channel -replace "'", "''"
            $sql = "INSERT OR REPLACE INTO videos (youtube_id, title, upload_date, duration, view_count, channel, description, transcript, status) " +
                   "VALUES ('$($res.Id)', '$eTitle', '$($res.Date)', $($res.Duration), $($res.Views), '$eChannel', '$eDesc', '$eTranscript', 'PROCESSED');"
            [void]$sb.AppendLine($sql)
            if ($global:Settings.AutoClean) { foreach ($f in $res.FilesToDelete) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
            $newCount++
        }
        [void]$sb.AppendLine("COMMIT;")
        Invoke-Sqlite -DbPath $dbPath -Query $sb.ToString()
    }
    return $newCount
}
                        
function Build-Packs {
    param ($DenseDir, $PacksDir, $Prefix, $LogPrefix, $GlobalPacksDir)
    
    if (!(Test-Path -LiteralPath $PacksDir)) { New-Item -ItemType Directory -Force -Path $PacksDir | Out-Null }
    
    $dbPath = Join-Path $global:DbDir "$($Prefix).db"
    if (!(Test-Path $dbPath)) { return 0 }

    Write-Host "  [DB] Generation des packs depuis la base de donnees..." -ForegroundColor Gray
    
    $query = "SELECT youtube_id, title, upload_date, duration, transcript FROM videos WHERE transcript IS NOT NULL AND transcript <> '' ORDER BY upload_date ASC;"
    $rawData = & $global:Sqlite -separator "|||" $dbPath $query
    
    $packsPlan = [System.Collections.Generic.List[PSObject]]::new()
    $currentBatch = [System.Collections.Generic.List[PSObject]]::new()
    $currentWords = 0
    $packNum = 1

    foreach ($line in $rawData) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "\|\|\|"
        if ($parts.Count -lt 5) { continue }
        
        $vId = $parts[0]; $vTitle = $parts[1]; $vDate = $parts[2]; $vDur = $parts[3]; $vTranscript = $parts[4]
        $wordCount = ($vTranscript -split "\s+" | Where-Object { $_ -ne "" }).Count
        
        if (($currentWords + $wordCount) -gt 500000 -and $currentBatch.Count -gt 0) {
            $packsPlan.Add([PSCustomObject]@{ ID = $packNum; Vids = $currentBatch.ToArray(); TotalWords = $currentWords; Start = $currentBatch[0].Date; End = $currentBatch[-1].Date })
            $packNum++; $currentBatch = [System.Collections.Generic.List[PSObject]]::new(); $currentWords = 0
        }
        $currentBatch.Add([PSCustomObject]@{ Id = $vId; Title = $vTitle; Date = $vDate; Duration = $vDur; Transcript = $vTranscript })
        $currentWords += $wordCount
    }
    if ($currentBatch.Count -gt 0) {
        $packsPlan.Add([PSCustomObject]@{ ID = $packNum; Vids = $currentBatch.ToArray(); TotalWords = $currentWords; Start = $currentBatch[0].Date; End = $currentBatch[-1].Date })
    }

    if (Test-Path $GlobalPacksDir) {
        Get-ChildItem -Path $GlobalPacksDir -Filter ($Prefix + "_*.txt") | Where-Object { $_.Name -match "^$Prefix(_ULTRA)?_\d{2}_\(" } | Remove-Item -Force -ErrorAction SilentlyContinue 
    }

    foreach ($plan in $packsPlan) {
        $sFmt = $plan.Start -replace '^(\d{4})(\d{2})(\d{2})$', '$1.$2.$3'
        $eFmt = $plan.End -replace '^(\d{4})(\d{2})(\d{2})$', '$1.$2.$3'
        if (!$sFmt) { $sFmt = "0000.00.00" }; if (!$eFmt) { $eFmt = "0000.00.00" }
        $pName = $Prefix + "_" + $plan.ID.ToString("00") + "_(" + $sFmt + "-au-" + $eFmt + ").txt"
        $pPath = Join-Path $PacksDir $pName
        $sb = New-Object System.Text.StringBuilder
        foreach ($v in $plan.Vids) {
            [void]$sb.AppendLine($v.Transcript)
            [void]$sb.AppendLine("`r`n################################### SOURCE: $($v.Title) [$($v.Id)] [DUR:$($v.Duration)] ###################################`r`n")
        }
        $sb.ToString() | Out-File -LiteralPath $pPath -Encoding utf8
        if ($GlobalPacksDir -and (Test-Path $GlobalPacksDir)) {
            Copy-Item -LiteralPath $pPath -Destination (Join-Path $GlobalPacksDir $pName) -Force -ErrorAction SilentlyContinue
        }
    }
    return $packsPlan.Count
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
                    # Utilisation de Get-SafeContent pour l'encodage robuste
                    $content = Get-SafeContent -Path $f.FullName -Raw $true
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
            $content = Get-SafeContent -Path $f.FullName -Raw $true
            # Detection de fuite JSON : si on trouve des cles JSON en dehors du bloc METADATA
            $textContent = if ($content -match "\[/METADATA.*?\](?:\r?\n){2}(.*)") { $Matches[1] } else { $content }
            
            $isDirty = $false
            $reason = ""
            if ($textContent -match '"formats":' -or $textContent -match '"url":' -or $textContent -match '"downloader_options":') {
                $isDirty = $true; $reason = "Fuite JSON"
            } elseif ($f.Name -match "\?\?\?\?" -or $textContent -match "\?\?\?\?" -or $textContent -match '-->|\b(align|position|size|line|vertical):') {
                $isDirty = $true; $reason = "Artifacts VTT (Timestamps/Align/Encoding)"
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
                    
                    # Purge de la base de donnees pour forcer le re-traitement par Process-LocalFiles
                    $dbPath = Ensure-ChannelDb -ChannelName $Prefix
                    Invoke-Sqlite -DbPath $dbPath -Query "DELETE FROM videos WHERE youtube_id = '$id';" | Out-Null
                    
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
    
    # 3. Verification de la base de donnees (Titres corrompus avec ????)
    $dbPath = Ensure-ChannelDb -ChannelName $Prefix
    if (Test-Path $dbPath) {
        $corruptedDb = Invoke-Sqlite -DbPath $dbPath -Query "SELECT youtube_id, title FROM videos WHERE title LIKE '%????%';"
        if ($corruptedDb) {
            foreach ($row in $corruptedDb) {
                $id = $row.youtube_id
                Write-Host "    [!] Titre corrompu (????) detecte dans la DB : $($row.title)" -ForegroundColor Red
                $corruptedCount++
                Invoke-Sqlite -DbPath $dbPath -Query "DELETE FROM videos WHERE youtube_id = '$id';" | Out-Null
                # Nettoyage des fichiers pour forcer re-traitement
                $derivedFiles = Get-ChildItem -Path $BaseDir -Recurse -File | Where-Object { $_.Name -match "\[$id\]" -and $_.Extension -eq ".txt" }
                foreach ($df in $derivedFiles) { Remove-Item -LiteralPath $df.FullName -Force -ErrorAction SilentlyContinue }
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
                $c = Get-SafeContent -Path $f.FullName -Raw $true
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
    return $deletedCount
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
    
    Write-Host "`n  ????  BILAN DES PACKS GENERES" -ForegroundColor Cyan
    Write-Host "  " + ("a??" * 60) -ForegroundColor Cyan
    Write-Host "  Pack Name".PadRight(34) + "Vids".PadLeft(5) + "Hours".PadLeft(8) + "Words".PadLeft(13) -ForegroundColor Gray
    
    $totalWords = 0; $totalVids = 0; $totalSecs = 0
    foreach ($p in $packs) {
        # Lecture securisee pour eviter les erreurs d'encodage et drive
        $content = Get-SafeContent -Path $p.FullName -Raw $true
        
        # Nombre de mots
        $words = ($content -split "\s+" | Where-Object { $_ -ne "" }).Count
        
        # Nombre de videos (on compte les marqueurs SOURCE:)
        $vids = ([regex]::Matches($content, "SOURCE:")).Count
        
        # Somme des durees (on extrait le champ DUR: des marqueurs SOURCE:)
        $secs = 0
        [regex]::Matches($content, '\[DUR:(\d+)\]') | ForEach-Object { $secs += [int]$_.Groups[1].Value }
        
        # Securite si l'ancien format est present ou si DUR: a echoue
        if ($secs -eq 0) {
            [regex]::Matches($content, '"duration":\s*(\d+)') | ForEach-Object { $secs += [int]$_.Groups[1].Value }
        }
        
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
    Write-Host "  " + ("a??" * 60) -ForegroundColor Cyan
    $totalHrs = $totalSecs / 3600
    Write-Host "  TOTAL : $($totalWords.ToString('N0')) mots | $($totalVids) videos | $($totalHrs.ToString('N1'))h dans $($packs.Count) packs." -ForegroundColor Gray
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
    $currentBL = Get-Content -LiteralPath $global:BlacklistPath
    
    if (!$SpecificChannelDir) {
        Write-Host "`n=================================================" -ForegroundColor Cyan
        Write-Host "   DIAGNOSTIC DE LANGUE ET FILTRAGE AUTO" -ForegroundColor Cyan
        Write-Host "=================================================" -ForegroundColor Cyan
        
        Write-Host "  Quelles videos analyser ?" -ForegroundColor White
        Write-Host "  1. Nouveaux IDs (missing_videos.txt, 429_errors.txt)"
        Write-Host "  2. Categorie specifique Blacklist (ex: [TO-REVIEW] ou [SUB-KO])"
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
    
    $finalList = @($idsToProcess)
    if ($finalList.Count -eq 0) { Write-Host "  [OK] Aucune video a? analyser." -ForegroundColor Gray; return }
    Write-Host "  [SYSTEME] Analyse de $($finalList.Count) videos en cours (Parallel)..." -ForegroundColor Gray
    
    $finalList | ForEach-Object {
        $id = $_
        $userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"
        $YtDlp = $YtDlp
        $BlacklistPath = $BlacklistPath
        
        try {
            $info = & $YtDlp --user-agent $userAgent --print "%(language)s|%(title)s" --no-warnings "https://www.youtube.com/watch?v=$id" 2>$null
            if ($info) {
                $parts = $info -split '\|'; $lang = $parts[0]; $title = $parts[1]
                if ($lang -and !($lang.StartsWith("fr") -or $lang.StartsWith("en"))) {
                    Write-Host "      [REJECT] $id ($lang) - $title" -ForegroundColor Red
                    "$id # [AUTO-LANG: $lang] $title" | Add-Content -LiteralPath $global:BlacklistPath -Encoding utf8
                }
            }
        } catch { }
    }
}

# ==============================================================================
# MODULE 3: RE-SUBTITLING WORKFLOW
# ==============================================================================

function Run-ReSubtitling {
    if (!(Test-Path -LiteralPath $YtDlp) -or !(Test-Path -LiteralPath $Ffmpeg)) {
        Write-Host "  [!] BINAIRES MANQUANTS : yt-dlp.exe ou ffmpeg.exe introuvables dans BIN." -ForegroundColor Red
        return
    }
    $startTime = Get-Date
    # Chemins dedies au Workflow de re-sous-titrage
    $AudioDir = Join-Path $BaseDir "_RE_SUBTITLING_WORK\1_AUDIO"
    $OutputDir = Join-Path $BaseDir "_RE_SUBTITLING_WORK\3_STATIC_VIDEOS"
    $ThumbDir = Join-Path $BaseDir "_RE_SUBTITLING_WORK\0_THUMBS"

    # S'assurer que les dossiers existent
    foreach ($dir in @($AudioDir, $OutputDir, $ThumbDir)) {
        if (!(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }

    Write-StepHeader -Title "WORKFLOW RE-SUBTITLING (1FPS)" -Emoji "????i??"
    
    Write-Host "  Utilisation d'un buffer local pour la blacklist..." -ForegroundColor Gray
    $localBuffer = Join-Path $env:TEMP "blacklist_industrial.tmp"
    Copy-Item -LiteralPath $BlacklistPath -Destination $localBuffer -Force
    $global:CurrentBlacklistPath = $localBuffer

    Write-Host "  Chargement de la blacklist... (Patientez)" -ForegroundColor Gray
    $blContent = Get-SafeContent $localBuffer
    
    Write-Host "  Quelles videos re-sous-titrer ?" -ForegroundColor White
    Write-Host "  a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??" -ForegroundColor Gray
    Write-Host "  1. [SUB-MISSING] uniquement (Absence de ST)"
    Write-Host "  2. [SUB-KO]      uniquement (Mauvaise langue)"
    Write-Host "  3. [TO-REVIEW]    uniquement (Videos a? valeur ajoutee)"
    Write-Host "  4. [FORCE]        uniquement (Fora?age manuel)"
    Write-Host "  5. [MANUAL-SKIP]  uniquement (Videos ignorees)"
    Write-Host "  6. ???? TOUT (Missing + KO + TO-REVIEW + FORCE + SKIP)"
    Write-Host "  7. a??i?? Manuel (Saisir un ID)"
    Write-Host "  a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??" -ForegroundColor Gray
    $resubChoice = Read-Host "`n  Votre choix (1-7)"
    
    $filter = switch ($resubChoice) {
        "1" { "\[SUB-MISSING\]" }
        "2" { "\[SUB-KO\]" }
        "3" { "\[TO-REVIEW\]" }
        "4" { "\[FORCE\]" }
        "5" { "\[MANUAL-SKIP\]" }
        "6" { "Aucun sous-titre|no subtitles|\[SUB-MISSING\]|\[SUB-KO\]|\[TO-REVIEW\]|\[FORCE|\[MANUAL-SKIP" }
        "7" { "MANUAL" }
        default { return }
    }

    Write-Host "  Analyse des entrees... (Patientez)" -ForegroundColor Gray
    $idsToProcess = [System.Collections.Generic.List[PSObject]]::new()
    if ($filter -eq "MANUAL") {
        $manualId = Read-Host "  Saisir l'ID YouTube"
        if ($manualId -match "^[a-zA-Z0-9_-]{11}$") { $idsToProcess.Add([PSCustomObject]@{ ID = $manualId; Title = "Saisie manuelle" }) } else { return }
    } else {
        foreach ($line in $blContent) {
            if ($line -match $filter -and $line -notmatch "\[RE-SUB-VIDEO\]|\[INACCESSIBLE") {
                if ($line -match "^([a-zA-Z0-9_-]{11})") {
                    $id = $Matches[1]
                    $title = if ($line -match "#\s*(.*)") { $Matches[1].Trim() } else { "Sans titre" }
                    # Nettoyage du titre pour enlever les tags a la fin si besoin, mais on va tout garder pour l'instant
                    $idsToProcess.Add([PSCustomObject]@{ ID = $id; Title = $title })
                }
            }
        }
    }
    
    if ($idsToProcess.Count -eq 0) { Write-Log "Aucune video correspondant aux criteres." "Green"; return }

    # Ajout d'une limite optionnelle pour eviter de saturer le systeme
    Write-Host "  $($idsToProcess.Count) videos detectees." -ForegroundColor Yellow
    Write-Host "  Combien de videos traiter dans cette session ? (Entree pour TOUT)" -ForegroundColor White
    $limit = Read-Host "  Limite"
    if ($limit -as [int]) { 
        $limitVal = [int]$limit
        if ($limitVal -gt 0 -and $limitVal -lt $idsToProcess.Count) {
            $idsToProcess = $idsToProcess.GetRange(0, $limitVal)
        }
    }

    $finalIds = @($idsToProcess)
    if ($finalIds.Count -eq 0) { Write-Log "Aucun ID final a traiter." "Yellow"; return }

    Write-Host "`n  [DEMARRAGE] Traitement de $($finalIds.Count) videos..." -ForegroundColor Cyan
    Write-Host "  Dossier Audio : $AudioDir" -ForegroundColor Gray
    Write-Host "  Dossier Video : $OutputDir" -ForegroundColor Gray
    
    $success = 0; $failed = 0; $idx = 0; $batchIdx = 0
    
    # Buffer pour la liste d'upload (a_uploader.txt)
    $toUpload = [System.Collections.Generic.List[string]]::new()
    $uploadFile = Join-Path $BaseDir "a_uploader.txt"
    if (Test-Path $uploadFile) { $toUpload.AddRange((Get-SafeContent $uploadFile)) }

    # Dossier de travail local pour eviter les erreurs de buffer Drive
    $localWork = Join-Path $env:TEMP "Industrial_Work_Local"
    if (!(Test-Path $localWork)) { New-Item -ItemType Directory -Path $localWork -Force | Out-Null }

    $processedIds = [System.Collections.Generic.List[string]]::new()

    for ($i=0; $i -lt $finalIds.Count; $i++) {
        $item = $finalIds[$i]
        $id = $item.ID; $title = $item.Title
        $idx = $i + 1; $batchIdx = $idx
        $prefix = "  [$idx/$($finalIds.Count)]"
        
        try {
            $audioPath = Join-Path $AudioDir "$id.m4a"
            $videoPath = Join-Path $OutputDir "$id.mp4"
            $tmpAudio = Join-Path $localWork "$id.m4a"
            $tmpVideo = Join-Path $localWork "$id.mp4"
            
            # Securite Reprise : Si le MP4 existe deja, on considere comme traite
            if (Test-Path -LiteralPath $videoPath) {
                Write-Host "$prefix a?? SKIP : $title [$id]" -ForegroundColor Green
                $processedIds.Add($id)
                if ($id -notmatch "MANUAL" -and $id -notin $toUpload) { $toUpload.Add($id) }
                $success++; continue
            }

            Write-Host "$prefix ????i?? PROCESS : $title [$id]" -ForegroundColor Cyan
        
            # 1. Recuperation Audio (Local)
            if (Test-Path -LiteralPath $audioPath) {
                Copy-Item -LiteralPath $audioPath -Destination $tmpAudio -Force
            } else {
                & $YtDlp --user-agent $userAgent --quiet --no-warnings -f "bestaudio[ext=m4a]/bestaudio" -o $tmpAudio "https://www.youtube.com/watch?v=$id"
                if (Test-Path -LiteralPath $tmpAudio) { Copy-Item -LiteralPath $tmpAudio -Destination $audioPath -Force }
            }
            
            # 2. Video 1fps (Local)
            if (Test-Path -LiteralPath $tmpAudio) {
                & $YtDlp --user-agent $userAgent --quiet --no-warnings --write-thumbnail --skip-download -o (Join-Path $localWork $id) "https://www.youtube.com/watch?v=$id"
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
                Write-Host "      [!] ECHEC : La video n'a pas pu a?tre generee pour $id" -ForegroundColor Yellow
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
    
    $dur = Get-DurationStr $startTime
    Write-Host "`n  [OK] Blacklist mise a? jour (videos traitees supprimees)." -ForegroundColor Green
    Write-Host "  [OK] Liste d'upload mise a? jour : $($finalToUpload.Count) videos pra?tes dans a_uploader.txt ($dur)" -ForegroundColor Cyan
}

# ==============================================================================
# MODULE 4: INVENTAIRE ET TABLEAU DE BORD GLOBAL
# ==============================================================================

function Export-MasterInventory {
    $startTime = Get-Date
    $exportPath = Join-Path $BaseDir "MASTER_INVENTORY_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"
    Write-Host "`n[SYSTEME] Generation de l'inventaire global... (Patientez)" -ForegroundColor Cyan
    
    $channels = Import-Csv $ConfigPath -Delimiter ";"
    $totalChans = $channels.Count
    
    # Charger la blacklist une seule fois
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

    Write-Host "`n  Traitement parallelise de $totalChans chaa?nes..." -ForegroundColor White
    
    # Utilisation du parallelisme pour scanner les dossiers (Lecture intensive)
    $inventory = $channels | ForEach-Object {
        $chan = $_
        $BaseDir = $BaseDir
        $blMap = $blMap
        $logPrefix = $chan.Prefixe
        $channelResults = [System.Collections.Generic.List[PSObject]]::new()
        
        # Logique de dossier (copie locale car $using ne supporte pas tout)
        $folderCandidates = @(
            $chan.Prefixe.Trim(),
            ($chan.Prefixe -replace "[^a-zA-Z0-9 ]", "").Trim(),
            ($chan.Prefixe -replace "[^a-zA-Z0-9]", "_").Trim(),
            ($chan.Prefixe -replace "\s+", "_").Trim()
        ) | Select-Object -Unique
        
        $cDir = $null
        foreach ($f in $folderCandidates) {
            $path = Join-Path $BaseDir $f
            if (Test-Path -LiteralPath $path) { $cDir = $path; break }
        }

        if (!$cDir) { return $null }
        
        # Scan local du dossier
        $masterPath = Join-Path $cDir "youtube_master_list.txt"
        $missingPath = Join-Path $cDir "missing_videos.txt"
        $rawPath = Join-Path $cDir "1_RAW"
        $densePath = Join-Path $cDir "3_TXT_dense"
        $p4 = Join-Path $cDir "4_Packs"
        
        if (!(Test-Path $masterPath)) { return $null }
        $masterIds = Get-Content -LiteralPath $masterPath -ErrorAction SilentlyContinue
        
        $missingIds = @{}
        if (Test-Path $missingPath) {
            foreach ($mId in (Get-Content -LiteralPath $missingPath)) { if ($mId.Trim()) { $missingIds[$mId.Trim()] = $true } }
        }
        
        $denseFiles = @{}
        if (Test-Path $densePath) {
            Get-ChildItem -Path $densePath -Filter "*.txt" | ForEach-Object {
                if ($_.Name -match "\[([a-zA-Z0-9_-]{11})\]") { $denseFiles[$Matches[1]] = $_.FullName }
            }
        }

        $rawFiles = @{}
        if (Test-Path $rawPath) {
            Get-ChildItem -Path $rawPath -Filter "*.info.json" | ForEach-Object {
                if ($_.Name -match "\[([a-zA-Z0-9_-]{11})\]") { $rawFiles[$Matches[1]] = $_.FullName }
            }
        }

        $packMap = @{}
        if (Test-Path $p4) {
            Get-ChildItem -Path $p4 -Filter "*.txt" | ForEach-Object {
                $pName = $_.BaseName
                $pContent = (Get-Content -LiteralPath $_.FullName -ErrorAction SilentlyContinue) -join "`n"
                $matches = [regex]::Matches($pContent, "\[([a-zA-Z0-9_-]{11})\]")
                foreach ($m in $matches) { $packMap[$m.Groups[1].Value] = $pName }
            }
        }

        foreach ($id in $masterIds) {
            $id = $id.Trim(); if ([string]::IsNullOrWhiteSpace($id)) { continue }
            $status = "DETECTED (ON YT)"; $reason = ""; $wordCount = 0; $title = ""; $date = ""; $duration = ""; $lang = ""
            
            if ($rawFiles.ContainsKey($id)) {
                $fPath = $rawFiles[$id]; $fName = [System.IO.Path]::GetFileNameWithoutExtension($fPath)
                if ($fName -match "^(\d{8})\s*-\s*(.*)\s+\[$id\]") { $date = $Matches[1]; $title = $Matches[2] }
                elseif ($fName -match "^(.*)\s+\[$id\]") { $title = $Matches[1] }
                
                try {
                    $jsonSample = (Get-Content -LiteralPath $fPath -TotalCount 20) -join ""
                    if ($jsonSample -match '"duration":\s*(\d+)') { $duration = $Matches[1] }
                    if ($jsonSample -match '"language":\s*"(.*?)"') { $lang = $Matches[1] }
                } catch {}
            }

            if ($blMap.ContainsKey($id)) { $status = "BLACKLISTED"; $reason = $blMap[$id] }
            elseif ($denseFiles.ContainsKey($id)) {
                $status = "SUCCESS (DENSE)"
                try {
                    $content = (Get-Content -LiteralPath $denseFiles[$id] -TotalCount 5) -join ""
                    if ($content -match "TITLE: (.*)") { $title = $Matches[1].Trim() }
                } catch { }
            } elseif ($rawFiles.ContainsKey($id)) { $status = "DOWNLOADED (RAW ONLY)" }
            elseif ($missingIds.ContainsKey($id)) { $status = "FAILED/PENDING" }

            $channelResults.Add([PSCustomObject]@{
                Channel  = $logPrefix
                Date     = $date
                Title    = $title
                Duration = $duration
                Lang     = $lang
                VideoID  = $id
                Status   = $status
                Reason   = $reason
                Pack     = if ($packMap.ContainsKey($id)) { $packMap[$id] } else { "" }
            })
        }
        Write-Host "." -NoNewline # Progress dot
        return $channelResults
    }

    # Compilation des resultats
    $finalInventory = @()
    foreach ($res in $inventory) { if ($null -ne $res) { $finalInventory += $res } }

    if ($finalInventory.Count -gt 0) {
        $finalInventory | Export-Csv -Path $exportPath -NoTypeInformation -Delimiter "," -Encoding utf8
        $dur = Get-DurationStr $startTime
        Write-Host "`n`n[SUCCES] Inventaire genere : $exportPath" -ForegroundColor Green
        Write-Host "Nombre total d'entrees : $($finalInventory.Count) | Temps : $dur" -ForegroundColor White
    } else {
        Write-Host "`n[!] Aucune donnee trouvee pour l'inventaire." -ForegroundColor Red
    }
}

while ($true) {
    try { Clear-Host } catch {}
    Write-Header -Title "INDUSTRIAL PIPELINE v14.0.0 UNIFIED"
    Write-Host "  1. [M] Ajouter et traiter une chaine (manuel)"
    Write-Host "  2. [A] Rafraichir toutes les chaines (auto)"
    Write-Host "  3. [R] Retenter uniquement les echecs (rapide)"
    Write-Host "  4. [L] Lancer le diagnostic de langue (filtrage)"
    Write-Host "  5. [S] Lancer le workflow de re-sous-titrage (1 fps)"
    Write-Host "  6. [T] Maintenance globale (nettoyage + diagnostic)"
    Write-Host "  7. [I] Generer l'inventaire global (fichier CSV)"
    Write-Host "  8. [P] Parametres (cookies, delais, etc.)"
    Write-Host "  0. [Q] Quitter"
    Write-Host ("=" * 80) -ForegroundColor Cyan
    
    if ($ChannelName) {
        Write-Host ">>>> MODE DIRECT : Traitement de la chaine '$ChannelName'" -ForegroundColor Green
        $choice = "2" 
    } elseif ($AutoLoop) {
        $choice = "2"
    } elseif ($Action -eq "RefreshAll") {
        Write-Host ">>>> ACTION : Rafraichissement de toutes les chaines" -ForegroundColor Green
        $choice = "2"
    } else {
        $choice = ""
        while ($choice -notmatch "^[0-8]$") {
            Write-Host "  Votre choix: " -NoNewline -ForegroundColor Cyan
            $choice = Read-Host
            if ($choice -notmatch "^[0-8]$") { Write-Host "  [!] Choix invalide." -ForegroundColor Red }
        }
    }

    if ($choice -eq "0") { break }
    
    # Configuration Load
    $channels = Import-Csv $ConfigPath -Delimiter ";"
    
    if ($choice -eq "8") {
        try { Clear-Host } catch {}
        Write-Host "  a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??" -ForegroundColor Cyan
        Write-Host "  a??           PARAMETRES DU PIPELINE             a??" -ForegroundColor White
        Write-Host "  a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??" -ForegroundColor Cyan
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
        Write-Host "  [DEBUG] $ConfigPath : $($channels.Count) chaines chargees." -ForegroundColor Cyan
        if ($channels.Count -gt 0) {
            $sample = $channels[0..4] | ForEach-Object { $_.Prefixe }
            Write-Host "  [DEBUG] Echantillon Prefixes : $($sample -join ', ')" -ForegroundColor Gray
        }
        if ($choice -eq "1") { 
            $url = ""; while ($url -notmatch "youtube\.com") { $url = Read-Host "  URL de la chaine"; if ($url -notmatch "youtube\.com") { Write-Host "  [!] URL invalide." -ForegroundColor Red } }
            Write-Host "  [SYSTEME] Recuperation du nom de la chaine..." -ForegroundColor Gray
            $suggested = Get-YouTubeName $url
            $pref = Read-Host "  Prefixe (Tag) [$suggested]"
            if ($pref -eq "") { $pref = $suggested }
            if ($pref -eq "") { $pref = "NewChannel" }
            $lang = Read-Host "  Langue (fr, en, ou auto) [auto]"
            if ($lang -eq "") { $lang = "auto" }
            $newChan = [PSCustomObject]@{ URL=$url; Prefixe=$pref; Lang=$lang }
            # Sauvegarde immediate dans le CSV pour eviter les incoherences
            if (!($channels | Where-Object { $_.URL -eq $url -or $_.Prefixe -eq $pref })) {
                $newChan | Export-Csv $ConfigPath -Delimiter ";" -Append -NoTypeInformation -Force
                $channels = Import-Csv $ConfigPath -Delimiter ";" # Rechargement
            }
            $targets = @($newChan)
        } else { 
            if ($ChannelName) {
                Write-Host "  [DEBUG] Debut du filtrage manuel..." -ForegroundColor Gray
                $t = [System.Collections.Generic.List[PSObject]]::new()
                foreach ($c in $channels) {
                    if ($c.Prefixe.Trim() -eq $ChannelName.Trim()) {
                        $t.Add($c)
                    }
                }
                $targets = $t.ToArray()
                Write-Host "  [DEBUG] Filtrage sur '$ChannelName' : $($targets.Count) trouve." -ForegroundColor Cyan
            } else {
                $targets = $channels 
            }
        }

        # 1. Nettoyage GLOBAL des verrous morts
        $startTime = Get-Date
        Write-Host "`n[SYSTEME] Audit des verrous de securite..." -ForegroundColor Gray
        foreach ($c in $channels) {
            $lock = Join-Path (Join-Path $BaseDir $c.Prefixe) "process.lock"
            if (Test-Path $lock) {
                $pidVal = Get-Content $lock -ErrorAction SilentlyContinue
                if ($pidVal -and ($pidVal -ne $PID)) {
                    $p = Get-Process -Id $pidVal -ErrorAction SilentlyContinue
                    if (!$p -or ($p.Name -notmatch "pwsh|powershell")) {
                        if (Test-Path -LiteralPath $lock) {
                            Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
                        }
                        Write-Host "  ???? Verrou libere pour $($c.Prefixe)" -ForegroundColor Yellow
                    }
                }
            }
        }

        # Cleanup packs (uniquement en mode Refresh complet ou Maintenance)
        if ($choice -ne "1") {
            $validPrefixes = $channels | ForEach-Object { $_.Prefixe }
            Clean-GlobalPacks -GlobalPacksDir $AllPacksDir -ValidPrefixes $validPrefixes | Out-Null
        }
        
        $ReverseAll = $false
        if ($choice -eq "2") {
            if ($AutoLoop -or $ChannelName) {
                if ($ReverseAll -eq "y") { $ReverseAll = $true } else { $ReverseAll = $false }
            } else {
                $revQ = Read-Host "  Voulez-vous synchroniser en partant de la FIN de la playlist ? (y/N)"
                if ($revQ -eq "y") { $ReverseAll = $true; Write-Host "  [MODE] Synchronisation INVERSEE activee." -ForegroundColor Yellow }
            }
        }

        # Boucle de traitement principale
        Write-Host "  [DEBUG] Entree dans la boucle principale avec $($targets.Count) cibles." -ForegroundColor Cyan
        # --- MODE PARALLELE ---
        $functionNames = @("Sync-YouTube", "Process-LocalFiles", "Build-Packs", "Invoke-Sqlite", "Write-Log", "Ensure-ChannelDb", "Get-SafeContent", "Get-CleanTranscript", "Get-ChannelLock", "Get-YouTubeName", "Write-Log", "Write-StepHeader", "Write-SubStep", "Get-DurationStr")
        $scriptFunctions = @{}
        foreach ($f in $functionNames) { if (Get-Command $f -ErrorAction SilentlyContinue) { $scriptFunctions[$f] = (Get-Command $f).Definition } }

        $skippedChannels = [System.Collections.Generic.List[string]]::new()
        
        # Local copies for thread safety
        $locSqlite = $global:Sqlite
        $locYtDlp = $global:YtDlp
        $locFfmpeg = $global:Ffmpeg
        $locDbDir = $global:DbDir
        $locConfigPath = $global:ConfigPath
        $locBlacklistPath = $global:BlacklistPath
        $locAllPacksDir = $global:AllPacksDir
        $locLogsDir = $global:LogsDir
        $locReSubDir = $global:ReSubDir

        $targets | ForEach-Object -Parallel {
            $chan = $_
            $allT = $using:targets
            $sIdx = [array]::IndexOf($allT, $chan)
            
            # Staggered start (décalage aléatoire de 5 à 10s par thread)
            if ($sIdx -gt 0) { 
                $delay = Get-Random -Minimum 5 -Maximum 11
                Start-Sleep -Seconds $delay 
            }

            $funcs = $using:scriptFunctions
            $modeVal = $using:mode
            $sChannels = $using:skippedChannels
            
            # Re-importation des fonctions
            foreach ($fName in $funcs.Keys) {
                $def = $funcs[$fName]
                New-Item -Path "function:global:$fName" -Value ([scriptblock]::Create($def)) -Force | Out-Null
            }
            
            # Re-importation du contexte global
            $global:BaseDir = $using:BaseDir
            $global:YtDlp = $using:locYtDlp
            $global:Ffmpeg = $using:locFfmpeg
            $global:Sqlite = $using:locSqlite
            $global:Settings = $using:Settings
            $global:userAgent = $using:userAgent
            $global:useCookies = $using:useCookies
            $global:BlacklistPath = $using:locBlacklistPath
            $global:LogsDir = $using:locLogsDir
            $global:ConfigPath = $using:locConfigPath
            $global:DbDir = $using:locDbDir
            $global:AllPacksDir = $using:locAllPacksDir
            $global:ReSubDir = $using:locReSubDir
            
            $folder = $chan.Prefixe 
            $cDir = Join-Path $global:BaseDir $folder
            if (!(Test-Path -LiteralPath $cDir)) { New-Item -ItemType Directory -Force -Path $cDir | Out-Null }
            
            if (!(Get-ChannelLock $cDir)) {
                Write-Host "  [!] [BUSY] Skip (en cours ailleurs) : $($chan.Prefixe)" -ForegroundColor Yellow
                $sChannels.Add($chan.Prefixe)
                return
            }
            
            try {
                Write-Host "`n[PARALLEL] >>> SYNC : $($chan.Prefixe) <<<" -ForegroundColor Cyan
                
                # Securite URL (casse variable dans le CSV)
                $targetUrl = $chan.URL
                if (!$targetUrl) { $targetUrl = $chan.Url }
                if (!$targetUrl) { $targetUrl = $chan.url }
                
                if (!$targetUrl) {
                    Write-Host "  [ERREUR] URL manquante pour $($chan.Prefixe). Verifiez channels_config.csv." -ForegroundColor Red
                    return
                }

                $p1 = Join-Path $cDir "1_RAW"; $p2 = Join-Path $cDir "2_TXT"; $p3 = Join-Path $cDir "3_TXT_dense"; $p4 = Join-Path $cDir "4_Packs"
                foreach ($p in @($p1,$p2,$p3,$p4)) { if (!(Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null } }

                $syncResult = Sync-YouTube -Url $targetUrl -LogPrefix $chan.Prefixe -Lang $chan.Langue -RetryOnly ($modeVal -eq "3") -Reverse $using:ReverseAll
                
                $newTxt = Process-LocalFiles -RawDir $p1 -TxtDir $p2 -DenseDir $p3 -Lang $chan.Langue -Prefix $chan.Prefixe
                $null = Build-Packs -DenseDir $p3 -PacksDir $p4 -Prefix $chan.Prefixe -LogPrefix $chan.Prefixe -GlobalPacksDir $global:AllPacksDir
                
                $statusIcon = if ($syncResult.Missing -eq 0) { "[OK]" } else { "[...]" }
                Write-Host "`n  $statusIcon BILAN [$($chan.Prefixe)] : " -NoNewline -ForegroundColor Green
                Write-Host "Playlist: $($syncResult.Playlist) " -NoNewline -ForegroundColor White
                Write-Host "| Local: $($syncResult.Local) " -NoNewline -ForegroundColor Green
                Write-Host "| Blacklist: $($syncResult.Ignored) " -NoNewline -ForegroundColor Gray
                
                $missColor = if ($syncResult.Missing -gt 0) { "Yellow" } else { "Gray" }
                Write-Host "| Manquantes: $($syncResult.Missing)" -ForegroundColor $missColor

            } catch {
                Write-Host "  [ERREUR] $($chan.Prefixe) : $($_.Exception.Message)" -ForegroundColor Red
            } finally {
                $lockFile = Join-Path $cDir "process.lock"
                if (Test-Path -LiteralPath $lockFile) { Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue }
            }
        } -ThrottleLimit 8

        if ($skippedChannels.Count -gt 0) {
            Write-Host "`n  [!] $($skippedChannels.Count) chaine(s) verouillee(s) ont ete sautees." -ForegroundColor Yellow
        }
        $durationStr = Get-DurationStr $startTime
        Write-Host "`n[FIN] Traitement termine en $durationStr" -ForegroundColor Cyan
            
        if ($AutoLoop) {
            Write-Host "`n  [AUTO] Mise a jour du Dashboard et Rapport de sante..." -ForegroundColor Cyan
            & pwsh -File Audit-DataHealth.ps1 | Out-Null
            & pwsh -File Sync-Dashboard.ps1 | Out-Null
            Write-Host "  [AUTO] Attente de 30 minutes avant le prochain cycle..." -ForegroundColor Gray
            Start-Sleep -Seconds 1800
            continue
        }
            
        if ($Action) { break } # Quitter si on est en mode ligne de commande simple
        $null = [Console]::ReadKey()
    }
    elseif ($choice -eq "4") {
        $startTime = Get-Date
        Run-LanguageDiagnostic
        Write-Host "`n[SUCCES] Diagnostic de langue termine ($(Get-DurationStr $startTime))." -ForegroundColor Green
    }
    elseif ($choice -eq "5") { Run-ReSubtitling }
    elseif ($choice -eq "6") {
        $startTime = Get-Date
        Write-Host "  a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??" -ForegroundColor Cyan
        Write-Host "  a??             Maintenance globale du pipeline              a??" -ForegroundColor White
        Write-Host "  a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??a??" -ForegroundColor Cyan
        
        $mMode = Read-Host "`n  Mode de travail : (1) TOUTES les chaa?nes | (2) Une chaa?ne specifique [Defaut: 1]"
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

        $steps = @("Migration", "Integrite", "Doublons", "Packs", "Langues", "ManualSkip", "Verification")
        $totalSteps = $steps.Count

        $doMigration = (Read-Host "  [1/$totalSteps] Lancer la migration ? [O/N] (Defaut: N)").ToUpper() -eq "O"
        $doIntegrity = (Read-Host "  [2/$totalSteps] Lancer le diagnostic d'integrite ? [O/N] (Defaut: O)").ToUpper() -ne "N"
        $doDoublons  = (Read-Host "  [3/$totalSteps] Lancer le nettoyage des doublons ? [O/N] (Defaut: O)").ToUpper() -ne "N"
        $doPacks     = (Read-Host "  [4/$totalSteps] Lancer la reconstruction des packs ? [O/N] (Defaut: O)").ToUpper() -ne "N"
        $doLangues   = (Read-Host "  [5/$totalSteps] Lancer le filtrage des langues ? [O/N] (Defaut: N)").ToUpper() -eq "O"
        $doManual    = (Read-Host "  [6/$totalSteps] Debloquer les [MANUAL-SKIP] ? [O/N] (Defaut: N)").ToUpper() -eq "O"
        $doReview    = (Read-Host "  [7/$totalSteps] Lancer la verification finale des packs ? [O/N] (Defaut: O)").ToUpper() -ne "N"

        # Etape 1: Migration
        if ($doMigration) {
            Write-StepHeader -Title "Migration et Nomenclature" -StepNum 1 -TotalSteps $totalSteps -Emoji "[M]"
            $migrated = Maintenance-Migration -channels $channels
            if ($migrated) { $channels = Import-Csv $ConfigPath -Delimiter ";" }
        }
        
        # Etape 2: Diagnostic d'Integrite
        if ($doIntegrity) {
            Write-StepHeader -Title "Diagnostic d'Integrite" -StepNum 2 -TotalSteps $totalSteps -Emoji "[D]"
            $cIdx = 0; $cTotal = $channels.Count
            foreach ($c in $channels) {
                $cIdx++
                $folder = $c.Prefixe; $cDir = Join-Path $BaseDir $folder
                if (Test-Path -LiteralPath $cDir) {
                    Write-SubStep -Title "Analyse : $($c.Prefixe)" -StepNum $cIdx -TotalSteps $cTotal -Emoji "????"
                    $diag = Repair-Packs -BaseDir $cDir -Prefix $c.Prefixe
                    if ($diag.NeedDownload) {
                        Write-Host "      [AUTO-HEAL] Re-telechargement..." -ForegroundColor Cyan
                        $p1 = Join-Path $cDir "1_RAW"
                        $null = Sync-YouTube -Url $c.URL -LogPrefix $c.Prefixe -Lang $c.Langue -RetryOnly $true
                    }
                }
            }
        }

        # Etape 3: Nettoyage des Doublons
        if ($doDoublons) {
            Write-StepHeader -Title "Nettoyage des Doublons" -StepNum 3 -TotalSteps $totalSteps -Emoji "[X]"
            $cIdx = 0; $cTotal = $channels.Count
            foreach ($c in $channels) {
                $cIdx++
                $folder = $c.Prefixe; $cDir = Join-Path $BaseDir $folder
                if (Test-Path -LiteralPath $cDir) {
                    $count = Maintenance-Doublons -chanDir $cDir -prefix $c.Prefixe
                    $status = if ($count -gt 0) { "NETTOYa? ($count)" } else { "OK (Aucun)" }
                    Write-SubStep -Title "Analyse : $($c.Prefixe)" -StepNum $cIdx -TotalSteps $cTotal -Emoji "????" -Status $status
                }
            }
        }
        
        # Etape 4: Reconstruction des Packs
        if ($doPacks) {
            Write-StepHeader -Title "Reconstruction des Packs" -StepNum 4 -TotalSteps $totalSteps -Emoji "[P]"
            $cIdx = 0; $cTotal = $channels.Count
            foreach ($c in $channels) {
                $cIdx++
                $folder = $c.Prefixe; $cDir = Join-Path $BaseDir $folder
                if (Test-Path -LiteralPath $cDir) {
                    $p1 = Join-Path $cDir "1_RAW"; $p2 = Join-Path $cDir "2_TXT"; $p3 = Join-Path $cDir "3_TXT_dense"; $p4 = Join-Path $cDir "4_Packs"
                    $null = Process-LocalFiles -RawDir $p1 -TxtDir $p2 -DenseDir $p3 -Lang $c.Langue -Prefix $c.Prefixe
                    $packCount = Build-Packs -DenseDir $p3 -PacksDir $p4 -Prefix $c.Prefixe -LogPrefix $c.Prefixe -GlobalPacksDir $AllPacksDir
                    Write-SubStep -Title "Analyse : $($c.Prefixe)" -StepNum $cIdx -TotalSteps $cTotal -Emoji "????" -Status "OK ($packCount packs)"
                }
            }
        }

        # Etape 5: Diagnostic de Langue
        if ($doLangues) {
            Write-StepHeader -Title "Filtrage des Langues" -StepNum 5 -TotalSteps $totalSteps -Emoji "[L]"
            $cIdx = 0; $cTotal = $channels.Count
            foreach ($c in $channels) {
                $cIdx++
                $folder = $c.Prefixe; $cDir = Join-Path $BaseDir $folder
                if (Test-Path -LiteralPath $cDir) {
                    Write-SubStep -Title "Analyse : $($c.Prefixe)" -StepNum $cIdx -TotalSteps $cTotal -Emoji "????"
                    Run-LanguageDiagnostic -SpecificChannelDir $cDir
                }
            }
        }
        
        # Etape 6: Deblocage ManualSkip
        if ($doManual) {
            Write-StepHeader -Title "Deblocage [MANUAL-SKIP]" -StepNum 6 -TotalSteps $totalSteps -Emoji "[U]"
            if (Test-Path $BlacklistPath) {
                $bl = Get-Content $BlacklistPath
                $toRemove = $bl | Where-Object { $_ -match "\[MANUAL-SKIP\]" }
                if ($toRemove.Count -gt 0) {
                    Write-Host "  [!] $($toRemove.Count) videos Manual-Skip detectees." -ForegroundColor Yellow
                    foreach ($line in $toRemove) { Write-Host "      > $line" -ForegroundColor Gray }
                    $newBL = $bl | Where-Object { $_ -notmatch "\[MANUAL-SKIP\]" }
                    $newBL | Out-File $BlacklistPath -Encoding utf8
                    Write-Host "  [OK] $($toRemove.Count) videos debloquees de la blacklist." -ForegroundColor Green
                } else {
                    Write-Host "  [OK] Aucune video [MANUAL-SKIP] trouvee." -ForegroundColor Gray
                }
            }
        }
        
        # Etape 7: Verification Finale
        if ($doReview) {
            Write-StepHeader -Title "Bilan et Verification des Packs" -StepNum 7 -TotalSteps $totalSteps -Emoji "[B]"
            Review-GlobalPacks -GlobalPacksDir $AllPacksDir
        }

        $dur = Get-DurationStr $startTime
        Write-Host "`n  [SUCCES] Maintenance Terminee ($dur)." -ForegroundColor Green
    }
    elseif ($choice -eq "7") { Export-MasterInventory }
    
    if ($choice -ne "0") {
        if ($ChannelName) { exit }
        if (!($ChannelName -or $Action)) {
            Write-Host "`nAppuyez sur une touche pour continuer..."
            $null = [Console]::ReadKey()
        } else {
            break
        }
    }
}
