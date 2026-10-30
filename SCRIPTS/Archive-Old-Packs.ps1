# New generations preserve previous packs on Drive automatically.
$root = Split-Path $PSScriptRoot -Parent
Get-ChildItem -LiteralPath (Join-Path $root 'assets') -Directory -Filter 'packs-previous-*' | Select-Object Name,LastWriteTime
Write-Host 'Versions précédentes conservées sur Drive. Aucune suppression automatique.'
