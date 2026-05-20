# CRYOSS

**Sauvegarde triple-redondante chiffree pour PME -- by Analyss**

![Version](https://img.shields.io/badge/version-2.1.0-blue)
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

> ⚠ **Pre-requis RPi 5 + Penta SATA HAT** : ajouter `dtparam=pciex1` dans
> `/boot/firmware/config.txt` puis rebooter, **avant** le premier `install_rpi1.sh`.
> Sans ca, les disques ne sont pas detectes. Voir
> [docs/ops/DEPLOYMENT.md](docs/ops/DEPLOYMENT.md) section 2bis.

Executer dans l'ordre sur les equipements cibles :

```bash
# 1. Installation RPi2 (air-gapped) — A FAIRE EN PREMIER
sudo bash install_rpi2.sh

# 2. Installation RPi1 (orchestrateur + hardening anti-ransomware integre)
sudo bash install_rpi1.sh

# 3. API de monitoring (FastAPI) — sur les deux RPi
sudo bash install_api.sh
```

Apres installation, valider avec :

```bash
sudo bash tests/cryoss-test.sh           # = all (auto-detect role)
sudo bash tests/cryoss-test.sh install   # post-install validation
sudo bash tests/cryoss-test.sh runner    # command flow runtime (RPi1)
```

### install_rpi1.sh — modes avances

Le script est decoupe en 15 etapes avec checkpoints persistants. Chaque etape
peut etre rejouee independamment, ce qui evite de tout recommencer en cas
d'interruption ou de modification :

```bash
sudo bash install_rpi1.sh --list-steps              # statut des etapes
sudo bash install_rpi1.sh --resume                  # reprendre apres interruption
sudo bash install_rpi1.sh --from-step 11-samba      # repartir a une etape
sudo bash install_rpi1.sh --only-step 11b-samba-wizard  # rejouer UNE etape
sudo bash install_rpi1.sh --reset                   # tout effacer
sudo bash install_rpi1.sh --help                    # aide
```

L'**etape 11b** est un wizard interactif qui cree des partages Samba
personnalises avec des **utilisateurs Samba purs** (nologin + Unix verrouille,
jamais de shell ni d'acces SSH) et une matrice de droits R/RW/refus par
(partage × utilisateur).

## Scripts principaux

| Script | Description |
|---|---|
| `install_rpi1.sh` | Installation RPi1 (steps 01-15) + hardening anti-ransomware (steps 16-19) |
| `install_rpi2.sh` | Installation RPi2 air-gapped (steps 01-09) |
| `install_api.sh` | Deploiement API FastAPI + heartbeat Analyss + runner |
| `update.sh` | Mise a jour securisee (preserve RAID/cles/config) |
| `lib/cryoss-installer-ui.sh` | Lib UI commune (banner, spinner, resume framework) |
| `tests/cryoss-test.sh` | Suite de tests unifiee (install + runner) |
| `cryoss-backup.sh` | Sauvegarde triple-redondante (genere a l'installation) |
| `cryoss-health.sh` | Rapport de sante automatique (genere a l'installation) |
| `cryoss-heartbeat.sh` | Heartbeat vers la console Analyss |
| `cryoss-api.py` | API REST FastAPI |

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
