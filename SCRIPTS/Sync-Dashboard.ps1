# Sync-Dashboard.ps1 (v15.0 Industrial Center - Deep Indexing OPTIMIZED)
# Genere les donnees JS et exporte CHAQUE transcription individuellement.
# Version optimisée pour la vitesse (Extraction massive en une seule passe).

$PSScriptDir = Split-Path $PSCommandPath -Parent
. (Join-Path $PSScriptDir "Global-Paths.ps1")

$StatsPath = Join-Path $ProjectRoot "assets\stats.js"
$IndexPath = Join-Path $ProjectRoot "assets\data.js"
$HealthJsPath = Join-Path $ProjectRoot "assets\health.js"
$TranscriptDir = Join-Path $ProjectRoot "assets\transcripts"

function Invoke-Sqlite {
    param($DbPath, $Query)
    $cleanPath = $DbPath.Replace('"', '')
    $res = & $Sqlite -header -json "$cleanPath" "$Query" 2>$null
    if ($res) { return ($res -join "") | ConvertFrom-Json }
    return @()
}

Write-Host "--- SYNCHRONISATION DU DASHBOARD v15 (DEEP INDEXING OPTIMISE) ---" -ForegroundColor Cyan

if (!(Test-Path $TranscriptDir)) { New-Item $TranscriptDir -ItemType Directory | Out-Null }

Write-Host "Extraction massive des 19k+ transcriptions (Veuillez patienter)..." -ForegroundColor Gray

# Extraction de TOUT en une seule requête SQL
# Note: On utilise -json pour garder la structure propre
$bigQuery = "SELECT v.youtube_id, v.title, v.upload_date, v.duration, v.transcript, c.prefix as channel 
              FROM videos v 
              JOIN channels c ON v.channel_id = c.id 
              WHERE v.transcript IS NOT NULL AND v.transcript != '';"

$allData = Invoke-Sqlite -DbPath $DbFile -Query $bigQuery

$allVideos = [System.Collections.Generic.List[PSObject]]::new()
$totalVids = 0; $totalWords = 0; $totalSecs = 0

Write-Host "Ecriture des fichiers individuels..." -ForegroundColor Gray
$count = 0
foreach ($v in $allData) {
    # 1. Metadonnées pour data.js (on coupe le transcript à 2000 pour l'index de recherche)
    $snippet = if ($v.transcript.Length -gt 2000) { $v.transcript.Substring(0, 2000) } else { $v.transcript }
    $allVideos.Add([PSCustomObject]@{
        youtube_id = $v.youtube_id
        title = $v.title
        upload_date = $v.upload_date
        duration = $v.duration
        transcript = $snippet
        channel = $v.channel
    })
    $totalVids++
    
    # 2. Exportation du texte COMPLET (.txt)
    $v.transcript | Out-File (Join-Path $TranscriptDir "$($v.youtube_id).txt") -Encoding utf8
    
    # 3. Stats
    $totalSecs += [int]$v.duration
    # Word count approx
    $totalWords += ($v.transcript -replace " ", "`n" | Measure-Object).Count

    $count++
    if ($count % 1000 -eq 0) { Write-Host " > $count vidéos indexées..." -ForegroundColor DarkGray }
}

# 4. Vidéos en attente
$queryPending = "SELECT v.youtube_id, v.title, v.status, c.prefix as channel 
                 FROM videos v 
                 JOIN channels c ON v.channel_id = c.id 
                 WHERE v.status IN ('PENDING', 'RETRY_429', 'NO_SUBS') LIMIT 500;"
$dataPending = Invoke-Sqlite -DbPath $DbFile -Query $queryPending

# Export stats.js
$channels = Import-Csv $ConfigCsv -Delimiter ";"
$channelsJson = $channels | ConvertTo-Json -Depth 2
$statsJs = @"
const GLOBAL_STATS = {
    totalVids: $totalVids,
    totalHours: $([math]::Round($totalSecs / 3600, 1)),
    totalWords: $totalWords,
    lastSync: '$(Get-Date -Format "HH:mm (dd/MM)")',
    channelCount: $((Invoke-Sqlite -DbPath $DbFile -Query "SELECT COUNT(*) as c FROM channels;").c),
    totalMissing: $(if (Test-Path $HealthReportJson) { (($h = Get-Content $HealthReportJson | ConvertFrom-Json).Missing_Count | Measure-Object -Sum).Sum } else { 0 }),
    totalPremium: $(if ($h) { ($h.Premium_Count | Measure-Object -Sum).Sum } else { 0 }),
    totalNoSubs: $(if ($h) { ($h.NoSubs_Count | Measure-Object -Sum).Sum } else { 0 }),
    totalFailed: $(if ($h) { ($h.Retry_429_Count | Measure-Object -Sum).Sum } else { 0 }),
    channelsConfig: $channelsJson
};
const GLOBAL_RECOVERY = $($dataPending | ConvertTo-Json -Depth 2);
"@
$statsJs | Out-File $StatsPath -Encoding utf8

# Export data.js
$indexJs = "const GLOBAL_DATA = " + ($allVideos | ConvertTo-Json -Depth 2) + ";"
$indexJs | Out-File $IndexPath -Encoding utf8

# Export health.js
if (Test-Path $HealthReportJson) {
    $healthData = Get-Content $HealthReportJson | ConvertFrom-Json
    "const HEALTH_DATA = " + ($healthData | ConvertTo-Json -Depth 5) + ";" | Out-File $HealthJsPath -Encoding utf8
}

Write-Host "Termine ! Index de $($allVideos.Count) videos et deep-files générés à haute vitesse." -ForegroundColor Green
