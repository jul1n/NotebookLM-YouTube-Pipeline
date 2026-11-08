# Pipeline : stockage limité et reprise fiable

## Répartition retenue

- Budget du répertoire de travail local : **10 000 000 000 octets (10 Go)**, base et cache compris.
- Médias historiques, VTT compressés, modèles Whisper, résultats détaillés et exports restent sur Google Drive.
- Seule la base active est copiée en local après vérification. La source Drive reste conservée.
- Les nouveaux audios sont temporaires, traités un par un et limités à 512 Mio. Une réserve de 1 Gio libre sur le volume est exigée.
- Le moteur vérifie la taille du répertoire local avant chaque acquisition et pendant yt-dlp. Il arrête le traitement si le budget est atteint ; il ne supprime pas de données pour le contourner.
- Ce plafond couvre les fichiers gérés par le pipeline. **Le cache propre de Google Drive et les dépendances Python installées hors de ce répertoire ne sont pas contrôlés par ce compteur.** Lire un média sur un lecteur Drive peut le rendre disponible dans le cache de Drive. Aucun rapatriement massif des médias n'est effectué.

## Architecture compatible avec le menu v15

`SCRIPTS/pipeline_core.py` utilise Python 3.10+ et sa bibliothèque standard pour SQLite, RSS, inventaire, VTT, sauvegardes et exports. yt-dlp et FFmpeg restent dans `RESOURCES/BIN`.
Les entrées PowerShell du menu délèguent au même moteur. `Global-Paths.ps1` lit `DATABASE/local-runtime.json` si une migration a été validée. Ce fichier est propre à cette machine et ignoré par Git. Une base configurée mais absente provoque un arrêt explicite plutôt qu'un repli silencieux sur une ancienne copie.

Avant la migration, arrêter les traitements du projet puis lancer :

```powershell
pwsh -NoProfile -File SCRIPTS/Enable-Local-Runtime.ps1
```

Le script vérifie les processus connus. Le moteur utilise une sauvegarde SQLite pour WAL, ou une copie séquentielle sous transaction de lecture pour un journal classique. `quick_check` et les comptages vidéos/chaînes doivent réussir avant activation. La source n'est pas supprimée. Ne pas relancer les anciens scripts v13/v14 contre une copie indépendante après la bascule.

## Synchronisation et demandes à YouTube

```powershell
pwsh -NoProfile -File SCRIPTS/Discover-New-v15.ps1
pwsh -NoProfile -File SCRIPTS/Industrial_Pipeline_v15_Unified_Sync.ps1
```

La découverte lit toutes les chaînes SQLite ; `-SpecificChannel` permet de cibler une chaîne. Les identifiants de chaîne résolus sont conservés pour réutiliser RSS. RSS et le rattrapage de 50 vidéos ne remplacent pas un inventaire historique complet après une longue interruption.

Les tâches sont sélectionnées directement en base, sans dépendre du rapport de santé exporté. Les VTT/SRT existants dans les anciens dossiers sont recherchés avant tout accès réseau et conservés ; les sous-titres en cache sont traités hors ligne. Pour une acquisition nouvelle, les métadonnées sont extraites une seule fois puis réutilisées avec `--load-info-json` ; une seule langue est téléchargée, en privilégiant les sous-titres humains.

`pipeline_attempts` conserve erreur, nombre de tentatives et prochaine date. Absence de sous-titres : 7 jours ; échec de téléchargement : 24 heures ; HTTP 429 : suspension globale de 62 minutes. `-ForceRetry` contourne les délais individuels mais pas la suspension globale. Un verrou système interdit deux acquisitions simultanées. Ces délais réduisent les accès et ne garantissent pas l'absence de limitation YouTube.

Les VTT sont conservés dans `WORKING_ZONE/_CAPTIONS_GZ`. Le nettoyage supprime les chevauchements entre deux cues temporellement superposés, sans éliminer les répétitions ultérieures ni rejeter un texte uniquement parce qu'il fait moins de 100 caractères. Le texte existant n'est pas écrasé. Provenance, langue, empreinte et version du nettoyeur sont enregistrées dans `pipeline_transcripts` ; les anciens statuts restent compatibles avec le dashboard.

