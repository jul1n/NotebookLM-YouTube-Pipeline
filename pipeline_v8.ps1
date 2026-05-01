# PIPELINE DE CONNAISSANCES v9.0 - MULTI-CHAINES & BATCH PROCESSING
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
Write-Host "      PIPELINE DE CONNAISSANCES v9.0" -ForegroundColor Cyan
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

# 1. MENU PRINCIPAL
Write-Host "MENU PRINCIPAL" -ForegroundColor Yellow
Write-Host "1. Ajouter et traiter une nouvelle chaine (Mode Manuel)"
Write-Host "2. Rafraichir toutes les chaines enregistrees (Mode Auto)"
$mode = Read-Host "Votre choix (1 ou 2)"

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
} elseif ($mode -eq "2") {
    $configData = Import-Csv -Path $configFile -Delimiter ";" -Encoding utf8
    foreach ($row in $configData) {
        if (![string]::IsNullOrWhiteSpace($row.URL)) {
            $channelsToProcess += [PSCustomObject]@{ URL = $row.URL; Prefix = $row.Prefixe; Lang = $row.Langue }
        }
    }
    Write-Log "$($channelsToProcess.Count) chaine(s) trouvee(s) dans la configuration." "Green"
} else {
    Write-Host "Choix invalide. Fermeture du script." -ForegroundColor Red
    exit
}

if ($channelsToProcess.Count -eq 0) {
    Write-Host "Aucune chaine a traiter." -ForegroundColor Yellow
    exit
}

Write-Host "`n"
$browserChoice = Read-Host "Quel navigateur utilisez-vous (chrome, edge, firefox, txt pour un fichier texte, ou none pour ignorer) ?"
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
$syncChoice = Read-Host "Souhaitez-vous synchroniser YouTube pour telecharger les nouveautes ? (O/N)"

# ==============================================================================
# FONCTIONS DU PIPELINE
# ==============================================================================

function Process-LocalFiles {
    param ($RawDir, $TxtDir, $DenseDir, $Lang, $Prefix)
    
    $rawFiles = Get-ChildItem -LiteralPath $RawDir -Include "*.srt", "*.vtt" -Recurse
    if ($rawFiles.Count -eq 0) { return 0 }
    
    $newDenseCount = 0
    foreach ($file in $rawFiles) {
        $srtFile = $file.FullName
        $extRegex = '\.' + $Lang + '\.srt$|\.' + $Lang + '\.vtt$|\.srt$|\.vtt$'
        $jsonFile = $srtFile -replace $extRegex, '.info.json'
        
        $title = ""; $date = ""; $vUrl = "URL non disponible"

        if (Test-Path -LiteralPath $jsonFile) {
            try {
                $meta = Get-Content -LiteralPath $jsonFile -Raw | ConvertFrom-Json
                $title = $meta.title; $date = $meta.upload_date; $vUrl = "https://www.youtube.com/watch?v=$($meta.id)"
            } catch {
                $date = "00000000"; $title = $file.Name -replace $extRegex, ""
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
                $rawLines = Get-Content -LiteralPath $srtFile
                $cleanList = New-Object System.Collections.Generic.List[string]
                foreach ($line in $rawLines) {
                    $l = $line -replace '^\d+$', '' -replace '\d{2}:\d{2}:\d{2},\d{3}.*', '' -replace '<[^>]+>', ''
                    if ($l.Trim() -ne "") { $cleanList.Add($l.Trim()) }
                }
                $finalLines = New-Object System.Collections.Generic.List[string]
                if ($cleanList.Count -gt 0) {
                    for ($i = 0; $i -lt $cleanList.Count - 1; $i++) {
                        if ($cleanList[$i+1].StartsWith($cleanList[$i])) { continue }
                        $finalLines.Add($cleanList[$i])
                    }
                    $finalLines.Add($cleanList[-1])
                }
                $header = "====================================`r`nSOURCE: YouTube`r`nTITLE: $title`r`nURL: $vUrl`r`nDATE: $date`r`n====================================`r`n`r`n"
                $textContent = ($finalLines -join " ") -replace '\. ', ".`r`n`r`n"
                $header + $textContent | Out-File -LiteralPath $destPath2 -Encoding utf8
                Write-Host "[$Prefix] V1 cree : $($file.Name)" -ForegroundColor DarkGray
            } catch { }
        }

        if ((Test-Path -LiteralPath $destPath2) -and !(Test-Path -LiteralPath $destPath3)) {
            try {
                $content = Get-Content -LiteralPath $destPath2 -Raw
                $parts = $content -split "===================================="
                if ($parts.Count -ge 3) {
                    $header = "====================================" + $parts[1] + "===================================="
                    $transcript = ""
                    for ($i = 2; $i -lt $parts.Count; $i++) { $transcript += $parts[$i] }
                    
                    $dense = $transcript -replace '\[.*?\]', '' -replace '&[a-z]+;', '' -replace '<[^>]*>?', '' -replace '(?i)\b(\w+)(?:\s+\1\b)+', '$1' -replace "[\r\n\t]+", " " -replace '\s{2,}', ' '
                    
                    $header.Trim() + "`r`n`r`n" + $dense.Trim() | Out-File -LiteralPath $destPath3 -Encoding utf8
                    Write-Host "[$Prefix] V2 Dense cree : $($file.Name)" -ForegroundColor Gray
                    $newDenseCount++
                }
            } catch { }
        }
    }
    return $newDenseCount
}

