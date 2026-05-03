# check_languages.ps1 - Filtre automatique des videos par langue
# Usage: .\check_languages.ps1

$BaseDir = $PSScriptRoot
$BlacklistPath = Join-Path $BaseDir "blacklist.txt"
$Log429Path = Join-Path $BaseDir "_LOGS\429_errors.txt"
$YtDlp = Join-Path $BaseDir "BIN\yt-dlp.exe"

# Langues autorisees
$AllowedLangs = @("fr", "en")

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "   DIAGNOSTIC DE LANGUE ET NETTOYAGE 429" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

# 1. Collecter les IDs a verifier
$idsToCheck = [System.Collections.Generic.HashSet[string]]::new()

# Ajouter les IDs du log 429
if (Test-Path $Log429Path) {
    $content = Get-Content $Log429Path
    foreach ($line in $content) {
        if ($line -match "^([a-zA-Z0-9_-]{11})") {
            [void]$idsToCheck.Add($Matches[1])
        }
    }
}

# Ajouter les IDs des missing_videos.txt existants
$missingFiles = Get-ChildItem -Path $BaseDir -Recurse -Filter "missing_videos.txt"
foreach ($f in $missingFiles) {
    $content = Get-Content $f.FullName
    foreach ($id in $content) {
        if ($id -match "^[a-zA-Z0-9_-]{11}$") {
            [void]$idsToCheck.Add($id)
        }
    }
}

Write-Host "Found $($idsToCheck.Count) unique IDs to verify." -ForegroundColor Yellow

if ($idsToCheck.Count -eq 0) {
    Write-Host "No IDs found. Work done." -ForegroundColor Green
    exit
}

# 2. Charger la blacklist actuelle pour eviter les doublons
$currentBlacklist = Get-Content $BlacklistPath

# 3. Verifier chaque ID
$count = 0
foreach ($id in $idsToCheck) {
    $count++
    if ($currentBlacklist -match [regex]::Escape($id)) { continue }

    Write-Host "[$count/$($idsToCheck.Count)] Checking $id... " -NoNewline
    
    try {
        # On recupere la langue et le titre
        $info = & $YtDlp --print "%(language)s|%(title)s" --no-warnings "https://www.youtube.com/watch?v=$id" 2>$null
        
        if ($null -eq $info -or $info -eq "") {
            Write-Host "No info (blocked?)" -ForegroundColor Gray
            continue
        }

        $parts = $info -split '\|'
        $lang = $parts[0]
        $title = $parts[1]

        if ($lang -and !($lang.StartsWith("fr") -or $lang.StartsWith("en"))) {
            Write-Host "REJECTED ($lang) - $title" -ForegroundColor Red
            "$id # [AUTO-LANG: $lang] $title" | Add-Content -Path $BlacklistPath
        } else {
            $displayLang = if ($lang) { $lang } else { "unknown" }
            Write-Host "KEEP ($displayLang)" -ForegroundColor Green
        }
    } catch {
        Write-Host "Error" -ForegroundColor Red
    }
    
    # Petit delai pour eviter d'etre banni du diagnostic lui-meme
    Start-Sleep -Milliseconds 500
}

Write-Host "`nFini ! La blacklist a ete mise a jour." -ForegroundColor Cyan
