# MASTER-COMMANDER-v15.ps1
# Interface de contrôle centralisée pour le Pipeline YouTube Industrial Center.

$ErrorActionPreference = 'Stop'

$PSScriptDir = Split-Path $PSCommandPath -Parent
$ScriptsDir = Join-Path $PSScriptDir "SCRIPTS"
. (Join-Path $ScriptsDir "Global-Paths.ps1")

function Show-Header {
    Clear-Host
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "    🚀 PIPELINE YOUTUBE INDUSTRIAL CENTER v15.2" -ForegroundColor White -BackgroundColor DarkBlue
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host " [Statut Base] : $DbFile" -ForegroundColor Gray
}

function Show-Menu {
    Write-Host "`n --- MENU PRINCIPAL ---" -ForegroundColor Yellow
    Write-Host " 1. [Pipeline]   Lancer la Découverte + Audit + Synchro" -ForegroundColor White
    Write-Host " 2. [Santé]      Lancer l'Audit Global de Santé"
    Write-Host " 3. [Synchro]    Synchronisation des sous-titres (Unified)"
    Write-Host " 4. [Maintenance] Nettoyage Mojibake, Unlock Base, Stockage"
    Write-Host " 5. [Packs]      Générer ou Archiver les Packs NotebookLM"
    Write-Host " 6. [Dashboard]  Lancer le Serveur Web Dashboard"
    Write-Host " 7. [Update]     Mettre à jour les stats du Dashboard"
    Write-Host " 8. [Suivi]      Lister les vidéos sans sous-titres (audio différé)"
    Write-Host " 9. [Import]     Ré-injecter Transcriptions IA (Recovery)" -ForegroundColor Green
    Write-Host " 10. [Chaînes]    Ajouter une nouvelle chaîne (Add Channel)" -ForegroundColor Yellow
    Write-Host " 11. [Diagnostic] Sondage des manques de sous-titres (Probe Gaps)"
    Write-Host " 12. [Config]     Synchroniser le CSV des chaînes vers la Base"
    Write-Host "----------------------------------------------------------"
    Write-Host " 0. [Quitter]" -ForegroundColor Red
    Write-Host "`n Choisissez une option : " -NoNewline
}