function Sync-YouTube {
    param ($Url, $RawDir, $YtDlp, $Ffmpeg, $Cookies, $Lang, $BaseDir, $LogPrefix)
    
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

    if ($fetchMaster) {
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

    $localIds = @()
    $jsonFiles = Get-ChildItem -LiteralPath $RawDir -Filter "*.info.json"
    foreach ($json in $jsonFiles) {
        $baseName = $json.Name -replace '\.info\.json$', ''
        $hasSub = (Test-Path (Join-Path $RawDir "$baseName.srt")) -or (Test-Path (Join-Path $RawDir "$baseName.vtt")) -or (Test-Path (Join-Path $RawDir "$baseName.$Lang.srt")) -or (Test-Path (Join-Path $RawDir "$baseName.$Lang.vtt"))
        if ($hasSub) {
            try { 
                $id = (Get-Content -LiteralPath $json.FullName -Raw | ConvertFrom-Json).id 
                if ($id) { $localIds += $id }
            } catch { $null }
        }
    }

    $toDownload = @()
    foreach ($mid in $masterIds) { 
        if ($mid -notin $localIds) { $toDownload += $mid } 
    }

    $toDownload | Out-File -LiteralPath $missingListPath -Encoding utf8

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
        
        foreach ($id in $toDownload) {
            Write-Host "`n[$LogPrefix] [DOWNLOAD $currentIndex/$totalVideos] $id" -ForegroundColor Cyan
            $vidUrl = "https://www.youtube.com/watch?v=" + $id
            
            $dlpCmd = {
                & $YtDlp --user-agent $userAgent @Cookies `
                    --ffmpeg-location $Ffmpeg `
                    --write-auto-sub --write-info-json `
                    --sub-langs $Lang --skip-download --convert-subs srt `
                    --min-sleep-interval 10 --max-sleep-interval 45 --sleep-requests 2 `
                    --download-archive (Join-Path $BaseDir "archive.txt") `
                    -o (Join-Path $RawDir "%(upload_date)s - %(title)s.%(ext)s") $vidUrl 2>&1
            }
            
            $dlpCmd.Invoke() | ForEach-Object {
                $line = $_.ToString()
                if ($line -match "(?i)sleeping .* seconds") {
                    Write-Host "  $line" -ForegroundColor DarkMagenta
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
            
            $newFiles = Get-ChildItem -Path $RawDir -Filter "*$id*" -Include "*.srt", "*.vtt" -Recurse
            if ($global:LASTEXITCODE -eq 0 -or $newFiles.Count -gt 0) {
                $errorCount = 0
                $toDownload = $toDownload | Where-Object { $_ -ne $id }
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
    $packsPlan = @(); $currentBatch = @(); $currentWords = 0; $packNum = 1

    foreach ($file in $denseFiles) {
        try {
            $content = Get-Content -LiteralPath $file.FullName -Raw
            $wordCount = ($content -split "\s+" | Where-Object { $_ -ne "" }).Count
            
            if (($currentWords + $wordCount) -gt 500000 -and $currentBatch.Count -gt 0) {
                $packsPlan += [PSCustomObject]@{
                    ID = $packNum; Files = $currentBatch; TotalWords = $currentWords
                    Start = $currentBatch[0].Name.Substring(0,8); End = $currentBatch[-1].Name.Substring(0,8)
                }
                $packNum++; $currentBatch = @(); $currentWords = 0
            }
            $currentBatch += $file
            $currentWords += $wordCount
        } catch { }
    }

    if ($currentBatch.Count -gt 0) {
        $packsPlan += [PSCustomObject]@{
            ID = $packNum; Files = $currentBatch; TotalWords = $currentWords
            Start = $currentBatch[0].Name.Substring(0,8); End = $currentBatch[-1].Name.Substring(0,8)
        }
    }

    Write-Log "$($packsPlan.Count) packs a generer." "Green" $LogPrefix
    Get-ChildItem -Path $PacksDir -Filter "*.txt" | Remove-Item -Force
    
    # Nettoyage des anciens packs du meme prefixe dans le dossier global pour eviter les doublons
    Get-ChildItem -Path $GlobalPacksDir -Filter ($Prefix + "_ULTRA_*.txt") | Remove-Item -Force

    foreach ($plan in $packsPlan) {
        try {
            $pName = $Prefix + "_ULTRA_" + $plan.ID.ToString("00") + "_(" + $plan.Start + "-au-" + $plan.End + ").txt"
            $pPath = Join-Path $PacksDir $pName
            Write-Host "[$LogPrefix] Ecriture Pack $($plan.ID)... " -ForegroundColor Yellow -NoNewline

            foreach ($b in $plan.Files) {
                Get-Content -LiteralPath $b.FullName -Raw | Add-Content -LiteralPath $pPath
                $sep = "`r`n`r`n###################################`r`nSOURCE: " + $b.BaseName + "`r`n###################################`r`n`r`n"
                $sep | Add-Content -LiteralPath $pPath
            }
            Write-Host "[OK]" -ForegroundColor Green
            
            # Export to Global ALL_PACKS directory
            Copy-Item -LiteralPath $pPath -Destination $GlobalPacksDir -Force
        } catch { }
    }
}

# ==============================================================================
# EXECUTION BATCH
# ==============================================================================

$globalStats = @{
    Master = 0; Raw = 0; Txt = 0; Dense = 0; Packs = 0; Missing = 0
    Processed = 0; Failed = 0
}

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

    $p1_Raw   = Join-Path $baseDir "1_RAW"
    $p2_Txt   = Join-Path $baseDir "2_TXT"
    $p3_Dense = Join-Path $baseDir "3_TXT_dense"
    $p4_Packs = Join-Path $baseDir "4_Packs"

    foreach ($p in @($p1_Raw, $p2_Txt, $p3_Dense, $p4_Packs)) { 
        if (!(Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null } 
    }

    Write-Log "Traitement local rapide..." "Cyan" $logPrefix
    $newDense1 = Process-LocalFiles -RawDir $p1_Raw -TxtDir $p2_Txt -DenseDir $p3_Dense -Lang $chan.Lang -Prefix $logPrefix

    if ($syncChoice -eq "O" -or $syncChoice -eq "o") {
        Write-Log "Synchronisation YouTube..." "Cyan" $logPrefix
        Sync-YouTube -Url $chan.URL -RawDir $p1_Raw -YtDlp $ytDlp -Ffmpeg $ffmpegPath -Cookies $cookieArgsBase -Lang $chan.Lang -BaseDir $baseDir -LogPrefix $logPrefix
        
        Write-Log "Traitement des nouveautes..." "Cyan" $logPrefix
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
        Get-ChildItem -Path $allPacksDir -Filter ($chan.Prefix + "_ULTRA_*.txt") | Remove-Item -Force
        # Copie des packs locaux vers le dossier global
        Get-ChildItem -Path $p4_Packs -Filter "*.txt" | Copy-Item -Destination $allPacksDir -Force
    }

    # Aggregate stats
    $globalStats.Processed++
    $globalStats.Raw += (Get-ChildItem -LiteralPath $p1_Raw -Include "*.srt", "*.vtt" -Recurse).Count
    $globalStats.Txt += (Get-ChildItem -LiteralPath $p2_Txt -Filter "*.txt").Count
    $globalStats.Dense += (Get-ChildItem -LiteralPath $p3_Dense -Filter "*.txt").Count
    $globalStats.Packs += (Get-ChildItem -LiteralPath $p4_Packs -Filter "*.txt").Count
    
    $masterListPath = Join-Path $baseDir "youtube_master_list.txt"
    $missingListPath = Join-Path $baseDir "missing_videos.txt"
    if (Test-Path $masterListPath) { $globalStats.Master += (Get-Content $masterListPath | Where-Object { $_ -ne "" }).Count }
    if (Test-Path $missingListPath) { $globalStats.Missing += (Get-Content $missingListPath | Where-Object { $_ -ne "" }).Count }
}

# ==============================================================================
# DASHBOARD GLOBAL STATISTIQUE
# ==============================================================================
Write-Host "`n=================================================" -ForegroundColor Cyan
Write-Host "          RAPPORT GLOBAL DU PIPELINE v9.0" -ForegroundColor White
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
    Write-Host "Statut : $($globalStats.Missing) video(s) manquante(s) au total (voir missing_videos.txt)" -ForegroundColor Red
} else {
    Write-Host "Statut : Parfaitement a jour. Aucune video manquante." -ForegroundColor Green
}
Write-Host "Dossier global des packs       : $allPacksDir" -ForegroundColor Magenta
Write-Host "=================================================" -ForegroundColor Cyan