## Vidéos sans sous-titres : suivi, tests audio différés

Aucune transcription audio n'est lancée à ce stade. La politique `audio_transcription_mode: deferred` bloque aussi les commandes audio existantes. Le menu 8 produit une liste de suivi :

```powershell
python SCRIPTS/pipeline_core.py missing-captions
```

Le rapport privé est enregistré dans `DATABASE/pilot_reports`. Il distingue les sous-titres FR/EN signalés absents, les contenus trop courts à vérifier, les erreurs réseau et les vidéos qui n'ont pas encore été vérifiées. `ERR_NO_EN_FR` ne prouve pas une absence de sous-titres dans toutes les langues. Les tests Whisper sur les quelques vidéos réellement concernées sont reportés à une étape ultérieure ; les transcriptions existantes ne sont pas remplacées.

## Validation d'une chaîne avec ses sous-titres existants

```powershell
python SCRIPTS/pipeline_core.py validate-channel --channel ScienceEtonnante --limit 2
python SCRIPTS/pipeline_core.py packs --channel ScienceEtonnante
```

La première commande réimporte au plus deux vidéos depuis leurs VTT/SRT dans une base pilote isolée. Elle vérifie l'intégrité SQLite, l'index FTS, la génération des packs et l'absence de changement dans les transcriptions de production. Elle ne contacte pas YouTube et ne traite aucun audio. La seconde exporte la chaîne entière dans un sous-dossier `assets/pilot-packs`, sans remplacer les packs globaux. Les rapports privés restent dans `DATABASE/pilot_reports`.

## Sauvegarde et stockage

```powershell
pwsh -NoProfile -File SCRIPTS/Backup-Database.ps1
pwsh -NoProfile -File SCRIPTS/Audit-Storage-v15.ps1
```

Les sauvegardes vérifiées sont écrites dans `DATABASE/snapshots` sur Drive. La rétention est de trois sauvegardes gérées et vérifiées. Chaque nouvelle sauvegarde reçoit un manifeste de vérification ; seules les anciennes sauvegardes dotées d'un manifeste du pipeline peuvent être retirées lors de la rotation. Les anciennes copies sans manifeste restent intactes et seront examinées séparément. L'inventaire compte les tailles logiques, pas les octets physiques du cache Drive. Il conserve les fichiers sans ID fiable dans la liste des médias et signale les erreurs de parcours.

Le dashboard lit le rapport existant au lieu de relancer un scan récursif à chaque affichage. La suppression des médias est bloquée par la politique tant qu'aucun lot précis n'a été présenté et approuvé. Les protections existantes exigent en outre un POST explicite, un inventaire complet de moins d'une heure, un média inchangé dans le projet et une transcription identique dans la base active et la dernière sauvegarde. L'exécution de cet outil ne lance aucune purge. Ne jamais supprimer manuellement les journaux SQLite pour débloquer la base.

## Packs

`Batch-Generate-Packs.ps1` et `Export-Packs.ps1` utilisent le même générateur, avec 200 000 mots par défaut (paramètre `-WordLimit`). Les titres et liens source sont comptés ; une vidéo trop longue est répartie sur plusieurs packs. Un manifeste associe chaque pack à ses vidéos. La génération précédente reste sur Drive et n'est remplacée qu'après une construction réussie. La rétention des anciennes générations reste manuelle.

## Vérification hors ligne

```powershell
python -m unittest discover -s SCRIPTS -p "test_*.py" -v
```

Les tests utilisent uniquement des bases temporaires et des médias synthétiques : nettoyage, répétitions, cache, erreurs, HTTP 429, budget, verrou, migration, sauvegarde, import, purge, RSS et génération sans perte des anciens packs. Ils ne contactent pas YouTube.

## Points encore à traiter

