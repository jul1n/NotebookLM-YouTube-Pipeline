# PIPELINE DE CONNAISSANCES v9.5 - MULTI-CHAINES & BATCH PROCESSING
# ==============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8

Clear-Host
$globalLog = Join-Path $PSScriptRoot "pipeline_operations.log"
if (Test-Path $globalLog) { Remove-Item $globalLog -Force }

function Write-Log($msg, $color = "White", $prefix = "") {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $p = if ($prefix) { "[$prefix] " } else { "" }
    "[$timestamp] $p$msg" | Add-Content -LiteralPath $globalLog
    Write-Host "[$timestamp] $p$msg" -ForegroundColor $color
}

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "      PIPELINE DE CONNAISSANCES v9.5" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "`n"

$binPath = Join-Path $PSScriptRoot "BIN"
$ytDlp = Join-Path $binPath "yt-dlp.exe"
$ffmpegPath = Join-Path $binPath "ffmpeg.exe"
$userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
$allPacksDir = Join-Path $PSScriptRoot "ALL_PACKS"
if (!(Test-Path $allPacksDir)) { New-Item -ItemType Directory -Force -Path $allPacksDir | Out-Null }

$configFile = Join-Path $PSScriptRoot "channels_config.csv"
if (!(Test-Path $configFile)) {
    "URL;Prefixe;Langue" | Out-File -LiteralPath $configFile -Encoding utf8
}

$blacklistCandidates = [System.Collections.Generic.List[PSObject]]::new()
$threadLimit = 16 # Cible pour l'Intel Core Ultra 7

# 1. MENU PRINCIPAL
Write-Host "MENU PRINCIPAL" -ForegroundColor Yellow
Write-Host "1. Ajouter et traiter une nouvelle chaine (Mode Manuel)"
Write-Host "2. Rafraichir toutes les chaines enregistrees (Mode Auto)"
Write-Host "3. Retenter uniquement les echecs (Mode Rapide)"
Write-Host "4. Analyser et REPARER les artefacts JSON (Mode Diagnostic)" -ForegroundColor Yellow
$mode = Read-Host "Votre choix (1, 2, 3 ou 4)"

$channelsToProcess = @()

if ($mode -eq "1") {
    $url = Read-Host "URL de la chaine YouTube"
    $abbrev = Read-Host "Prefixe pour les packs (ex: YC)"
    $lang = Read-Host "Langue des sous-titres (Tapez 'fr' pour Francais, 'en' pour Anglais)"
    if ($lang -notin @('fr', 'en')) { $lang = 'fr' }
    
    $existing = Import-Csv -Path $configFile -Delimiter ";" -Encoding utf8
    $exists = $false
    foreach ($row in $existing) { if ($row.URL -eq $url) { $exists = $true; break } }
    
    if (!$exists) {
        "$url;$abbrev;$lang" | Out-File -LiteralPath $configFile -Encoding utf8 -Append
        Write-Log "Chaine ajoutee a la configuration." "Green"
    }
    
    $channelsToProcess += [PSCustomObject]@{ URL = $url; Prefix = $abbrev; Lang = $lang }
    Write-Log "$($channelsToProcess.Count) chaine(s) trouvee(s) dans la configuration." "Green"
} elseif ($mode -eq "2" -or $mode -eq "3") {
    $configData = Import-Csv -Path $configFile -Delimiter ";" -Encoding utf8
    foreach ($row in $configData) {
        if (![string]::IsNullOrWhiteSpace($row.URL)) {
            $channelsToProcess += [PSCustomObject]@{ URL = $row.URL; Prefix = $row.Prefixe; Lang = $row.Langue }
        }
    }
    Write-Log "Mode $($mode) : $($channelsToProcess.Count) chaines a verifier." "Cyan"
} elseif ($mode -eq "4") {
    $configData = Import-Csv -Path $configFile -Delimiter ";" -Encoding utf8
    $channelsToProcess = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($row in $configData) {
        if (![string]::IsNullOrWhiteSpace($row.URL)) {
            $channelsToProcess.Add([PSCustomObject]@{ URL = $row.URL; Prefix = $row.Prefixe; Lang = $row.Langue })
        }
    }
    Write-Log "MODE DIAGNOSTIC : Analyse de $($channelsToProcess.Count) chaines..." "Yellow"
} else {
    Write-Host "Choix invalide. Fermeture du script." -ForegroundColor Red
    exit
}

if ($channelsToProcess.Count -eq 0) {
    Write-Host "Aucune chaine a traiter." -ForegroundColor Yellow
    exit
}

Write-Host "`n[OPTIONNEL] Authentification YouTube" -ForegroundColor Yellow
Write-Host "Fournir des cookies est facultatif, mais fortement recommande pour les longues playlists (evite les blocages YouTube)." -ForegroundColor Gray
Write-Host "Note: Chrome et Edge sont deconseilles car ils bloquent souvent l'acces aux cookies." -ForegroundColor DarkGray
$browserChoice = Read-Host "Source (firefox, txt pour cookies.txt, ou Entree pour ignorer)"
if ([string]::IsNullOrWhiteSpace($browserChoice)) { $browserChoice = 'none' }
$browserChoice = $browserChoice.ToLower()

