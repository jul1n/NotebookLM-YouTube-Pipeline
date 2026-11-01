# Revue complète des transcriptions douteuses

`caption_full_review.py` examine tous les signalements, y compris les répétitions
rares. Il consulte les sources VTT/SRT, les exports TXT et les exports JSON locaux
identifiés par vidéo. Les noms sans identifiant peuvent être rapprochés d'un titre
unique, puis leur contenu doit confirmer la correspondance. Aucun accès YouTube,
audio ou Whisper n'est utilisé. La lecture des sources est bornée à 4 Go ; le
compteur persiste dans le cache local et n'est pas remis à zéro après un arrêt.

Les propositions restent séparées de la base. Une copie compressée de chaque
source acceptée et chaque original modifié est conservée. Une source TXT/JSON
est étiquetée comme telle, sans lui attribuer des horodatages.
Les candidats et décisions de travail sont préparés dans le cache local, puis
publiés sur Drive avec contrôle d'empreinte et quatre copies simultanées au plus.
Une reprise recharge les décisions et candidats vérifiés, sans recommencer la
lecture des exports JSON ni remettre à zéro le compteur de lecture.
Les prochaines lectures sont anticipées par un petit groupe de tâches d'entrée/
sortie ; elles partagent le même compteur de volume protégé contre les accès
concurrents. Aucun traitement réseau YouTube n'est ajouté.

`caption_review_finalize.py` vérifie les empreintes, contrôle les nombres et les
négations des remplacements depuis une source, et enrichit les correspondances
d'encodage depuis des couples de textes/sources déjà vérifiés. Chaque substitution
de caractère doit être démontrée dans au moins trois vidéos indépendantes, avec
au moins dix occurrences et sans cible contradictoire. Les rares lettres ASCII
porteuses d'un encodage imbriqué sont comptabilisées ; les chiffres et le texte
hors de ces séquences restent inchangés. Les réparations partielles dont des
marqueurs d'encodage subsistent sont rejetées.

Une restauration depuis une source horodatée peut rétablir des mots perdus par
un ancien nettoyage, même si elle réintroduit des hésitations réellement présentes
dans les sous-titres. Elle exige une concordance lexicale renforcée, la préservation
des nombres et négations, et l'absence de nouvelles répétitions longues. Les
répétitions isolées dans une prose sans preuve de format restent conservées.

L'application utilise le journal réversible `pipeline_revisions`, une sauvegarde
vérifiée avant/après, les contrôles SQLite/FTS, un audit final, puis la régénération
des packs et du dashboard. Les rapports privés distinguent les corrections,
les sources concordantes, les hésitations reconnues et les cas encore indécidables.
Une concordance avec des sous-titres ne certifie pas leur fidélité à l'audio.

## Déduplication des reprises orales autorisée le 1er novembre 2026

L’utilisateur accepte que les tics de langage, reprises et répétitions d’emphase soient retirés. `caption_spoken_dedup.py` retire les copies immédiatement adjacentes de mots ou groupes de mots (jusqu’à 128 mots), en comparant les mots sans tenir compte de leur casse ni de la ponctuation. Il conserve une occurrence, sans réécrire le vocabulaire, sans fusionner des passages éloignés et sans supprimer les groupes contenant des chiffres. Les nombres sont revérifiés et le résultat doit être idempotent. Une boucle déjà exclue pour absence de parole exploitable reste exclue.

Le plan contient les empreintes avant/après, le nombre de copies retirées et des exemples. L’application utilise le même journal de révision réversible et les mêmes sauvegardes, contrôles SQLite/FTS, audit complet et exports que les corrections de sources. Les sous-titres bruts ne sont pas modifiés. Aucun audio ni réseau.

```powershell
python SCRIPTS/caption_spoken_dedup.py --target DATABASE/pilot_reports/spoken-dedup-20261101 --apply
```

Une relance du même plan reprend les corrections déjà journalisées sans les dupliquer. Le fichier DONE.json indique la fin des contrôles et des exports.
