# Cryoss -- Guide d'integration equipe

> Document destine aux nouveaux membres de l'equipe Analyss travaillant sur Cryoss.

---

## Presentation du projet

Cryoss est un systeme de sauvegarde chiffree a triple redondance, concu par **Analyss** pour les clients PME. Il est deploye sur des paires de Raspberry Pi et garantit la protection des donnees grace a trois chemins de sauvegarde independants, chacun chiffre avec ses propres cles (XSalsa20-Poly1305 + AES-256-EME via rclone crypt).

**Clients cibles** : PME avec un serveur ou poste Windows qui depose ses fichiers sur un partage Samba. Cryoss chiffre et replique automatiquement ces fichiers vers trois destinations distinctes.

**Stack technique** : scripts Bash, FastAPI (Python 3.11+), rclone crypt, systemd.

---

## Structure du depot

```
cryoss/
  install_rpi1.sh              # Installation RPi1 (primaire) : RAID, Samba, rclone crypt 3 chemins, health, email
  install_rpi2.sh              # Installation RPi2 (secondaire) : RAID, SFTP chroot, health, monitoring
  install_security.sh          # Hardening anti-ransomware : versioning SFTP, honeypot, chattr +a, AppArmor
  install_api.sh               # API REST + serial + heartbeat (sur les deux RPi)
  update.sh                    # Mise a jour safe (preserve RAID, cles, reseau, users)
  test_installation.sh         # Tests post-installation complets (RAID, rclone, Samba, SSH, API...)
  migrate_deepsave_to_cryoss.sh # Migration depuis DeepSave v1
  CRYOSS_DEPLOIEMENT.md        # Guide de deploiement complet (architecture, procedures, depannage)
  api/
    cryoss-api.py              # API FastAPI : controle distant, status, backup, logs, securite
  heartbeat/
    cryoss-heartbeat.sh        # Agent phone-home vers Analyss (collecte metriques, envoie via HTTPS)
  serial/
    cryoss-serial.sh           # Generateur et gestionnaire de numeros de serie (DS-XXXXXXXX)
  tunnel/
    cryoss-tunnel.sh           # Tunnel SSH inverse persistant via autossh vers VPS Analyss
  docs/
    ONBOARDING.md              # Ce document
    GIT_WORKFLOW.md            # Workflow Git et conventions
    STYLE_GUIDE.md             # Conventions de code
```

---

## Environnement de developpement

### Materiel

- **Ideal** : une paire de RPi 4B/5 avec disques pour tester le RAID et l'interco.
- **Alternative** : deux VM Linux (Debian/Raspberry Pi OS) connectees par un reseau interne. Le RAID peut etre simule avec des fichiers loop (`losetup`). Le lien interco est un bridge virtuel.

### Outils requis

| Outil | Version min. | Usage |
|-------|-------------|-------|
| bash | 5.x | Scripts d'installation et de monitoring |
| python3 | 3.11+ | API FastAPI |
| rclone | 1.60+ | Chiffrement et synchronisation des sauvegardes |
| mdadm | - | Gestion RAID 1 |
| msmtp | - | Envoi d'emails d'alerte |
| inotify-tools | - | Honeypot anti-ransomware |
| apparmor | - | Confinement des processus |
| autossh | - | Tunnel SSH inverse (optionnel) |

### Deploiement d'une instance dev

