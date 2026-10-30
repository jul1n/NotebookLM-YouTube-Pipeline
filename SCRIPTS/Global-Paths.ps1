
# Global-Paths.ps1
# Source of truth for all Pipeline v15 paths.

$ProjectRoot = Split-Path $PSScriptRoot -Parent
$DatabaseDir = Join-Path $ProjectRoot "DATABASE"
$ScriptsDir = Join-Path $ProjectRoot "SCRIPTS"
$ResourcesDir = Join-Path $ProjectRoot "RESOURCES"
$ChannelsDataDir = Join-Path $ProjectRoot "CHANNELS_DATA"
$WorkingZoneDir = Join-Path $ProjectRoot "WORKING_ZONE"
$OldDir = Join-Path $ProjectRoot "OLD"

# Key Files
$DbFile = Join-Path $DatabaseDir "PIPELINE_V15.db"
$ConfigCsv = Join-Path $DatabaseDir "channels_config.csv"
$BlacklistFile = Join-Path $DatabaseDir "blacklist.txt"
$HealthReportJson = Join-Path $DatabaseDir "health_report.json"
$StatsJs = Join-Path $ProjectRoot "stats.js" # Keep at root for dashboard fetch if needed, or move to assets
$DataJs = Join-Path $ProjectRoot "data.js"
$HealthJs = Join-Path $ProjectRoot "health.js"

# Binaries
$BinDir = Join-Path $ResourcesDir "BIN"
$CookieFile = Join-Path $ResourcesDir "cookie.txt"
$YtDlp = Join-Path $BinDir "yt-dlp.exe"
$YtDlpArgs = @("--cookies-from-browser", "firefox")
if (Test-Path $CookieFile) {
    $YtDlpArgs += @("--cookies", $CookieFile)
}
$Sqlite = Join-Path $BinDir "sqlite3.exe"

# Working Folders
$TempDir = Join-Path $WorkingZoneDir "_TEMP"
$UploadForSubsDir = Join-Path $WorkingZoneDir "_UPLOAD_FOR_SUBS"
$TranscriptsBackupDir = Join-Path $WorkingZoneDir "_BACKUP_VTT"

# A machine-specific configuration is only written after a verified SQLite backup.
$LocalRuntimeConfig = Join-Path $DatabaseDir 'local-runtime.json'
if (Test-Path -LiteralPath $LocalRuntimeConfig) {
    $runtime = Get-Content -LiteralPath $LocalRuntimeConfig -Raw | ConvertFrom-Json
    if (!(Test-Path -LiteralPath $runtime.DatabasePath -PathType Leaf)) { throw 'Base locale configurée introuvable : arrêt, sans repli silencieux vers une ancienne base.' }
    $DbFile = $runtime.DatabasePath
    $TempDir = $runtime.TempPath
}

# Ensure crucial paths exist
if (!(Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }
if (!(Test-Path $TranscriptsBackupDir)) { New-Item -ItemType Directory -Path $TranscriptsBackupDir -Force | Out-Null }
