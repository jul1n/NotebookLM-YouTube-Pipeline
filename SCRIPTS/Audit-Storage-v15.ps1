# Compatibility entry point for the Python core. No downloads occur before invocation.

$ErrorActionPreference = 'Stop'
$cliArgs = @((Join-Path $PSScriptRoot 'pipeline_core.py'), 'audit', '--root', (Split-Path $PSScriptRoot -Parent))

& python @cliArgs
if ($LASTEXITCODE -ne 0) { throw 'Le moteur Python a échoué ; consultez le message précédent.' }