- Confirmer les rares vidéos réellement sans sous-titres ; tester Whisper plus tard uniquement sur celles-ci.
- Examiner les lots de médias et les anciennes générations avant toute suppression ; conserver trois sauvegardes vérifiées.
- Reprendre les anciens scripts de maintenance v14 et les variantes spécifiques ; ils ne constituent pas le nouveau parcours pris en charge.
- Contrôler le cache Google Drive séparément si son occupation devient importante.

## Choix confirmés

- Exécution uniquement à la demande ; aucune planification automatique.
- Chaîne pilote : ScienceEtonnante, validation avant nettoyage.
- Conservation durable : texte, sous-titres horodatés compressés et provenance.
- Suppression des médias : accord explicite sur chaque lot.
- Tests audio : différés ; suivi des vidéos concernées seulement.
- Sauvegardes : trois dernières sauvegardes gérées et vérifiées.
- Publication des commits : directement sur `main`, sans forcer l'historique.

Ces règles sont matérialisées par `pipeline_policy.json`. Le budget local de 10 Go reste inchangé.

## Qualité et retraitement sans YouTube

```powershell
python SCRIPTS/caption_quality.py --samples 6
# Ou une chaîne seulement :
python SCRIPTS/caption_quality.py --channel "Marc Lou" --samples 3
```

Le contrôle lit les transcriptions sans modifier la base et produit un rapport privé sous `DATABASE/pilot_reports`. Il repère horodatages, balises VTT et répétitions suspectes. Les répétitions naturelles ne sont pas supprimées automatiquement. « Aucune alerte » signifie seulement qu'aucune règle de détection n'a réagi.

Des fichiers `before.txt` et `after.txt` permettent une lecture rapide. Quand un VTT/SRT est retrouvé, le candidat est régénéré depuis cette source ; le brut compressé, son empreinte et la version du nettoyeur sont conservés. Si aucun VTT/SRT n'est retrouvé, le contrôle recherche le format historique où une ligne horodatée est suivie de deux copies identiques. Le motif doit être confirmé au moins deux fois et couvrir 80 % des lignes horodatées. Il conserve une copie par groupe ; les répétitions dans une même ligne ou à des horodatages distincts restent présentes. Les groupes sans horodatage inférés de ce format sont signalés pour relecture. Sans preuve suffisante du format, seules les balises sont nettoyées. Tous ces résultats restent des copies à valider, sans remplacement en base.

La règle de conservation est donc : une source horodatée exploitable et vérifiée, sa provenance et un texte validé. Les anciennes versions TXT et packs sont des dérivés régénérables. Aucune purge ne doit reposer sur la seule présence d'un texte en base : source retraitable et contrôle qualité sont également nécessaires, puis accord explicite sur le lot.

## Reconstruction des copies de fenêtres historiques

`SCRIPTS/caption_reconstruction.py` traite le motif observé dans les exemples Marc Lou : un bloc enrichi de balises, puis deux rendus identiques en clair. Il ne recherche pas des phrases répétées à supprimer dans un texte quelconque. Chaque ligne retirée doit être une copie normalisée exacte du bloc gardé ; le nombre de lignes et de mots conservés est contrôlé. Les répétitions à des instants différents sont conservées.

Le rapport enregistre version, empreintes, groupes confirmés, groupes sans horodatage inférés, régressions temporelles et blocs avant/après alignés. Il fournit aussi le début du texte reconstruit pour une lecture continue. Les inférences et les alertes résiduelles nécessitent une relecture. Les erreurs de reconnaissance vocale du sous-titre d'origine ne sont pas corrigées par cette reconstruction.

## Entretien local des anomalies historiques

`python SCRIPTS/caption_maintenance.py --plan DATABASE/pilot_reports/nom-du-lot` prépare un plan privé sans modifier les textes. L'option facultative `--baseline CHEMIN/RESULT.json` utilise un audit antérieur pour prioriser ; chaque modification proposée est revérifiée sur le texte actuel et un nouvel audit complet suit l'application.

Après lecture du rapport : `python SCRIPTS/caption_maintenance.py --plan DATABASE/pilot_reports/nom-du-lot --apply`.

