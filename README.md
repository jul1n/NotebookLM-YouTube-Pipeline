# YouTube Knowledge Pipeline v9.3 🚀
### Industrialization of YouTube Transcript Extraction for LLMs & NotebookLM

Ce pipeline est un système industriel conçu pour extraire, nettoyer et packager les connaissances issues de centaines de chaînes YouTube. Il transforme des milliers d'heures de vidéo en fichiers texte ultra-denses, optimisés pour être ingérés par des outils comme **NotebookLM**, **ChatGPT**, ou **Claude**.

---

## 🌟 Points Forts & Subtilités

- **Traitement Multi-Chaînes** : Gérez des dizaines de chaînes en un seul clic via un fichier de configuration CSV.
- **Double Nettoyage (V1 & V2)** : 
    - **V1 (TXT)** : Transcription propre avec en-têtes (URL, Titre, Date).
    - **V2 (DENSE)** : Version compressée à l'extrême (suppression des balises, répétitions, espaces inutiles) pour maximiser la fenêtre contextuelle des LLM.
- **Packaging "ULTRA"** : Fusionne les transcriptions dans des "packs" de ~500 000 mots, organisés par ordre chronologique avec un nommage intelligent `Prefix_XX_(Date-au-Date).txt`.
- **Synchronisation Google Drive Safe** : Optimisation des flux d'écriture (mémoire tampon) pour éviter les erreurs d'accès lors de la synchronisation simultanée vers le cloud.
- **Liste Noire Intelligente & Temporisée** : 
    - Ignore les vidéos sans sous-titres.
    - **Nouveauté v9.3** : Support des dates d'expiration `[YYYY-MM-DD]` pour débloquer automatiquement les "Premières" une fois sorties.
- **Robustesse Anti-Ban** : Gestion fine des délais d'attente (sleep) et support des cookies de navigateurs pour contourner les protections YouTube (Erreur 429).

---

## 🛠️ Structure du Projet

```text
📂 PROJET_ROOT
├── 📂 BIN                     # Exécutables (yt-dlp.exe, ffmpeg.exe)
├── 📂 ALL_PACKS                # Centralisation de TOUS les packs générés
├── 📂 [Nom_de_Chaine]          # Dossier créé automatiquement par chaîne
│   ├── 📂 1_RAW                # Fichiers bruts (.vtt, .json)
│   ├── 📂 2_TXT                # Transcriptions propres (V1)
│   ├── 📂 3_TXT_dense          # Transcriptions compressées (V2)
│   └── 📂 4_Packs              # Packs fusionnés finaux
├── 📄 channels_config.csv      # Configuration des chaînes (URL, Préfixe, Langue)
├── 📄 blacklist.txt            # Liste des vidéos à ignorer
└── 📄 pipeline_v9.ps1          # Le script principal (v9.3)
```

---

## 🚀 Installation & Utilisation

### 1. Prérequis
- **PowerShell 7+** : [Télécharger ici](https://github.com/PowerShell/PowerShell/releases). 
- **Oh My Posh** (Interface visuelle) :
    - Installation : `winget install JanDeDobbeleer.OhMyPosh -s winget`
    - Configuration : [Documentation officielle](https://ohmyposh.dev/docs/installation/windows)
- **yt-dlp.exe** : [Télécharger ici](https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe) (à placer dans le dossier `BIN`).
- **ffmpeg.exe** : [Télécharger ici](https://www.gyan.dev/ffmpeg/builds/ffmpeg-git-essentials.7z).
    - **Note** : Extrayez tout le contenu du dossier `bin` de l'archive (incluant `ffmpeg.exe` et les éventuelles DLL) dans le dossier `BIN` de votre projet.
- **Cookies YouTube** :
    - **Recommandation importante** : Utilisez le navigateur **Firefox**.
    - Les navigateurs basés sur Chromium (Chrome, Edge) posent souvent des problèmes de verrouillage de base de données.
    - Le format `cookies.txt` peut être capricieux ; l'option `--cookies-from-browser firefox` intégrée au script est la plus stable.

### 2. Configuration
Remplissez le fichier `channels_config.csv` :
```csv
URL;Prefixe;Langue
https://youtube.com/@Channel1;CH1;fr
https://youtube.com/@Channel2;CH2;en
```

### 3. Lancement
Ouvrez votre terminal dans le dossier du projet :
```powershell
cd "C:\Chemin\Vers\Votre\Dossier\NotebookLM"
```

Puis exécutez la commande suivante (elle permet de contourner les restrictions de script par défaut) :
```powershell
pwsh -ExecutionPolicy Bypass -File .\pipeline_v9.ps1
```

---

## 🧩 Fonctions Clés en Détail

### `Sync-YouTube` (Le Cœur)
Cette fonction scanne la chaîne, compare avec vos fichiers locaux et télécharge uniquement ce qui manque.
- **Subtilité** : Elle intègre un système de filtrage par `blacklist.txt`. Si une vidéo est dans la liste, elle est totalement ignorée.
- **Anti-429** : Utilise des intervalles de sommeil aléatoires pour imiter un comportement humain.

### `Process-LocalFiles` (Le Nettoyeur)
Transforme les fichiers `.vtt` ou `.srt` en textes lisibles.
- **V2 Dense** : Utilise des expressions régulières avancées pour supprimer tout ce qui n'est pas de la connaissance pure, réduisant la taille des fichiers de 30 à 50% sans perte de sens.

### `Build-Packs` (L'Architecte)
Regroupe les fichiers denses en volumes massifs.
- **Algorithme de seuil** : Dès qu'un pack atteint 500 000 mots, il en commence un nouveau.
- **Mirroring** : Copie automatiquement les packs finaux vers `ALL_PACKS` en nettoyant les anciennes versions pour éviter les doublons.

### `Revue de Liste Noire` (L'Apprentissage)
En fin de traitement, si des vidéos ont échoué par manque de sous-titres, le pipeline vous propose de les ajouter à la liste noire interactivement.

---

## 🌑 Gestion de la Blacklist (Subtilités v9.3)

Le fichier `blacklist.txt` accepte deux formats :
1. **Permanent** : `VIDEO_ID # Raison` (ex: `xiBqQ6D1q60 # Musique`)
2. **Temporisé** : `VIDEO_ID # [YYYY-MM-DD] Description` (ex: `DlM96_ltL40 # [2026-04-30] Premiere`)
   *Le script ignorera cette vidéo jusqu'à la date indiquée, puis retentera le téléchargement automatiquement après cette date.*

---

## 📜 Licence & Crédits

Développé avec passion pour transformer le chaos de YouTube en nectar de connaissances.

**Licence "Gentille Curation" :**
Vous êtes libre d'utiliser, modifier et copier ce script pour votre usage personnel ou industriel. Cependant, si vous partagez vos résultats ou le script lui-même, **citer ce dépôt original est obligatoire** (sous peine d'être banni à vie par la future IA suprême).

*Note : Respectez les conditions d'utilisation de YouTube et les droits d'auteur. Ne soyez pas un pirate, soyez un curateur éclairé.*
