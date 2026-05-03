# RE-SUBTITLER SUPPLEMENTARY SCRIPT
# Purpose: Process videos without subtitles, convert to static-image videos for YouTube re-upload
# ==============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8

$binPath = Join-Path $PSScriptRoot "BIN"
$ytDlp = Join-Path $binPath "yt-dlp.exe"
$ffmpegPath = Join-Path $binPath "ffmpeg.exe"
$userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

$workDir = Join-Path $PSScriptRoot "_RE_SUBTITLING_WORK"
$audioDir = Join-Path $workDir "1_AUDIO"
$thumbDir = Join-Path $workDir "2_THUMBS"
$outputDir = Join-Path $workDir "3_VIDEO_TO_UPLOAD"
$registryPath = Join-Path $workDir "mapping_registry.json"

function Get-SafeContent($path) {
    $p = $path
    if ($p.Length -gt 240 -and !$p.StartsWith("\\?\")) { $p = "\\?\$p" }
    return Get-Content -LiteralPath $p -Raw
}

foreach ($p in @($workDir, $audioDir, $thumbDir, $outputDir)) {
    if (!(Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
}

$blacklistPath = Join-Path $PSScriptRoot "blacklist.txt"
$configFile = Join-Path $PSScriptRoot "channels_config.csv"

$logFile = Join-Path $workDir "re_subtitler.log"

function Write-Log($msg, $color = "White") {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] $msg" | Add-Content -LiteralPath $logFile -ErrorAction SilentlyContinue
    Write-Host "[$timestamp] $msg" -ForegroundColor $color
}


function Update-BlacklistEntry($id, $marker, $metadata = "") {
    if (!(Test-Path $blacklistPath)) { return }
    
    # On ajoute la demande a la file d'attente
    $global:pendingBlacklistUpdates.Add([PSCustomObject]@{ ID=$id; Marker=$marker; Metadata=$metadata })
    
    # On essaie de vider la file
    Flush-BlacklistUpdates
}

function Flush-BlacklistUpdates {
    if ($global:pendingBlacklistUpdates.Count -eq 0) { return }
    
    try {
        # On essaie de lire le fichier
        $content = Get-Content $blacklistPath -ErrorAction Stop
        $newContent = [System.Collections.Generic.List[string]]::new($content)
        $processedIndices = [System.Collections.Generic.List[int]]::new()
        
        $i = 0
        foreach ($update in $global:pendingBlacklistUpdates) {
            $found = $false
            for ($lineIdx = 0; $lineIdx -lt $newContent.Count; $lineIdx++) {
                if ($newContent[$lineIdx].Trim().StartsWith($update.ID)) {
                    $line = $newContent[$lineIdx]
                    $base = ($line -split "#")[0].Trim()
                    $existingComment = if ($line -match "#") { ($line -split "#", 2)[1].Trim() } else { "" }
                    $cleanComment = $existingComment -replace "\[RE-SUB-AUDIO\]", "" -replace "\[RE-SUB-VIDEO\]", "" -replace "\[INACCESSIBLE-PREMIUM-CONTENT\]", ""
                    
                    $finalMeta = if (![string]::IsNullOrWhiteSpace($update.Metadata)) { $update.Metadata } else { $cleanComment.Trim() }
                    $newComment = "$($finalMeta.Trim()) $($update.Marker)".Trim()
                    
                    $newContent[$lineIdx] = "$base # $newComment"
                    $found = $true; break
                }
            }
            if (!$found) {
                $newContent.Add("$($update.ID) # $($update.Metadata) $($update.Marker)".Trim())
            }
            [void]$processedIndices.Add($i)
            $i++
        }
        
        # On essaie d'ecrire
        $newContent | Out-File $blacklistPath -Encoding utf8 -ErrorAction Stop
        
        # Succes ! On vide les elements traites de la file d'attente
        $global:pendingBlacklistUpdates.Clear()
    } catch {
        # Echec (fichier verrouille), on laisse les elements dans la file pour le prochain essai
        # On ne bloque pas le script
    }
}

# 1. PARSE BLACKLIST & EXTRACT PERSISTED METADATA
Write-Log "Lecture de la blacklist et des metadonnees persistees..." "Cyan"
$idsToProcess = @()
$persistedMapping = @{} # ID -> PSCustomObject

if (Test-Path $blacklistPath) {
    $blContent = Get-Content -LiteralPath $blacklistPath
    foreach ($line in $blContent) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match "\[\d{4}-\d{2}-\d{2}\]") { continue }
        if ($line -match "\[RE-SUB-VIDEO\]") { continue }
        
        $id = ($line -split "#")[0].Trim()
        if (!$id) { continue }
        
        $idsToProcess += $id
        
        # Tenter d'extraire les metadonnees deja presentes : [PREF] DATE - TITLE
        if ($line -match "#\s*\[(.*?)\]\s*(\d{8})\s*-\s*(.*?)(\[|$)") {
            $persistedMapping[$id] = [PSCustomObject]@{
                Original_ID = $id
                Original_Prefix = $Matches[1]
                Date = $Matches[2]
                Title = $Matches[3].Trim()
                Status = if ($line -match "\[RE-SUB-AUDIO\]") { "AudioDownloaded" } else { "Pending" }
            }
        }
    }
}
Write-Log "$($idsToProcess.Count) IDs a traiter." "Green"

# 2. OPTIMIZED METADATA DISCOVERY (One-pass indexing)
$missingMetaIds = $idsToProcess | Where-Object { !($persistedMapping.ContainsKey($_)) }

if ($missingMetaIds.Count -gt 0) {
    Write-Log "Indexation unique des dossiers pour $($missingMetaIds.Count) IDs manquants..." "Yellow"
    $allJsonFiles = Get-ChildItem -LiteralPath $PSScriptRoot -Filter "*.info.json" -Recurse | Where-Object { $_.FullName -match "1_RAW" }
    
    $config = Import-Csv -Path $configFile -Delimiter ";" -Encoding utf8
    
    foreach ($id in $missingMetaIds) {
        $json = $allJsonFiles | Where-Object { $_.Name -match "\[$id\]" } | Select-Object -First 1
        if ($json) {
            $jsonPath = $json.FullName
            $channelFolder = $json.Directory.Parent.Name
            if ($jsonPath.Length -gt 240 -and !$jsonPath.StartsWith("\\?\")) { $jsonPath = "\\?\$jsonPath" }
            $info = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
            
            $prefix = "UNK"
            foreach ($row in $config) {
                $safeName = ($row.URL -replace "https://www.youtube.com/","" -replace "@","" -replace "/videos","" -replace "[^a-zA-Z0-9]", "_").Trim()
                if ($channelFolder -like "*$safeName*") { $prefix = $row.Prefixe; break }
            }

            $persistedMapping[$id] = [PSCustomObject]@{
                Original_ID = $id
                Original_Channel_Folder = $channelFolder
                Original_Prefix = $prefix
                Title = $info.title
                Date = $info.upload_date
                Status = "Pending"
                Local_JSON = $json.FullName
            }
            
            # Sauvegarder immediatement dans la blacklist pour ne plus avoir a scanner
            $metaString = "[$prefix] $($info.upload_date) - $($info.title)"
            Update-BlacklistEntry -id $id -marker "" -metadata $metaString
        } else {
            Write-Log "ID $id non trouve localement. Tentative de recuperation via YouTube..." "Cyan"
            try {
                $ytMeta = & $ytDlp --user-agent $userAgent --quiet --no-warnings --print "%(title)s|%(upload_date)s|%(uploader)s|%(uploader_id)s" "https://www.youtube.com/watch?v=$id" 2>$null
                if ($ytMeta -match "\|") {
                    $parts = $ytMeta -split "\|"
                    $yTitle = $parts[0]
                    $yDate = $parts[1]
                    $yUploader = $parts[2]
                    
                    # Tenter de trouver le prefixe
                    $prefix = "UNK"
                    foreach ($row in $config) {
                        if ($row.URL -like "*$yUploader*" -or $row.URL -like "*$($parts[3])*") {
                            $prefix = $row.Prefixe; break
                        }
                    }

                    $persistedMapping[$id] = [PSCustomObject]@{
                        Original_ID = $id
                        Original_Prefix = $prefix
                        Title = $yTitle
                        Date = $yDate
                        Status = "Pending"
                    }
                    $metaString = "[$prefix] $yDate - $yTitle"
                    Update-BlacklistEntry -id $id -marker "" -metadata $metaString
                    Write-Log "  > Metadonnees recuperees via YouTube : $metaString" "Green"
                } else {
                    Write-Log "  [!] Video inaccessible (Donnees vides). Marquage Blacklist." "Yellow"
                    Update-BlacklistEntry -id $id -marker "[INACCESSIBLE-PREMIUM-CONTENT]"
                }
            } catch {
                Write-Log "  [!] Video inaccessible (Erreur YouTube). Marquage Blacklist." "Yellow"
                Update-BlacklistEntry -id $id -marker "[INACCESSIBLE-PREMIUM-CONTENT]"
            }
        }
    }
}

# Charger le registre global pour la compatibilite
$mapping = @()
if (Test-Path $registryPath) { $mapping = Get-SafeContent $registryPath | ConvertFrom-Json }

$finalItems = @()
foreach ($id in $idsToProcess) {
    if ($persistedMapping.ContainsKey($id)) {
        $finalItems += $persistedMapping[$id]
    }
}

# 3. PROCESSING
$total = $finalItems.Count
$successCount = 0
$failedCount = 0
$currentIndex = 0

foreach ($item in $finalItems | Where-Object { $_.Status -ne "Done" }) {
    $currentIndex++
    $remaining = $total - $currentIndex
    $statsPrefix = "[$currentIndex/$total] [OK: $successCount | KO: $failedCount | Reste: $remaining]"
    
    $safeTitle = $item.Title -replace '[^a-zA-Z0-9\s\-]', ''
    $fileNameBase = "$($item.Original_Prefix) $($item.Date) - $($safeTitle) [$($item.Original_ID)]"
    
    Write-Log "$statsPrefix Traitement : $fileNameBase" "Cyan"
    
    $audioPath = Join-Path $audioDir "$($item.Original_ID).m4a"
    $thumbPath = Join-Path $thumbDir "$($item.Original_ID).jpg"
    $videoPath = Join-Path $outputDir "$fileNameBase.mp4"

    # A. Download Audio
    if (!(Test-Path $audioPath)) {
        Write-Log "  > Telechargement Audio..." "Gray"
        & $ytDlp --user-agent $userAgent --quiet --no-warnings -f "bestaudio[ext=m4a]/bestaudio" -o $audioPath "https://www.youtube.com/watch?v=$($item.Original_ID)"
        if (Test-Path $audioPath) {
            Update-BlacklistEntry -id $item.Original_ID -marker "[RE-SUB-AUDIO]"
        }
    }

    # B. Download Thumbnail
    $thumbFile = Get-ChildItem -Path $thumbDir -Filter "$($item.Original_ID).*" | Where-Object { $_.Extension -ne ".m4a" } | Select-Object -First 1
    if (!$thumbFile) {
        Write-Log "  > Telechargement Thumbnail..." "Gray"
        # On force la recuperation de la vignette au format webp ou jpg
        & $ytDlp --user-agent $userAgent --quiet --no-warnings --write-thumbnail --skip-download -o (Join-Path $thumbDir $item.Original_ID) "https://www.youtube.com/watch?v=$($item.Original_ID)"
        $thumbFile = Get-ChildItem -Path $thumbDir -Filter "$($item.Original_ID).*" | Where-Object { $_.Extension -ne ".m4a" } | Select-Object -First 1
    }
    
    if ($thumbFile) { 
        $thumbPath = $thumbFile.FullName 
    } else { 
        Write-Log "  [!] Thumbnail introuvable. Utilisation d'un fond noir." "Yellow"
        $thumbPath = "black"
    }
    
    # C. Assembly with FFmpeg
    if (!(Test-Path $videoPath)) {
        Write-Log "  > Assemblage Video (FFmpeg - UltraFast 1fps)..." "Yellow"
        
        # On utilise -probesize et -analyzeduration pour eviter les erreurs de buffer sur les fichiers longs
        # On utilise -c:a copy car l'audio m4a est deja compatible MP4 (evite le re-encodage et les crashs)
        if ($thumbPath -eq "black") {
            & $ffmpegPath -y -loglevel error -hide_banner -probesize 100M -analyzeduration 100M -f lavfi -i color=c=black:s=1280x720:r=1 -i $audioPath -c:v libx264 -tune stillimage -preset ultrafast -pix_fmt yuv420p -c:a copy -shortest $videoPath
        } else {
            & $ffmpegPath -y -loglevel error -hide_banner -probesize 100M -analyzeduration 100M -loop 1 -framerate 1 -i $thumbPath -i $audioPath -c:v libx264 -tune stillimage -preset ultrafast -pix_fmt yuv420p -c:a copy -shortest $videoPath
        }
    }

    if (Test-Path $videoPath) {
        $item.Status = "Done"
        $item.Generated_Filename = "$fileNameBase.mp4"
        $mapping | ConvertTo-Json -Depth 5 | Out-File $registryPath -Encoding utf8
        Update-BlacklistEntry -id $item.Original_ID -marker "[RE-SUB-VIDEO]"
        $successCount++
        Write-Log "  > TERMINE : $videoPath" "Green"
    } else {
        $failedCount++
        Write-Log "  [!] ECHEC de la preparation pour $fileNameBase" "Red"
    }
}

Write-Log "-------------------------------------------------"
Write-Log "FIN DU WORKFLOW" "White"
Write-Log "Total traite : $total" "Cyan"
Write-Log "Succes       : $successCount" "Green"
Write-Log "Echecs       : $failedCount" "Red"
Write-Log "-------------------------------------------------"

Write-Log "Workflow de preparation termine." "White"

# 4. FUNCTION FOR IMPORTING SUBTITLES (To be called manually or added to a menu)
function Import-NewSubtitles {
    param ($SourceDir)
    
    Write-Log "Importation des nouveaux sous-titres depuis $SourceDir..." "Cyan"
    $srtFiles = Get-ChildItem -Path $SourceDir -Filter "*.srt"
    
    foreach ($srt in $srtFiles) {
        # Extraire l'ID original du nom de fichier (on s'attend a ce qu'il soit entre crochets)
        if ($srt.Name -match "\[([a-zA-Z0-9_-]{11})\]") {
            $origId = $Matches[1]
            $match = $mapping | Where-Object { $_.Original_ID -eq $origId }
            
            if ($match) {
                $targetDir = Join-Path $PSScriptRoot (Join-Path $match.Original_Channel_Folder "1_RAW")
                $newName = (Get-Item $match.Local_JSON).BaseName + ".srt"
                $destPath = Join-Path $targetDir $newName
                
                Write-Log "  > Copie de $($srt.Name) vers $destPath" "Green"
                Copy-Item $srt.FullName $destPath -Force
            } else {
                Write-Log "  > ID $origId non trouve dans le registre." "Yellow"
            }
        }
    }
}

Write-Host "`nASTUCE: Pour importer les sous-titres une fois telecharges :" -ForegroundColor Gray
Write-Host "Import-NewSubtitles -SourceDir 'C:\chemin\vers\vos\nouveaux\srts'" -ForegroundColor White
