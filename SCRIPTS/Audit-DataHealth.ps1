# Audit-DataHealth.ps1 (v15.0 Industrial Center)
# Audit de santé global basé sur la base unifiée avec calcul des mots pour NotebookLM.

$PSScriptDir = Split-Path $PSCommandPath -Parent
. (Join-Path $PSScriptDir "Global-Paths.ps1")

if (!(Test-Path $ConfigCsv)) {
    Write-Host "Erreur : channels_config.csv introuvable dans DATABASE/." -ForegroundColor Red
    exit
}

# 1. Chargement de la blacklist
$blacklist = if (Test-Path $BlacklistFile) { Get-Content $BlacklistFile } else { @() }

# 2. Audit Séquentiel
Write-Host "--- AUDIT DE SANTE GLOBAL v15 ---" -ForegroundColor Cyan
$healthReport = @()

$channelsSql = "SELECT id, prefix FROM channels;"
$dbChannels = & $Sqlite $DbFile -header -csv $channelsSql | ConvertFrom-Csv

foreach ($chan in $dbChannels) {
    $chanPrefix = $chan.prefix
    if (!$chanPrefix) { $chanPrefix = $chan.Prefix }
    $chanId = $chan.id
    if (!$chanId) { $chanId = $chan.Id }
    
    $cStr = [string]$chanPrefix
    Write-Host "Analyse : $cStr (ID: $chanId)..." -ForegroundColor Gray
    
    if (!$chanId) { continue }

    # Comptages via SQL direct sur base unifiée
    $totalDb = [int](& $Sqlite $DbFile "SELECT COUNT(*) FROM videos WHERE channel_id = $chanId;")
    $localCount = [int](& $Sqlite $DbFile "SELECT COUNT(*) FROM videos WHERE channel_id = $chanId AND transcript IS NOT NULL AND transcript != '';")
    $noSubsDb = [int](& $Sqlite $DbFile "SELECT COUNT(*) FROM videos WHERE channel_id = $chanId AND status = 'NO_SUBS';")
    $premiumDb = [int](& $Sqlite $DbFile "SELECT COUNT(*) FROM videos WHERE channel_id = $chanId AND status = 'PREMIUM';")
    $r429Count = [int](& $Sqlite $DbFile "SELECT COUNT(*) FROM videos WHERE channel_id = $chanId AND status = 'RETRY_429';")
    
    # Calcul des mots (approximation par espaces + 1)
    $wordCountSql = "SELECT SUM(LENGTH(transcript) - LENGTH(REPLACE(transcript, ' ', '')) + 1) FROM videos WHERE channel_id = $chanId AND transcript IS NOT NULL;"
    $wordRes = & $Sqlite $DbFile $wordCountSql
    $wordCount = if ($wordRes -match '^\d+$') { [int]$wordRes } else { 0 }

    $successCount = $localCount + $noSubsDb + $premiumDb
    $missingCount = $totalDb - $successCount
    
    # Récupération de la liste des "Missing" (Tout ce qui n'a pas de transcript et n'est pas Premium/NoSubs)
    $missingList = @()
    if ($missingCount -gt 0) {
        $missingSql = "SELECT youtube_id as id, title as t FROM videos WHERE channel_id = $chanId AND (transcript IS NULL OR transcript = '') AND (status IS NULL OR status NOT IN ('PREMIUM', 'NO_SUBS')) LIMIT 100;"
        $missingList = & $Sqlite $DbFile -header -csv $missingSql | ConvertFrom-Csv
        if ($missingList -and $missingList.PSObject.BaseObject -isnot [System.Array]) { $missingList = @($missingList) }
    }

    $ytCount = $totalDb
    $rate = if ($ytCount -gt 0) { [Math]::Round(($successCount / $ytCount) * 100, 1) } else { 0 }
    $status = if ($rate -ge 95) { "OK" } elseif ($rate -ge 80) { "RETARD" } else { "CRITIQUE" }

    $healthReport += [PSCustomObject]@{
        Chaine            = $cStr
        Status            = $status
        Success_Rate      = "$rate%"
        Total_Local       = $localCount
        Total_YouTube     = $ytCount
        Word_Count        = $wordCount
        Est_Packs         = [Math]::Ceiling($wordCount / 200000) # Estimation : 1 pack tous les 200k mots
        Missing_Count     = $missingCount
        NoSubs_Count      = $noSubsDb
        Premium_Count     = $premiumDb
        Retry_429_Count   = $r429Count
        Missing_List      = $missingList
    }
}

# 3. Exportation
$healthReport | ConvertTo-Json -Depth 5 | Out-File $HealthReportJson -Encoding utf8

Write-Host "`n--- RESULTATS DE L'AUDIT ---" -ForegroundColor Cyan
$healthReport | Sort-Object Total_YouTube -Descending | Format-Table Chaine, Status, Success_Rate, Total_Local, Word_Count, Est_Packs -AutoSize
