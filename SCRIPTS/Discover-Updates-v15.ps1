# Discover-Updates-v15.ps1
# Rafraîchit les chaînes pour découvrir de nouvelles vidéos et retenter les échecs.

$PSScriptDir = Split-Path $PSCommandPath -Parent
. (Join-Path $PSScriptDir "Global-Paths.ps1")

$ConcernedChannels = @(
    "TED",
    "Marc Lou",
    "Sharran Srivatsaa",
    "Shelby Sapp",
    "Peterson Academy",
    "Jesse Itzler",
    "Linda Raynier"
)

Write-Host "=== RAFRAICHISSEMENT DES CHAINES v15 (INDUSTRIAL CENTER) ===" -ForegroundColor Cyan

foreach ($prefix in $ConcernedChannels) {
    # 1. Infos sur la chaine
    $chanSql = "SELECT id, yt_url FROM channels WHERE prefix = '$($prefix -replace "'", "''")';"
    $chan = & $Sqlite $DbFile -header -csv $chanSql | ConvertFrom-Csv
    
    if (!$chan) {
        Write-Host " [!] Chaine non trouvée: $prefix" -ForegroundColor Yellow
        continue
    }
    
    $chanId = $chan.id
    $chanUrl = $chan.yt_url
    
    Write-Host "`n--- Discovery: $prefix (ID: $chanId) ---" -ForegroundColor Blue
    
    # 2. Découverte des 50 dernières vidéos
    $discoveryFile = Join-Path $TempDir "discovery_refresh_$($prefix.Replace(' ','_')).txt"
    $ytCmd = "& `"$YtDlp`" $YtDlpArgs --print `"%(id)s[SEP]%(title)s`" --playlist-end 50 `"$chanUrl`""
    Invoke-Expression $ytCmd > $discoveryFile
    
    if (Test-Path $discoveryFile) {
        $vids = Get-Content $discoveryFile
        $newCount = 0
        foreach ($line in $vids) {
            if ($line -like "*[SEP]*") {
                $parts = $line -split "\[SEP\]"
                $id = $parts[0].Trim()
                $title = $parts[1].Trim()
                
                if ($id -and $title) {
                    $escapedTitle = $title -replace "'", "''"
                    $insertVidSql = "INSERT OR IGNORE INTO videos (channel_id, youtube_id, title, status) VALUES ($chanId, '$id', '$escapedTitle', 'PENDING');"
                    & $Sqlite $DbFile $insertVidSql
                    $newCount++
                }
            }
        }
        Write-Host "  $newCount vidéos analysées. Nouvelles vidéos ajoutées en PENDING." -ForegroundColor Gray
        Remove-Item $discoveryFile
    }

    # 3. Optionnel : Retenter les 'RETRY_429' ou 'MISSING' s'il y en avait
    # (Déjà fait par le script de sync général)
}

Write-Host "`n=== DISCOVERY TERMINEE. VOUS POUVEZ LANCER LA SYNC. ===" -ForegroundColor Cyan
