# Reference de configuration Cryoss

Ce document decrit tous les fichiers de configuration utilises par Cryoss, leur emplacement et comment les modifier.

## Arborescence /etc/cryoss/

```
/etc/cryoss/
├── serial              # Numero de serie unique du boitier
├── api-key             # Cle API locale (authentification FastAPI)
├── analyss.conf        # Configuration du heartbeat vers Analyss
├── keys-backup.conf    # Sauvegarde des cles de chiffrement rclone
└── shares.conf         # Config wizard Samba (utilisateurs purs, partages, droits)
```

### /etc/cryoss/serial

Numero de serie unique attribue au boitier lors du deploiement. Utilise pour identifier le boitier dans Analyss.

- **Format** : chaine alphanumérique (ex. `CRY-2026-0042`)
- **Modifie par** : `install_rpi1.sh` lors de l'installation initiale
- **Modification manuelle** : ne pas modifier apres deploiement

### /etc/cryoss/api-key

Cle API locale utilisee pour authentifier les requetes vers l'API REST FastAPI du boitier.

- **Format** : token opaque (64 caracteres hex)
- **Modifie par** : `install_api.sh`
- **Modification manuelle** : regenerer avec `install_api.sh` si compromise

### /etc/cryoss/analyss.conf

Configuration de la connexion heartbeat vers le serveur Analyss.

- **Variables** :
  - `ANALYSS_URL` — URL du serveur Analyss (ex. `https://analyss.example.com`)
  - `ANALYSS_API_KEY` — Cle API pour l'authentification aupres d'Analyss
- **Modifie par** : `install_rpi1.sh`
- **Modification manuelle** : editer le fichier directement, puis redemarrer le timer heartbeat

### /etc/cryoss/keys-backup.conf

Sauvegarde des cles de chiffrement rclone. Permet de restaurer le chiffrement si `rclone.conf` est perdu.

- **Modifie par** : `install_rpi1.sh`
- **Modification manuelle** : ne pas modifier — fichier de reference uniquement

### /etc/cryoss/shares.conf

Source de verite du wizard Samba (etape `11b-samba-wizard` de `install_rpi1.sh`).
Decrit les utilisateurs Samba purs, les partages personnalises et la matrice
de droits user × partage.

- **Format** : un enregistrement par ligne, espace-separes :
  - `USER <nom> <pass-obscured>` — utilisateur Samba pur (Unix verrouille)
  - `SHARE <nom> <chemin>` — partage avec son chemin filesystem
  - `PERM <share> <user> <r|rw|no>` — droit de l'utilisateur sur le partage
- **Modifie par** : wizard interactif (`install_rpi1.sh --only-step 11b-samba-wizard`)
- **Permissions** : 600 root (contient des mots de passe Samba obscurcis)
- **Modification manuelle** : possible mais non recommande — preferer rejouer
  le wizard. Si edition directe, regenerer ensuite `/etc/samba/cryoss-shares.conf`
  via `--only-step 11b-samba-wizard`.

## Fichiers d'etat d'installation

Les fichiers suivants sont crees par `install_rpi1.sh` et permettent les modes
de reprise (`--resume`, `--from-step`, `--only-step`) :

```
/var/lib/cryoss/
├── install.state       # Liste des etapes validees (1 ID par ligne)
└── install.env         # Variables collectees (mots de passe SMTP/SFTP en clair)

/var/log/
└── cryoss-install.log  # Log brut de toutes les commandes encapsulees pendant l'install
```

| Fichier | Permissions | Contenu | Suppression |
|---------|-------------|---------|-------------|
| `install.state` | 600 root | IDs d'etapes (`01-packages`, ...) | `--reset` |
| `install.env` | 600 root | **Sensible** : mots de passe SMTP/SFTP/Samba en clair | `--reset` ou `rm` apres install |
| `cryoss-install.log` | 644 root | Stdout/stderr des commandes encapsulees | logrotate |

> ⚠ **`install.env` est sensible** : il est conserve apres install pour permettre
> les reprises (`--resume`, `--from-step`). Sur un poste partage, le supprimer
> apres install reussie : `sudo rm /var/lib/cryoss/install.env`. Le repo Cryoss
> etant prive, la conservation est acceptable sur un poste dedie au deploiement.

## Fichiers de configuration externes

### /root/.config/rclone/rclone.conf

Configuration des remotes rclone (chemins de backup chiffres).

- **Modifie par** : `install_rpi1.sh` (creation initiale)
- **Modification manuelle** : utiliser `rclone config` pour ajouter/modifier des remotes

### /etc/msmtprc

Configuration SMTP pour l'envoi d'emails d'alerte.

- **Parametres cles** : `host`, `port`, `from`, `auth`, `user`, `password`, `tls`
- **Modifie par** : `install_rpi1.sh`
- **Modification manuelle** : editer le fichier, puis tester avec `echo "test" | msmtp destinataire@example.com`

