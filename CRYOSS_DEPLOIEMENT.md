# CRYOSS — Guide de deploiement complet

> Systeme de sauvegarde chiffree triple-redondance sur Raspberry Pi
> Developpe par **Analyss** — https://analyss.fr

---

## Architecture

```
PC Client (Windows)
  └── Samba (SMB) ──► /etc/sauvegarde (RPi1 RAID md0)
                          │
                     RPi1 (primaire)
                    ┌─────┴─────────────────────────────┐
                    │  3 chemins rclone crypt            │
                    │                                    │
    C1 ─────────────┤  rclone sync → cryoss-c1-crypt:   │
    RAID local md1  │  XSalsa20-Poly1305 + AES-256-EME  │
    /etc/encrypted  │  Cle KEY_C1 (independante)         │
                    │                                    │
    C2 ─────────────┤  rclone sync → cryoss-c2-crypt:   │──► RPi2
    RPi2 via SFTP   │  XSalsa20-Poly1305 + AES-256-EME  │   (air-gapped)
    cable interco   │  Cle KEY_C2 (independante)         │   RAID md0
                    │                                    │
    C3 ─────────────┤  rclone sync → cryoss-c3-crypt:   │──► Serveur SFTP
    SFTP distant    │  XSalsa20-Poly1305 + AES-256-EME  │   (internet)
    (optionnel)     │  Cle KEY_C3 (independante)         │   + versioning
                    └────────────────────────────────────┘
```

**Chaque chemin a ses propres cles** — la compromission d'un chemin ne compromet pas les autres.

**Chiffrement authentifie (AEAD)** — XSalsa20-Poly1305 detecte toute alteration des donnees.

**Noms de fichiers obfusques** — AES-256-EME rend les noms de fichiers illisibles sur les 3 destinations.

---

## Pre-requis

### Materiel

| Composant | RPi1 (primaire) | RPi2 (secondaire) |
|-----------|----------------|-------------------|
| Raspberry Pi | 4B ou 5 (4 Go RAM min) | 4B ou 5 (2 Go RAM min) |
| Stockage systeme | Carte SD 32 Go | Carte SD 32 Go |
| Stockage donnees | 4 disques (2x RAID 1) | 2 disques (1x RAID 1) |
| Reseau | Ethernet LAN + cable interco | Cable interco uniquement |
| HAT recommande | Penta SATA HAT (Radxa) | Dual SATA HAT ou USB-SATA |

### A preparer avant l'installation

- [ ] Nom du client
- [ ] Adresse IP fixe RPi1 (ex: 192.168.1.50/24)
- [ ] Passerelle et DNS du reseau local
- [ ] Identifiants SMTP pour les alertes email
- [ ] Adresse(s) email de destination des alertes
- [ ] (Optionnel) Identifiants serveur SFTP distant
- [ ] 4 disques pour RPi1 + 2 disques pour RPi2

---

## ⚠ Pre-installation — Activation PCIe pour le Penta SATA HAT (RPi 5)

**A FAIRE AVANT TOUTE INSTALLATION** sur RPi1 ET RPi2 si vous utilisez un
Penta SATA HAT (ou tout HAT PCIe). Sans ca, **les disques ne seront pas
detectes** par le kernel — `lsblk` ne montrera que la carte SD et l'install
echouera des l'etape RAID.

### 1. Editer la config bootloader

```bash
sudo nano /boot/firmware/config.txt
```

Ajouter ces lignes en bas du fichier (apres la section `[all]` ou en creer une) :

```ini
# Cryoss — activer le PCIe pour le Penta SATA HAT (Radxa / Geekworm / autres)
dtparam=pciex1
# Optionnel : forcer Gen 3 (5 GT/s) au lieu de Gen 2 par defaut. Augmente le debit
# mais peut etre instable sur certains HATs ou cables. Activer SEULEMENT apres
# avoir valide que `dtparam=pciex1` seul fonctionne.
# dtparam=pciex1_gen=3
```

### 2. Redemarrer

```bash
sudo reboot
```

### 3. Verifier la detection PCIe puis les disques

```bash
# Le bus PCIe doit apparaitre
lspci
# → 0000:01:00.0 SATA controller: ASMedia ASM1166 ...   (ou similaire selon le HAT)

# Les 4 disques doivent etre listes (sda, sdb, sdc, sdd)
lsblk -d -o NAME,SIZE,MODEL,SERIAL,TRAN
# → sda  X.XT  WDC...  WD-XXXX  sata
# → sdb  X.XT  WDC...  WD-XXXX  sata
# → sdc  X.XT  WDC...  WD-XXXX  sata
# → sdd  X.XT  WDC...  WD-XXXX  sata

# Si rien : verifier que le HAT est bien clipse, le cable PCIe FFC dans le bon
# sens, et que `dtparam=pciex1` est bien present sans typo dans config.txt.
```

