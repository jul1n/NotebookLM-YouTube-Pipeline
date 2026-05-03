# PIPELINE DE CONNAISSANCES v8.0 - UNIFIE & MULTITHREADING (PS7+)
# ==============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8

Clear-Host
$globalLog = Join-Path $PSScriptRoot "pipeline_operations.log"

function Write-Log($msg, $color = "White") {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] $msg" | Add-Content -LiteralPath $globalLog
    Write-Host "[$timestamp] $msg" -ForegroundColor $color
}

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "      PIPELINE DE CONNAISSANCES v8.0" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "`n"

# 1. CONFIGURATION INTERACTIVE
$url = Read-Host "URL de la chaine YouTube"
$abbrev = Read-Host "Prefixe pour les packs (ex: YC)"

$langChoice = Read-Host "Langue des sous-titres (Tapez 'fr' pour Francais, 'en' pour Anglais)"
if ($langChoice -notin @('fr', 'en')) {
    Write-Host "Choix invalide. Par defaut, 'fr' sera utilise." -ForegroundColor Yellow
    $langChoice = 'fr'
}

$browserChoice = Read-Host "Quel navigateur utilisez-vous (chrome, edge, firefox, txt pour un fichier texte, ou none pour ignorer) ?"
if ([string]::IsNullOrWhiteSpace($browserChoice)) { $browserChoice = 'none' }
$browserChoice = $browserChoice.ToLower()

$cookieArgs = @()
if ($browserChoice -eq 'txt') {
    $cookiePath1 = Join-Path $PSScriptRoot "cookies.txt"
    $cookiePath2 = Join-Path $PSScriptRoot "cookie.txt"
    if (Test-Path $cookiePath1) {
        $cookieArgs = @("--cookies", $cookiePath1)
        Write-Host "Utilisation du fichier cookies.txt" -ForegroundColor Green
    } elseif (Test-Path $cookiePath2) {
        $cookieArgs = @("--cookies", $cookiePath2)
        Write-Host "Utilisation du fichier cookie.txt" -ForegroundColor Green
    } else {
        Write-Host "Fichier cookies.txt introuvable dans le dossier ! Mode sans cookies active." -ForegroundColor Red
    }
} elseif ($browserChoice -ne 'none') {
    $cookieArgs = @("--cookies-from-browser", $browserChoice)
}