### /etc/samba/smb.conf

Partages Samba de base (`[sauvegarde]`, `[encrypted_backup]`) plus une directive
`include = /etc/samba/cryoss-shares.conf` qui ajoute les partages dynamiques
generes par le wizard.

- **Modifie par** : `install_rpi1.sh` (etape `11-samba`)
- **Modification manuelle** : editer le fichier, puis `systemctl reload smbd`

### /etc/samba/cryoss-shares.conf

Partages Samba **dynamiques** generes par le wizard (`11b-samba-wizard`).
Inclus depuis `smb.conf`. Recree a chaque rejeu du wizard.

- **Modifie par** : wizard (`install_rpi1.sh --only-step 11b-samba-wizard`)
- **Modification manuelle** : non — modifier `/etc/cryoss/shares.conf` puis
  rejouer le wizard. Toute edition directe sera ecrasee au prochain rejeu.

### /etc/ssh/sshd_config.d/99-cryoss.conf

Durcissement SSH : desactivation mot de passe, restriction des utilisateurs, port personnalise.

- **Modifie par** : `install_rpi1.sh` (steps 13-hardening + 19-apparmor)
- **Modification manuelle** : editer le fichier, puis `systemctl restart sshd`

### /etc/fail2ban/jail.d/99-cryoss.conf

Jails fail2ban pour proteger SSH et Samba contre les attaques par force brute.

- **Modifie par** : `install_rpi1.sh` (steps 13-hardening + 19-apparmor)
- **Modification manuelle** : editer le fichier, puis `systemctl restart fail2ban`

### /etc/sysctl.d/99-cryoss.conf

Parametres de durcissement noyau (desactivation IP forwarding, protection SYN flood, etc.).

- **Modifie par** : `install_rpi1.sh` (steps 13-hardening + 19-apparmor)
- **Modification manuelle** : editer le fichier, puis `sysctl --system` pour appliquer

## Timers systemd

| Timer | Planification | Description |
|-------|---------------|-------------|
| `cryoss-backup.timer` | Quotidien, 02:00 | Lancement du backup chiffre sur les 3 chemins |
| `cryoss-heartbeat.timer` | Toutes les 5 min | Envoi du heartbeat vers Analyss |
| `cryoss-scrub.timer` | Hebdomadaire, dimanche 03:00 | Verification d'integrite RAID |
| `cryoss-update-check.timer` | Quotidien, 06:00 | Verification des mises a jour disponibles |

Gestion des timers :

```bash
# Voir l'etat de tous les timers Cryoss
systemctl list-timers 'cryoss-*'

# Desactiver un timer
systemctl disable --now cryoss-backup.timer

# Reactiver un timer
systemctl enable --now cryoss-backup.timer
```

## Variables d'environnement

| Variable | Defaut | Description |
|----------|--------|-------------|
| `CRYOSS_LOG_LEVEL` | `INFO` | Niveau de log (DEBUG, INFO, WARNING, ERROR) |
| `CRYOSS_BACKUP_RETENTION` | `30` | Nombre de jours de retention des backups |
| `CRYOSS_HEARTBEAT_INTERVAL` | `300` | Intervalle heartbeat en secondes |
| `CRYOSS_API_PORT` | `8443` | Port de l'API REST FastAPI |

Les variables peuvent etre definies dans `/etc/environment` ou dans les fichiers unit systemd correspondants.

## Resume des scripts de configuration

| Action | Script a relancer |
|--------|-------------------|
| Reinstall complete | `install_rpi1.sh --reset` puis `install_rpi1.sh` |
| Reprendre une install interrompue | `install_rpi1.sh --resume` |
| Reconfigurer une etape precise | `install_rpi1.sh --from-step <ID>` |
| Ajouter / modifier des partages Samba | `install_rpi1.sh --only-step 11b-samba-wizard` |
| Lister les etapes et leur statut | `install_rpi1.sh --list-steps` |
| Reconfigurer l'API | `install_api.sh` |
| Rejouer le hardening anti-ransomware | `install_rpi1.sh --from-step 16-versioning-sftp` |
| Rejouer uniquement le honeypot | `install_rpi1.sh --only-step 17-honeypot` |
| Mettre a jour Cryoss | `update.sh` |
| Tester l'installation | `tests/cryoss-test.sh` |

## Pre-requis hardware (RPi 5 + Penta SATA HAT)

Avant le premier `install_rpi1.sh`, ajouter dans `/boot/firmware/config.txt` :

```ini
dtparam=pciex1
```

puis rebooter. Sans ca, le bus PCIe est inactif et les disques du HAT sont
invisibles. Voir [`docs/ops/DEPLOYMENT.md`](ops/DEPLOYMENT.md) section 2bis
pour la procedure complete (verification `lspci`/`lsblk`, identification
physique des disques, liens udev stables `/dev/cryoss/baieN`).
