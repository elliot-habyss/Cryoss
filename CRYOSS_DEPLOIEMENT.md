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

## Ordre d'installation

```
ETAPE 1          ETAPE 2          ETAPE 3            ETAPE 4          ETAPE 5
install_rpi2     install_rpi1     Connecter          install_security  install_api
(standalone)     (standalone)     RPi1 → RPi2        (sur RPi1)        (sur les deux)
                                  (cle SSH)
```

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

```bash
sudo bash install_rpi1.sh
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

## ETAPE 4 — Securisation anti-ransomware

```bash
sudo bash install_security.sh
```

| Couche | Mecanisme | Protection |
|--------|-----------|------------|
| 1 | Versioning SFTP | Anciennes versions preservees |
| 2 | Honeypot inotify | Alerte immediate |
| 3 | chattr +a | Append-only sur archives |
| 4 | AppArmor | Confinement processus |

---

## ETAPE 5 — API + numero de serie

```bash
sudo bash install_api.sh                  # API seule
sudo bash install_api.sh --with-tunnel    # API + tunnel SSH inverse
```

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

Les noms `sda`, `sdb`, `sdc`, `sdd` sont attribues par le kernel et
**peuvent changer apres un reboot**. Cryoss utilise les UUID, donc ca
ne casse rien — mais il faut identifier les disques a l'installation.

```bash
# Voir tous les disques avec serial et taille
lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN

# Methode 1 : faire clignoter un disque
dd if=/dev/sda of=/dev/null bs=1M count=100 &
# → observer quelle LED clignote

# Methode 2 : numero de serie
smartctl -i /dev/sda | grep "Serial Number"
# → comparer avec le numero sur le disque physique

# Methode 3 : debrancher un disque et voir lequel disparait
lsblk   # avant
# debrancher un disque
lsblk   # apres
```

**Schema Penta SATA HAT (vue de dessus) :**
```
┌──────────────────────┐
│    Raspberry Pi      │
├──────────────────────┤
│  Penta SATA HAT     │
│  ┌────┐  ┌────┐     │  Rangee haut (sda, sdb)
│  │ S1 │  │ S2 │     │
│  └────┘  └────┘     │
│  ┌────┐  ┌────┐     │  Rangee bas (sdc, sdd)
│  │ S3 │  │ S4 │     │
│  └────┘  └────┘     │
│  ┌────┐              │  5e port
│  │ S5 │              │
│  └────┘              │
└──────────────────────┘
```

**Fixer l'ordre (optionnel, via udev) :**
```bash
echo 'SUBSYSTEM=="block", ATTRS{serial}=="WD-XXXXX", SYMLINK+="disk-slot1"' \
    > /etc/udev/rules.d/99-cryoss-disks.rules
udevadm control --reload-rules
```

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
| `/etc/cryoss/serial` | Numero de serie unique |
| `/etc/cryoss/api-key` | Cle API |
| `/root/.config/rclone/rclone.conf` | Config rclone (3 remotes) |
| `/root/.ssh/cryoss_rpi2` | Cle SSH vers RPi2 |
| `/usr/local/bin/cryoss-backup.sh` | Script backup principal |
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
