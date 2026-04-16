# Reference de configuration Cryoss

Ce document decrit tous les fichiers de configuration utilises par Cryoss, leur emplacement et comment les modifier.

## Arborescence /etc/cryoss/

```
/etc/cryoss/
├── serial              # Numero de serie unique du boitier
├── api-key             # Cle API locale (authentification FastAPI)
├── analyss.conf        # Configuration du heartbeat vers Analyss
└── keys-backup.conf    # Sauvegarde des cles de chiffrement rclone
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

Partages Samba exposes aux clients sur le reseau local.

- **Modifie par** : `install_rpi1.sh`
- **Modification manuelle** : editer le fichier, puis `systemctl restart smbd`

### /etc/ssh/sshd_config.d/99-cryoss.conf

Durcissement SSH : desactivation mot de passe, restriction des utilisateurs, port personnalise.

- **Modifie par** : `install_security.sh`
- **Modification manuelle** : editer le fichier, puis `systemctl restart sshd`

### /etc/fail2ban/jail.d/99-cryoss.conf

Jails fail2ban pour proteger SSH et Samba contre les attaques par force brute.

- **Modifie par** : `install_security.sh`
- **Modification manuelle** : editer le fichier, puis `systemctl restart fail2ban`

### /etc/sysctl.d/99-cryoss.conf

Parametres de durcissement noyau (desactivation IP forwarding, protection SYN flood, etc.).

- **Modifie par** : `install_security.sh`
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
| Reconfigurer les backups | `install_rpi1.sh` |
| Reconfigurer l'API | `install_api.sh` |
| Reconfigurer la securite | `install_security.sh` |
| Mettre a jour Cryoss | `update.sh` |
| Migrer depuis DeepSave | `migrate_deepsave_to_cryoss.sh` |
