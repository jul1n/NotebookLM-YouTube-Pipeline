# Debug-Oussama.ps1
$BaseDir = $PSScriptRoot
$BinDir = Join-Path $BaseDir "BIN"
$YtDlp = Join-Path $BinDir "yt-dlp.exe"
$Sqlite = Join-Path $BinDir "sqlite3.exe"
$DbDir = Join-Path $BaseDir "DATA_STORES"
$DbPath = Join-Path $DbDir "Oussama Ammar.db"

$id = "6UbxfNK8leE"
$url = "https://www.youtube.com/watch?v=$id"

Write-Host "--- DEBUG OUSSAMA AMMAR ---" -ForegroundColor Cyan
Write-Host "Cible: $id"

# 1. Test Metadata
Write-Host "[1/3] Metadata fetch..."
$json = & $YtDlp --dump-json $url 2>$null | ConvertFrom-Json
if (!$json) { Write-Host "  [!] Echec Metadata" -ForegroundColor Red; exit }
Write-Host "  [OK] Titre: $($json.title)"

# 2. Test Subtitles
Write-Host "[2/3] Subtitle download..."
$tempDir = Join-Path $BaseDir "_TEMP_DEBUG"
if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
New-Item -ItemType Directory -Path $tempDir | Out-Null

& $YtDlp --skip-download --write-auto-sub --sub-langs "fr" -o "$tempDir\sub.%(ext)s" $url 2>&1 | Write-Host -ForegroundColor Gray

$subFile = Get-ChildItem $tempDir -Filter "sub.*" | Select-Object -First 1
if (!$subFile) { Write-Host "  [!] Echec Subtitle" -ForegroundColor Red; exit }
Write-Host "  [OK] Subtitle trouvé: $($subFile.Name)"

# 3. Test SQL Write
Write-Host "[3/3] SQL Write test..."
$eTitle = $json.title -replace "'", "''"
$sql = "CREATE TABLE IF NOT EXISTS videos (youtube_id TEXT PRIMARY KEY, title TEXT, transcript TEXT); INSERT OR REPLACE INTO videos (youtube_id, title, transcript) VALUES ('$id', '$eTitle', 'DEBUG_TRANSCRIPT_TEST');"
& $Sqlite "$DbPath" "$sql" 2>&1 | Write-Host -ForegroundColor Gray

# 4. Verification
$check = & $Sqlite "$DbPath" "SELECT count(*) FROM videos WHERE youtube_id='$id';"
Write-Host "  [VERIF] Videos avec ID $id en base: $check" -ForegroundColor Yellow
