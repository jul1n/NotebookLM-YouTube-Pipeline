
$DbPath = "C:\NoteBookLM\DATABASE\PIPELINE_V15.db"
$Sqlite = "C:\NoteBookLM\RESOURCES\BIN\sqlite3.exe"

$TargetIDs = @('qP03ZwtQDQw', 'xqSKawORrPo', 'wKimU8jy2a8', 'sBCOrkn3lBk', 'i680MtxrKmk', '0iYGcI27adA')

Write-Host "--- POLISSAGE FINAL DES DERNIERS RESIDUS ---" -ForegroundColor Cyan

foreach ($id in $TargetIDs) {
    # On récupère le texte tel qu'il est
    $v = & $Sqlite -header -json $DbPath "SELECT title, transcript FROM videos WHERE youtube_id = '$id';" | ConvertFrom-Json
    
    if ($v) {
        $t = $v.title
        $tr = $v.transcript
        
        # Nettoyage manuel forcé des séquences identifiées
        $cleanT = $t -replace "├®", "é" -replace "├¿", "è" -replace "├á", "à" -replace "├¬", "ê"
        $cleanTr = $tr -replace "├®", "é" -replace "├¿", "è" -replace "├á", "à" -replace "├¬", "ê"
        
        $st = $cleanT -replace "'", "''"
        $str = $cleanTr -replace "'", "''"
        
        & $Sqlite $DbPath "UPDATE videos SET title = '$st', transcript = '$str' WHERE youtube_id = '$id';"
        Write-Host "[OK] Video $id nettoyée." -ForegroundColor Green
    }
}
