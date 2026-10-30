# Compatibility entry point for the Python core. No downloads occur before invocation.
param([int]$WordLimit = 200000)
$ErrorActionPreference = 'Stop'
$cliArgs = @((Join-Path $PSScriptRoot 'pipeline_core.py'), 'packs', '--root', (Split-Path $PSScriptRoot -Parent))
$cliArgs += @('--word-limit', $WordLimit)
& python @cliArgs
if ($LASTEXITCODE -ne 0) { throw 'Le moteur Python a échoué ; consultez le message précédent.' }
