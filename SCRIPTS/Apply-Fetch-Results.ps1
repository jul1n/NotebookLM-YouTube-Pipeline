# Apply-Fetch-Results.ps1 (v15.0 Industrial Center)
# Injecte les transcriptions récupérées manuellement depuis DATABASE/fetch_results.csv.

$PSScriptDir = Split-Path $PSCommandPath -Parent
. (Join-Path $PSScriptDir "Global-Paths.ps1")

$FetchCsv = Join-Path $DatabaseDir "fetch_results.csv"

if (!(Test-Path $FetchCsv)) {
    Write-Host "Erreur : fetch_results.csv introuvable dans DATABASE/." -ForegroundColor Red
    exit
}

Write-Host "--- APPLICATION DES RESULTATS MANUELS v15 (INDUSTRIAL CENTER) ---" -ForegroundColor Cyan

$results = Import-Csv $FetchCsv -Delimiter ";"
$success = 0; $fail = 0

foreach ($row in $results) {
    $id = $row.youtube_id
    $status = $row.status
    $transcript = $row.transcript
    
    if ($status -eq "SUCCESS" -and $transcript) {
        $escaped = $transcript -replace "'", "''"
        & $Sqlite $DbFile "UPDATE videos SET transcript = '$escaped', status = 'SUCCESS' WHERE youtube_id = '$id';"
        $success++
    } else {
        $fail++
    }
}

Write-Host "Terminé : $success injections réussies, $fail échecs." -ForegroundColor Green
