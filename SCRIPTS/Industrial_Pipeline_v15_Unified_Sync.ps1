# Compatibility entry point for the Python core. No downloads occur before invocation.
param([string]$SpecificChannel = '', [switch]$ForceRetry)
$ErrorActionPreference = 'Stop'
$cliArgs = @((Join-Path $PSScriptRoot 'pipeline_core.py'), 'sync', '--root', (Split-Path $PSScriptRoot -Parent))
if ($SpecificChannel) { $cliArgs += @('--channel', $SpecificChannel) }
if ($ForceRetry) { $cliArgs += '--force-retry' }
& python @cliArgs
if ($LASTEXITCODE -ne 0) { throw 'Le moteur Python a échoué ; consultez le message précédent.' }
