# Sync-Dashboard-v15.ps1
# High-performance synchronization script for the Industrial Pipeline Dashboard.
# Optimisé pour SQL pur (plus de boucles PowerShell lentes).

$PSScriptDir = Split-Path $PSCommandPath -Parent
. (Join-Path $PSScriptDir "Global-Paths.ps1")

Write-Host "--- SYNCHRONISATION DASHBOARD v15 (INDUSTRIEL) ---" -ForegroundColor Cyan

# 1. Extraction des Statistiques Globales en une seule passe
$statsSql = @"
SELECT 
    COUNT(*) as totalVids,
    SUM(duration) / 3600.0 as totalHours,
    SUM(LENGTH(transcript) - LENGTH(REPLACE(transcript, ' ', '')) + 1) as totalWords
FROM videos 
WHERE transcript IS NOT NULL AND transcript != '';
"@

$stats = & $Sqlite -header -csv $DbFile $statsSql | ConvertFrom-Csv

$totalVids = if ($stats.totalVids) { $stats.totalVids } else { 0 }
$totalHours = if ($stats.totalHours) { [math]::Round([float]$stats.totalHours, 1) } else { 0 }
$totalWords = if ($stats.totalWords) { $stats.totalWords } else { 0 }

# Fallback: Si les durées sont manquantes, on estime à partir du nombre de mots (moyenne 150 mots/min)
if ($totalHours -lt 1 -and $totalWords -gt 0) {
    $totalHours = [math]::Round($totalWords / (150 * 60), 0)
}

# 2. Stats des chaines et manquants
$countsSql = "SELECT COUNT(*) as c FROM channels;"
$chanCount = (& $Sqlite $DbFile $countsSql)

$missingSql = "SELECT COUNT(*) as c FROM videos WHERE status = 'MISSING' OR status = 'PENDING';"
$totalMissing = (& $Sqlite $DbFile $missingSql)

$failedSql = "SELECT COUNT(*) as c FROM videos WHERE status LIKE 'ERR_DL_FAIL%';"
$totalFailed = (& $Sqlite $DbFile $failedSql)

$premiumSql = "SELECT COUNT(*) as c FROM videos WHERE status = 'PREMIUM';"
$totalPremium = (& $Sqlite $DbFile $premiumSql)

$nosubsSql = "SELECT COUNT(*) as c FROM videos WHERE status LIKE 'ERR_NO_EN_FR%' OR status LIKE 'ERR_TOO_SHORT%' OR status = 'NO_SUBS';"
$totalNoSubs = (& $Sqlite $DbFile $nosubsSql)

# 3. Extraction des Données pour Recherche (Top 2000 pour la rapidité du dashboard local)
$searchSql = "SELECT v.youtube_id, v.title, v.upload_date, v.duration, c.prefix as channel, SUBSTR(v.transcript, 0, 1000) as transcript
              FROM videos v JOIN channels c ON v.channel_id = c.id 
              WHERE v.transcript IS NOT NULL AND v.transcript != ''
              ORDER BY v.upload_date DESC LIMIT 2000;"
$searchData = & $Sqlite -header -json $DbFile $searchSql