> **Astuce typo** : la ligne s'ecrit bien `dtparam=pciex1` (un X minuscule, un 1).
> `dtparam=pciex` ou `dtparam=pcie_x1` ne fonctionneront pas.

> **Distros plus anciennes** : sur Bullseye et anterieurs le fichier est
> `/boot/config.txt`. Sur Bookworm et plus recent (recommande pour Cryoss),
> c'est `/boot/firmware/config.txt`.

### 4. Identifier physiquement chaque disque AVANT d'installer

Avant de lancer `install_rpi1.sh` (qui formate et detruit les donnees existantes),
il est **fortement recommande** de noter quel `/dev/sdX` correspond a quelle baie
physique du HAT. Ca facilite enormement le depannage en cas de panne disque
(remplacement a chaud, identification du disque defectueux a la LED).

```bash
# 1) Recuperer le numero de serie de chaque disque kernel-detecte
for d in /dev/sd?; do
    echo "=== $d ==="
    sudo smartctl -i "$d" | grep -E "Serial Number|Model|User Capacity"
done

# 2) Faire clignoter chaque disque tour a tour pour reperer la baie
sudo dd if=/dev/sda of=/dev/null bs=1M count=2000 status=progress
# → la LED de la baie correspondante clignote pendant ~10s
# → noter "Baie 1 = sda = serial WD-XXXXX"
# Repeter pour sdb, sdc, sdd.

# 3) Coller une etiquette physique sur chaque disque avec :
#    - sa baie HAT (1, 2, 3, 4)
#    - les 6 derniers chiffres du serial
#    - son role Cryoss (md0=sauvegarde / md1=encrypted)
```

**Layout par defaut Cryoss** :