while ($true) {
    Show-Header
    Show-Menu
    $choice = Read-Host

    switch ($choice) {
        "1" {
            Write-Host "`n--- LANCEMENT PIPELINE COMPLET ---" -ForegroundColor Cyan
            pwsh -File "$ScriptsDir\Discover-New-v15.ps1"
            if ($LASTEXITCODE -ne 0) { throw 'Découverte interrompue' }
            pwsh -File "$ScriptsDir\Audit-DataHealth.ps1"
            pwsh -File "$ScriptsDir\Industrial_Pipeline_v15_Unified_Sync.ps1"
            if ($LASTEXITCODE -ne 0) { throw 'Synchronisation interrompue' }
            pwsh -File "$ScriptsDir\Sync-Dashboard-v15.ps1"
            Write-Host "`n[CONSEIL] : Tout est à jour ! Vous pouvez maintenant ouvrir le Dashboard (Option 6)." -ForegroundColor Yellow
            Write-Host "`nAppuyez sur une touche pour revenir au menu..." -ForegroundColor Gray
            $null = [Console]::ReadKey()
        }
        "2" {
            pwsh -File "$ScriptsDir\Audit-DataHealth.ps1"
            Write-Host "`n[SUGGESTION] : Maintenant, lancez l'Option 7 pour voir ces stats sur le Web." -ForegroundColor Yellow
            Write-Host "`nAppuyez sur une touche pour revenir au menu..." -ForegroundColor Gray
            $null = [Console]::ReadKey()
        }
        "3" {
            Write-Host "`nNom de la chaîne (Laissez vide pour TOUT synchroniser) : " -NoNewline
            $chan = Read-Host
            if ($chan) {
                pwsh -File "$ScriptsDir\Industrial_Pipeline_v15_Unified_Sync.ps1"
            if ($LASTEXITCODE -ne 0) { throw 'Synchronisation interrompue' } -SpecificChannel $chan
            } else {
                pwsh -File "$ScriptsDir\Industrial_Pipeline_v15_Unified_Sync.ps1"
            if ($LASTEXITCODE -ne 0) { throw 'Synchronisation interrompue' }
            }
            Write-Host "`n[SUGGESTION] : Synchronisation terminée. Pensez à l'Audit (Option 2) pour valider." -ForegroundColor Yellow
            Write-Host "`nAppuyez sur une touche..."
            $null = [Console]::ReadKey()
        }
        "4" {
            Show-Header
            Write-Host "`n --- MAINTENANCE ---" -ForegroundColor Yellow
            Write-Host " A. Nettoyage Mojibake (Global-Heal)"
            Write-Host " B. Déverrouiller la base (Unlock-Database)"
            Write-Host " C. Nettoyage stockage (Cleanup-Storage)"
            Write-Host " D. Reset PREMIUM (Forcer la synchro des vidéos Premium)"
            Write-Host " E. Correction des artefacts locaux (Heal-Artifacts)"
            Write-Host " F. Sauvegarder et vérifier la base sur Drive"
            Write-Host " Q. Retour"
            $maint = Read-Host
            if ($maint -eq 'A') { pwsh -File "$ScriptsDir\Global-Heal-v15.ps1" }
            elseif ($maint -eq 'B') { pwsh -File "$ScriptsDir\Unlock-Database-v15.ps1" }
            elseif ($maint -eq 'C') { pwsh -File "$ScriptsDir\Cleanup-Storage.ps1" }
            elseif ($maint -eq 'D') { 
                & $Sqlite $DbFile "UPDATE videos SET status = 'PENDING' WHERE status = 'PREMIUM';"
                Write-Host " Statut PREMIUM réinitialisé en PENDING." -ForegroundColor Green
            }
            elseif ($maint -eq 'E') { pwsh -File "$ScriptsDir\Heal-Artifacts-v15.ps1" }
            elseif ($maint -eq 'F') { pwsh -File "$ScriptsDir\Backup-Database.ps1" }
            Write-Host "`nAppuyez sur une touche..."
            $null = [Console]::ReadKey()
        }
        "5" {
            Show-Header
            Write-Host "`n --- GESTION DES PACKS ---" -ForegroundColor Yellow
            Write-Host " A. Générer tous les packs"
            Write-Host " B. Archiver les anciens packs"
            Write-Host " Q. Retour"
            $pack = Read-Host
            if ($pack -eq 'A') { pwsh -File "$ScriptsDir\Batch-Generate-Packs.ps1" }
            elseif ($pack -eq 'B') { pwsh -File "$ScriptsDir\Archive-Old-Packs.ps1" }
            Write-Host "`nAppuyez sur une touche..."
            $null = [Console]::ReadKey()
        }
        "6" {
            Write-Host "`nLancement du Dashboard... Laissez cette fenêtre ouverte pour le serveur." -ForegroundColor Green
            Start-Process pwsh -ArgumentList "-File `"$ScriptsDir\Run-Dashboard-Server.ps1`""
            Write-Host "Dashboard lancé ! Accédez à http://localhost:8080" -ForegroundColor Cyan
            Start-Sleep -Seconds 3
        }
        "7" {
            pwsh -File "$ScriptsDir\Sync-Dashboard-v15.ps1"
            Write-Host "`nDashboard mis à jour." -ForegroundColor Green
            Write-Host "[CONSEIL] : Rafraîchissez votre page (F5) dans votre navigateur." -ForegroundColor Yellow
            Start-Sleep -Seconds 2
        }
        "8" {
            & python (Join-Path $ScriptsDir 'pipeline_core.py') missing-captions --root $ProjectRoot
            Write-Host 'Les tests audio sont différés. Aucun média ni modèle audio ne sera traité.'
            $null = [Console]::ReadKey()
        }
        "9" {
            pwsh -File "$ScriptsDir\Import-Audio-Transcripts-v15.ps1"
            Write-Host "`nAppuyez sur une touche..."
            $null = [Console]::ReadKey()
        }
        "10" {
            pwsh -File "$ScriptsDir\Add-Channel-v15.ps1"
            Write-Host "`nAppuyez sur une touche..."
            $null = [Console]::ReadKey()
        }
        "11" {
            pwsh -File "$ScriptsDir\Probe-DataGaps-v15.ps1"
            Write-Host "`nAppuyez sur une touche..."
            $null = [Console]::ReadKey()
        }
        "12" {
            pwsh -File "$ScriptsDir\Sync-Channels-Config.ps1"
            Write-Host "`nAppuyez sur une touche..."
            $null = [Console]::ReadKey()
        }
        "0" {
            Write-Host "`nAu revoir !" -ForegroundColor Cyan
            exit
        }
    }
}
