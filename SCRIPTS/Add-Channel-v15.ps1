# Add-Channel-v15.ps1 (v15.0 Industrial Center - ROBUST)
# Ajoute une nouvelle chaine et decouvre ses videos de maniere robuste.

param(
    [Parameter(Mandatory=$false)]
    [string]$ChannelUrl,
    [Parameter(Mandatory=$false)]
    [string]$Prefix,
    [Parameter(Mandatory=$false)]
    [int]$Limit = 500
)

$PSScriptDir = Split-Path $PSCommandPath -Parent
. (Join-Path $PSScriptDir "Global-Paths.ps1")

if (!$ChannelUrl) {
    $ChannelUrl = Read-Host "URL de la chaîne YouTube (ex: https://www.youtube.com/@Nom/videos)"
}
if (!$Prefix) {
    $Prefix = Read-Host "Nom/Préfixe de la chaîne (ex: Nom de la chaine)"
}

Write-Host "Limite par défaut configurée à : $Limit" -ForegroundColor Gray
$userLimit = Read-Host "Voulez-vous élargir la recherche ? Saisissez une nouvelle limite (ex: 1000, 2000) ou appuyez sur Entrée pour garder $Limit"
if ($userLimit -and $userLimit -match '^\d+$') {
    $Limit = [int]$userLimit
}
$Lang = Read-Host "Langue principale de la chaîne (fr / en / auto) [Défaut: fr]"
if (!$Lang) { $Lang = "fr" }
$Lang = $Lang.ToLower().Trim()

Write-Host "--- AJOUT DE CHAINE v15 (INDUSTRIAL CENTER - ROBUST) ---" -ForegroundColor Cyan

# 1. Insertion dans 'channels'
$insertChanSql = "INSERT OR IGNORE INTO channels (prefix, yt_url, lang_config) VALUES ('$($Prefix -replace "'", "''")', '$ChannelUrl', '$Lang');"
& $Sqlite $DbFile $insertChanSql
# Au cas où elle existe déjà, on met à jour la langue
$updateChanSql = "UPDATE channels SET lang_config = '$Lang' WHERE prefix = '$($Prefix -replace "'", "''")';"
& $Sqlite $DbFile $updateChanSql

$chanId = & $Sqlite $DbFile "SELECT id FROM channels WHERE prefix = '$($Prefix -replace "'", "''")';"

if (!$chanId) {
    Write-Host "Erreur : Impossible de créer la chaîne en base." -ForegroundColor Red
    exit
}

Write-Host "Chaîne '$Prefix' enregistrée (ID: $chanId)." -ForegroundColor Green

# 2. Découverte des vidéos
Write-Host "Découverte des $($Limit) dernières vidéos YouTube (Format Robuste)..." -ForegroundColor Gray
$discoveryFile = Join-Path $TempDir "discovery_$($Prefix.Replace(' ','_')).txt"

if ($ChannelUrl -match "@" -and $ChannelUrl -notlike "*/videos*") {
    $ChannelUrl = $ChannelUrl.TrimEnd('/') + "/videos"
}

# On utilise --flat-playlist pour une découverte rapide sans warnings de métadonnées
$ytCmd = "& `"$YtDlp`" $YtDlpArgs --flat-playlist --print `"%(id)s[SEP]%(title)s`" --playlist-end $Limit `"$ChannelUrl`""
Invoke-Expression $ytCmd > $discoveryFile

if (!(Test-Path $discoveryFile)) {
    Write-Host "Erreur : Le fichier de découverte n'a pas été généré." -ForegroundColor Red
    exit
}

$vids = Get-Content $discoveryFile
$count = 0
foreach ($line in $vids) {
    if ($line -like "*[SEP]*") {
        $parts = $line -split "\[SEP\]"
        $id = $parts[0].Trim()
        $title = $parts[1].Trim()
        
        if ($id -and $title) {
            $escapedTitle = $title -replace "'", "''"
            $insertVidSql = "INSERT OR IGNORE INTO videos (channel_id, youtube_id, title, status) VALUES ($chanId, '$id', '$escapedTitle', 'PENDING');"
            & $Sqlite $DbFile $insertVidSql
            $count++
        }
    }
}

Write-Host "$count vidéos ajoutées ou mises à jour en file d'attente (PENDING)." -ForegroundColor Green

# 3. Ménage
if (Test-Path $discoveryFile) { Remove-Item $discoveryFile }

Write-Host "Terminé ! Vous pouvez lancer la Synchronisation." -ForegroundColor Cyan
