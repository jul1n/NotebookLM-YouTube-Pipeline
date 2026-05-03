# 📺 Industrial YouTube Transcription Pipeline v9.5

Ecosystème complet pour la récupération, le filtrage et la préparation massive de données YouTube pour **NotebookLM**.

## 🚀 Fonctionnalités Principales

- **Multi-Channel Batch Processing** : Synchronisation et traitement de 50+ chaînes simultanément.
- **Intelligent Subtitle Extraction** : Gestion des sous-titres natifs, automatiques et traductions avec mode `auto` (EN/FR).
- **Industrial Packaging** : Fusion des transcriptions en "Packs" optimisés de 500k mots pour NotebookLM.
- **Robustesse Anti-429** : Gestion des limitations YouTube avec délais dynamiques, cookies-from-browser et retry logic.
- **Diagnostic de Langue** : Filtrage automatique des vidéos en langues indésirables (Hindi, Espagnol, etc.).
- **Workflow de Re-Subtitling** : Génération de vidéos "pseudo-statiques" (1fps) pour forcer la génération de sous-titres sur les vidéos qui n'en ont pas.

## 🛠 Les Outils de la Suite

### 1. `pipeline_v9.ps1` (Le Cœur)
Le chef d'orchestre qui gère la synchronisation des chaînes, la conversion des sous-titres en texte brut, et la génération des packs finaux dans `ALL_PACKS`.
- **Mode 1 & 2** : Ajout et rafraîchissement complet.
- **Mode 3 (Rapide)** : Ne traite que les échecs précédents.
- **Mode 4 (Diagnostic)** : Répare les fichiers texte corrompus.

### 2. `check_languages.ps1` (Le Filtre)
Outil de diagnostic qui scanne les vidéos en échec et identifie leur langue réelle. 
- Blackliste automatiquement tout ce qui n'est pas `fr` ou `en`.
- Évite de solliciter inutilement YouTube pour des contenus hors-sujet.

### 3. `re_subtitler.ps1` (La Seconde Chance)
Traite les vidéos de la blacklist sans sous-titres exploitables.
- Extrait l'audio (MP3).
- Combine l'audio avec la vignette pour créer une vidéo légère de 1fps.
- Marque les vidéos pour l'upload afin de récupérer de nouveaux sous-titres automatiques.

## 📦 Installation & Configuration

1. **Pré-requis** : PowerShell 7+, `yt-dlp.exe` et `ffmpeg.exe` dans le dossier `BIN/`.
2. **Configuration** : Editez `channels_config.csv` pour ajouter vos chaînes et préfixes.
3. **Blacklist** : Le fichier `blacklist.txt` sert de mémoire centrale pour les vidéos à ignorer ou à retraiter.

## 🔒 Confidentialité
Le projet est configuré avec un `.gitignore` strict pour ne jamais uploader vos cookies, vos configurations de chaînes privées ou les données brutes sur GitHub.

---
*Développé pour une intégration fluide avec Google NotebookLM.*