$cookieArgsBase = @()
if ($browserChoice -eq 'txt') {
    $cookiePath1 = Join-Path $PSScriptRoot "cookies.txt"
    $cookiePath2 = Join-Path $PSScriptRoot "cookie.txt"
    if (Test-Path $cookiePath1) { $cookieArgsBase = @("--cookies", $cookiePath1) }
    elseif (Test-Path $cookiePath2) { $cookieArgsBase = @("--cookies", $cookiePath2) }
    else { Write-Log "Fichier cookies.txt introuvable ! Mode sans cookies active." "Red" }
} elseif ($browserChoice -ne 'none') {
    $cookieArgsBase = @("--cookies-from-browser", $browserChoice)
}

# Demander une seule fois si on veut synchroniser avec YouTube
$syncChoice = "n"
if ($mode -ne "3") {
    $syncChoice = Read-Host "Souhaitez-vous synchroniser YouTube pour telecharger les nouveautes ? (O/N)"
}

# ==============================================================================
# FONCTIONS DU PIPELINE
# ==============================================================================

function Fix-Mojibake {
    param ($txt)
    if ([string]::IsNullOrWhiteSpace($txt)) { return $txt }
    
    # Construction des patterns par codes de caracteres pour eviter les problemes d'encodage du script lui-meme
    $c226 = [char]226; $c8364 = [char]8364; $c8482 = [char]8482; $c157 = [char]157; $c339 = [char]339; $c195 = [char]195; $c169 = [char]169; $c194 = [char]194
    
    # â€™ (E2 80 99)
    $txt = $txt.Replace($c226 + $c8364 + $c8482, "'")
    # â€œ (E2 80 9C)
    $txt = $txt.Replace($c226 + $c8364 + $c339, '"')
    # â€ (E2 80 9D)
    $txt = $txt.Replace($c226 + $c8364 + $c157, '"')
    # â€  (E2 80 20)
    $txt = $txt.Replace($c226 + $c8364 + " ", '"')
    # â€ (E2 80) - Cas generique
    $txt = $txt.Replace($c226 + $c8364, '"')
    # â€“ (E2 80 93)
    $txt = $txt.Replace($c226 + $c8364 + [char]8211, "-")
    # Ã© (C3 A9)
    $txt = $txt.Replace($c195 + $c169, "é")
    # Â (C2)
    $txt = $txt.Replace($c194, "")
    
    return $txt
}