Le traitement retire les paires d'en-têtes `Kind: captions Language: ...` uniquement en début de texte, ainsi que leurs paramètres d'affichage. Les balises restantes sont nettoyées sans correction du vocabulaire. Dans les fichiers partiellement endommagés, seules les copies identiques rattachées à une ligne horodatée sont retirées, avec au moins dix groupes confirmés ; les groupes sans horodatage restent présents.

Pour les anciens textes aplatis sans horodatage, la reconstruction exige au moins 98 % de mots dans des triples copies exactes, cent groupes au total et trente groupes de six mots ou plus. Seules les copies des groupes d'au moins six mots sont retirées. Cette règle est une inférence du format du document, pas une certification de la parole originale. Les répétitions courtes, partielles, isolées ou insuffisamment documentées restent signalées.

L'application exige le journal `pipeline_revisions` existant, effectue une sauvegarde vérifiée, conserve chaque original compressé avec ses empreintes et préserve la provenance de la source horodatée. Une modification concurrente interrompt le traitement. Une reprise ne réapplique pas les textes déjà identiques au résultat prévu. SQLite/FTS sont contrôlés, les packs et le dashboard régénérés, puis une sauvegarde finale est vérifiée. Aucun appel à YouTube, aucun audio, aucune suppression de média ou d'archive historique.


## Lot manuel de vidéos en attente

`python SCRIPTS/pending_runner.py --job DATABASE/pending_runs/nom-du-lot --prepare` fige la liste exacte des vidéos PENDING sans texte. La même commande sans `--prepare` lance le lot. Les autres catégories et les nouvelles fiches ajoutées après préparation ne sont pas intégrées à ce lot.

Le traitement indexe les sources locales une fois, sélectionne chaque identifiant explicitement et espace les invocations yt-dlp d’au moins 60 secondes. Il désactive les relances internes et s’arrête au premier échec réseau. Il conserve un état privé, une liste QUEUE.json et un REPORT.md dans le répertoire du lot. Il sauvegarde avant acquisition, tous les 50 éléments et à la fin. Packs et tableau de bord sont actualisés à la fin ou après un blocage réseau.

Un lot terminé, bloqué ou en erreur n’est pas relancé automatiquement. Une requête interrompue nécessite une vérification avant nouvelle tentative. Aucun audio ni suppression n’est exécuté. La commande peut être lancée une fois en arrière-plan, sans créer de planification récurrente. Sur plusieurs centaines de vidéos, le traitement peut durer plus d’une journée. Le plafond local reste de 10 Go.


### Reprise après limitation et cache des extractions

Le lot de sous-titres conserve les métadonnées d’extraction utiles pendant six heures dans le cache local privé. Une reprise après échec des sous-titres réutilise ces données au lieu de réextraire la même vidéo. Les cookies et en-têtes d’authentification ne sont pas conservés dans ce cache. Les métadonnées périmées sont retirées à la prochaine extraction. La rétention durable des sous-titres et du texte reste inchangée.

Après HTTP 429, le moteur attend la fin de la suspension globale de 62 minutes, puis reprend la même vidéo. Trois blocages consécutifs provoquent un arrêt définitif du passage, sans boucle de relance indéfinie. Une vidéo traitée réinitialise uniquement ce compteur consécutif ; le nombre total d’appels et de tentatives est conservé. Les autres erreurs arrêtent toujours le lot. Le rythme reste d’au moins une minute entre invocations yt-dlp, avec un seul processus réseau.

Pour reprendre explicitement un ancien lot arrêté sur HTTP 429 : `python SCRIPTS/pending_runner.py --job DATABASE/pending_runs/nom-du-lot --resume`. Les résultats antérieurs sont conservés, la dernière vidéo bloquée est reprise et les contrôles finaux sont régénérés. Un arrêt d’origine inconnue n’est pas repris automatiquement. Les sections antérieures décrivant l’arrêt à chaque 429 correspondent au comportement initial, remplacé par cette reprise bornée.