| Baie HAT | /dev/* | RAID | Role |
|----------|--------|------|------|
| S1 (haut-gauche)  | sda | md0 | /etc/sauvegarde (donnees client) |
| S2 (haut-droit)   | sdb | md0 | /etc/sauvegarde (miroir) |
| S3 (bas-gauche)   | sdc | md1 | /etc/encrypted (chiffre rclone) |
| S4 (bas-droit)    | sdd | md1 | /etc/encrypted (miroir) |

> Ce layout correspond a la convention du Penta SATA HAT Radxa. Sur d'autres
> modeles, les correspondances baie ↔ port SATA peuvent varier — utiliser la
> methode `dd` ci-dessus pour confirmer.

### 5. (Optionnel mais recommande) Fixer l'ordre via udev

Les noms `sda`/`sdb`/... peuvent permuter d'un boot a l'autre. Cryoss utilise
les UUID donc ca ne casse pas le RAID, mais pour le depannage c'est confortable
d'avoir des liens stables :

```bash
sudo nano /etc/udev/rules.d/99-cryoss-disks.rules
```

```
# Remplacer les serials par ceux releves a l'etape precedente
SUBSYSTEM=="block", ATTRS{serial}=="WD-XXXX1", SYMLINK+="cryoss/baie1"
SUBSYSTEM=="block", ATTRS{serial}=="WD-XXXX2", SYMLINK+="cryoss/baie2"
SUBSYSTEM=="block", ATTRS{serial}=="WD-XXXX3", SYMLINK+="cryoss/baie3"
SUBSYSTEM=="block", ATTRS{serial}=="WD-XXXX4", SYMLINK+="cryoss/baie4"
```

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger
ls -l /dev/cryoss/   # → baie1 → ../sda, baie2 → ../sdb, ...
```

---

## Ordre d'installation

```
ETAPE 1          ETAPE 2          ETAPE 3            ETAPE 4
install_rpi2     install_rpi1     Connecter          install_api
(standalone)     (standalone)     RPi1 → RPi2        (sur les deux)
                                  (cle SSH)
```

Le hardening anti-ransomware (versioning SFTP, honeypot, chattr +a, AppArmor)
est integre a `install_rpi1.sh` en steps 16-19. Plus de script separe.

> ⚠ **RPi2 DOIT etre installe EN PREMIER** car RPi1 a besoin de connaitre
> l'IP et le repertoire de reception sur RPi2.

---

## ETAPE 1 — Installer RPi2

```bash
sudo bash install_rpi2.sh
```

A la fin, **notez** :
```
IP RPi2 interco    : 10.42.0.2
Repertoire recep.  : /etc/encrypted/rpi1
Mot de passe habyss: _______________
Mot de passe ds-repl: ______________
```

> **ds-repl** est confine en SFTP-only (ForceCommand internal-sftp + chroot).
> Il n'a aucun acces shell.

---

## ETAPE 2 — Installer RPi1

> ⚠ **Pre-requis** : avoir applique la section "Pre-installation — Activation
> PCIe" ci-dessus (`dtparam=pciex1` dans `/boot/firmware/config.txt`). Sans ca,
> l'install echouera a l'etape RAID car aucun disque ne sera detecte.

### Mode standard

```bash
sudo bash install_rpi1.sh
```

### Modes avances (resume / rejeu d'etapes)

L'installeur est divise en 15 etapes numerotees, chacune avec un checkpoint
persistant. Si l'install est interrompue (ssh coupe, panne secteur, erreur),
la reprise se fait sans tout recommencer.

```bash
# Lister les etapes et leur statut (✓ fait / ○ a faire)
sudo bash install_rpi1.sh --list-steps

# Reprendre apres une interruption (skip les etapes deja validees)
sudo bash install_rpi1.sh --resume

# Repartir depuis une etape precise (rejoue celle-la + toutes les suivantes)
sudo bash install_rpi1.sh --from-step 11-samba

# Rejouer UNIQUEMENT une etape, sans toucher au reste
# (cas d'usage typique : ajouter de nouveaux partages plus tard)
sudo bash install_rpi1.sh --only-step 11b-samba-wizard

# Tout reinitialiser (efface l'etat ET les variables sauvegardees)
sudo bash install_rpi1.sh --reset

# Afficher l'aide
sudo bash install_rpi1.sh --help
```

**Fichiers d'etat (mode 600 root) :**

| Fichier | Role |
|---------|------|
| `/var/lib/cryoss/install.state` | Liste des etapes validees (1 ID/ligne) |
| `/var/lib/cryoss/install.env` | Variables collectees (incl. mots de passe SMTP/SFTP en clair) |
| `/var/log/cryoss-install.log` | Log brut de toutes les commandes encapsulees |

> **Securite** : `install.env` contient les mots de passe SMTP et SFTP en clair
> (mode 600 root, repo prive). Si vous deployez sur un poste partage, supprimez
> ce fichier apres install reussie : `sudo rm /var/lib/cryoss/install.env`.

### Liste des etapes

```
01-packages          Paquets de base
02-network           IP fixe (NetworkManager)
03-raid              RAID 1 (mdadm)
04-mounts            Repertoires et montage
05-users             Utilisateurs systeme et permissions
06-rclone            Configuration rclone (3 chemins chiffres)
07-ssh-rpi2          Cle SSH pour replication RPi2
09-msmtp             msmtp + relais SMTP
09b-emaillib         Librairie email HTML
10-backup-script     Script cryoss-backup.sh
11-samba             Samba (partages de base)
11b-samba-wizard     Partages personnalises (interactif)
12-systemd           Services et timers systemd
13-hardening         Durcissement systeme
14-monitoring        Monitoring et rapports HTML
```

### Etape 11b — Wizard de partages Samba personnalises

Apres la config Samba de base (partages `[sauvegarde]` et `[encrypted_backup]`),
le script propose un wizard interactif pour creer des partages supplementaires
avec leurs propres utilisateurs et niveaux de droits.

**Caracteristiques :**

- **Utilisateurs Samba purs** — jamais de comptes systeme exploitables :
  `useradd -r -M -s /usr/sbin/nologin -d /nonexistent` + `passwd -l` (mot de
  passe Unix verrouille). Aucun acces SSH, aucun login console possible. Seul
  `smbpasswd` les active pour l'authentification Samba.
- **Matrice de droits** — pour chaque (partage × utilisateur), choisir
  `R` (lecture seule), `RW` (lecture + ecriture) ou `–` (refus explicite).
- **Persistance** — la config est sauvegardee dans `/etc/cryoss/shares.conf`,
  rejouable et editable. Les blocs Samba generes vont dans
  `/etc/samba/cryoss-shares.conf` (inclus depuis `smb.conf`).
- **Validation** — noms reserves bloques (`habyss`, `root`, `ds-user`,
  `sauvegarde`, `encrypted_backup`, `global`), pattern `[a-z][a-z0-9_-]{1,31}`.

**Pour ajouter / modifier des partages plus tard** :

```bash
sudo bash install_rpi1.sh --only-step 11b-samba-wizard
```

> ⚠ **Les 3 paires de cles de chiffrement sont auto-generees** et sauvegardees
> dans `/etc/cryoss/keys-backup.conf`. **Copiez ce fichier en lieu sur** —
> sans ces cles, les donnees chiffrees sont irrecuperables.

---

## ETAPE 3 — Connecter RPi1 vers RPi2

### 3a. Afficher la cle publique RPi1

```bash
cat /root/.ssh/cryoss_rpi2.pub
```

### 3b. Ajouter la cle sur RPi2

```bash
# Sur RPi2 en tant que root :
PUBKEY="ssh-ed25519 AAAA..."   # collez la cle RPi1
echo "$PUBKEY" >> /var/lib/ds-repl/.ssh/authorized_keys
chown ds-repl:ds-repl /var/lib/ds-repl/.ssh/authorized_keys
chmod 600 /var/lib/ds-repl/.ssh/authorized_keys
```

### 3c. Tester

```bash
# Sur RPi1 :
rclone lsd cryoss-c2-crypt: && echo "C2 OK" || echo "C2 ECHEC"
```

### 3d. Test backup complet

```bash
echo "test" > /etc/sauvegarde/test.txt
systemctl start cryoss-backup.service
journalctl -u cryoss-backup.service -f
# Verifier :
rclone ls cryoss-c1-crypt:    # C1
rclone ls cryoss-c2-crypt:    # C2
rclone ls cryoss-c3-crypt:    # C3
```

---

## (Anciennement ETAPE 4 — anti-ransomware)

Le hardening 4 couches est integre a `install_rpi1.sh` :

| Step | Couche | Mecanisme | Protection |
|------|--------|-----------|------------|
| 16-versioning-sftp | 1 | Versioning SFTP (rclone --backup-dir) | Anciennes versions preservees |
| 17-honeypot | 2 | Honeypot inotify | Alerte immediate |
| 18-chattr-append | 3 | chattr +a | Append-only sur archives |
| 19-apparmor | 4 | AppArmor smbd + cryoss-backup | Confinement processus |

Pour rejouer uniquement le hardening sans tout reinstaller :
```bash
sudo bash install_rpi1.sh --from-step 16-versioning-sftp
```

---

## ETAPE 4 — API + numero de serie

```bash
sudo bash install_api.sh                  # API seule
sudo bash install_api.sh --with-tunnel    # API + tunnel SSH inverse
```

`install_api.sh` deploie aussi :
- `cryoss-command-runner.sh` (executeur des commandes Console Analyss)
- `cryoss-decrypt-secret` (helper Fernet pour les params chiffres)
- Service+timer `cryoss-decrypted-cleanup` (nettoyage TTL 1h des dechiffres
  a la demande)

---

## ETAPE 5b — Master key Console Analyss (Fernet)

> Optionnelle — uniquement si vous utilisez les commandes bidirectionnelles
> Console (panels users / shares / decrypt_path). Si vous restez en monitoring
> read-only, sautez cette etape.

La Console Analyss envoie certains parametres (mots de passe Samba ajoutes
via le panel "Utilisateurs") chiffres en Fernet (`enc:v1:<token>`). Le runner
local doit pouvoir les dechiffrer avec une cle partagee.

```bash
sudo bash install_rpi1.sh --only-step 15-master-key
```

L'etape :
1. Verifie / installe `python3-cryptography`.
2. Demande la master key (copie depuis l'UI Analyss, format Fernet base64
   url-safe, 44 caracteres).
3. Valide via un `encrypt+decrypt` de test.
4. Pose dans `/etc/cryoss/master_key` (mode 0600 root:root).

> ⚠ Sans master key, toute commande contenant un parametre `enc:v1:` sera
> ack_error avec "missing Cryoss master key". Les commandes en clair-text
> (diagnostics, restart_service, etc.) fonctionnent normalement.

**Rotation** : procedure documentee dans ADR 0001 §4 cote Analyss (drain de la
queue → generer → push → cutover Console → verifier). Pas de dual-key grace
period en v1.

---

## ETAPE 5c — Roots filesystem (override optionnel)

Le runner utilise par defaut :

| Variable                | Default              | Role                              |
|-------------------------|----------------------|-----------------------------------|
| `CRYOSS_SHARE_ROOT`     | `/etc/sauvegarde`    | Racine des partages Samba         |
| `CRYOSS_ARCHIVE_ROOT`   | `/etc/encrypted`     | Cible de `decrypt_path`           |
| `CRYOSS_DECRYPT_DIR`    | `/var/lib/cryoss/decrypted` | Dest. dechiffrement a la demande |
| `CRYOSS_DECRYPT_TTL_HOURS` | `1`               | TTL avant cleanup auto            |

Si votre layout differe (RAID montes ailleurs), creez `/etc/cryoss/config.env`
en mode 600 root:root :

```bash
sudo install -m 600 -o root -g root /dev/null /etc/cryoss/config.env
sudo tee /etc/cryoss/config.env <<'EOF'
CRYOSS_SHARE_ROOT=/data/sauvegarde
CRYOSS_ARCHIVE_ROOT=/data/encrypted
EOF
```

Le parser est strict (whitelist limitee, pas de `source`) — toute variable
non-whitelistee genere un WARN et est ignoree.

---

## API — Guide d'utilisation

### Connexion

```bash
ssh -L 8420:localhost:8420 habyss@IP_PUBLIQUE_CLIENT
export KEY="$(cat /chemin/vers/api-key)"
curl -H "Authorization: Bearer $KEY" http://localhost:8420/api/v1/status
```

### Swagger : http://localhost:8420/docs

### Endpoints principaux

| Methode | Endpoint | Description |
|---------|----------|-------------|
| GET | `/api/v1/status` | Vue globale |
| GET | `/api/v1/health/{daily\|weekly\|alert}` | Rapport sante |
| GET | `/api/v1/system/raid` | Detail RAID |
| GET | `/api/v1/system/smart/{sda}` | SMART disque |
| POST | `/api/v1/backup/run` | Lancer backup (+`X-Cryoss-Confirm: yes`) |
| GET | `/api/v1/backup/status` | Dernier backup |
| GET | `/api/v1/logs/{name}` | Lire un log |
| GET | `/api/v1/security/fail2ban` | IPs bannies |
| GET | `/api/v1/rpi2/status` | Status RPi2 (proxy) |
| GET | `/healthz` | Ping (sans auth) |

---

## Checklist post-deploiement

### RPi1
```bash
cat /proc/mdstat                        # [UU] x2
rclone listremotes                      # cryoss-c1-*, c2-*, c3-*
systemctl is-active smbd fail2ban ssh   # active x3
systemctl list-timers | grep cryoss     # 5 timers actifs
curl http://localhost:8420/healthz       # {"status":"ok"}
```

### RPi2
```bash
cat /proc/mdstat                        # [UU]
systemctl is-active fail2ban ssh        # active x2
grep "ForceCommand internal-sftp" /etc/ssh/sshd_config.d/99-cryoss.conf
```

---

## Restauration

```bash
# Depuis C1 (local)
rclone sync cryoss-c1-crypt: /tmp/restore --progress

# Depuis C2 (RPi2)
rclone sync cryoss-c2-crypt: /tmp/restore --progress

# Depuis C3 (SFTP — version specifique)
rclone lsd cryoss-c3-versions:                           # lister les dates
rclone sync cryoss-c3-versions:2025-06-14 /tmp/restore   # restaurer une date
```

---

## Alertes email

| Alerte | Frequence | Cooldown |
|--------|-----------|----------|
| Backup OK/ECHEC | Quotidien 02h | - |
| Rapport quotidien | 07h00 | - |
| Rapport hebdomadaire + SMART | Lundi 08h00 | - |
| RAID degrade | /15 min | 1h |
| SMART critique | /15 min | 1h |
| Disque >85% | /15 min | 1h |
| Service arrete | /15 min | 1h |
| Replication silencieuse >26h | /15 min | 1h |
| Honeypot declenche | Immediat | 5 min |

---

## Depannage

### Identifier physiquement les disques (Penta SATA HAT)

Voir la section "Pre-installation — Activation PCIe" plus haut pour la procedure
complete (commandes `dd` pour faire clignoter, `smartctl -i` pour les serials,
udev pour des liens stables `/dev/cryoss/baieN`).

**Schema Penta SATA HAT (vue de dessus, layout Cryoss) :**
```
┌──────────────────────┐
│    Raspberry Pi      │
├──────────────────────┤
│  Penta SATA HAT     │
│  ┌────┐  ┌────┐     │  Rangee haut → md0 (sauvegarde)
│  │ S1 │  │ S2 │     │  S1=sda, S2=sdb
│  └────┘  └────┘     │
│  ┌────┐  ┌────┐     │  Rangee bas → md1 (encrypted)
│  │ S3 │  │ S4 │     │  S3=sdc, S4=sdd
│  └────┘  └────┘     │
│  ┌────┐              │  5e port (non utilise par Cryoss)
│  │ S5 │              │
│  └────┘              │
└──────────────────────┘
```

### Aucun disque detecte (`lsblk` ne montre que mmcblk0)

99% du temps, c'est le PCIe qui n'est pas active sur RPi 5 :

```bash
# Verifier
grep dtparam /boot/firmware/config.txt
# → dtparam=pciex1   doit etre present (sans #)

lspci
# → doit lister un controleur SATA. Si vide : PCIe inactif.

# Corriger
sudo sed -i '/^dtparam=pciex1/d' /boot/firmware/config.txt
echo "dtparam=pciex1" | sudo tee -a /boot/firmware/config.txt
sudo reboot
```

Voir la section "Pre-installation — Activation PCIe" plus haut pour les details.

### Problemes courants

**rclone C2 echoue (RPi2)** :
```bash
ping 10.42.0.2                                    # cable branche ?
ssh habyss@10.42.0.2 "systemctl is-active ssh"    # SSH actif ?
sftp -i /root/.ssh/cryoss_rpi2 ds-repl@10.42.0.2  # SFTP OK ?
ssh habyss@10.42.0.2 "mount | grep ds-repl"       # bind mount OK ?
```

**Email non recu** :
```bash
echo "Test" | msmtp -v destinataire@email.com      # test direct
tail -20 /var/log/msmtp.log                         # logs msmtp
```

**RAID degrade** :
```bash
cat /proc/mdstat                                    # etat
mdadm --detail /dev/md0 | grep faulty              # disque defaillant
mdadm /dev/md0 --remove /dev/sdb                   # retirer
# remplacer physiquement le disque
mdadm /dev/md0 --add /dev/sdb                      # ajouter le neuf
```

**API ne repond pas** :
```bash
systemctl status cryoss-api                         # service actif ?
journalctl -u cryoss-api -n 20                      # logs
curl http://localhost:8420/healthz                   # ping
```

---

## Fichiers importants

| Fichier | Description |
|---------|-------------|
| `/etc/cryoss/keys-backup.conf` | **CRITIQUE : 3 paires de cles rclone** |
| `/etc/cryoss/shares.conf` | Source de verite des partages Samba (wizard CLI + Console Analyss) |
| `/etc/cryoss/master_key` | Master key Fernet (Console Analyss bidirectionnelle, 600 root:root) |
| `/etc/cryoss/config.env` | Override roots filesystem (optionnel, 600 root:root) |
| `/etc/cryoss/serial` | Numero de serie unique |
| `/etc/cryoss/api-key` | Cle API locale |
| `/etc/cryoss/analyss.conf` | URL + API key heartbeat Analyss |
| `/etc/samba/cryoss-shares.conf` | Partages Samba dynamiques generes (NE PAS EDITER : regenere depuis shares.conf) |
| `/var/lib/cryoss/last-shutdown.txt` | Dernier shutdown via commande Console (raison, ts) |
| `/var/lib/cryoss/decrypted/<cmd_id>/` | Decryptes a la demande (TTL 1h, cleanup auto) |
| `/root/.config/rclone/rclone.conf` | Config rclone (3 remotes) |
| `/root/.ssh/cryoss_rpi2` | Cle SSH vers RPi2 |
| `/usr/local/bin/cryoss-backup.sh` | Script backup principal |
| `/var/lib/cryoss/install.state` | Etapes d'installation validees (resume) |
| `/var/lib/cryoss/install.env` | Variables d'install collectees (sensible — 600 root) |
| `/var/log/cryoss-install.log` | Log brut de l'installation (commandes encapsulees) |
| `/var/log/cryoss-backup.log` | Log backup |
| `/var/log/rclone_cryoss.log` | Log rclone |
| `/var/log/cryoss-health.log` | Log monitoring |

## Timers systemd

| Timer | Heure |
|-------|-------|
| `cryoss-backup.timer` | 02h00 |
| `cryoss-sftp-sync.timer` | 08/14/20h |
| `cryoss-health-daily.timer` | 07h00 |
| `cryoss-health-weekly.timer` | Lundi 08h00 |
| `cryoss-watchdog.timer` | /15 min |