function Process-LocalFiles {
    param ($RawDir, $TxtDir, $DenseDir, $Lang, $Prefix)
    
    $rawFiles = Get-ChildItem -LiteralPath $RawDir -File -Recurse | Where-Object { $_.Extension -match '^\.(srt|vtt)$' }
    $totalRaw = $rawFiles.Count
    if ($totalRaw -eq 0) { return 0 }

    Write-Host "[$Prefix] Analyse locale (Parallele x16) de $totalRaw fichiers..." -ForegroundColor Cyan
    
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $results = $rawFiles | ForEach-Object -ThrottleLimit $threadLimit -Parallel {
        $file = $_
        $Lang = $using:Lang
        $Prefix = $using:Prefix
        $TxtDir = $using:TxtDir
        $DenseDir = $using:DenseDir
        $RawDir = $using:RawDir

        $newDenseCreated = 0
        
        $srtFile = $file.FullName
        $extRegex = '\.' + $Lang + '\.srt$|\.' + $Lang + '\.vtt$|\.srt$|\.vtt$'
        $jsonFile = $srtFile -replace $extRegex, '.info.json'
        
        $title = ""; $date = ""; $vUrl = "URL non disponible"

        if (Test-Path -LiteralPath $jsonFile) {
            try {
                $jsonContent = [System.IO.File]::ReadAllText($jsonFile)
                # Regex ultra-rapide pour l'ID, le titre et la date
                if ($jsonContent -match '"title":\s*"(.*?)",') { $title = $Matches[1] }
                if ($jsonContent -match '"upload_date":\s*"(.*?)",') { $date = $Matches[1] }
                if ($jsonContent -match '"id":\s*"(.*?)",') { $vUrl = "https://www.youtube.com/watch?v=$($Matches[1])" }
            } catch {
                $date = "00000000"
                $title = $file.Name -replace $extRegex, ""
            }
        } else {
            if ($file.Name -match "^(\d{8})") { 
                $date = $Matches[1]
                $title = $file.Name -replace "^\d{8}\s-\s", "" -replace $extRegex, "" 
            } else { 
                $date = "00000000"
                $title = $file.Name -replace $extRegex, "" 
            }
        }

        $simpleName = $title -replace '[^a-zA-Z0-9\s\-]', ''
        $simpleName = $simpleName.Trim()
        if ($simpleName.Length -gt 80) { $simpleName = $simpleName.Substring(0,80) }
        $txtFileName = $date + " - " + $simpleName + ".txt"
        
        $destPath2 = Join-Path $TxtDir $txtFileName
        $destPath3 = Join-Path $DenseDir $txtFileName

        if (!(Test-Path -LiteralPath $destPath2)) {
            try {
                $rawLines = [System.IO.File]::ReadAllLines($srtFile)
                if ($rawLines.Count -gt 0) {
                    if ($rawLines[0].Trim().StartsWith("{")) { return 0 }
                }
                
                $cleanList = [System.Collections.Generic.List[string]]::new()
                foreach ($line in $rawLines) {
                    $l = $line -replace '^\d+$', '' -replace '\d{2}:\d{2}:\d{2},\d{3}.*', '' -replace '<[^>]+>', ''
                    if ($l.Trim() -ne "") { $cleanList.Add($l.Trim()) }
                }
                
                $finalLines = [System.Collections.Generic.List[string]]::new()
                if ($cleanList.Count -gt 0) {
                    for ($i = 0; $i -lt $cleanList.Count - 1; $i++) {
                        if ($cleanList[$i+1].StartsWith($cleanList[$i])) { continue }
                        $finalLines.Add($cleanList[$i])
                    }
                    $finalLines.Add($cleanList[-1])
                }
                
                $header = "====================================`r`nSOURCE: YouTube`r`nTITLE: $title`r`nURL: $vUrl`r`nDATE: $date`r`n====================================`r`n`r`n"
                $textContent = ($finalLines -join " ") -replace '\. ', ".`r`n`r`n"
                # Fix-Mojibake est une fonction globale, on l'inline ou on la re-déclare ici
                # Pour simplifier on va faire les remplacements courants
                $textContent = $textContent.Replace([char]226 + [char]8364 + [char]8482, "'").Replace([char]195 + [char]169, "é")
                
                [System.IO.File]::WriteAllText($destPath2, $header + $textContent)
            } catch { }
        }

        if ((Test-Path -LiteralPath $destPath2) -and !(Test-Path -LiteralPath $destPath3)) {
            try {
                $content = [System.IO.File]::ReadAllText($destPath2)
                $parts = $content -split "===================================="
                if ($parts.Count -ge 3) {
                    $header = "====================================" + $parts[1] + "===================================="
                    $transcript = ""
                    for ($i = 2; $i -lt $parts.Count; $i++) { $transcript += $parts[$i] }
                    
                    $dense = $transcript -replace '\[.*?\]', '' -replace '&[a-z]+;', '' -replace '<[^>]*>?', '' -replace '(?i)\b(\w+)(?:\s+\1\b)+', '$1' -replace "[\r\n\t]+", " " -replace '\s{2,}', ' '
                    
                    [System.IO.File]::WriteAllText($destPath3, $header.Trim() + "`r`n`r`n" + $dense.Trim())
                    $newDenseCreated = 1
                }
            } catch { }
        }
        return $newDenseCreated
        }
    } else {
        # Fallback pour PowerShell 5.1 (Sequentiel)
        $results = foreach ($file in $rawFiles) {
            $srtFile = $file.FullName
            $extRegex = '\.' + $Lang + '\.srt$|\.' + $Lang + '\.vtt$|\.srt$|\.vtt$'
            $jsonFile = $srtFile -replace $extRegex, '.info.json'
            $title = ""; $date = ""; $vUrl = "URL non disponible"
            if (Test-Path -LiteralPath $jsonFile) {
                try {
                    $jsonContent = [System.IO.File]::ReadAllText($jsonFile)
                    if ($jsonContent -match '"title":\s*"(.*?)",') { $title = $Matches[1] }
                    if ($jsonContent -match '"upload_date":\s*"(.*?)",') { $date = $Matches[1] }
                    if ($jsonContent -match '"id":\s*"(.*?)",') { $vUrl = "https://www.youtube.com/watch?v=$($Matches[1])" }
                } catch { $date = "00000000"; $title = $file.Name -replace $extRegex, "" }
            } else {
                if ($file.Name -match "^(\d{8})") { $date = $Matches[1]; $title = $file.Name -replace "^\d{8}\s-\s", "" -replace $extRegex, "" }
                else { $date = "00000000"; $title = $file.Name -replace $extRegex, "" }
            }
            $simpleName = ($title -replace '[^a-zA-Z0-9\s\-]', '').Trim()
            if ($simpleName.Length -gt 80) { $simpleName = $simpleName.Substring(0,80) }
            $txtFileName = $date + " - " + $simpleName + ".txt"
            $destPath2 = Join-Path $TxtDir $txtFileName
            $destPath3 = Join-Path $DenseDir $txtFileName
            $newDenseCreated = 0
            if (!(Test-Path -LiteralPath $destPath2)) {
                try {
                    $rawLines = [System.IO.File]::ReadAllLines($srtFile)
                    if ($rawLines.Count -gt 0 -and $rawLines[0].Trim().StartsWith("{")) { continue }
                    $cleanList = [System.Collections.Generic.List[string]]::new()
                    foreach ($line in $rawLines) {
                        $l = $line -replace '^\d+$', '' -replace '\d{2}:\d{2}:\d{2},\d{3}.*', '' -replace '<[^>]+>', ''
                        if ($l.Trim() -ne "") { $cleanList.Add($l.Trim()) }
                    }
                    $finalLines = [System.Collections.Generic.List[string]]::new()
                    if ($cleanList.Count -gt 0) {
                        for ($i = 0; $i -lt $cleanList.Count - 1; $i++) { if ($cleanList[$i+1].StartsWith($cleanList[$i])) { continue }; $finalLines.Add($cleanList[$i]) }
                        $finalLines.Add($cleanList[-1])
                    }
                    $header = "====================================`r`nSOURCE: YouTube`r`nTITLE: $title`r`nURL: $vUrl`r`nDATE: $date`r`n====================================`r`n`r`n"
                    $textContent = (($finalLines -join " ") -replace '\. ', ".`r`n`r`n").Replace([char]226 + [char]8364 + [char]8482, "'").Replace([char]195 + [char]169, "é")
                    [System.IO.File]::WriteAllText($destPath2, $header + $textContent)
                } catch { }
            }
            if ((Test-Path -LiteralPath $destPath2) -and !(Test-Path -LiteralPath $destPath3)) {
                try {
                    $content = [System.IO.File]::ReadAllText($destPath2)
                    $parts = $content -split "===================================="
                    if ($parts.Count -ge 3) {
                        $header = "====================================" + $parts[1] + "===================================="
                        $transcript = ""
                        for ($i = 2; $i -lt $parts.Count; $i++) { $transcript += $parts[$i] }
                        $dense = $transcript -replace '\[.*?\]', '' -replace '&[a-z]+;', '' -replace '<[^>]*>?', '' -replace '(?i)\b(\w+)(?:\s+\1\b)+', '$1' -replace "[\r\n\t]+", " " -replace '\s{2,}', ' '
                        [System.IO.File]::WriteAllText($destPath3, $header.Trim() + "`r`n`r`n" + $dense.Trim())
                        $newDenseCreated = 1
                    }
                } catch { }
            }
            $newDenseCreated
        }
    }
    
    $totalNew = ($results | Measure-Object -Sum).Sum
    Write-Host "[$Prefix] Analyse terminee : $totalNew nouveaux fichiers denses." -ForegroundColor Gray
    return $totalNew
}

