# CRYOSS

**Sauvegarde triple-redondante chiffree pour PME -- by Analyss**

![Version](https://img.shields.io/badge/version-2.0.0-blue)
![License](https://img.shields.io/badge/licence-proprietaire-red)
![Tests](https://img.shields.io/badge/tests-62%20passed-brightgreen)

---

## Architecture

```
                          INTERNET (HTTPS)
                               |
                               v
                    +---------------------+
                    |   Console Analyss   |
                    |   (monitoring)      |
                    +---------------------+
                               ^
                               | heartbeat / 5 min
                               |
+----------+    C1     +------------------+    C3     +------------------+
|  RAID    | --------> |      RPi1        | --------> |   SFTP distant   |
|  local   |  rclone   |  (orchestrateur) |  rclone   |   (hors-site)    |
+----------+  crypt    +------------------+  crypt    +------------------+
                               |
                               | C2 (cable Ethernet dedie)
                               | SFTP interco + rclone crypt
                               v
                       +------------------+
                       |      RPi2        |
                       |   (air-gapped)   |
                       +------------------+

  Chiffrement : XSalsa20-Poly1305 + AES-256-EME (rclone crypt)
  3 paires de cles independantes par installation
```

## Fonctionnalites

- **Triple redondance** -- 3 chemins de sauvegarde independants (C1, C2, C3)
- **Chiffrement rclone crypt** -- XSalsa20-Poly1305 pour les donnees, AES-256-EME pour les noms de fichiers
- **Air-gap physique** -- RPi2 isole, connexion uniquement via cable Ethernet dedie
- **Anti-ransomware 4 couches** -- versioning SFTP, honeypot inotify, chattr +a, AppArmor
- **Phone-home monitoring** -- heartbeat HTTPS toutes les 5 minutes vers la console Analyss
- **Rapports de sante automatiques** -- verification integrite, espace disque, statut des services
- **Numero de serie unique** -- identifiant DS-XXXXXXXX par installation
- **API REST** -- FastAPI pour le monitoring et la gestion a distance
- **Suite de tests** -- 62 tests automatises pour valider chaque installation

## Installation rapide

Executer dans l'ordre sur les equipements cibles :

```bash
# 1. Installation RPi1 (orchestrateur)
sudo bash install_rpi1.sh

# 2. Installation RPi2 (air-gapped)
sudo bash install_rpi2.sh

# 3. Securisation (anti-ransomware, AppArmor, honeypot)
sudo bash install_security.sh

# 4. API de monitoring (FastAPI)
sudo bash install_api.sh
```

Apres installation, valider avec :

```bash
sudo bash test_installation.sh
```

## Scripts principaux

| Script | Description |
|---|---|
| `install_rpi1.sh` | Installation et configuration du RPi1 |
| `install_rpi2.sh` | Installation et configuration du RPi2 air-gapped |
| `install_security.sh` | Mise en place des 4 couches anti-ransomware |
| `install_api.sh` | Deploiement de l'API FastAPI |
| `cryoss-backup.sh` | Sauvegarde triple-redondante (genere a l'installation) |
| `cryoss-health.sh` | Rapport de sante automatique (genere a l'installation) |
| `cryoss-heartbeat.sh` | Heartbeat vers la console Analyss |
| `cryoss-api.py` | API REST FastAPI |
| `test_installation.sh` | Suite de tests (62 tests) |
| `update.sh` | Mise a jour securisee (preserve RAID/cles/config) |
| `migrate_deepsave_to_cryoss.sh` | Migration depuis DeepSave v1 |

## Documentation

La documentation complete est disponible dans le repertoire [`/docs/`](docs/) :

- Architecture detaillee et flux de donnees
- Guide de deploiement pas a pas
- Procedures de restauration
- Configuration du monitoring Analyss
- Guide de depannage

## Stack technique

- **Bash** -- scripts d'installation, sauvegarde et maintenance
- **Python (FastAPI)** -- API REST de monitoring
- **rclone** -- chiffrement et transfert des sauvegardes
- **systemd** -- orchestration des services et timers
- **Samba** -- partage reseau pour les postes clients
- **SFTP** -- transfert securise inter-RPi et hors-site

## Licence

Logiciel proprietaire -- Analyss, tous droits reserves.
Voir [LICENSE.md](LICENSE.md) pour les details.

---

Developpe par **Analyss** | [analyss.fr](https://analyss.fr)
