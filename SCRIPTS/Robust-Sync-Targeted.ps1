# Robust-Sync-Targeted.ps1 (Industrial Center v15)
# Optimized for a specific targeted channel to maximize subtitle recovery.
# Inspired by Fetch-Specific-Subs.ps1 logic.

$PSScriptDir = Split-Path $PSCommandPath -Parent
. (Join-Path $PSScriptDir "Global-Paths.ps1")

Write-Host "--- SYNC ROBUSTE TARGET (TARGET: ENGLISH) ---" -ForegroundColor Cyan

# 1. Récupérer les vidéos à traiter
# REPLACE WITH YOUR ACTUAL CHANNEL ID:
$chanId = 1 
$getVidsSql = "SELECT youtube_id, title FROM videos WHERE channel_id = $chanId AND (status = 'PENDING' OR status = 'NO_SUBS');"
$videos = & $Sqlite $DbFile $getVidsSql | ForEach-Object {
    if ($_ -match "\|") {
        $parts = $_ -split "\|"
        [PSCustomObject]@{ youtube_id = $parts[0]; title = $parts[1] }
    }
}

if (!$videos) {
    Write-Host "Aucune vidéo en attente pour la chaîne (ID $chanId)." -ForegroundColor Yellow
    exit
}

Write-Host "$($videos.Count) vidéos identifiées pour traitement." -ForegroundColor Gray

foreach ($vid in $videos) {
    $vidId = $vid.youtube_id
    $title = $vid.title
    Write-Host "`n[DIAG] $vidId : $title" -ForegroundColor White -BackgroundColor DarkBlue
    
    $status = "NO_SUBS"
    $chosenLang = ""
    
    # 2. Diagnostic des langues disponibles
    $subsRaw = & $YtDlp @YtDlpArgs --list-subs "https://www.youtube.com/watch?v=$vidId" 2>&1
    $subsInfo = $subsRaw | Out-String
    
    if ($subsInfo -match "HTTP Error 429") {
        Write-Host "BLOQUÉ : Erreur 429 détectée. On attend 10s..." -ForegroundColor Red
        Start-Sleep -Seconds 10
        continue
    }

    if ($subsInfo -match "has no subtitles") {
        Write-Host "INFO : Aucun sous-titre du tout sur cette vidéo." -ForegroundColor Gray
        $status = "NO_SUBS_TOTAL"
    } else {
        $langs = $subsRaw | Where-Object { $_ -match "^[a-z]{2}(-[a-zA-Z0-9]+)?\s+" } | ForEach-Object { $_.Split(' ')[0] }
        Write-Host "LANGUES DISPONIBLES : $($langs -join ', ')" -ForegroundColor Cyan
        
        # Identifier les langues manuelles ou auto (Priorité EN puis FR)
        $hasEn = $subsInfo -match "^en\s+" -or $subsInfo -match "en-orig"
        $hasFr = $subsInfo -match "^fr\s+"
        
        if ($hasEn) { $chosenLang = "en" }
        elseif ($hasFr) { $chosenLang = "fr" }
        else {
            # Si aucune langue cible trouvée mais que des sous-titres existent
            $status = "NO_EN_FR"
            Write-Host "INFO : Sous-titres existants mais pas en EN/FR." -ForegroundColor Yellow
        }
    }

    if ($chosenLang) {
        Write-Host "LANGUE CIBLE : $chosenLang" -ForegroundColor Cyan
        
        # 3. Téléchargement ciblé
        $outputPath = Join-Path $TempDir $vidId
        $downloadResult = & $YtDlp @YtDlpArgs --write-sub --write-auto-sub --sub-lang "$chosenLang" --skip-download --output "$outputPath" "https://www.youtube.com/watch?v=$vidId" 2>&1 | Out-String
        
        # Trouver le fichier généré
        $vttFiles = Get-ChildItem $TempDir -Filter "$vidId.*.vtt"
        if ($vttFiles) {
            $vttPath = $vttFiles[0].FullName
            $rawText = Get-Content $vttPath -Raw
            
            # Nettoyage VTT simplifié
            $cleanTranscript = $rawText -replace "<[^>]+>", "" -replace "WEBVTT", "" -replace "\d{2}:\d{2}:\d{2}\.\d{3} --> \d{2}:\d{2}:\d{2}\.\d{3}", ""
            $cleanTranscript = ($cleanTranscript -split "`n" | Where-Object { $_.Trim() -ne "" -and $_ -notmatch "^\d+$" } | Select-Object -Unique) -join " "
            $cleanTranscript = $cleanTranscript.Trim()
            
            if ($cleanTranscript.Length -gt 100) {
                # 4. Mise à jour SQL robuste
                $escapedTranscript = $cleanTranscript -replace "'", "''"
                $updateSql = "UPDATE videos SET transcript = '$escapedTranscript', status = 'SUCCESS' WHERE youtube_id = '$vidId';"
                $tempSql = Join-Path $TempDir "update_$vidId.sql"
                $updateSql | Out-File $tempSql -Encoding utf8
                
                # Conversion du chemin pour SQLite (forward slashes)
                $sqlitePath = $tempSql.Replace("\", "/")
                & $Sqlite $DbFile ".read `"$sqlitePath`""
                
                # Vérification rapide de l'injection
                $check = & $Sqlite $DbFile "SELECT COUNT(*) FROM videos WHERE youtube_id = '$vidId' AND status = 'SUCCESS' AND transcript IS NOT NULL;"
                if ([int]$check -gt 0) {
                    Write-Host "SUCCÈS : Transcription injectée ($chosenLang)." -ForegroundColor Green
                    $status = "SUCCESS"
                } else {
                    Write-Host "ERREUR : L'injection SQL a échoué pour $vidId." -ForegroundColor Red
                    $status = "SQL_ERROR"
                }
                Remove-Item $tempSql -ErrorAction SilentlyContinue
            }
            Remove-Item $vttPath -ErrorAction SilentlyContinue
        }
    }

    # Mise à jour du statut final si ce n'est pas déjà un succès (ou si on a eu une erreur SQL)
    if ($status -ne "SUCCESS") {
        & $Sqlite $DbFile "UPDATE videos SET status = '$status' WHERE youtube_id = '$vidId';"
    }

    # Pause systématique pour éviter le 429
    Start-Sleep -Seconds 2
}

Write-Host "`nTerminé !" -ForegroundColor Cyan