function Sync-YouTube {
    param ($Url, $RawDir, $YtDlp, $Ffmpeg, $Cookies, $Lang, $BaseDir, $LogPrefix, $BlacklistPath, $RetryOnly = $false)
    
    $masterListPath = Join-Path $BaseDir "youtube_master_list.txt"
    $missingListPath = Join-Path $BaseDir "missing_videos.txt"
    
    $fetchMaster = $true
    if (Test-Path $masterListPath) {
        $lastMod = (Get-Item $masterListPath).LastWriteTime
        if ((Get-Date) - $lastMod -lt (New-TimeSpan -Hours 24)) {
            $fetchMaster = $false
            Write-Log "Cache YouTube (24h) trouve." "Green" $LogPrefix
        }
    }

    if ($RetryOnly) {
        if (Test-Path $missingListPath) {
            $masterIds = @(Get-Content -LiteralPath $missingListPath | Where-Object { $_ -ne "" })
            Write-Log "Mode Rapide : $($masterIds.Count) echecs precedents charges." "Cyan" $LogPrefix
            if ($masterIds.Count -eq 0) {
                return
            }
        } else {
            Write-Log "Aucun fichier d'echecs trouve." "Yellow" $LogPrefix
            return
        }
    } elseif ($fetchMaster) {
        Write-Log "Scan complet de la chaine..." "Yellow" $LogPrefix
        try {
            $scan = & $YtDlp --ffmpeg-location $Ffmpeg --user-agent $userAgent @Cookies --flat-playlist --match-filter "duration > 60" --print "%(id)s" $Url
            $masterIds = $scan -split "`r`n" | Where-Object { $_ -ne "" }
            $masterIds | Out-File -LiteralPath $masterListPath -Encoding utf8
            Write-Log "Scan termine et cache mis a jour." "Green" $LogPrefix
        } catch {
            Write-Log "Erreur lors du scan. Passage a la chaine suivante." "Red" $LogPrefix
            return
        }
    } else {
        $masterIds = Get-Content -LiteralPath $masterListPath | Where-Object { $_ -ne "" }
    }

    # Filtrage par Blacklist (avec support d'expiration)
    $blacklist = @()
    if (Test-Path $blacklistPath) {
        $today = Get-Date
        foreach ($line in Get-Content $blacklistPath) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $id = ($line -split "#")[0].Trim()
            
            # Verification de la date d'expiration [YYYY-MM-DD]
            if ($line -match "\[(\d{4}-\d{2}-\d{2})\]") {
                try {
                    $expDate = [DateTime]::ParseExact($Matches[1], "yyyy-MM-dd", $null)
                    if ($today -gt $expDate) { continue } # Date depassee, on ne blackliste plus
                } catch { }
            }
            $blacklist += $id
        }
    }
    
    $originalMasterCount = $masterIds.Count
    $masterIds = $masterIds | Where-Object { $_ -notin $blacklist }
    $ignoredByBlacklist = $originalMasterCount - $masterIds.Count
    if ($ignoredByBlacklist -gt 0) { Write-Log "$ignoredByBlacklist video(s) ignoree(s) (Blacklist)." "Gray" $LogPrefix }

    if (!$RetryOnly) {
        $localIds = [System.Collections.Generic.HashSet[string]]::new()
        $jsonFiles = Get-ChildItem -LiteralPath $RawDir -Filter "*.info.json"
        $totalJson = $jsonFiles.Count
        
        Write-Host "[$LogPrefix] Scan local ultra-rapide ($totalJson fichiers)..." -ForegroundColor Cyan
        
        # On recupere la liste des fichiers SRT/VTT une seule fois pour eviter des milliers de Test-Path
        $rawFileMap = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach($f in [System.IO.Directory]::GetFiles($RawDir)) {
            $ext = [System.IO.Path]::GetExtension($f)
            if ($ext -eq ".srt" -or $ext -eq ".vtt") { [void]$rawFileMap.Add([System.IO.Path]::GetFileName($f)) }
        }

        foreach ($json in $jsonFiles) {
            $baseName = $json.Name -replace '\.info\.json$', ''
            $found = $false
            foreach($suffix in @("", ".$Lang")) {
                if ($rawFileMap.Contains($baseName + $suffix + ".srt") -or $rawFileMap.Contains($baseName + $suffix + ".vtt")) {
                    $found = $true; break
                }
            }

            if ($found) {
                try { 
                    $jsonContent = [System.IO.File]::ReadAllText($json.FullName)
                    if ($jsonContent -match '"id":\s*"(.*?)"') {
                        [void]$localIds.Add($Matches[1])
                    }
                } catch { }
            }
        }
        Write-Host "[$LogPrefix] Scan local termine." -ForegroundColor Gray

        $toDownload = [System.Collections.Generic.List[string]]::new()
        foreach ($mid in $masterIds) { 
            if (!($localIds.Contains($mid))) { $toDownload.Add($mid) } 
        }
        $toDownload | Out-File -LiteralPath $missingListPath -Encoding utf8
    } else {
        $toDownload = [System.Collections.Generic.List[string]]::new($masterIds)
    }

    if ($toDownload.Count -gt 0) {
        Write-Log "$($toDownload.Count) videos manquantes a telecharger." "Yellow" $LogPrefix
        
        $browserName = if ($Cookies -match "--cookies-from-browser") { $Cookies[1] } else { $null }
        if ($browserName) {
            $tempCookie = Join-Path $BaseDir "temp_cookies.txt"
            & $YtDlp --cookies-from-browser $browserName --cookies $tempCookie --playlist-items 0 "https://www.youtube.com" 2>&1 | Out-Null
            if (Test-Path $tempCookie) { $Cookies = @("--cookies", $tempCookie) }
        }

        $errorCount = 0
        $currentIndex = 1
        $totalVideos = $toDownload.Count
        
        foreach ($id in $toDownload.ToArray()) {
            Write-Host "`n[$LogPrefix] [DOWNLOAD $currentIndex/$totalVideos] $id" -ForegroundColor Cyan
            $vidUrl = "https://www.youtube.com/watch?v=" + $id
            
            $noSubsFound = $false
            $currentTitle = "ID: $id"

            $dlpCmd = {
                & $YtDlp --user-agent $userAgent @Cookies `
                    --ffmpeg-location $Ffmpeg `
                    --write-auto-sub --write-info-json `
                    --sub-langs $Lang --skip-download --convert-subs srt `
                    --min-sleep-interval 10 --max-sleep-interval 40 --sleep-requests 1 `
                    --download-archive (Join-Path $BaseDir "archive.txt") `
                    -o (Join-Path $RawDir "%(upload_date)s - %(title)s.%(ext)s") $vidUrl 2>&1
            }
            
            $dlpCmd.Invoke() | ForEach-Object {
                $line = $_.ToString()
                if ($line -match "(?i)sleeping .* seconds") {
                    Write-Host "  $line" -ForegroundColor DarkMagenta
                } elseif ($line -match "There are no subtitles for the requested languages") {
                    $noSubsFound = $true
                } elseif ($line -match "Writing video metadata as JSON to: .*\\(\d{8} - .*)\.info\.json") {
                    $currentTitle = $Matches[1]
                } elseif ($line -match "(?i)(Writing video subtitles to|Destination): .*1_RAW\\\d{8} - (.*)\.$Lang\.(vtt|srt)") {
                    $title = $Matches[2]
                    $idx = $line.IndexOf($title)
                    if ($idx -ge 0) {
                        Write-Host "  " -NoNewline
                        Write-Host $line.Substring(0, $idx) -NoNewline -ForegroundColor Gray
                        Write-Host $title -NoNewline -ForegroundColor Green
                        Write-Host $line.Substring($idx + $title.Length) -ForegroundColor Gray
                    }
                } elseif ($line -match "(?i)Extracting cookies") {
                    # Ignore
                } else {
                    Write-Host "  $line" -ForegroundColor DarkGray
                }
            }
            
            if ($noSubsFound) {
                Write-Host "  [!] Aucun sous-titre trouve pour cette video." -ForegroundColor Yellow
                $blacklistCandidates.Add([PSCustomObject]@{ ID=$id; Title=$currentTitle; Prefix=$LogPrefix })
            }

            $newFiles = Get-ChildItem -Path $RawDir -Filter "*$id*" -Include "*.srt", "*.vtt" -Recurse
            if ($global:LASTEXITCODE -eq 0 -or $newFiles.Count -gt 0) {
                $errorCount = 0
                $toDownload.Remove($id)
                $toDownload | Out-File -LiteralPath $missingListPath -Encoding utf8
            } else {
                $errorCount++
                Write-Log "Echec de telechargement sur $id ($errorCount/3)" "Red" $LogPrefix
                if ($errorCount -ge 3) {
                    Write-Log "3 echecs consecutifs. Pause de 15 minutes..." "Yellow" $LogPrefix
                    Start-Sleep -Seconds 900
                    $errorCount = 0
                }
            }
            $currentIndex++
        }
    } else {
        Write-Log "Aucune video manquante." "Green" $LogPrefix
    }
}

