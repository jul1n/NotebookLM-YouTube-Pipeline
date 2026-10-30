param([int]$WordLimit = 200000)
& (Join-Path $PSScriptRoot 'Batch-Generate-Packs.ps1') -WordLimit $WordLimit
