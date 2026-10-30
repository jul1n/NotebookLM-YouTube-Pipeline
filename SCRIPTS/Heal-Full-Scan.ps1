# Heal-Full-Scan.ps1 (v15.0)
# Scan complet et réparation des artefacts d'encodage (Mojibake) dans toute la base.

$PSScriptDir = Split-Path $PSCommandPath -Parent
. (Join-Path $PSScriptDir "Global-Paths.ps1")

Write-Host "--- DÉMARRAGE DU SCAN COMPLET DE RÉPARATION ---" -ForegroundColor Cyan

$replacements = @(
    # Patterns ├ (CP850/UTF-8 Mojibake)
    @("├®", "é"), @("├¿", "è"), @("├á", "à"), @("├¬", "ê"), @("├┤", "ô"), 
    @("├╗", "û"), @("├╣", "ù"), @("├º", "ç"), @("├î", "î"), @("├Ç", "Ç"),
    @("├ü", "é"), @("├╝", "ü"), @("├½", "ë"), @("├»", "ï"), @("├¬", "ê"),
    
    # Patterns Ã (Common UTF-8 Mojibake)
    @("Ã©", "é"), @("Ã¨", "è"), @("Ã ", "à"), @("Ãª", "ê"), @("Ã´", "ô"),
    @("Ã§", "ç"), @("Ã»", "û"), @("Ã¹", "ù"), @("Ã®", "î"), @("Ã¯", "ï"),
    @("Ã«", "ë"), @("Ã‰", "É"), @("Ã€", "À"), @("Ãˆ", "È"), @("ÃŽ", "Î"),
    @("Ã¦", "æ"), @("Ã¶", "ö"), @("Ã¡", "á"), @("Ã±", "ñ"), @("Ã¼", "ü"),
    
    # Autres artefacts
    @("Æ", "'"), @("Â", ""), @("oû╣", "où"), @("ûº", "ç"), @("Ã_", "í")
)

$batchFile = Join-Path $TempDir "full_heal_batch.sql"
"BEGIN TRANSACTION;" | Out-File $batchFile -Encoding utf8

foreach ($r in $replacements) {
    $search = $r[0]
    $replace = $r[1]
    
    # Échapper les apostrophes pour SQL
    $searchSql = $search -replace "'", "''"
    $replaceSql = $replace -replace "'", "''"
    
    # Mise à jour des transcripts
    "UPDATE videos SET transcript = REPLACE(transcript, '$searchSql', '$replaceSql') WHERE transcript LIKE '%$searchSql%';" | Out-File $batchFile -Encoding utf8 -Append
    # Mise à jour des titres
    "UPDATE videos SET title = REPLACE(title, '$searchSql', '$replaceSql') WHERE title LIKE '%$searchSql%';" | Out-File $batchFile -Encoding utf8 -Append
}

"COMMIT;" | Out-File $batchFile -Encoding utf8 -Append

Write-Host "Exécution du script SQL de réparation..." -ForegroundColor Yellow
$sqlitePath = $batchFile.Replace("\", "/")
& $Sqlite $DbFile ".read `"$sqlitePath`""

# Nettoyage des espaces doubles (optionnel mais recommandé)
Write-Host "Normalisation des espaces..." -ForegroundColor Gray
& $Sqlite $DbFile "UPDATE videos SET transcript = REPLACE(transcript, '  ', ' ') WHERE transcript LIKE '%  %';"

# Mise à jour de l'index FTS5 pour refléter les changements dans le dashboard
Write-Host "Mise à jour de l'index de recherche (FTS5)..." -ForegroundColor Yellow
& $Sqlite $DbFile "INSERT INTO videos_fts(videos_fts) VALUES('rebuild');"

Remove-Item $batchFile -ErrorAction SilentlyContinue

Write-Host "`n--- RÉPARATION TERMINÉE ---" -ForegroundColor Green
Write-Host "Le dashboard devrait maintenant afficher les caractères corrects." -ForegroundColor Gray