function Build-Packs {
    param ($DenseDir, $PacksDir, $Prefix, $LogPrefix, $GlobalPacksDir)
    
    $denseFiles = Get-ChildItem -LiteralPath $DenseDir -Filter "*.txt" | Sort-Object Name
    $packsPlan = [System.Collections.Generic.List[PSObject]]::new()
    $currentBatch = [System.Collections.Generic.List[PSObject]]::new()
    $currentWords = 0; $packNum = 1

    foreach ($file in $denseFiles) {
        try {
            $content = Get-Content -LiteralPath $file.FullName -Raw
            $wordCount = ($content -split "\s+" | Where-Object { $_ -ne "" }).Count
            
            if (($currentWords + $wordCount) -gt 500000 -and $currentBatch.Count -gt 0) {
                $packsPlan.Add([PSCustomObject]@{
                    ID = $packNum; Files = $currentBatch.ToArray(); TotalWords = $currentWords
                    Start = $currentBatch[0].Name.Substring(0,8); End = $currentBatch[-1].Name.Substring(0,8)
                })
                $packNum++; $currentBatch = [System.Collections.Generic.List[PSObject]]::new(); $currentWords = 0
            }
            $currentBatch.Add($file)
            $currentWords += $wordCount
        } catch { }
    }

    if ($currentBatch.Count -gt 0) {
        $packsPlan.Add([PSCustomObject]@{
            ID = $packNum; Files = $currentBatch.ToArray(); TotalWords = $currentWords
            Start = $currentBatch[0].Name.Substring(0,8); End = $currentBatch[-1].Name.Substring(0,8)
        })
    }

    # Nettoyage des anciens packs du meme prefixe dans le dossier global pour eviter les doublons
    # On nettoie les versions avec ULTRA et les nouvelles sans ULTRA
    Get-ChildItem -Path $GlobalPacksDir -Filter ($Prefix + "_*.txt") | Where-Object { $_.Name -match "^$Prefix(_ULTRA)?_\d{2}_\(" } | Remove-Item -Force

    Write-Log "$($packsPlan.Count) packs a generer." "Green" $LogPrefix
    
    if ($packsPlan.Count -gt 0) {
        Write-Host "[PLAN DE BATAILLE ETABLI]" -ForegroundColor Cyan
        foreach ($plan in $packsPlan) {
            $sFmt = $plan.Start -replace '^(\d{4})(\d{2})(\d{2})$', '$1.$2.$3'
            $eFmt = $plan.End -replace '^(\d{4})(\d{2})(\d{2})$', '$1.$2.$3'
            Write-Host "  > Pack $($plan.ID) : $sFmt au $eFmt | $($plan.Files.Count) videos | $($plan.TotalWords) mots" -ForegroundColor Gray
        }
    }
    Get-ChildItem -Path $PacksDir -Filter "*.txt" | Remove-Item -Force

    foreach ($plan in $packsPlan) {
        try {
            $sFmt = $plan.Start -replace '^(\d{4})(\d{2})(\d{2})$', '$1.$2.$3'
            $eFmt = $plan.End -replace '^(\d{4})(\d{2})(\d{2})$', '$1.$2.$3'
            $pName = $Prefix + "_" + $plan.ID.ToString("00") + "_(" + $sFmt + "-au-" + $eFmt + ").txt"
            $pPath = Join-Path $PacksDir $pName
            Write-Host "[$LogPrefix] Ecriture Pack $($plan.ID)... " -ForegroundColor Yellow -NoNewline

            $sb = New-Object System.Text.StringBuilder
            foreach ($b in $plan.Files) {
                [void]$sb.AppendLine((Get-Content -LiteralPath $b.FullName -Raw))
                [void]$sb.AppendLine("`r`n###################################")
                [void]$sb.AppendLine("SOURCE: " + $b.BaseName)
                [void]$sb.AppendLine("###################################`r`n")
            }
            
            $sb.ToString() | Out-File -LiteralPath $pPath -Encoding utf8
            Write-Host "[OK]" -ForegroundColor Green
            
            # Petit delai pour laisser le temps au systeme de fichier de stabiliser avant la copie
            Start-Sleep -Milliseconds 100
            Copy-Item -LiteralPath $pPath -Destination $GlobalPacksDir -Force
        } catch {
            Write-Host "[ERREUR]" -ForegroundColor Red
            Write-Log "Erreur d'ecriture sur le pack $($plan.ID) : $($_.Exception.Message)" "Red" $LogPrefix
        }
    }
}

