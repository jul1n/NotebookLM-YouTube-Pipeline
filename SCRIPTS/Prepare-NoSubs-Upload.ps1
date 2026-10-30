# Prepare-NoSubs-Upload.ps1
# Updated version: Tracks local files in DB, filters by transcript availability, and preserves URLs in filenames.

$BaseDir = "c:\NoteBookLM"
$DbFile = Join-Path $BaseDir "PIPELINE_V15.db"
$BinDir = Join-Path $BaseDir "BIN"
$Sqlite = Join-Path $BinDir "sqlite3.exe"
$UploadDir = Join-Path $BaseDir "_UPLOAD_FOR_SUBS"

if (!(Test-Path $UploadDir)) { New-Item -ItemType Directory $UploadDir }
else { 
    Write-Host "Nettoyage du dossier d'upload..." -ForegroundColor Gray
    Remove-Item (Join-Path $UploadDir "*") -Force -ErrorAction SilentlyContinue 
}

Write-Host "--- ANALYSE ET PREPARATION DE L'UPLOAD POUR SOUS-TITRES ---" -ForegroundColor Cyan

# 1. Scan massif des fichiers MP4 locaux
$ScanPaths = @("G:\Mon Drive\NotebookLM\_RE_SUBTITLING_WORK\3_STATIC_VIDEOS") 
$localFiles = @()

foreach ($path in $ScanPaths) {
    if (Test-Path $path) {
        Write-Host "Scan de $path..." -ForegroundColor Gray
        $files = Get-ChildItem -Path $path -Filter "*.mp4" -Recurse -ErrorAction SilentlyContinue
        $localFiles += $files
    }
}

Write-Host "$($localFiles.Count) fichiers MP4 trouvés au total."

# 2. Mise à jour de la base de données (Tag is_downloaded)
Write-Host "Mise à jour des tags 'is_downloaded' dans la base..." -ForegroundColor Gray
foreach ($file in $localFiles) {
    if ($file.Name -match "([a-zA-Z0-9_-]{11})") {
        $id = $Matches[1]
        & $Sqlite $DbFile "UPDATE videos SET is_downloaded = 'OUI' WHERE youtube_id = '$id';"
    }
}

# 3. Identification des candidats réels (Pas de transcription ET (NoSubs ou Premium))
$sqlCandidats = "SELECT v.youtube_id, v.title, c.prefix as channel 
                 FROM videos v JOIN channels c ON v.channel_id = c.id 
                 WHERE (v.transcript IS NULL OR v.transcript = '') 
                 AND (v.status = 'NO_SUBS' OR v.status = 'PREMIUM')
                 AND v.is_downloaded = 'OUI';"

$jsonRaw = & $Sqlite $DbFile -json $sqlCandidats | Out-String
$candidats = if ($jsonRaw.Trim() -ne "") { $jsonRaw | ConvertFrom-Json } else { @() }

if (!$candidats) {
    Write-Host "Aucun candidat trouvé (soit ils ont déjà des sous-titres, soit les fichiers MP4 sont introuvables)." -ForegroundColor Yellow
    exit
}

Write-Host "$($candidats.Count) vidéos prêtes pour l'upload (Fichier local OK, Sous-titres manquants)." -ForegroundColor Green

# 4. Préparation du dossier d'upload avec URL dans le nom
foreach ($c in $candidats) {
    $id = $c.youtube_id
    $match = $localFiles | Where-Object { $_.Name -like "*$id*" } | Select-Object -First 1
    
    if ($match) {
        # Nettoyage du titre pour le nom de fichier
        $cleanTitle = $c.title -replace '[\\/:*?"<>|]', '_'
        
        $destName = "$($c.channel) - $cleanTitle - [$id].mp4"
        $destPath = Join-Path $UploadDir $destName
        
        if (!(Test-Path $destPath)) {
            Write-Host "Préparation : $id" -ForegroundColor Gray
            Copy-Item $match.FullName $destPath -ErrorAction SilentlyContinue
            # Marquer comme préparé pour upload
            & $Sqlite $DbFile "UPDATE videos SET recovery_status = 'PREPARED' WHERE youtube_id = '$id';"
        }
    }
}

Write-Host "`nDossier d'upload prêt : $UploadDir" -ForegroundColor Cyan
Write-Host "Le manifeste CSV a été mis à jour." -ForegroundColor Gray
$candidats | Export-Csv (Join-Path $UploadDir "upload_candidates.csv") -NoTypeInformation -Delimiter ";" -Encoding utf8
