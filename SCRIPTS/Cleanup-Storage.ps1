# Inventory first; bulk deletion requires an independently verified snapshot.
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Audit-Storage-v15.ps1')
Write-Host 'Audit terminé. Aucune suppression automatique ; vérifiez les sauvegardes et les candidats dans le dashboard.'