> ⚠ **Sur RPi 5 avec Penta SATA HAT, ajouter `dtparam=pciex1` dans
> `/boot/firmware/config.txt` AVANT toute installation, puis rebooter.**
> Sans ca, les disques ne sont pas detectes par le kernel et l'install RAID
> echoue. Voir `docs/ops/DEPLOYMENT.md` etape 2bis pour la procedure complete
> (incluant l'identification physique des disques).

```bash
# 1. Preparer RPi2 (ou VM2)
sudo bash install_rpi2.sh

# 2. Preparer RPi1 (ou VM1)
sudo bash install_rpi1.sh

# 3. Connecter RPi1 vers RPi2 (copie cle SSH)
cat /root/.ssh/cryoss_rpi2.pub
# -> coller sur RPi2 dans /var/lib/ds-repl/.ssh/authorized_keys

# 4. Securisation (optionnel en dev, recommande)
sudo bash install_security.sh

# 5. API et serial
sudo bash install_api.sh

# 6. Verifier l'installation
sudo bash test_installation.sh
```

> RPi2 doit etre installe **avant** RPi1 car RPi1 a besoin de connaitre l'IP et le repertoire de reception sur RPi2.

#### Modes utiles d'install_rpi1.sh

```bash
sudo bash install_rpi1.sh --list-steps              # liste 15 etapes + statut
sudo bash install_rpi1.sh --resume                  # reprend apres interruption
sudo bash install_rpi1.sh --from-step 11-samba      # rejoue a partir d'une etape
sudo bash install_rpi1.sh --only-step 11b-samba-wizard  # rejoue UNE seule etape
sudo bash install_rpi1.sh --reset                   # tout effacer
sudo bash install_rpi1.sh --help                    # aide
```

L'etape 11b est un wizard interactif qui cree des partages Samba personnalises
avec des utilisateurs Samba **purs** (nologin + Unix locked, jamais de shell).

---

## Concepts cles

### Numeros de serie

Chaque installation Cryoss possede un identifiant unique au format `DS-XXXXXXXX` (8 caracteres hexadecimaux). Il est stocke dans `/etc/cryoss/serial`, inclus dans les reponses API, les rapports email et le heartbeat vers Analyss.

### Trois chemins de sauvegarde

| Chemin | Destination | Chiffrement | Cle |
|--------|------------|-------------|-----|
| C1 | RAID local md1 (`/etc/encrypted`) | rclone crypt (XSalsa20-Poly1305) | KEY_C1 |
| C2 | RPi2 via SFTP interco | rclone crypt (cle independante) | KEY_C2 |
| C3 | Serveur SFTP distant (optionnel) | rclone crypt (cle independante) | KEY_C3 |

Chaque chemin a ses propres cles de chiffrement. La compromission d'un chemin ne compromet pas les autres.

### Air-gap (RPi2)

RPi2 est deconnecte du reseau local en production. Il est uniquement accessible depuis RPi1 via un cable Ethernet direct (reseau 10.42.0.0/30). L'utilisateur `ds-repl` est confine en SFTP-only avec chroot.

### Lien interco

Cable Ethernet direct entre RPi1 (10.42.0.1) et RPi2 (10.42.0.2). Reseau dedie /30, pas de routage vers le LAN. Utilise pour la replication C2 et l'administration de RPi2.

### Heartbeat

RPi1 collecte ses propres metriques ainsi que celles de RPi2 (via SSH interco) et les envoie toutes les 5 minutes au serveur central Analyss. RPi2 ne communique jamais directement avec l'exterieur.

---

## Taches courantes

### Ajouter un nouveau client

1. Preparer le materiel (2 RPi + disques).
2. Collecter les informations : nom client, IP fixe, identifiants SMTP, emails d'alerte.
3. Suivre la procedure de deploiement dans `CRYOSS_DEPLOIEMENT.md`.
4. Enregistrer le serial aupres d'Analyss : `sudo cryoss-heartbeat.sh register`.
5. Executer les tests : `sudo bash test_installation.sh`.

### Mettre a jour une installation existante

```bash
sudo bash update.sh              # RPi1
sudo bash update.sh --rpi2       # RPi2
```

Le script `update.sh` preserve le RAID, les cles, les mots de passe, le reseau et les identifiants. Seuls les scripts, services et configurations sont mis a jour.

### Debugger un probleme

1. Consulter les logs : `/var/log/cryoss-backup.log`, `/var/log/cryoss-health.log`, `/var/log/rclone_cryoss_c*.log`.
2. Verifier les services : `systemctl list-timers --all | grep cryoss`.
3. Tester l'API : `curl http://localhost:8420/healthz`.
4. Lancer un health check manuel : `sudo /usr/local/bin/cryoss-health.sh daily`.
5. Voir la section "Depannage" dans `CRYOSS_DEPLOIEMENT.md`.

---

## Liens utiles

- [Guide de deploiement complet](../CRYOSS_DEPLOIEMENT.md)
- [Workflow Git](GIT_WORKFLOW.md)
- [Conventions de code](STYLE_GUIDE.md)
- Swagger API : `http://localhost:8420/docs` (via tunnel SSH)
