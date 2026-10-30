# Dedicated-Sync-Template.ps1
# Synchronisation haute priorite pour une chaine specifique
$BaseDir = $PSScriptRoot
$Pipeline = Join-Path $BaseDir "Industrial_Pipeline_v15_Unified_Sync.ps1" # Assuming v15

Write-Host "--- LANCEMENT SYNCHRO DEDIEE : [TARGET CHANNEL] ---" -ForegroundColor Cyan

# On s'assure que la chaine a son propre fichier de config pour ne pas interferer avec le global
$TargetChannelName = "Example Channel"
$configData = '"https://www.youtube.com/@ExampleChannel/videos";"Example Channel";"fr"'
$tempConfig = Join-Path $BaseDir "dedicated_standalone.csv"
$configData | Out-File $tempConfig -Encoding utf8

# Boucle infinie pour rattraper le retard
while ($true) {
    Write-Host "`n[$(Get-Date -Format 'HH:mm')] Lancement d'un cycle..." -ForegroundColor Yellow
    
    # On lance le pipeline principal en mode DIRECT pour cette chaine
    & pwsh -File $Pipeline -ChannelName $TargetChannelName -Action "2"
    
    Write-Host "`n[OK] Fin du cycle. Attente de 15 minutes avant relance." -ForegroundColor Gray
    Start-Sleep -Seconds 900
}
