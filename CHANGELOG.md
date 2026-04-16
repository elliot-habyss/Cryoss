# Changelog

Toutes les modifications notables du projet Cryoss sont documentees dans ce fichier.

Le format est base sur [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/).

---

## [2.0.0] - 2026-04-16

Reecriture majeure depuis DeepSave v1. Cryoss remplace integralement le systeme DeepSave avec une architecture repensee, un chiffrement renforce et un monitoring centralise.

### Modifie

- Migration du chiffrement `openssl enc` (AES-256-CBC) vers `rclone crypt` (XSalsa20-Poly1305 + AES-256-EME)
- Remplacement du tunnel SSH par un heartbeat HTTPS vers la console Analyss (toutes les 5 minutes)

### Ajoute

- 3 paires de cles independantes par installation (une par chemin de sauvegarde C1/C2/C3)
- API REST FastAPI pour le monitoring et la gestion a distance (`cryoss-api.py`, `install_api.sh`)
- Anti-ransomware 4 couches : versioning SFTP, honeypot inotify, `chattr +a`, AppArmor
- Numero de serie unique par installation (format `DS-XXXXXXXX`)
- Suite de tests automatises (62 tests) via `test_installation.sh`
- Script de mise a jour securise (`update.sh`) preservant RAID, cles et configuration
- Script de migration depuis DeepSave v1 (`migrate_deepsave_to_cryoss.sh`)
- Heartbeat phone-home HTTPS vers la console centrale Analyss
- Rapports de sante automatiques (`cryoss-health.sh`)
- Installateurs separes par composant (`install_rpi1.sh`, `install_rpi2.sh`, `install_security.sh`, `install_api.sh`)

### Securite

- Chiffrement XSalsa20-Poly1305 pour les donnees (remplace AES-256-CBC)
- Chiffrement AES-256-EME pour les noms de fichiers
- Isolation air-gap du RPi2 renforcee
- Profils AppArmor dedies pour les services Cryoss
- Detection de ransomware par honeypot avec notification immediate

---

## [1.x] - DeepSave (obsolete)

Version initiale du systeme de sauvegarde sous le nom DeepSave.
Remplacee integralement par Cryoss 2.0.0.
Utilisez `migrate_deepsave_to_cryoss.sh` pour migrer une installation existante.
