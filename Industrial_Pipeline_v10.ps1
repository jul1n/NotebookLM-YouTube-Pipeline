# Industrial YouTube Transcription Pipeline v10.0
# Unified Industrial Suite for NotebookLM
# Combined: Main Pipeline + Language Diagnostic + Re-Subtitling Workflow

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

# Ensure core directories exist
foreach ($p in @($BinDir, $AllPacksDir, $LogsDir, $ReSubDir, $AudioDir, $ThumbDir, $OutputDir)) {
    if (!(Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
}

$threadLimit = 16
$userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36"
$global:pendingBlacklistUpdates = [System.Collections.Generic.List[PSObject]]::new()
$blacklistCandidates = [System.Collections.Generic.List[PSObject]]::new()

# ==============================================================================
# FONCTIONS PARTAGEES
# ==============================================================================

function Write-Log {
    param ($msg, $color = "White", $prefix = "SYSTEM")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMsg = "[$timestamp] [$prefix] $msg"
    $logFile = Join-Path $LogsDir "pipeline.log"
    $logMsg | Add-Content -LiteralPath $logFile -ErrorAction SilentlyContinue
    Write-Host "[$timestamp] [$prefix] " -NoNewline -ForegroundColor Gray
    Write-Host $msg -ForegroundColor $color
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
        $content = Get-Content $BlacklistPath -ErrorAction Stop
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

filter Count-Progress { $global:itemCount++; $_ }

# ==============================================================================
# MODULE 1: PIPELINE PRINCIPAL (SYNC & PACKS)
# ==============================================================================

function Sync-YouTube {
    param ($Url, $RawDir, $YtDlp, $Ffmpeg, $Cookies, $Lang, $BaseDir, $LogPrefix, $BlacklistPath, $RetryOnly)
    
    $masterListPath = Join-Path $BaseDir "youtube_master_list.txt"
    $missingListPath = Join-Path $BaseDir "missing_videos.txt"
    
    $blacklist = @()
    if (Test-Path $BlacklistPath) {
        $blRaw = Get-Content $BlacklistPath
        foreach ($line in $blRaw) {
            if ($line -match "^([a-zA-Z0-9_-]{11})") { $blacklist += $Matches[1] }
        }
    }

    $masterIds = @()
    if ($RetryOnly -and (Test-Path $missingListPath)) {
        $masterIds = Get-Content $missingListPath | Where-Object { $_ -ne "" }
    } else {
        Write-Log "Extraction de la liste des videos..." "Gray" $LogPrefix
        $masterIds = & $YtDlp --get-id --flat-playlist --playlist-end 2000 $Url 2>$null
        $masterIds | Out-File -LiteralPath $masterListPath -Encoding utf8
    }

    if ($null -eq $masterIds) { return 0 }
    
    $originalMasterCount = $masterIds.Count
    $masterIds = $masterIds | Where-Object { $_ -notin $blacklist }
    $ignoredByBlacklist = $originalMasterCount - $masterIds.Count
    if ($ignoredByBlacklist -gt 0) { Write-Log "$ignoredByBlacklist video(s) ignoree(s) (Blacklist)." "Gray" $LogPrefix }

    if (!$RetryOnly) {
        $localIds = [System.Collections.Generic.HashSet[string]]::new()
        $jsonFiles = Get-ChildItem -LiteralPath $RawDir -Filter "*.info.json"
        
        $rawFileMap = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach($f in [System.IO.Directory]::GetFiles($RawDir)) {
            $ext = [System.IO.Path]::GetExtension($f)
            if ($ext -eq ".srt" -or $ext -eq ".vtt") { [void]$rawFileMap.Add([System.IO.Path]::GetFileName($f)) }
        }

        foreach ($json in $jsonFiles) {
            $baseName = $json.Name -replace '\.info\.json$', ''
            $found = $false
            $checkSuffixes = if ($Lang -eq "auto") { @(".fr", ".en", "") } else { @(".$Lang", "") }
            foreach($suffix in $checkSuffixes) {
                if ($rawFileMap.Contains($baseName + $suffix + ".srt") -or $rawFileMap.Contains($baseName + $suffix + ".vtt")) {
                    $found = $true; break
                }
            }
            if ($found) {
                try { 
                    $jsonContent = [System.IO.File]::ReadAllText($json.FullName)
                    if ($jsonContent -match '"id":\s*"(.*?)"') { [void]$localIds.Add($Matches[1]) }
                } catch { }
            }
        }

        $toDownload = [System.Collections.Generic.List[string]]::new()
        foreach ($mid in $masterIds) { if (!($localIds.Contains($mid))) { $toDownload.Add($mid) } }
        $toDownload | Out-File -LiteralPath $missingListPath -Encoding utf8
    } else {
        if ($null -eq $masterIds -or $masterIds.Count -eq 0) { $toDownload = [System.Collections.Generic.List[string]]::new() }
        else { $toDownload = [System.Collections.Generic.List[string]]::new([string[]]$masterIds) }
    }

    if ($toDownload.Count -gt 0) {
        Write-Log "$($toDownload.Count) videos manquantes." "Yellow" $LogPrefix
        $errorCount = 0; $currentIndex = 1; $totalVideos = $toDownload.Count

        foreach ($id in $toDownload.ToArray()) {
            Write-Host "`n[$LogPrefix] [DOWNLOAD $currentIndex/$totalVideos] $id" -ForegroundColor White
            $vidUrl = "https://www.youtube.com/watch?v=" + $id
            $noSubsFound = $false; $currentTitle = "ID: $id"

            $dlpCmd = {
                & $YtDlp --user-agent $userAgent @Cookies `
                    --ffmpeg-location $Ffmpeg `
                    --write-auto-sub --write-info-json --ignore-errors `
                    --sub-langs ($Lang -eq "auto" ? "fr,en" : $Lang) --skip-download --convert-subs srt `
                    --min-sleep-interval 10 --max-sleep-interval 40 --sleep-requests 1 `
                    --download-archive (Join-Path $BaseDir "archive.txt") `
                    -o (Join-Path $RawDir "%(upload_date)s - %(title)s [%(id)s].%(ext)s") $vidUrl 2>&1
            }
            
            $outputLines = $dlpCmd.Invoke() | ForEach-Object {
                $line = $_.ToString()
                if ($line -match "(?i)sleeping .* seconds") { Write-Host "  $line" -ForegroundColor DarkMagenta }
                elseif ($line -match "There are no subtitles for the requested languages") { $noSubsFound = $true }
                elseif ($line -match "Writing video metadata as JSON to: .*\\(\d{8} - .*)\.info\.json") { $currentTitle = $Matches[1] }
                elseif ($line -match "(?i)ERROR: (.*)") { Write-Host "  [!] $($Matches[0])" -ForegroundColor Red }
                elseif ($line -match "(?i)WARNING: (.*)") { Write-Host "  [!] $($Matches[0])" -ForegroundColor Yellow }
                elseif ($line -match "(?i)(Writing video subtitles to|Destination): .*1_RAW\\\d{8} - (.*)\.(.*?)\.(vtt|srt)") {
                    $title = $Matches[2]; $idx = $line.IndexOf($title)
                    if ($idx -ge 0) {
                        Write-Host "  " -NoNewline
                        Write-Host $line.Substring(0, $idx) -NoNewline -ForegroundColor Gray
                        Write-Host $title -NoNewline -ForegroundColor Cyan
                        Write-Host $line.Substring($idx + $title.Length) -ForegroundColor Gray
                    } else { Write-Host "  $line" -ForegroundColor Gray }
                } else { Write-Host "  $line" -ForegroundColor DarkGray }
                $line
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
    return $ignoredByBlacklist
}

function Process-LocalFiles {
    param ($RawDir, $TxtDir, $DenseDir, $Lang, $Prefix)
    
    $rawFiles = Get-ChildItem -LiteralPath $RawDir -Filter "*.info.json"
    $newDenseCount = 0
    
    foreach ($json in $rawFiles) {
        $id = ""; if ($json.Name -match "\[([a-zA-Z0-9_-]{11})\]\.info\.json$") { $id = $Matches[1] }
        if (!$id) { continue }
        
        $baseName = $json.Name -replace '\.info\.json$', ''
        $txtPath = Join-Path $TxtDir ($baseName + ".txt")
        $densePath = Join-Path $DenseDir ($baseName + ".dense.txt")
        
        if (Test-Path $densePath) { continue }

        $subFile = $null
        $checkSuffixes = if ($Lang -eq "auto") { @(".fr", ".en", "") } else { @(".$Lang", "") }
        foreach ($suffix in $checkSuffixes) {
            $f = Join-Path $RawDir ($baseName + $suffix + ".srt")
            if (Test-Path $f) { $subFile = $f; break }
            $f = Join-Path $RawDir ($baseName + $suffix + ".vtt")
            if (Test-Path $f) { $subFile = $f; break }
        }

        if ($subFile) {
            try {
                $content = Get-Content -LiteralPath $subFile -Raw
                $txt = $content -replace '<.*?>', '' -replace '^\d+\s*$', '' -replace '^\d{2}:\d{2}:\d{2}.*', '' -replace '-->.*', ''
                $lines = $txt -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
                $cleanTxt = [System.Collections.Generic.HashSet[string]]::new()
                foreach ($l in $lines) { [void]$cleanTxt.Add($l) }
                $finalTxt = $cleanTxt -join " "
                
                $finalTxt | Out-File -LiteralPath $txtPath -Encoding utf8
                $jsonMeta = Get-Content -LiteralPath $json.FullName -Raw
                $denseContent = $jsonMeta.Trim() + "`r`n`r`n" + $finalTxt
                $denseContent | Out-File -LiteralPath $densePath -Encoding utf8
                $newDenseCount++
            } catch { }
        }
    }
    return $newDenseCount
}

function Build-Packs {
    param ($DenseDir, $PacksDir, $Prefix, $LogPrefix, $GlobalPacksDir)
    $denseFiles = Get-ChildItem -LiteralPath $DenseDir -Filter "*.txt" | Sort-Object Name
    $packsPlan = [System.Collections.Generic.List[PSObject]]::new()
    $currentBatch = [System.Collections.Generic.List[PSObject]]::new(); $currentWords = 0; $packNum = 1

    foreach ($file in $denseFiles) {
        $content = Get-Content -LiteralPath $file.FullName -Raw
        $wordCount = ($content -split "\s+" | Where-Object { $_ -ne "" }).Count
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
            foreach ($b in $plan.Files) { [void]$sb.AppendLine((Get-Content -LiteralPath $b.FullName -Raw)); [void]$sb.AppendLine("`r`n################################### SOURCE: $($b.BaseName) ###################################`r`n") }
            $sb.ToString() | Out-File -LiteralPath $pPath -Encoding utf8
            Copy-Item -LiteralPath $pPath -Destination $GlobalPacksDir -Force
        }
    }
}

function Repair-Packs {
    param ($BaseDir, $Prefix)
    $densePath = Join-Path $BaseDir "3_TXT_dense"
    if (!(Test-Path $densePath)) { return 0 }
    $files = Get-ChildItem -Path $densePath -Filter "*.txt"
    if ($files.Count -eq 0) { return 0 }
    $corrupted = foreach ($f in $files) {
        $content = [System.IO.File]::ReadAllText($f.FullName)
        if ($content -match '\{"id":' -or $content -match '"formats":' -or $content -match ([char]226 + [char]8364)) { $f.Name }
    }
    if ($corrupted.Count -gt 0) {
        foreach ($name in $corrupted) {
            Remove-Item -LiteralPath (Join-Path $BaseDir "2_TXT" $name) -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Join-Path $densePath $name) -Force -ErrorAction SilentlyContinue
        }
        return $corrupted.Count
    }
    return 0
}

function Clean-GlobalPacks {
    param ($GlobalPacksDir, $ValidPrefixes)
    if (!(Test-Path $GlobalPacksDir)) { return }
    Write-Host "`n[SYSTEME] Nettoyage du dossier global ALL_PACKS..." -ForegroundColor Gray
    Repair-Packs -BaseDir $GlobalPacksDir -Prefix "GLOBAL"
    $deprecatedDir = Join-Path $GlobalPacksDir "_OLD_OR_DEPRECATED"
    foreach ($f in Get-ChildItem -Path $GlobalPacksDir -Filter "*.txt") {
        $prefix = ($f.Name -split "_")[0]
        if ($ValidPrefixes -notcontains $prefix -and $f.Name -notmatch "^_") {
            if (!(Test-Path $deprecatedDir)) { New-Item -ItemType Directory -Path $deprecatedDir | Out-Null }
            Move-Item -LiteralPath $f.FullName -Destination $deprecatedDir -Force
        }
    }
}

# ==============================================================================
# MODULE 2: DIAGNOSTIC DE LANGUE
# ==============================================================================

function Run-LanguageDiagnostic {
    Write-Host "`n=================================================" -ForegroundColor Cyan
    Write-Host "   DIAGNOSTIC DE LANGUE ET FILTRAGE AUTO" -ForegroundColor Cyan
    Write-Host "=================================================" -ForegroundColor Cyan
    
    $idsToCheck = [System.Collections.Generic.HashSet[string]]::new()
    $log429 = Join-Path $LogsDir "429_errors.txt"
    if (Test-Path $log429) { foreach ($line in Get-Content $log429) { if ($line -match "^([a-zA-Z0-9_-]{11})") { [void]$idsToCheck.Add($Matches[1]) } } }
    foreach ($f in Get-ChildItem -Path $BaseDir -Recurse -Filter "missing_videos.txt") { foreach ($id in Get-Content $f.FullName) { if ($id -match "^[a-zA-Z0-9_-]{11}$") { [void]$idsToCheck.Add($id) } } }

    $currentBL = Get-Content $BlacklistPath
    $count = 0; $total = $idsToCheck.Count
    foreach ($id in $idsToCheck) {
        $count++; if ($currentBL -match [regex]::Escape($id)) { continue }
        Write-Host "[$count/$total] Checking $id... " -NoNewline
        try {
            $info = & $YtDlp --user-agent $userAgent --print "%(language)s|%(title)s" --no-warnings "https://www.youtube.com/watch?v=$id" 2>$null
            if (!$info) { Write-Host "Inaccessible" -ForegroundColor Gray; continue }
            $parts = $info -split '\|'; $lang = $parts[0]; $title = $parts[1]
            if ($lang -and !($lang.StartsWith("fr") -or $lang.StartsWith("en"))) {
                Write-Host "REJECTED ($lang) - $title" -ForegroundColor Red
                Update-BlacklistEntry -id $id -marker "[AUTO-LANG: $lang]" -metadata $title
            } else { Write-Host "KEEP ($lang)" -ForegroundColor Green }
        } catch { Write-Host "Error" -ForegroundColor Red }
        Start-Sleep -Milliseconds 300
    }
}

# ==============================================================================
# MODULE 3: RE-SUBTITLING WORKFLOW
# ==============================================================================

function Run-ReSubtitling {
    Write-Host "`n=================================================" -ForegroundColor Cyan
    Write-Host "   WORKFLOW RE-SUBTITLING (1FPS STATIC VIDEOS)" -ForegroundColor Cyan
    Write-Host "=================================================" -ForegroundColor Cyan
    
    $blContent = Get-Content $BlacklistPath
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
        if (!(Test-Path $audioPath)) {
            & $YtDlp --user-agent $userAgent --quiet --no-warnings -f "bestaudio[ext=m4a]/bestaudio" -o $audioPath "https://www.youtube.com/watch?v=$id"
            if (Test-Path $audioPath) { Update-BlacklistEntry -id $id -marker "[RE-SUB-AUDIO]" }
        }
        
        # Video 1fps
        if (Test-Path $audioPath -and !(Test-Path $videoPath)) {
            # On recupere la vignette
            & $ytDlp --user-agent $userAgent --quiet --no-warnings --write-thumbnail --skip-download -o (Join-Path $ThumbDir $id) "https://www.youtube.com/watch?v=$id"
            $thumb = Get-ChildItem -Path $ThumbDir -Filter "$id.*" | Where-Object { $_.Extension -ne ".m4a" } | Select-Object -First 1
            $tIn = if ($thumb) { $thumb.FullName } else { "color=c=black:s=1280x720:r=1" }
            
            if ($thumb) {
                & $Ffmpeg -y -loglevel error -probesize 100M -analyzeduration 100M -loop 1 -framerate 1 -i $tIn -i $audioPath -c:v libx264 -tune stillimage -preset ultrafast -pix_fmt yuv420p -c:a copy -shortest $videoPath
            } else {
                & $Ffmpeg -y -loglevel error -probesize 100M -analyzeduration 100M -f lavfi -i $tIn -i $audioPath -c:v libx264 -tune stillimage -preset ultrafast -pix_fmt yuv420p -c:a copy -shortest $videoPath
            }
        }
        
        if (Test-Path $videoPath) { $success++; Update-BlacklistEntry -id $id -marker "[RE-SUB-VIDEO]" } else { $failed++ }
    }
}

# ==============================================================================
# MENU PRINCIPAL
# ==============================================================================

while ($true) {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Magenta
    Write-Host "      INDUSTRIAL PIPELINE v10.0 UNIFIED" -ForegroundColor White
    Write-Host "=================================================" -ForegroundColor Magenta
    Write-Host "1. Ajouter et traiter une chaine (Manuel)"
    Write-Host "2. Rafraichir toutes les chaines (Auto)"
    Write-Host "3. Retenter uniquement les echecs (Rapide)"
    Write-Host "4. Reparer les artefacts JSON (Diagnostic)"
    Write-Host "5. Lancer le diagnostic de LANGUE (Filtrage)"
    Write-Host "6. Lancer le workflow RE-SUBTITLING (Videos 1fps)"
    Write-Host "7. Maintenance GLOBALE (Nettoyage + Diagnostic)"
    Write-Host "0. Quitter"
    Write-Host "-------------------------------------------------"
    $choice = Read-Host "Votre choix"

    if ($choice -eq "0") { break }
    
    # Configuration Load
    $channels = Import-Csv $ConfigPath -Delimiter ";"
    
    if ($choice -match "[12347]") {
        $mode = if ($choice -eq "7") { "3" } else { $choice }
        $targets = if ($choice -eq "1") { 
            $url = Read-Host "URL de la chaine"; $pref = Read-Host "Prefixe"; @([PSCustomObject]@{ URL=$url; Prefixe=$pref; Lang="auto" })
        } else { $channels }

        # Cleanup before start
        $validPrefixes = $channels | ForEach-Object { $_.Prefixe }
        Clean-GlobalPacks -GlobalPacksDir $AllPacksDir -ValidPrefixes $validPrefixes
        
        foreach ($chan in $targets) {
            Write-Host "`n>>> CHAINE : $($chan.URL)" -ForegroundColor Cyan
            $folder = ($chan.Prefixe -replace "[^a-zA-Z0-9]", "_").Trim()
            $cDir = Join-Path $BaseDir $folder
            $p1 = Join-Path $cDir "1_RAW"; $p2 = Join-Path $cDir "2_TXT"; $p3 = Join-Path $cDir "3_TXT_dense"; $p4 = Join-Path $cDir "4_Packs"
            foreach ($p in @($p1,$p2,$p3,$p4)) { if (!(Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null } }

            if ($choice -eq "4") { Repair-Packs -BaseDir $cDir -Prefix $chan.Prefixe }
            
            $ignored = Sync-YouTube -Url $chan.URL -RawDir $p1 -YtDlp $YtDlp -Ffmpeg $Ffmpeg -Cookies @() -Lang $chan.Lang -BaseDir $cDir -LogPrefix $chan.Prefixe -BlacklistPath $BlacklistPath -RetryOnly ($mode -eq "3")
            Process-LocalFiles -RawDir $p1 -TxtDir $p2 -DenseDir $p3 -Lang $chan.Lang -Prefix $chan.Prefixe
            Build-Packs -DenseDir $p3 -PacksDir $p4 -Prefix $chan.Prefixe -LogPrefix $chan.Prefixe -GlobalPacksDir $AllPacksDir
            
            # Rapport
            $master = (Get-SafeContent (Join-Path $cDir "youtube_master_list.txt")).Count
            $missing = (Get-SafeContent (Join-Path $cDir "missing_videos.txt")).Count
            $raw = (Get-ChildItem $p1 -Filter "*.info.json").Count
            Write-Host "`n--- BILAN $($chan.Prefixe) ---" -ForegroundColor Green
            Write-Host "  Total: $master | Pretes: $raw | Ignorees: $ignored | Manquantes: $missing" -ForegroundColor White
        }
        if ($choice -eq "7") { Run-LanguageDiagnostic }
    }
    elseif ($choice -eq "5") { Run-LanguageDiagnostic }
    elseif ($choice -eq "6") { Run-ReSubtitling }
    
    Write-Host "`nAppuyez sur une touche pour continuer..."
    $null = [Console]::ReadKey()
}
