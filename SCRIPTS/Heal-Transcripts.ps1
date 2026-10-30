# Heal-Transcripts.ps1 (v15.7 - Pure Hex Logic)
$PSScriptRoot = Split-Path $PSCommandPath -Parent
. (Join-Path $PSScriptRoot "Global-Paths.ps1")

Write-Host "--- CLEANING (PURE HEX) ---"

$Pipe = [char]0x7C
$Box  = [char]0x251C
$Atilde = [char]0x00C3

$Map = @{}
$Map["$([char]0xAE)"] = "e"
$Map["$([char]0xBF)"] = "e"
$Map["$([char]0xAC)"] = "e"
$Map["$([char]0xEB)"] = "E"
$Map["$([char]0xE1)"] = "a"
$Map["$([char]0xAA)"] = "c"
$Map["$([char]0x2524)"] = "o"

$MapUtf8 = @{}
$MapUtf8["$Atilde$([char]0xA9)"] = "e"
$MapUtf8["$Atilde$([char]0xA8)"] = "e"
$MapUtf8["$Atilde$([char]0xA0)"] = "a"
$MapUtf8["$Atilde$([char]0xB9)"] = "u"
$MapUtf8["$Atilde$([char]0xA2)"] = "a"
$MapUtf8["$Atilde$([char]0xB4)"] = "o"
$MapUtf8["$Atilde$([char]0xBB)"] = "u"
$MapUtf8["$Atilde$([char]0xAB)"] = "e"
$MapUtf8["$Atilde$([char]0xAF)"] = "i"
$MapUtf8["$Atilde$([char]0xAE)"] = "i"
$MapUtf8["$Atilde$([char]0xA7)"] = "c"
$MapUtf8["$Atilde$([char]0xAA)"] = "e"

$q = "SELECT id, youtube_id, title, transcript FROM videos WHERE transcript LIKE '%$Pipe%' OR title LIKE '%$Pipe%' OR transcript LIKE '%$Box%' OR title LIKE '%$Box%' OR transcript LIKE '%$Atilde%' OR title LIKE '%$Atilde%';"
$videos = & $Sqlite -header -json $DbFile $q | ConvertFrom-Json

if (!$videos) { Write-Host "Nothing to fix."; exit }

Write-Host "Videos: $($videos.Count)"
$count = 0
foreach ($v in $videos) {
    $t = $v.title; $tr = $v.transcript; $c = $false
    if ($null -eq $t) { $t = "" }
    if ($null -eq $tr) { $tr = "" }
    foreach ($k in $Map.Keys) {
        foreach ($p in @($Pipe, $Box)) {
            $key = "$p$k"
            if ($t.Contains($key)) { $t = $t.Replace($key, $Map[$k]); $c = $true }
            if ($tr.Contains($key)) { $tr = $tr.Replace($key, $Map[$k]); $c = $true }
        }
    }
    foreach ($k in $MapUtf8.Keys) {
        if ($t.Contains($k)) { $t = $t.Replace($k, $MapUtf8[$k]); $c = $true }
        if ($tr.Contains($k)) { $tr = $tr.Replace($k, $MapUtf8[$k]); $c = $true }
    }
    if ($c) {
        $st = $t -replace "'", "''"; $str = $tr -replace "'", "''"
        $sqlFile = Join-Path $TempDir "heal.sql"
        "UPDATE videos SET title = '$st', transcript = '$str' WHERE id = $($v.id);" | Out-File $sqlFile -Encoding utf8
        & $Sqlite $DbFile ".read `"$sqlFile`""
        $p = Join-Path $ProjectRoot "assets\transcripts\$($v.youtube_id).txt"
        if (Test-Path $p) { $tr | Out-File $p -Encoding utf8 }
        $count++
    }
}
Write-Host "Done: $count"
