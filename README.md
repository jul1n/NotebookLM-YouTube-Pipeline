# 📺 Industrial YouTube Transcription Pipeline v10.4

Ecosystème complet pour la récupération, le filtrage et la préparation massive de données YouTube pour **NotebookLM**.

## 🚀 Fonctionnalités Principales (v10.4)

- **Unified Suite** : Le pipeline, le diagnostic de langue et le workflow de re-subtitling sont désormais fusionnés dans un script unique.
- **Parallel Processing** : Traitement multi-threadé (8 threads) pour le nettoyage du texte et la génération des packs.
- **Robust Pathing** : Support total des caractères spéciaux YouTube (crochets, emojis) via `-LiteralPath`.
- **UI/UX Refinement** : Interface épurée, suppression des préfixes redondants, et harmonisation de la casse.
- **Pack Verification** : Module intégré pour lister les packs générés avec décompte de mots et alertes de taille.
- **Ultra-Clean Engine** : Nettoyage global des artefacts VTT (timestamps, headers) et gestion robuste des JSON corrompus (case-sensitivity).

## 🛠 L'Outil Central

### `Industrial_Pipeline_v10.ps1` (v10.4)
Le chef d'orchestre qui gère tout le workflow, de la détection sur YouTube à la génération des packs finaux dans `ALL_PACKS`.

- **Options 1-3** : Synchronisation (Manuelle, Auto, Rapide).
- **Option 4** : Diagnostic global de LANGUE (Filtre le Hindi, Espagnol, etc.).
- **Option 5** : Workflow RE-SUBTITLING (Vidéos 1fps pour forcer les sous-titres).
- **Option 6** : Maintenance GLOBALE (Migration, Intégrité, Doublons, Packs).
- **Option 7** : Inventaire Global (CSV).

## 📦 Installation & Configuration

1. **Pré-requis** : PowerShell 7+, `yt-dlp.exe` et `ffmpeg.exe` dans le dossier `BIN/`.
2. **Configuration** : Editez `channels_config.csv` pour ajouter vos chaînes et préfixes.
3. **Blacklist** : Le fichier `blacklist.txt` sert de mémoire centrale pour les vidéos à ignorer ou à retraiter.

## 🔒 Confidentialité
Le projet est configuré avec un `.gitignore` strict pour ne jamais uploader vos cookies, vos configurations de chaînes privées ou les données brutes sur GitHub.

---
*Développé pour une intégration fluide avec Google NotebookLM.*
