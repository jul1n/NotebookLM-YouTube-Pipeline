# Guide des commandes prises en charge

Le fonctionnement actuel et les règles de stockage sont décrits dans [STORAGE_AND_PIPELINE.md](STORAGE_AND_PIPELINE.md). Les choix confirmés sont dans `pipeline_policy.json`.

- `MASTER-COMMANDER-v15.ps1` : menu manuel. Aucune planification automatique.
- `SCRIPTS/Discover-New-v15.ps1` : découverte des vidéos ; `-SpecificChannel` pour cibler une chaîne.
- `SCRIPTS/Industrial_Pipeline_v15_Unified_Sync.ps1` : acquisition et import des sous-titres, avec cache et reprises différées.
- `SCRIPTS/Audit-DataHealth.ps1` et `SCRIPTS/Sync-Dashboard-v15.ps1` : état de la base et données du dashboard.
- `SCRIPTS/Run-Dashboard-Server.ps1` : dashboard sur localhost:8080.
- `SCRIPTS/Audit-Storage-v15.ps1` : inventaire sans suppression. Le rapport ne mesure pas le cache physique de Google Drive.
- `SCRIPTS/Backup-Database.ps1` : sauvegarde SQLite vérifiée ; conservation des trois dernières sauvegardes gérées.
- `SCRIPTS/Enable-Local-Runtime.ps1` : migration vérifiée de la seule base active, après arrêt des traitements.
- `SCRIPTS/Batch-Generate-Packs.ps1` et `SCRIPTS/Export-Packs.ps1` : générateur commun, limite de 200 000 mots par défaut.
- `python SCRIPTS/pipeline_core.py missing-captions` : suivi des vidéos sans transcription, avec distinction des causes.
- `python SCRIPTS/pipeline_core.py validate-channel --channel ScienceEtonnante --limit 2` : validation hors ligne dans une base pilote isolée.
- `python SCRIPTS/pipeline_core.py packs --channel ScienceEtonnante` : export ciblé, sans remplacement des packs globaux.

Les commandes audio sont différées et bloquées par la politique active. Les suppressions de médias restent suspendues jusqu'à présentation et approbation d'un lot précis. Les anciens outils v14 et les variantes spécifiques sont conservés pour référence ; ils ne constituent pas le parcours validé.

## Tests hors ligne

```powershell
python -m unittest discover -s SCRIPTS -p "test_*.py" -v
```
