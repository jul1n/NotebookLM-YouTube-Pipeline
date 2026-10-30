# Run only with project workers stopped. Copy only SQLite, never the media library.
$ErrorActionPreference = 'Stop'
$workers = @(Get-CimInstance Win32_Process | Where-Object {
    $_.ProcessId -ne $PID -and $_.Name -match '^(python|pythonw|sqlite3|yt-dlp|ffmpeg|pwsh|powershell)\.exe$' -and
    $_.CommandLine -match 'MASTER-COMMANDER|Run-Dashboard-Server|Industrial_Pipeline|Local-Whisper|pipeline_core|Download-Audio|Discover-New|Sync-Dashboard|Audit-DataHealth'
})
if ($workers.Count -gt 0) { throw "Traitements actifs détectés : $($workers.ProcessId -join ', '). Fermez-les proprement avant la migration." }
& python (Join-Path $PSScriptRoot 'pipeline_core.py') migrate --root (Split-Path $PSScriptRoot -Parent)
if ($LASTEXITCODE -ne 0) { throw 'Migration interrompue ; la base source sur Drive est conservée.' }