function Repair-Packs {
    param ($BaseDir, $Prefix)
    
    $densePath = Join-Path $BaseDir "3_TXT_dense"
    $v1Path = Join-Path $BaseDir "2_TXT"
    
    if (!(Test-Path $densePath)) { return 0 }
    
    Write-Host "[$Prefix] Analyse diagnostique (Parallele x16)..." -ForegroundColor Cyan
    $files = Get-ChildItem -Path $densePath -Filter "*.txt"
    if ($files.Count -eq 0) { return 0 }

    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $corrupted = $files | ForEach-Object -ThrottleLimit $threadLimit -Parallel {
            $content = [System.IO.File]::ReadAllText($_.FullName)
            if ($content -match '\{"id":' -or $content -match '"formats":' -or $content -match ([char]226 + [char]8364) -or $content -match ([char]195 + [char]169)) {
                return $_.Name
            }
        }
    } else {
        $corrupted = foreach ($f in $files) {
            $content = [System.IO.File]::ReadAllText($f.FullName)
            if ($content -match '\{"id":' -or $content -match '"formats":' -or $content -match ([char]226 + [char]8364) -or $content -match ([char]195 + [char]169)) {
                $f.Name
            }
        }
    }
    
    if ($corrupted.Count -gt 0) {
        Write-Host "[$Prefix] ALERTE : $($corrupted.Count) artefacts JSON detectes ! Nettoyage..." -ForegroundColor Yellow
        foreach ($name in $corrupted) {
            $f1 = Join-Path $v1Path $name
            $f2 = Join-Path $densePath $name
            if (Test-Path $f1) { Remove-Item -LiteralPath $f1 -Force }
            if (Test-Path $f2) { Remove-Item -LiteralPath $f2 -Force }
        }
        return $corrupted.Count
    }
    return 0
}

# ==============================================================================
# EXECUTION BATCH
# ==============================================================================

