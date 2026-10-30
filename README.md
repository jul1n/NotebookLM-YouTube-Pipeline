# NotebookLM YouTube Pipeline

Pipeline Windows de découverte YouTube, récupération des sous-titres, transcription audio optionnelle et export de packs pour NotebookLM.

Le moteur Python conserve les entrées du menu PowerShell v15, SQLite et le dashboard local. Les médias et archives restent sur Google Drive. La base active et un cache temporaire peuvent être placés en local dans un budget partagé de **10 Go**, après copie vérifiée.

Lire [le guide stockage et pipeline](STORAGE_AND_PIPELINE.md) avant la migration ou un nettoyage. Il détaille les commandes, les sauvegardes, les reprises après erreur et les limites du budget local.

## Démarrage

Prérequis : Python 3.10+, PowerShell 7, yt-dlp et FFmpeg dans `RESOURCES/BIN`, sqlite3.exe pour les outils PowerShell du dashboard et une base existante `DATABASE/PIPELINE_V15.db`. Les transcriptions audio sont différées : le menu propose une liste de suivi des vidéos sans sous-titres exploitables.

```powershell
pwsh -NoProfile -File MASTER-COMMANDER-v15.ps1
```

Les cookies, bases, médias, configuration personnelle et chemins propres à la machine ne doivent pas être envoyés sur GitHub.

## Tests hors ligne

```powershell
python -m unittest discover -s SCRIPTS -p "test_*.py" -v
```