$binPath = Join-Path $PSScriptRoot "BIN"
$ytDlp = Join-Path $binPath "yt-dlp.exe"
$ffmpegPath = Join-Path $binPath "ffmpeg.exe"
$userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# Detection et creation des dossiers
Write-Log "Recuperation des informations de la chaine..." "Cyan"
try {
    # On retire le 2>$null pour voir la vraie erreur de yt-dlp dans la console
    $channelName = & $ytDlp --ffmpeg-location $ffmpegPath --user-agent $userAgent @cookieArgs --get-filename -o "%(uploader)s" $url --playlist-items 1
    if ([string]::IsNullOrWhiteSpace($channelName)) {
        throw "Impossible de recuperer le nom de la chaine. Verifiez l'URL ou vos cookies."
    }
} catch {
    Write-Log "Erreur yt-dlp : $($_.Exception.Message)" "Red"
    Write-Host "Utilisation d'un nom par defaut 'Channel_Data'." -ForegroundColor Yellow
    $channelName = "Channel_Data"
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

# ==============================================================================
# PHASE A : TRAITEMENT DE L'EXISTANT (1_RAW -> 2_TXT -> 3_TXT_dense)
# ==============================================================================
Write-Log "`n--- PHASE A : TRAITEMENT DES FICHIERS LOCAUX (Dossier 1_RAW) ---" "Cyan"
$srtFiles = Get-ChildItem -LiteralPath $p1_Raw -Filter "*.srt"
Write-Log "Fichiers RAW trouves : $($srtFiles.Count)" "Yellow"

if ($srtFiles.Count -gt 0) {
    Write-Log "Début du traitement parallèle (PS7+)..." "Gray"
    
    # We use ForEach-Object -Parallel for PS7+. 
    # Variables outside the parallel block need the $using: scope modifier.
    $srtFiles | ForEach-Object -Parallel {
        $file = $_
        $srtFile = $file.FullName
        $lang = $using:langChoice
        
        # Determine json file path
        $extRegex = '\.' + $lang + '\.srt$|\.srt$'
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
        
        $destPath2 = Join-Path ($using:p2_Txt) $txtFileName
        $destPath3 = Join-Path ($using:p3_Dense) $txtFileName

        # 1. Passage RAW -> TXT (Si absent)
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
                Write-Host "V1 cree : $($file.Name)" -ForegroundColor Gray
            } catch { 
                Write-Host "Erreur V1 sur $($file.Name) : $($_.Exception.Message)" -ForegroundColor Red
            }
        }

        # 2. Passage TXT -> DENSE (Si absent)
        if ((Test-Path -LiteralPath $destPath2) -and !(Test-Path -LiteralPath $destPath3)) {
            try {
                $content = Get-Content -LiteralPath $destPath2 -Raw
                $parts = $content -split "===================================="
                if ($parts.Count -ge 3) {
                    $header = "====================================" + $parts[1] + "===================================="
                    $transcript = ""
                    for ($i = 2; $i -lt $parts.Count; $i++) { $transcript += $parts[$i] }
                    
                    # Nettoyage amélioré : supprime les crochets, chevrons orphelins, répétitions de mots simples, et espaces multiples
                    $dense = $transcript -replace '\[.*?\]', '' -replace '&[a-z]+;', '' -replace '<[^>]*>?', '' -replace '(?i)\b(\w+)(?:\s+\1\b)+', '$1' -replace "[\r\n\t]+", " " -replace '\s{2,}', ' '
                    
                    $header.Trim() + "`r`n`r`n" + $dense.Trim() | Out-File -LiteralPath $destPath3 -Encoding utf8
                    Write-Host "V2 Dense cree : $($file.Name)" -ForegroundColor Gray
                }
            } catch { 
                Write-Host "Erreur V2 sur $txtFileName : $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    } -ThrottleLimit 10
}

# ==============================================================================
# PHASE B : SYNCHRONISATION OPTIONNELLE (YouTube -> 1_RAW)
# ==============================================================================
Write-Host "`n"
$syncChoice = Read-Host "Souhaitez-vous verifier si de nouvelles videos sont sur YouTube ? (O/N)"
if ($syncChoice -eq "O") {
    Write-Log "--- PHASE B : SYNCHRONISATION YOUTUBE (MODE SECURISE) ---" "Cyan"
    
    Write-Host "Recherche des nouveautes..." -ForegroundColor Gray
    try {
        $scan = & $ytDlp --ffmpeg-location $ffmpegPath --user-agent $userAgent @cookieArgs --flat-playlist --match-filter "duration > 60" --print "%(id)s" $url
        $masterIds = $scan -split "`r`n" | Where-Object { $_ -ne "" }
        
        $localIds = Get-ChildItem -LiteralPath $p1_Raw -Filter "*.info.json" | ForEach-Object {
            try { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).id } catch { $null }
        }
        
        $toDownload = New-Object System.Collections.Generic.List[string]
        foreach ($mid in $masterIds) { 
            if ($mid -notin $localIds) { $toDownload.Add($mid) } 
        }

        if ($toDownload.Count -gt 0) {
            Write-Log "$($toDownload.Count) nouvelles videos detectees." "Yellow"
            $errorCount = 0
            foreach ($id in $toDownload) {
                Write-Host "`n[DOWNLOAD] $id" -ForegroundColor Cyan
                $vidUrl = "https://www.youtube.com/watch?v=" + $id
                
                # Utilisation des paramètres de sleep natifs de yt-dlp pour simuler un comportement humain au lieu d'un Start-Sleep en PowerShell
                & $ytDlp --user-agent $userAgent @cookieArgs `
                    --ffmpeg-location $ffmpegPath `
                    --write-auto-sub --write-info-json `
                    --sub-langs $langChoice --skip-download --convert-subs srt `
                    --min-sleep-interval 10 --max-sleep-interval 45 --sleep-requests 2 `
                    --download-archive (Join-Path $baseDir "archive.txt") `
                    -o (Join-Path $p1_Raw "%(upload_date)s - %(title)s.%(ext)s") $vidUrl
                
                if ($LASTEXITCODE -ne 0) {
                    $errorCount++
                    Write-Log "Attention: Erreur de telechargement sur $id. Echecs consecutifs: $errorCount/3" "Red"
                    if ($errorCount -ge 3) {
                        Write-Log "3 echecs consecutifs. Blocage YouTube probable." "Yellow"
                        Write-Log "Mise en pause automatique du script pendant 15 minutes (900 secondes)..." "Cyan"
                        Start-Sleep -Seconds 900
                        $errorCount = 0 # Réinitialise après la pause
                    }
                } else {
                    $errorCount = 0 # Réinitialise si un téléchargement réussit
                }
            }
            Write-Host "`nSynchronisation terminee. Relancez le script pour traiter ces nouveaux fichiers." -ForegroundColor Green
        } else {
            Write-Log "Aucune nouvelle video a telecharger." "Green"
        }
    } catch {
        Write-Log "Erreur lors de la synchronisation : $($_.Exception.Message)" "Red"
    }
}

# ==============================================================================
# PHASE C : ANALYSE DE L ARCHITECTURE
# ==============================================================================
Write-Log "`n--- PHASE C : ANALYSE DE L ARCHITECTURE ---" "Cyan"
$denseFiles = Get-ChildItem -LiteralPath $p3_Dense -Filter "*.txt" | Sort-Object Name
$packsPlan = @(); $currentBatch = @(); $currentWords = 0; $packNum = 1

foreach ($file in $denseFiles) {
    try {
        $content = Get-Content -LiteralPath $file.FullName -Raw
        $wordCount = ($content -split "\s+" | Where-Object { $_ -ne "" }).Count
        $msgScan = "  [SCAN] {0} ({1} mots)..." -f $file.Name, $wordCount
        Write-Host $msgScan -ForegroundColor Gray
        
        if (($currentWords + $wordCount) -gt 500000 -and $currentBatch.Count -gt 0) {
            $packsPlan += [PSCustomObject]@{
                ID = $packNum; Files = $currentBatch; TotalWords = $currentWords
                Start = $currentBatch[0].Name.Substring(0,8); End = $currentBatch[-1].Name.Substring(0,8)
            }
            $packNum++; $currentBatch = @(); $currentWords = 0
        }
        $currentBatch += $file
        $currentWords += $wordCount
    } catch {
        Write-Log "Erreur lors de l'analyse de $($file.Name) : $($_.Exception.Message)" "Red"
    }
}

if ($currentBatch.Count -gt 0) {
    $packsPlan += [PSCustomObject]@{
        ID = $packNum; Files = $currentBatch; TotalWords = $currentWords
        Start = $currentBatch[0].Name.Substring(0,8); End = $currentBatch[-1].Name.Substring(0,8)
    }
}

Write-Host "`n[PLAN DE BATAILLE ETABLI]" -ForegroundColor Green
foreach($p in $packsPlan) {
    $msgPack = "  > Pack {0} : {1} au {2} | {3} videos | {4} mots" -f $p.ID, $p.Start, $p.End, $p.Files.Count, $p.TotalWords
    Write-Host $msgPack -ForegroundColor Gray
}

# ==============================================================================
# PHASE D : FUSION ET ECRITURE
# ==============================================================================
Write-Log "`n--- PHASE D : FUSION ET ECRITURE ---" "Cyan"
foreach ($plan in $packsPlan) {
    try {
        $pName = $abbrev + "_ULTRA_" + $plan.ID.ToString("00") + "_(" + $plan.Start + "-au-" + $plan.End + ").txt"
        $pPath = Join-Path $p4_Packs $pName
        Write-Host "Traitement Pack $($plan.ID)... " -ForegroundColor Yellow -NoNewline
        
        if (Test-Path -LiteralPath $pPath) { Remove-Item -LiteralPath $pPath -Force }

        foreach ($b in $plan.Files) {
            Get-Content -LiteralPath $b.FullName -Raw | Add-Content -LiteralPath $pPath
            $sep = "`r`n`r`n###################################`r`nSOURCE: " + $b.BaseName + "`r`n###################################`r`n`r`n"
            $sep | Add-Content -LiteralPath $pPath
        }
        Write-Host "[OK]" -ForegroundColor Green
    } catch {
        Write-Log "Erreur lors de la fusion du pack $($plan.ID) : $($_.Exception.Message)" "Red"
    }
}

Write-Log "`nPIPELINE TERMINE. Fichiers prets dans 4_Packs." "Green"