$globalStats = @{
    Master = 0; Raw = 0; Txt = 0; Dense = 0; Packs = 0; Missing = 0
    Processed = 0; Failed = 0
}
$missingReportList = @()

foreach ($chan in $channelsToProcess) {
    Write-Host "`n=================================================================" -ForegroundColor Magenta
    Write-Host " DEMARRAGE CHAINE : $($chan.URL)" -ForegroundColor Magenta
    Write-Host "=================================================================" -ForegroundColor Magenta

    $logPrefix = $chan.Prefix
    
    try {
        $channelName = & $ytDlp --ffmpeg-location $ffmpegPath --user-agent $userAgent @cookieArgsBase --get-filename -o "%(uploader)s" $chan.URL --playlist-items 1
        if ([string]::IsNullOrWhiteSpace($channelName)) { throw "Nom de chaine introuvable" }
    } catch {
        Write-Log "Impossible d'acceder a la chaine. Passage a la suivante." "Red" $logPrefix
        $globalStats.Failed++
        continue
    }

    $channelFolder = ($channelName -replace "[^a-zA-Z0-9]", "_").Trim()
    $baseDir = Join-Path $PSScriptRoot $channelFolder
    
    $masterListPath = Join-Path $baseDir "youtube_master_list.txt"
    $missingListPath = Join-Path $baseDir "missing_videos.txt"

    $p1_Raw   = Join-Path $baseDir "1_RAW"
    $p2_Txt   = Join-Path $baseDir "2_TXT"
    $p3_Dense = Join-Path $baseDir "3_TXT_dense"
    $p4_Packs = Join-Path $baseDir "4_Packs"

    foreach ($p in @($p1_Raw, $p2_Txt, $p3_Dense, $p4_Packs)) { 
        if (!(Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null } 
    }

    Write-Log "Traitement local rapide..." "Cyan" $logPrefix
    
    if ($mode -eq "4") {
        $repaired = Repair-Packs -BaseDir $baseDir -Prefix $logPrefix
        if ($repaired -gt 0) { Write-Log "$repaired fichiers repares." "Green" $logPrefix }
    }

    $newDense1 = if ($mode -ne "3") { 
        Process-LocalFiles -RawDir $p1_Raw -TxtDir $p2_Txt -DenseDir $p3_Dense -Lang $chan.Lang -Prefix $logPrefix 
    } else { 0 }

    $skipProcessing = $false
    if ($mode -eq "3") {
        if (!(Test-Path $missingListPath)) { $skipProcessing = $true }
        else {
            $mIds = @(Get-Content -LiteralPath $missingListPath | Where-Object { $_ -ne "" })
            if ($mIds.Count -eq 0) { $skipProcessing = $true }
        }
    }

    if ($skipProcessing) {
        Write-Log "Aucun fichier d'echecs trouve. Chaine ignoree." "Yellow" $logPrefix
        $newDense2 = 0
    } elseif ($syncChoice -eq "O" -or $syncChoice -eq "o" -or $mode -eq "3") {
        Write-Log "Synchronisation YouTube (Mode $($mode))..." "Cyan" $logPrefix
        Sync-YouTube -Url $chan.URL -RawDir $p1_Raw -YtDlp $ytDlp -Ffmpeg $ffmpegPath -Cookies $cookieArgsBase -Lang $chan.Lang -BaseDir $baseDir -LogPrefix $logPrefix -BlacklistPath $blacklistPath -RetryOnly ($mode -eq "3")
        
        Write-Log "Traitement des fichiers..." "Cyan" $logPrefix
        $newDense2 = Process-LocalFiles -RawDir $p1_Raw -TxtDir $p2_Txt -DenseDir $p3_Dense -Lang $chan.Lang -Prefix $logPrefix
    } else {
        $newDense2 = 0
    }

    $totalNewDense = $newDense1 + $newDense2
    $existingPacks = (Get-ChildItem -Path $p4_Packs -Filter "*.txt").Count

    if ($totalNewDense -gt 0 -or $existingPacks -eq 0) {
        Write-Log "Analyse et fusion des packs..." "Cyan" $logPrefix
        Build-Packs -DenseDir $p3_Dense -PacksDir $p4_Packs -Prefix $chan.Prefix -LogPrefix $logPrefix -GlobalPacksDir $allPacksDir
    } else {
        Write-Log "Aucune nouveaute. Synchronisation des packs existants vers ALL_PACKS..." "Green" $logPrefix
        # Nettoyage des anciens packs du meme prefixe dans le dossier global
        Get-ChildItem -Path $allPacksDir -Filter ($chan.Prefix + "_*.txt") | Where-Object { $_.Name -match "^$($chan.Prefix)(_ULTRA)?_\d{2}_\(" } | Remove-Item -Force
        # Copie des packs locaux vers le dossier global
        Get-ChildItem -Path $p4_Packs -Filter "*.txt" | Copy-Item -Destination $allPacksDir -Force
    }

    # Aggregate stats
    $globalStats.Processed++
    $globalStats.Raw += (Get-ChildItem -LiteralPath $p1_Raw -Include "*.srt", "*.vtt" -Recurse).Count
    $globalStats.Txt += (Get-ChildItem -LiteralPath $p2_Txt -Filter "*.txt").Count
    $globalStats.Dense += (Get-ChildItem -LiteralPath $p3_Dense -Filter "*.txt").Count
    $globalStats.Packs += (Get-ChildItem -LiteralPath $p4_Packs -Filter "*.txt").Count
    
    if (Test-Path $masterListPath) { $globalStats.Master += (Get-Content $masterListPath | Where-Object { $_ -ne "" }).Count }
    if (Test-Path $missingListPath) { $globalStats.Missing += (Get-Content $missingListPath | Where-Object { $_ -ne "" }).Count }

    # Rapport individuel par chaine
    Write-Host "`n=================================================" -ForegroundColor Cyan
    Write-Host "    RAPPORT FINAL DU PIPELINE POUR $($channelName.ToUpper())" -ForegroundColor White
    Write-Host "=================================================" -ForegroundColor Cyan
    $chanMaster = if (Test-Path $masterListPath) { (Get-Content $masterListPath | Where-Object { $_ -ne "" }).Count } else { 0 }
    $chanMissing = if (Test-Path $missingListPath) { (Get-Content $missingListPath | Where-Object { $_ -ne "" }).Count } else { 0 }
    Write-Host "Videos sur la chaine (Cache) : $chanMaster"
    Write-Host "Fichiers bruts (RAW)         : $((Get-ChildItem -LiteralPath $p1_Raw -Include "*.srt", "*.vtt" -Recurse).Count)"
    Write-Host "Fichiers texte (TXT)         : $((Get-ChildItem -LiteralPath $p2_Txt -Filter "*.txt").Count)"
    Write-Host "Fichiers denses (DENSE)      : $((Get-ChildItem -LiteralPath $p3_Dense -Filter "*.txt").Count)"
    Write-Host "Fichiers packs generes       : $((Get-ChildItem -LiteralPath $p4_Packs -Filter "*.txt").Count)"
    Write-Host "-------------------------------------------------" -ForegroundColor Cyan
    if ($chanMissing -gt 0) {
        Write-Host "Statut : $chanMissing video(s) manquante(s) (voir missing_videos.txt dans le dossier chaine)" -ForegroundColor Red
        $missingReportList += [PSCustomObject]@{ Name = $channelName; Count = $chanMissing }
    } else {
        Write-Host "Statut : Parfaitement a jour. Aucune video manquante." -ForegroundColor Green
    }
    Write-Host "=================================================" -ForegroundColor Cyan
}

# ==============================================================================
# SESSION DE REVUE DE LA LISTE NOIRE (BLACKLIST)
# ==============================================================================
if ($blacklistCandidates.Count -gt 0) {
    Write-Host "`n=================================================" -ForegroundColor Yellow
    Write-Host "   REVUE DES SUGGESTIONS DE LISTE NOIRE" -ForegroundColor White
    Write-Host "=================================================" -ForegroundColor Yellow
    Write-Host "Les videos suivantes n'ont pas de sous-titres sur YouTube."
    Write-Host "Voulez-vous les ajouter a la blacklist pour les ignorer ?"
    Write-Host "(O = Oui, N = Non, A = Tout blacklister, S = Tout ignorer)`n"

    $autoAccept = $false
    $autoSkip = $false

    foreach ($c in $blacklistCandidates) {
        if ($autoSkip) { continue }
        
        $decision = ""
        if ($autoAccept) {
            $decision = "o"
        } else {
            Write-Host "[?] Blacklister $($c.Title) ($($c.ID)) ? " -NoNewline
            $decision = Read-Host "(O/N/A/S)"
        }

        if ($decision -eq "a" -or $decision -eq "A") { $autoAccept = $true; $decision = "o" }
        if ($decision -eq "s" -or $decision -eq "S") { $autoSkip = $true; continue }

        if ($decision -eq "o" -or $decision -eq "O") {
            $c.ID | Add-Content -LiteralPath $blacklistPath
            Write-Host "  > Ajoute a la blacklist." -ForegroundColor Gray
        } else {
            Write-Host "  > Ignore." -ForegroundColor DarkGray
        }
    }
}

# ==============================================================================
# DASHBOARD GLOBAL STATISTIQUE
# ==============================================================================
Write-Host "`n=================================================" -ForegroundColor Cyan
Write-Host "          RAPPORT GLOBAL DU PIPELINE v9.5" -ForegroundColor White
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "Chaines traitees avec succes : $($globalStats.Processed)"
if ($globalStats.Failed -gt 0) { Write-Host "Chaines en echec             : $($globalStats.Failed)" -ForegroundColor Red }
Write-Host "-------------------------------------------------" -ForegroundColor Cyan
Write-Host "Videos sur les chaines (Cache) : $($globalStats.Master)"
Write-Host "Fichiers bruts (RAW)           : $($globalStats.Raw)"
Write-Host "Fichiers texte (TXT)           : $($globalStats.Txt)"
Write-Host "Fichiers denses (DENSE)        : $($globalStats.Dense)"
Write-Host "Fichiers packs generes         : $($globalStats.Packs)"
Write-Host "-------------------------------------------------" -ForegroundColor Cyan
if ($globalStats.Missing -gt 0) {
    Write-Host "Statut : $($globalStats.Missing) video(s) manquante(s) au total" -ForegroundColor Red
    Write-Host "Detail par chaine :" -ForegroundColor Yellow
    foreach ($m in $missingReportList) {
        Write-Host "  > $($m.Name) : $($m.Count) video(s)" -ForegroundColor DarkRed
    }
} else {
    Write-Host "Statut : Parfaitement a jour. Aucune video manquante." -ForegroundColor Green
}
Write-Host "Dossier global des packs       : $allPacksDir" -ForegroundColor Magenta
Write-Host "=================================================" -ForegroundColor Cyan
