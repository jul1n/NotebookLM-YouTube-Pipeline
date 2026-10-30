# Compatibility entry point for the Python core. No downloads occur before invocation.
param([string]$SpecificChannel = '')
$ErrorActionPreference = 'Stop'
$cliArgs = @((Join-Path $PSScriptRoot 'pipeline_core.py'), 'discover', '--root', (Split-Path $PSScriptRoot -Parent))
if ($SpecificChannel) { $cliArgs += @('--channel', $SpecificChannel) }
& python @cliArgs
if ($LASTEXITCODE -ne 0) { throw 'Le moteur Python a échoué ; consultez le message précédent.' }
