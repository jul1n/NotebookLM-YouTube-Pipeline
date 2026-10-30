# Programme exceptionnel de la nuit du 31 octobre 2026

Ce programme est déclenché à la demande de l’utilisateur. Il ne remplace pas le fonctionnement manuel habituel et ne planifie pas de mises à jour quotidiennes.

1. Sauvegarder la base SQLite et vérifier la copie sur Drive.
2. Contrôler SQLite et l’index FTS. Un index FTS incohérent peut être reconstruit après sauvegarde, dans le budget local.
3. Parcourir tous les textes. Appliquer uniquement le motif des blocs rendus trois fois, avec couverture suffisante, chronologie cohérente et aucune balise technique résiduelle. Conserver l’original compressé, ses empreintes et un journal de révision avant chaque modification. Les répétitions ordinaires et les cas incertains restent inchangés.
4. Faire un audit complet en lecture seule.
5. Lancer les premières découvertes sur ScienceEtonnante, Fouloscopie et Marc Lou : RSS si possible, sinon liste plate de dix vidéos. Récupérer au plus deux sous-titres manquants par chaîne, six au total. Aucun audio.
6. Contrôler de nouveau SQLite et FTS, refaire l’audit, régénérer les packs et les données du dashboard.
7. Créer la sauvegarde finale et le bilan.

## Bornes

- Budget local partagé : 10 Go ; médias et sources compressées conservés sur Drive.
- Au plus trois découvertes de chaîne et quinze invocations yt-dlp, dont au plus six extractions de métadonnées et six téléchargements de sous-titres. Une invocation peut elle-même effectuer plusieurs requêtes HTTP : il ne s’agit pas d’une garantie de quinze requêtes HTTP.
- Au moins soixante secondes entre les démarrages de yt-dlp, sans retry interne pour ce lot ; durée maximale de deux minutes par invocation.
- Au premier échec réseau ou HTTP 429 : arrêter la partie réseau et ne pas la relancer cette nuit. Le programme conserve aussi la suspension globale de six heures pour HTTP 429.
- Aucun nouvel appel réseau après 07 h, heure de Paris, le 31 octobre 2026.
- Aucun nettoyage de médias, aucun traitement Whisper et aucune suppression des archives historiques.

## État et reprise

L’état privé et le bilan sont sous `DATABASE/night_runs/20261031`. `STATE.json` indique le PID, la phase et les opérations réseau déjà tentées. Le verrou système empêche deux acquisitions simultanées. Les étapes terminées ne sont pas répétées lors d’une reprise ; une découverte déjà tentée n’est pas relancée après un arrêt ambigu.

```powershell
python SCRIPTS/night_runner.py --root . --job DATABASE/night_runs/20261031 --prepare
python -u SCRIPTS/night_runner.py --root . --job DATABASE/night_runs/20261031
```

La reprise ne doit être lancée qu’après vérification de l’absence du processus indiqué. Ne jamais supprimer les journaux SQLite pour débloquer un traitement.
