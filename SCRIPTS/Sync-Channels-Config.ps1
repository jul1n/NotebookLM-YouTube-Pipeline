# Sync-Channels-Config.ps1
# Synchronise les URLs du CSV vers la table 'channels' de la base de données.

$PSScriptDir = Split-Path $PSCommandPath -Parent
. (Join-Path $PSScriptDir "Global-Paths.ps1")

Write-Host "--- SYNCHRONISATION DES URLS CHAÎNES ---" -ForegroundColor Cyan

if (!(Test-Path $ConfigCsv)) {
    Write-Host "Erreur : Fichier $ConfigCsv introuvable." -ForegroundColor Red
    exit
}

$channels = Import-Csv $ConfigCsv -Delimiter ";"
Write-Host "$($channels.Count) chaînes trouvées dans le CSV." -ForegroundColor Gray

foreach ($c in $channels) {
    $url = $c.URL
    $prefix = $c.Prefixe
    $lang = $c.Langue
    
    if ($url -and $prefix) {
        $prefixEscaped = $prefix -replace "'", "''"
        Write-Host " Mise à jour : $prefix ($lang)..." -NoNewline
        $sql = "UPDATE channels SET yt_url = '$url', lang_config = '$lang' WHERE prefix = '$prefixEscaped';"
        & $Sqlite $DbFile $sql
        Write-Host " OK" -ForegroundColor Green
    }
}

Write-Host "`nSynchronisation terminée !" -ForegroundColor Cyan