# 4. Export health.js
$healthSql = @"
SELECT 
    c.prefix as Chaine,
    'OK' as Status,
    ROUND(CAST(SUM(CASE WHEN v.transcript IS NOT NULL AND v.transcript != '' THEN 1 ELSE 0 END) AS FLOAT) / COUNT(*) * 100, 1) || '%' as Success_Rate,
    SUM(CASE WHEN v.transcript IS NOT NULL AND v.transcript != '' THEN 1 ELSE 0 END) as Total_Local,
    COUNT(*) as Total_YouTube,
    SUM(CASE WHEN (v.transcript IS NULL OR v.transcript = '') AND (v.status IS NULL OR v.status IN ('MISSING', 'PENDING')) THEN 1 ELSE 0 END) as Missing_Count,
    SUM(CASE WHEN v.status = 'PREMIUM' THEN 1 ELSE 0 END) as Premium_Count,
    SUM(CASE WHEN v.status LIKE 'ERR_NO_EN_FR%' OR v.status LIKE 'ERR_TOO_SHORT%' OR v.status = 'NO_SUBS' THEN 1 ELSE 0 END) as NoSubs_Count,
    SUM(CASE WHEN v.status LIKE 'ERR_429_BLOCK%' OR v.status = 'RETRY_429' THEN 1 ELSE 0 END) as Retry_429_Count,
    SUM(CASE WHEN v.transcript IS NOT NULL AND v.transcript != '' THEN (LENGTH(v.transcript) - LENGTH(REPLACE(v.transcript, ' ', '')) + 1) ELSE 0 END) as Word_Count,
    CAST((SUM(CASE WHEN v.transcript IS NOT NULL AND v.transcript != '' THEN (LENGTH(v.transcript) - LENGTH(REPLACE(v.transcript, ' ', '')) + 1) ELSE 0 END) + 199999) / 200000 AS INTEGER) as Est_Packs,
    (SELECT json_group_array(json_object('id', youtube_id, 't', title)) FROM (SELECT youtube_id, title FROM videos WHERE channel_id = c.id AND (transcript IS NULL OR transcript = '') AND (status IS NULL OR status IN ('MISSING', 'PENDING')) LIMIT 100)) as Missing_List,
    (SELECT json_group_array(json_object('id', youtube_id, 't', title)) FROM (SELECT youtube_id, title FROM videos WHERE channel_id = c.id AND status = 'PREMIUM' LIMIT 100)) as Premium_List,
    (SELECT json_group_array(json_object('id', youtube_id, 't', title)) FROM (SELECT youtube_id, title FROM videos WHERE channel_id = c.id AND (status LIKE 'ERR_NO_EN_FR%' OR status LIKE 'ERR_TOO_SHORT%' OR status = 'NO_SUBS') LIMIT 100)) as NoSubs_List
FROM channels c
LEFT JOIN videos v ON c.id = v.channel_id
GROUP BY c.id;
"@
$healthData = & $Sqlite -header -json $DbFile $healthSql

# 5. Export des données de récupération
$recoverySql = "SELECT youtube_id, title, status, (SELECT prefix FROM channels WHERE id = v.channel_id) as channel 
                FROM videos v 
                WHERE status IN ('PENDING', 'MISSING', 'RETRY_429', 'ERR_429_BLOCK', 'ERR_DL_FAIL') 
                ORDER BY upload_date DESC LIMIT 200;"
$recoveryData = & $Sqlite -header -json $DbFile $recoverySql

# 6. Ecriture des fichiers JS
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$assetsDir = Join-Path $ProjectRoot "assets"
if (!(Test-Path $assetsDir)) { New-Item $assetsDir -ItemType Directory | Out-Null }

# Sécurité : Si les données sont vides, on initialise avec un tableau vide pour éviter les crashs JS
if (!$searchData) { $searchData = "[]" }
if (!$healthData) { $healthData = "[]" }
if (!$recoveryData) { $recoveryData = "[]" }

$channels = Import-Csv $ConfigCsv -Delimiter ";"
$channelsJson = $channels | ConvertTo-Json -Depth 2

$statsJs = @"
const GLOBAL_STATS = {
    totalVids: $totalVids,
    totalHours: $totalHours,
    totalWords: $totalWords,
    lastSync: '$(Get-Date -Format "HH:mm (dd/MM)")',
    channelCount: $chanCount,
    totalMissing: $totalMissing,
    totalPremium: $totalPremium,
    totalNoSubs: $totalNoSubs,
    totalFailed: $totalFailed,
    channelsConfig: $channelsJson
};
"@

[System.IO.File]::WriteAllText((Join-Path $assetsDir "stats.js"), $statsJs, $utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $assetsDir "data.js"), "const GLOBAL_DATA = $searchData;", $utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $assetsDir "health.js"), "const HEALTH_DATA = $healthData; const GLOBAL_RECOVERY = $recoveryData;", $utf8NoBom)

Write-Host "Synchro terminee !" -ForegroundColor Green

Write-Host "Vidéos: $totalVids | Heures: $totalHours h | Mots: $([math]::Round($totalWords/1000000, 1))M"
