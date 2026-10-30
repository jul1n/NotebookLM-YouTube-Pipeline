# Search-Deep.ps1
# Recherche dans l'INTEGRALITE des transcriptions SQLite

param (
    [Parameter(Mandatory=$true)]
    [string]$Query
)

$BaseDir = $PSScriptRoot
$DbDir = Join-Path $BaseDir "DATA_STORES"
$SqliteExe = Join-Path $BaseDir "BIN\sqlite3.exe"
$IndexPath = Join-Path $BaseDir "data.js"

function Invoke-Sqlite {
    param($DbPath, $Query)
    $cleanPath = $DbPath.Replace('"', '')
    $res = & $SqliteExe -header -json "$cleanPath" "$Query" 2>$null
    if ($res) { return ($res -join "") | ConvertFrom-Json }
    return @()
}

Write-Host "--- RECHERCHE PROFONDE : '$Query' ---" -ForegroundColor Cyan

$dbFiles = Get-ChildItem $DbDir -Filter "*.db"
$results = [System.Collections.Generic.List[PSObject]]::new()

foreach ($db in $dbFiles) {
    $chanName = $db.BaseName
    $sqlQuery = "SELECT youtube_id as id, title as t, upload_date as d, duration as dur, SUBSTR(transcript, 1, 1000) as txt FROM videos WHERE transcript LIKE '%$Query%' OR title LIKE '%$Query%';"
    
    $data = Invoke-Sqlite -DbPath $db.FullName -Query $sqlQuery
    if ($data) {
        foreach ($v in $data) {
            $v | Add-Member -MemberType NoteProperty -Name "c" -Value $chanName
            $results.Add($v)
        }
        Write-Host "  [+] $chanName : $($data.Count) matchs" -ForegroundColor Green
    }
}

# Mise a jour de data.js avec UNIQUEMENT les resultats de la recherche
$indexJs = "const VIDEO_INDEX = " + ($results | ConvertTo-Json -Depth 2) + ";"
$indexJs | Out-File $IndexPath -Encoding utf8

Write-Host "`nTermine ! $($results.Count) resultats trouves. Rafraichissez votre Dashboard." -ForegroundColor Cyan
