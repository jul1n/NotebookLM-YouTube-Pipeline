# Global-Heal-v15.ps1
# Nettoyage global des artefacts, mojibake et pollutions sonores (Music, Applause).
# Version 15.1 : Robuste aux gros volumes et décalages CSV.

$PSScriptDir = Split-Path $PSCommandPath -Parent
. (Join-Path $PSScriptDir "Global-Paths.ps1")

Write-Host "--- NETTOYAGE GLOBAL v15.1 (Robuste) ---" -ForegroundColor Cyan

# 1. Définition des remplacements (Mojibake UTF-8 vers accents réels)
$replacements = @{
    "├®" = "é"
    "├¿" = "è"
    "├á" = "à"
    "├¬" = "ê"
    "├┤" = "ô"
    "├û" = "î"
    "├" = "û"
    "├º" = "ç"
    "├ï" = "ë"
    "├î" = "î"
    "Ã©" = "é"
    "Ã¨" = "è"
    "Ã " = "à"
    "Ãª" = "ê"
    "Ã´" = "ô"
    "Ã§" = "ç"
    "Â"   = ""   # Espace insécable fantôme
    "Æ"   = "'"  # Apostrophe mal encodée
    "├╣"  = " — " # Tiret long (TED)
    "├╗"  = '"'   # Guillemet (TED)
    "├Ñ"  = "'"   # Apostrophe (TED)
}

# 2. Artefacts sonores et visuels
$noisePatterns = @(
    "\[Musique\]", "\[Music\]", "\[Applaudissements\]", "\[Applause\]", 
    "\(Rires\)", "\(Laughter\)", "\[Silence\]", "\[Rires\]"
)

# 3. Traitement en Flux (Streaming) pour éviter les erreurs JSON/CSV sur 150k+ lignes
Write-Host "Analyse de la base en cours..." -ForegroundColor Gray

$batchFile = Join-Path $TempDir "global_heal_batch.sql"
"BEGIN TRANSACTION;" | Out-File $batchFile -Encoding utf8

$fixedCount = 0
$processedCount = 0

# Requête SQL avec séparateur PIPE personnalisé pour éviter les décalages de colonnes
$vidsSql = "SELECT id || '---PIPE---' || youtube_id || '---PIPE---' || transcript FROM videos WHERE transcript LIKE '%├%' OR transcript LIKE '%Ã%' OR transcript LIKE '%Â%' OR transcript LIKE '%Æ%' OR transcript LIKE '%Music%' OR transcript LIKE '%Musique%' OR transcript LIKE '%Applause%' OR transcript LIKE '%Applaudissements%';"

& $Sqlite $DbFile $vidsSql | ForEach-Object {
    if ($_ -match "---PIPE---") {
        $parts = $_ -split "---PIPE---", 3
        if ($parts.Count -lt 3) { return }
        
        $id = $parts[0].Trim()
        $vidId = $parts[1].Trim()
        $tr = $parts[2]
        
        # Sécurité : On vérifie que l'ID est bien un nombre
        if ($id -notmatch '^\d+$') { return }

        $processedCount++
        $modified = $false

        # Remplacement du Mojibake
        foreach ($key in $replacements.Keys) {
            if ($tr.Contains($key)) {
                $tr = $tr.Replace($key, $replacements[$key])
                $modified = $true
            }
        }

        # Remplacement du bruit (Noise)
        foreach ($pattern in $noisePatterns) {
            if ($tr -match $pattern) {
                $tr = $tr -replace $pattern, ""
                $modified = $true
            }
        }

        if ($modified) {
            $tr = ($tr -replace "\s+", " ").Trim()
            $escapedTr = $tr -replace "'", "''"
            "UPDATE videos SET transcript = '$escapedTr' WHERE id = $id;" | Out-File $batchFile -Encoding utf8 -Append
            $fixedCount++
        }

        if ($processedCount % 1000 -eq 0) {
            Write-Host "Analyse : $processedCount..." -ForegroundColor Gray
        }
    }
}

"COMMIT;" | Out-File $batchFile -Encoding utf8 -Append

if ($fixedCount -gt 0) {
    Write-Host "`nExécution des mises à jour ($fixedCount modifications)..." -ForegroundColor Yellow
    $sqlitePath = $batchFile.Replace("\", "/")
    & $Sqlite $DbFile ".read `"$sqlitePath`""
}

Remove-Item $batchFile -ErrorAction SilentlyContinue

Write-Host "`n--- NETTOYAGE TERMINÉ ---" -ForegroundColor Cyan
Write-Host "$fixedCount vidéos ont été polies et nettoyées sur $processedCount analysées." -ForegroundColor Green

