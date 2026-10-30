# Monitor-LiveStats.ps1
$BaseDir = $PSScriptRoot
$DbDir = Join-Path $BaseDir "DATA_STORES"
$SqliteExe = Join-Path $BaseDir "BIN\sqlite3.exe"
$StatsPath = Join-Path $BaseDir "stats.js"

Write-Host "--- MONITORING LIVE DASHBOARD v14 ---" -ForegroundColor Cyan

while ($true) {
    $dbFiles = Get-ChildItem $DbDir -Filter "*.db"
    $totalVids = 0; $totalWords = 0; $totalSecs = 0
    
    foreach ($db in $dbFiles) {
        # Count rapide
        $res = & $SqliteExe $db.FullName "SELECT count(*), SUM(duration) FROM videos;"
        if ($res -match "(\d+)\|(\d+)") {
            $totalVids += [int]$Matches[1]
            $totalSecs += [int]$Matches[2]
        }
    }
    
    # On recupere les autres stats (missing, etc.) depuis le dernier health_report.json
    $health = Get-Content (Join-Path $BaseDir "health_report.json") | ConvertFrom-Json
    
    $statsJs = @"
const GLOBAL_STATS = {
    totalVids: $totalVids,
    totalHours: $([math]::Round($totalSecs / 3600, 1)),
    totalWords: $([math]::Round($totalVids * 10000)), // Estimation rapide des mots
    lastSync: 'LIVE $(Get-Date -Format "HH:mm")',
    channelCount: $($dbFiles.Count),
    masterTotal: 192,
    masterLocal: 0,
    totalMissing: $(($health.Missing_Count | Measure-Object -Sum).Sum),
    totalFailed: $(($health.Failed_Count | Measure-Object -Sum).Sum),
    totalPremium: $(($health.Premium_Count | Measure-Object -Sum).Sum),
    totalNoSubs: $(($health.NoSubs_Count | Measure-Object -Sum).Sum)
};
"@
    $statsJs | Out-File $StatsPath -Encoding utf8
    
    Write-Host "[$(Get-Date -Format 'HH:mm')] Stats updated: $totalVids videos." -ForegroundColor Gray
    Start-Sleep -Seconds 60
}
