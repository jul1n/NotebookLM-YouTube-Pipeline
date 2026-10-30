# Probe-DataGaps-v15.ps1 (v15.0 Industrial Center)
# Diagnostic prudent : vérifie les sous-titres sur YouTube sans les télécharger.

$PSScriptDir = Split-Path $PSCommandPath -Parent
. (Join-Path $PSScriptDir "Global-Paths.ps1")

Write-Host "--- DIAGNOSTIC DES MANQUES v15 ---" -ForegroundColor Cyan

# 1. Sélection des vidéos à sonder (PENDING, NO_SUBS ou NULL)
$sql = "SELECT youtube_id, title FROM videos WHERE (status IS NULL OR status IN ('PENDING', 'NO_SUBS', 'RETRY_429', 'MISSING')) LIMIT 500;"
$jsonRaw = & $Sqlite -json $DbFile $sql
if ($jsonRaw) { $videos = $jsonRaw -join "" | ConvertFrom-Json }

if (!$videos) {
    Write-Host "Aucune vidéo à sonder." -ForegroundColor Green
    exit
}

Write-Host "$($videos.Count) vidéos à diagnostiquer." -ForegroundColor Gray

foreach ($v in $videos) {
    $id = $v.youtube_id
    Write-Host "[DIAG] $id : $($v.title)" -NoNewline
    
    # Appel yt-dlp prudent
    $url = "https://www.youtube.com/watch?v=$id"
    $diagRaw = & $YtDlp @YtDlpArgs --list-subs $url 2>&1 | Out-String
    
    $status = "DIAG_UNKNOWN"
    if ($diagRaw -match "429: Too Many Requests") {
        $status = "RETRY_429"
        Write-Host " -> BLOQUÉ (429)" -ForegroundColor Red
        Start-Sleep -Seconds 10
    } elseif ($diagRaw -match "has no subtitles") {
        $status = "DIAG_NO_SUBS"
        Write-Host " -> AUCUN S-T" -ForegroundColor Yellow
    } else {
        # Analyse sommaire des langues
        $hasEn = $diagRaw -match "en\s+"
        $hasFr = $diagRaw -match "fr\s+"
        if ($hasEn -and $hasFr) { $status = "DIAG_HAS_BOTH" }
        elseif ($hasEn) { $status = "DIAG_HAS_EN" }
        elseif ($hasFr) { $status = "DIAG_HAS_FR" }
        else { $status = "DIAG_HAS_OTHER" }
        
        Write-Host " -> $status" -ForegroundColor Green
    }
    
    # Mise à jour en base
    & $Sqlite $DbFile "UPDATE videos SET status = '$status' WHERE youtube_id = '$id';"
    
    # Petite pause pour éviter le spam
    Start-Sleep -Seconds 2
}

Write-Host "`nDiagnostic terminé." -ForegroundColor Cyan
