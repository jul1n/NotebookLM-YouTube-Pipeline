# Réduction du stockage — 31 octobre 2026

Les volumes de l'inventaire sont des tailles logiques sur Drive. Ils ne mesurent
pas la place physique du cache Drive sur C:.

La présence d'un texte en base produit des candidats, jamais une preuve de qualité.
Le traitement autorisé conserve les fichiers incertains et journalise chaque
suppression avec chemin, taille, identifiant vidéo et empreinte du texte.

## Médias

Avant suppression : identité dans le nom de fichier, texte actif identique dans
une sauvegarde SQLite vérifiée, absence de marqueurs techniques et d'encodage
corrompu. Les textes sans alerte heuristique bénéficient aussi d'une copie finale
compressée. Cette copie n'est pas présentée comme une source horodatée.

Pour les textes présentant des répétitions, les cas prioritaires restent protégés.
Les autres doivent concorder avec une source VTT/SRT compressée dont l'empreinte
est contrôlée. Les répétitions réellement prononcées restent présentes.

Les sources canoniques, originaux des corrections, sauvegardes et journaux SQLite
ne sont jamais des cibles de ce traitement. Les chemins et dates de modification
sont recontrôlés immédiatement avant suppression, sans suppression récursive.

## Métadonnées

Les anciens fichiers yt-dlp sont inutiles à la prochaine mise à jour du pipeline
actuel : celui-ci conserve les identifiants/états en SQLite et ne traite pour les
sous-titres que les vidéos dont le texte est absent. Son fichier info.json de
travail est créé temporairement pour une nouvelle acquisition.

Un ancien fichier info.json n'est retiré que si son identifiant et son titre
correspondent à la base, avec texte sauvegardé à l'identique. Pour les petits
fichiers, l'identifiant interne est contrôlé. Les gros fichiers cloud ne sont pas
ouverts uniquement pour les supprimer, afin d'éviter leur hydratation intégrale.
Les champs volatils (URLs signées, formats disponibles, statistiques) ne sont pas
archivés ; les informations utiles déjà en base et la liste des anciens chemins
restent conservées. Les cas sans correspondance restent en place.

## Git

Ne jamais publier l'ancienne branche privée ni toutes les références. Avant de
retirer son historique local : vérifier un bundle privé préservant l'historique
du code, des sources texte/sous-titres et de la configuration ; les anciens packs,
exports de dashboard, métadonnées et exécutables générés sont exclus du bundle ;
tester et publier les changements actuels sur main ; vérifier l'égalité avec
origin/main. Le bundle et les preuves restent exclus de GitHub.

Les fichiers intermédiaires et anciens packs hors de ces lots doivent faire
l'objet d'un contrôle séparé avant suppression. Le dashboard en mode fichier
utilise encore assets/transcripts : ne pas supprimer ce dossier en bloc.
