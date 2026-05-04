# 📺 Industrial YouTube Transcription Pipeline v13.2.1

Ecosystème complet pour la récupération, le filtrage et la préparation massive de données YouTube pour **NotebookLM**.

## 🚀 Fonctionnalités Principales (v13.2.1)

- **High-Performance Staging** : Utilise `%TEMP%` pour le traitement local (évite les verrous Google Drive).
- **Safe I/O** : Accès sécurisé aux fichiers partagés via lecture partagée.
- **Workflow de Re-sous-titrage** : Génération de vidéos statiques 1fps pour forcer les sous-titres manquants.
- **Maintenance Ciblée** : Possibilité de réparer une seule chaîne spécifique.
- **Parallel Processing** : Traitement multi-threadé pour le nettoyage du texte et la génération des packs.
- **UI/UX Refinement** : Interface épurée avec compteurs de progression [X/Total].

## 🛠 L'Outil Central

### `Industrial_Pipeline_v13.ps1` (v13.2.1)
Le chef d'orchestre qui gère tout le workflow, de la détection sur YouTube à la génération des packs finaux dans `ALL_PACKS`.

- **Options 1-3** : Synchronisation (Manuelle, Auto, Rapide).
- **Option 4** : Diagnostic global de LANGUE (Filtre le Hindi, Espagnol, etc.).
- **Option 5** : Workflow RE-SUBTITLING (Vidéos 1fps pour forcer les sous-titres).
- **Option 6** : Maintenance CIBLEE / GLOBALE (Migration, Intégrité, Doublons, Packs).
- **Option 7** : Inventaire Global (CSV).

## 📦 Installation & Configuration

1. **Pré-requis** : PowerShell 7+, `yt-dlp.exe` et `ffmpeg.exe` dans le dossier `BIN/`.
2. **Configuration** : Editez `channels_config.csv` pour ajouter vos chaînes et préfixes.
3. **Blacklist** : Le fichier `blacklist.txt` sert de mémoire centrale pour les vidéos à ignorer ou à retraiter.

## 🔒 Confidentialité
Le projet est configuré avec un `.gitignore` strict pour ne jamais uploader vos cookies, vos configurations de chaînes privées ou les données brutes sur GitHub.

---
*Développé pour une intégration fluide avec Google NotebookLM.*
