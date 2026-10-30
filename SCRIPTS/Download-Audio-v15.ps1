# Compatibility entry point for the Python core. No downloads occur before invocation.
param([int]$Limit = 1, [ValidateSet('tiny','base','small')][string]$Model = 'base')
$ErrorActionPreference = 'Stop'
$cliArgs = @((Join-Path $PSScriptRoot 'pipeline_core.py'), 'transcribe', '--root', (Split-Path $PSScriptRoot -Parent))
$cliArgs += @('--limit', $Limit, '--model', $Model)
& python @cliArgs
if ($LASTEXITCODE -ne 0) { throw 'Le moteur Python a échoué ; consultez le message précédent.' }
