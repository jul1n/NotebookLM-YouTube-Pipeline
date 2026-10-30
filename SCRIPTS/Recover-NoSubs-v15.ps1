# Recover-NoSubs-v15.ps1 (v15.0 Industrial Center)
# Téléchargement MP3 -> Conversion MP4 (1fps) pour upload externe.

$PSScriptDir = Split-Path $PSCommandPath -Parent
. (Join-Path $PSScriptDir "Global-Paths.ps1")

$Ffmpeg = Join-Path $BinDir "ffmpeg.exe"
$OutputDir = Join-Path $ProjectRoot "_UPLOAD_FOR_SUBS"
if (!(Test-Path $OutputDir)) { New-Item $OutputDir -ItemType Directory | Out-Null }

Write-Host "--- RECUPERATION AUDIO -> MP4 v15 ---" -ForegroundColor Cyan

# 1. Sélection des vidéos confirmées sans sous-titres
$sql = "SELECT v.youtube_id, v.title, c.prefix FROM videos v JOIN channels c ON v.channel_id = c.id WHERE v.status = 'DIAG_NO_SUBS' LIMIT 50;"
$jsonRaw = & $Sqlite -json $DbFile $sql
if ($jsonRaw) { $videos = $jsonRaw -join "" | ConvertFrom-Json }

if (!$videos) {
    Write-Host "Aucune vidéo à traiter (lancez d'abord Probe-DataGaps-v15.ps1)." -ForegroundColor Yellow
    exit
}

foreach ($v in $videos) {
    $id = $v.youtube_id
    $safeTitle = $v.title -replace '[\\/:*?"<>|]', '_'
    $chan = $v.prefix
    
    Write-Host "[RECOVERY] $id : $safeTitle" -ForegroundColor Blue
    
    $tmpAudio = Join-Path $TempDir "$id.m4a"
    $tmpThumb = Join-Path $TempDir "$id.jpg"
    $finalMp4 = Join-Path $OutputDir "[$chan] $safeTitle [$id].mp4"
    
    if (Test-Path $finalMp4) { Write-Host "  Déjà fait." -ForegroundColor Gray; continue }

    # A. Téléchargement Audio + Thumbnail
    & $YtDlp @YtDlpArgs --quiet --no-warnings -f "bestaudio[ext=m4a]/bestaudio" --write-thumbnail --skip-download -o (Join-Path $TempDir $id) "https://www.youtube.com/watch?v=$id"
    & $YtDlp @YtDlpArgs --quiet --no-warnings -f "bestaudio[ext=m4a]/bestaudio" -o $tmpAudio "https://www.youtube.com/watch?v=$id"
    
    # Trouver le thumbnail généré (extension variable)
    $thumbFile = Get-ChildItem $TempDir -Filter "$id.*" | Where-Object { $_.Extension -match "jpg|png|webp|jpeg" } | Select-Object -First 1
    
    if (Test-Path $tmpAudio) {
        # B. Conversion FFmpeg (1fps static image)
        $tIn = if ($thumbFile) { $thumbFile.FullName } else { "color=c=black:s=1280x720:r=1" }
        
        Write-Host "  Génération MP4 (1fps)..." -ForegroundColor Gray
        if ($thumbFile) {
            & $Ffmpeg -y -loglevel error -loop 1 -framerate 1 -i $tIn -i $tmpAudio -c:v libx264 -tune stillimage -preset ultrafast -pix_fmt yuv420p -c:a copy -shortest "$finalMp4"
        } else {
            & $Ffmpeg -y -loglevel error -f lavfi -i "$tIn" -i $tmpAudio -c:v libx264 -tune stillimage -preset ultrafast -pix_fmt yuv420p -c:a copy -shortest "$finalMp4"
        }
        
        if (Test-Path $finalMp4) {
            Write-Host "  OK : $finalMp4" -ForegroundColor Green
            & $Sqlite $DbFile "UPDATE videos SET status = 'RECOVERY_PREPARED' WHERE youtube_id = '$id';"
        } else {
            Write-Host "  ÉCHEC FFmpeg" -ForegroundColor Red
        }
    } else {
        Write-Host "  ÉCHEC Téléchargement Audio" -ForegroundColor Red
    }
    
    # Nettoyage
    Get-ChildItem $TempDir -Filter "$id*" | Remove-Item -Force -ErrorAction SilentlyContinue
}

Write-Host "`nRécupération terminée." -ForegroundColor Cyan
