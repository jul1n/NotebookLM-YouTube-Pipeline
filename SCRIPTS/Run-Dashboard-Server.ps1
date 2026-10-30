# Run-Dashboard-Server.ps1 (v15.0 Pro Edition)
# Serveur HTTP local pour recherche Full-Text ultra-rapide.

$PSScriptDir = Split-Path $PSCommandPath -Parent
. (Join-Path $PSScriptDir "Global-Paths.ps1")

$Port = 8080
$Url = "http://localhost:$Port/"

# Force l'encodage UTF-8 pour la sortie console et les interactions avec les processus externes (sqlite3)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$Listener = New-Object System.Net.HttpListener
$Listener.Prefixes.Add($Url)

function Send-Response($Context, $Content, $ContentType = "text/html") {
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($Content)
    $Context.Response.ContentLength64 = $buffer.Length
    $Context.Response.ContentType = $ContentType
    $Context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $Context.Response.Close()
}

function Invoke-Sqlite-Json($Query) {
    $res = & $Sqlite -header -json $DbFile "$Query" 2>$null
    if ($res) { return ($res -join "") }
    return "[]"
}

Write-Host "`n--- SERVEUR DASHBOARD PRO LANCE ---" -ForegroundColor Cyan
Write-Host "URL : $Url" -ForegroundColor Green
Write-Host "Appuyez sur CTRL+C pour arrêter le serveur." -ForegroundColor Gray

$Listener.Start()

try {
    while ($Listener.IsListening) {
        $Context = $Listener.GetContext()
        $Request = $Context.Request
        $Path = $Request.Url.LocalPath
        
        # API : Recherche Full-Text
        if ($Path -eq "/api/search") {
            $query = $Request.QueryString["q"]
            if (![string]::IsNullOrWhiteSpace($query)) {
                # Protection basique injection SQL / FTS5 (on ne garde que l'alpha-numérique et l'espace pour la recherche)
                $query = $query -replace "[^\p{L}\p{N}\s]", ""
                $query = ((@($query -split '\s+' | Where-Object { $_ }) | ForEach-Object { '"' + $_ + '"*' }) -join ' AND ')
                if (!$query) { Send-Response $Context "[]" "application/json"; continue }
                # Recherche Pro avec FTS5 (High Performance)
                $sql = "SELECT v.youtube_id, v.title, v.upload_date, v.duration, c.prefix as channel, 
                               snippet(videos_fts, 2, '<b>', '</b>', '...', 64) as transcript_snippet
                        FROM videos_fts f
                        JOIN videos v ON f.rowid = v.id
                        JOIN channels c ON v.channel_id = c.id
                        WHERE videos_fts MATCH '$query'
                        ORDER BY rank
                        LIMIT 100;"
                $results = Invoke-Sqlite-Json $sql
                Send-Response $Context $results "application/json"
            } else {
                Send-Response $Context "[]" "application/json"
            }
        }
        # API : Charger Transcription Complète
        elseif ($Path -eq "/api/transcript") {
            $id = $Request.QueryString["id"]
            if ($id -match '^[a-zA-Z0-9_-]{11}$') {
                $sql = "SELECT transcript FROM videos WHERE youtube_id = '$id';"
                $res = & $Sqlite $DbFile $sql 2>$null
                Send-Response $Context ($res -join "`n") "text/plain"
            } else {
                $Context.Response.StatusCode = 400
                Send-Response $Context "Invalid YouTube ID" "text/plain"
            }
        }
        # API : Rapport de stockage
        elseif ($Path -eq "/api/storage") {
            # Regénère l'audit en arrière-plan à chaque chargement de l'onglet
            # Explicit maintenance updates this report; reads never start a recursive scan.
            $reportFile = Join-Path $DatabaseDir "storage_report.json"
            if (Test-Path $reportFile) {
                $reportData = Get-Content $reportFile -Raw -Encoding utf8
                Send-Response $Context $reportData "application/json"
            } else {
                Send-Response $Context "{}" "application/json"
            }
        }
        # API : Purge chirurgicale approuvée
        elseif ($Path -eq "/api/purge") {
            $origin = $Request.Headers['Origin']
            $sameOrigin = !$origin -or $origin -eq $Request.Url.GetLeftPart([UriPartial]::Authority)
            if ($Request.HttpMethod -ne 'POST' -or $Request.Headers['X-Pipeline-Action'] -ne 'purge' -or !$sameOrigin) {
                $Context.Response.StatusCode = 405
                Send-Response $Context '{"status":"error","message":"POST explicite depuis le dashboard requis."}' 'application/json'
            } else {
                $targetFile = $Request.QueryString['file']
                if (!$targetFile) {
                    $Context.Response.StatusCode = 400
                    Send-Response $Context '{"status":"error","message":"Fichier manquant."}' 'application/json'
                } else {
                    $purgeResult = & python (Join-Path $ScriptsDir 'pipeline_core.py') purge --root $ProjectRoot --file $targetFile 2>$null
                    if ($LASTEXITCODE -ne 0) { $Context.Response.StatusCode = 409 }
                    if (!$purgeResult) { $purgeResult = '{"status":"error","message":"Purge impossible : vérifiez audit et sauvegarde."}' }
                    Send-Response $Context ($purgeResult -join "`n") 'application/json'
                }
            }
        }
        # Fichiers statiques (Dashboard.html et assets)
        else {
            $filePath = Join-Path $ProjectRoot $Path.TrimStart('/')
            # Protection contre le Path Traversal
            $normalizedProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot).ToLower()
            $normalizedFilePath = [System.IO.Path]::GetFullPath($filePath).ToLower()
            if ($Path -eq "/") { 
                $filePath = Join-Path $ProjectRoot "Dashboard.html" 
                $normalizedFilePath = [System.IO.Path]::GetFullPath($filePath).ToLower()
            }
            
            $assetsRoot = [IO.Path]::GetFullPath((Join-Path $ProjectRoot 'assets')).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
            $allowedAsset = $normalizedFilePath.StartsWith($assetsRoot, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetExtension($filePath) -in @('.js','.css','.png','.jpg','.jpeg','.svg','.ico','.txt')
            $allowedDashboard = $normalizedFilePath -eq [IO.Path]::GetFullPath((Join-Path $ProjectRoot 'Dashboard.html')).ToLower()
            if (($allowedDashboard -or $allowedAsset) -and (Test-Path -LiteralPath $filePath -PathType Leaf)) {
                $content = [System.IO.File]::ReadAllBytes($filePath)
                $ext = [System.IO.Path]::GetExtension($filePath)
                $ct = switch($ext) {
                    ".html" { "text/html" }
                    ".js"   { "application/javascript" }
                    ".css"  { "text/css" }
                    ".png"  { "image/png" }
                    default { "application/octet-stream" }
                }
                $Context.Response.ContentType = $ct
                $Context.Response.OutputStream.Write($content, 0, $content.Length)
                $Context.Response.Close()
            } else {
                $Context.Response.StatusCode = 403
                $Context.Response.Close()
            }
        }
    }
}
finally {
    $Listener.Stop()
}
