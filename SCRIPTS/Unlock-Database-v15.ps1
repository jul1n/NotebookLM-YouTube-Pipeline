# Unlock-Database-v15.ps1
# Utilitaire pour vérifier et forcer le déverrouillage de la base SQLite.

$PSScriptDir = Split-Path $PSCommandPath -Parent
. (Join-Path $PSScriptDir "Global-Paths.ps1")

Write-Host "--- DIAGNOSTIC DE VERROUILLAGE BASE v15 ---" -ForegroundColor Cyan

# 1. Vérification des fichiers de transaction (Signe d'un verrou actif)
$JournalFile = "$DbFile-journal"
$WalFile = "$DbFile-wal"

if (Test-Path $JournalFile) {
    Write-Host " [!] Fichier Journal détecté : Une transaction est en cours ou a planté." -ForegroundColor Yellow
}

# 2. Test de micro-écriture (Tentative de déverrouillage passif)
Write-Host " Tentative de test d'écriture..." -NoNewline
$testSql = "BEGIN IMMEDIATE; ROLLBACK;"
& $Sqlite -cmd ".timeout 2000" $DbFile $testSql 2>$null

if ($LASTEXITCODE -eq 0) {
    Write-Host " OK (Base Libre)" -ForegroundColor Green
} else {
    Write-Host " ÉCHEC (Base Verrouillée)" -ForegroundColor Red
    
    Write-Host "`n [!] RECHERCHE DES PROCESSUS BLOQUANTS..." -ForegroundColor Yellow
    Write-Warning "Fermez proprement les traitements qui utilisent cette base puis relancez le diagnostic."
    Write-Warning "Ne supprimez pas les fichiers -journal, -wal ou -shm : SQLite doit assurer leur récupération."

}

Write-Host "`n--- FIN DU DIAGNOSTIC ---"
