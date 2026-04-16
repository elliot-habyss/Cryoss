# Guide de durcissement Cryoss

**Produit :** Cryoss -- Sauvegarde chiffree triple-redondance
**Editeur :** Analyss
**Version du document :** 1.0
**Date :** 2026-04-16

---

## 1. Vue d'ensemble

Ce document detaille les regles de durcissement appliquees a chaque composant du systeme Cryoss. Chaque regle est classee par composant et par categorie de securite.

**Legende des statuts :**
- **APPLIQUE** : regle en place dans le deploiement standard
- **RECOMMANDE** : regle recommandee, a adapter selon l'environnement client

---

## 2. RPi1 -- Serveur principal

### 2.1 Pare-feu (UFW)

**Politique par defaut :**

```
ufw default deny incoming
ufw default allow outgoing
```

**Regles autorisees :**

| Regle | Port | Source | Justification |
|-------|------|--------|---------------|
| SSH | 22/tcp | LAN client | Administration par `habyss` |
| Samba | 445/tcp | LAN client | Partage de fichiers pour les postes clients |
| SSH interco | 22/tcp | 10.42.0.2 | Connexion depuis RPi2 (si necessaire) |
| API | Variable | Console Analyss | Heartbeat et commandes de supervision |

**Regles refusees implicitement :** tout le reste du trafic entrant est bloque.

```bash
# Verification
ufw status verbose
```

### 2.2 Fail2ban

**Configuration du jail SSH :**

```ini
[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 3600
findtime = 600
```

**Effet :** toute adresse IP echouant 3 tentatives d'authentification SSH en 10 minutes est bannie pendant 1 heure.

```bash
# Verification
fail2ban-client status sshd
```

### 2.3 Durcissement sysctl

Les parametres noyau suivants sont appliques dans `/etc/sysctl.d/99-cryoss-hardening.conf` :

```ini
# Desactiver le routage IP (le RPi1 n'est pas un routeur)
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0

# Protection contre le spoofing IP
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignorer les redirections ICMP
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# Ignorer les requetes ICMP broadcast (anti-smurf)
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Protection SYN flood
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048

# Desactiver les paquets source-routed
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Journaliser les paquets martiens
net.ipv4.conf.all.log_martians = 1

# Durcissement memoire
kernel.randomize_va_space = 2
```

```bash
# Application
sysctl --system
# Verification
sysctl net.ipv4.ip_forward
```

### 2.4 SSH (sshd_config)

```
# Authentification
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
AllowUsers habyss
AuthenticationMethods publickey

# Securite de session
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2

# Restrictions
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no

# Algorithmes (securite renforcee)
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
HostKeyAlgorithms ssh-ed25519
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
```

**Points cles :**
- Authentification par cle uniquement (Ed25519)
- Aucun acces root par SSH
- Seul le compte `habyss` est autorise
- Algorithmes cryptographiques modernes exclusivement

### 2.5 Samba

**Configuration de securite dans `smb.conf` :**

```ini
[global]
    # Chiffrement SMB3 obligatoire
    smb encrypt = required
    server min protocol = SMB3

    # Modules VFS
    vfs objects = fruit streams_xattr

    # Securite
    map to guest = never
    restrict anonymous = 2
    server signing = mandatory

    # Journalisation
    log level = 1
    log file = /var/log/samba/log.%m
    max log size = 1000

[sauvegarde]
    path = /etc/sauvegarde
    valid users = ds-user
    read only = no
    create mask = 0660
    directory mask = 0770
    browseable = yes
```

**Points cles :**
- Chiffrement SMB3 obligatoire pour toutes les connexions
- Module `vfs_fruit` pour la compatibilite macOS (Time Machine)
- Aucun acces anonyme
- Signature de paquets obligatoire

### 2.6 AppArmor

**Profils configures :**

| Service | Profil | Mode | Description |
|---------|--------|------|-------------|
| `smbd` | `/etc/apparmor.d/usr.sbin.smbd` | **enforce** | Restreint Samba a ses repertoires autorises |
| `cryoss-backup` | `/etc/apparmor.d/usr.local.bin.cryoss-backup` | **complain -> enforce** | Deploye initialement en complain pour validation, puis bascule en enforce |

**Profil smbd (extrait) :**

```
/usr/sbin/smbd {
    # Acces en lecture/ecriture au partage
    /etc/sauvegarde/ rw,
    /etc/sauvegarde/** rw,

    # Acces en lecture a la configuration
    /etc/samba/** r,

    # Logs
    /var/log/samba/** w,

    # Interdit tout acces a /etc/encrypted/
    deny /etc/encrypted/** rwx,
    deny /root/** rwx,
}
```

**Points cles :**
- `smbd` ne peut pas acceder aux archives chiffrees ni aux cles
- `cryoss-backup` est initialement deploye en mode `complain` pour observer les acces necessaires, puis bascule en mode `enforce` apres validation

```bash
# Verification
aa-status
```

### 2.7 Immutabilite des archives (chattr)

```bash
# Application de l'attribut append-only
chattr +a /etc/encrypted/

# Verification
lsattr /etc/encrypted/
```

**Effet :** les fichiers dans `/etc/encrypted/` ne peuvent etre que crees ou completes. Toute tentative de modification, suppression ou ecrasement est refusee par le noyau, meme par root (sauf retrait explicite de l'attribut).

Cela constitue une barriere critique contre le ransomware : meme si un processus malveillant obtient un acces root, il ne peut pas modifier les archives existantes.

---

## 3. RPi2 -- Replique air-gap

### 3.1 Pare-feu (UFW)

**Politique par defaut :**

```
ufw default deny incoming
ufw default deny outgoing
```

**Regles autorisees :**

| Regle | Port | Source | Justification |
|-------|------|--------|---------------|
| SSH/SFTP | 22/tcp | 10.42.0.1 uniquement | Replication depuis RPi1 |

**Aucune autre regle.** Le RPi2 ne peut :
- Ni recevoir de connexion depuis le LAN
- Ni recevoir de connexion depuis Internet
- Ni initier de connexion vers l'exterieur

```bash
# Verification
ufw status verbose
# Doit afficher UNIQUEMENT la regle SSH depuis 10.42.0.1
```

### 3.2 Absence de services superflus

Le RPi2 ne dispose pas de :
- Samba (pas de partage de fichiers)
- Serveur web ou API
- Acces Internet (aucune passerelle configuree)
- Interface graphique

Seuls les services suivants sont actifs :
- `sshd` (avec configuration SFTP chroot)
- `fail2ban`
- Services systeme essentiels

### 3.3 SFTP Chroot

**Configuration dans `sshd_config` sur RPi2 :**

```
Match User ds-repl
    ChrootDirectory /var/lib/ds-repl
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
    PermitTunnel no
    AllowAgentForwarding no
```

**Effet detaille :**

| Aspect | Restriction |
|--------|------------|
| **Systeme de fichiers** | Confine a `/var/lib/ds-repl/` ; aucune visibilite sur le reste du systeme |
| **Commandes** | `ForceCommand internal-sftp` interdit toute execution de commande shell |
| **Ecriture** | Autorisee dans `/var/lib/ds-repl/data/` uniquement |
| **Reseau** | Aucun forwarding de port ni tunnel SSH |

**Permissions du chroot :**

```bash
# Le repertoire chroot doit appartenir a root
chown root:root /var/lib/ds-repl
chmod 755 /var/lib/ds-repl

# Le repertoire de donnees appartient a ds-repl
chown ds-repl:ds-repl /var/lib/ds-repl/data
chmod 750 /var/lib/ds-repl/data
```

### 3.4 Fail2ban

Configuration identique au RPi1 (voir section 2.2). Le jail `sshd` protege contre les tentatives de brute force sur le port SSH de l'interco.

### 3.5 Durcissement sysctl

Parametres identiques au RPi1 (voir section 2.3), avec en complement :

```ini
# Pas de passerelle par defaut (pas d'Internet)
# Verifie par l'absence de route default dans la table de routage
```

```bash
# Verification : aucune route par defaut
ip route show default
# Doit retourner vide
```

### 3.6 SSH (sshd_config) -- Parametres generaux

Parametres identiques au RPi1 (section 2.4), avec la restriction supplementaire :

```
AllowUsers habyss ds-repl
```

Seuls les comptes `habyss` (administration) et `ds-repl` (replication SFTP) sont autorises. Le compte `ds-repl` est force en SFTP chroot par le bloc `Match` (section 3.3).

---

## 4. API (cryoss-api)

### 4.1 Execution non-root

Le service `cryoss-api` s'execute sous l'utilisateur dedie `cryoss-api` :

```ini
# Extrait du fichier systemd unit
[Service]
User=cryoss-api
Group=cryoss-api
```

Cet utilisateur n'a ni shell interactif ni acces sudo general.

### 4.2 Protection systemd

Le fichier unit integre des directives de confinement :

```ini
[Service]
User=cryoss-api
Group=cryoss-api

# Protection du systeme de fichiers
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/cryoss-api

# Restrictions de privileges
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes

# Restrictions reseau
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

# Restrictions systeme
SystemCallFilter=@system-service
SystemCallArchitectures=native
MemoryDenyWriteExecute=yes
LockPersonality=yes
```

**Effet :**
- Le systeme de fichiers est en lecture seule sauf `/var/lib/cryoss-api`
- Aucun nouveau privilege ne peut etre acquis
- Les appels systeme sont filtres au strict necessaire
- L'execution de code en memoire est interdite

### 4.3 Sudo -- Liste blanche

Le compte `cryoss-api` dispose d'un acces sudo restreint a **17 commandes** specifiques :

```
# /etc/sudoers.d/cryoss-api
cryoss-api ALL=(ALL) NOPASSWD: \
    /usr/bin/systemctl status cryoss-backup, \
    /usr/bin/systemctl start cryoss-backup, \
    /usr/bin/systemctl stop cryoss-backup, \
    /usr/bin/systemctl restart cryoss-backup, \
    /usr/bin/systemctl status smbd, \
    /sbin/mdadm --detail /dev/md*, \
    /usr/bin/rclone check *, \
    /usr/bin/rclone sync *, \
    /usr/bin/rclone lsf *, \
    /usr/bin/df -h, \
    /usr/bin/cat /proc/mdstat, \
    /usr/sbin/ufw status, \
    /usr/bin/fail2ban-client status, \
    /usr/bin/fail2ban-client status sshd, \
    /usr/bin/timedatectl status, \
    /usr/bin/uptime, \
    /usr/bin/journalctl -u cryoss-* --no-pager -n *
```

**Aucune commande arbitraire** ne peut etre executee via sudo. Chaque commande est specifiee avec son chemin absolu.

### 4.4 Rate limiting

L'API applique une limitation de debit :

- Limite globale par adresse IP source
- Limite par endpoint et par cle API
- Reponse HTTP 429 en cas de depassement

### 4.5 Authentification constant-time

La verification des cles API utilise une **comparaison en temps constant** (`hmac.compare_digest` ou equivalent) pour empecher les attaques par analyse de timing. Le temps de reponse est identique que la cle soit valide, invalide, ou partiellement correcte.

---

## 5. Reseau -- Interco

### 5.1 Topologie

```
RPi1 (10.42.0.1) ----[cable Ethernet direct]---- RPi2 (10.42.0.2)
     Masque : /30 (255.255.255.252)
```

**Caracteristiques :**
- Reseau point-a-point `/30` : seules 2 adresses hotes possibles
- Aucun routage configure (`ip_forward = 0` des deux cotes)
- Aucune passerelle par defaut sur RPi2
- Cable Ethernet direct (pas de switch intermediaire)

### 5.2 Isolation du RPi2

Le RPi2 est completement isole du LAN client :

| Test | Resultat attendu |
|------|-----------------|
| `ping 10.42.0.2` depuis le LAN | **Timeout** (pas de route) |
| `ping 8.8.8.8` depuis RPi2 | **Timeout** (pas de passerelle) |
| `ping 10.42.0.1` depuis RPi2 | **OK** (interco uniquement) |
| `ssh ds-repl@10.42.0.2` depuis RPi1 | **OK** (SFTP chroot) |

### 5.3 Pas de routing

Aucun des deux RPi ne fait de routage :

```bash
# Sur RPi1
sysctl net.ipv4.ip_forward
# Resultat : net.ipv4.ip_forward = 0

# Sur RPi2
ip route show default
# Resultat : vide (pas de passerelle)
```

Meme si un attaquant compromet le RPi1, il ne peut pas l'utiliser comme passerelle pour atteindre le RPi2 depuis le LAN (pas de forwarding), et le RPi2 ne peut pas etre utilise comme rebond vers Internet.

---

## 6. Verification post-deploiement

### 6.1 Checklist de verification

```bash
# --- RPi1 ---
# Pare-feu
ufw status verbose

# Fail2ban
fail2ban-client status sshd

# Sysctl
sysctl net.ipv4.ip_forward
sysctl net.ipv4.conf.all.rp_filter

# SSH
sshd -T | grep -E "passwordauthentication|permitrootlogin|allowusers"

# AppArmor
aa-status

# Chattr
lsattr /etc/encrypted/

# Samba
testparm -s 2>/dev/null | grep "smb encrypt"

# --- RPi2 ---
# Pare-feu
ufw status verbose

# Pas de route par defaut
ip route show default

# SFTP chroot
sshd -T -C user=ds-repl | grep -E "chrootdirectory|forcecommand"

# Pas de Samba
systemctl is-active smbd 2>/dev/null || echo "smbd absent"
```

### 6.2 Tests de non-regression

Apres chaque mise a jour, verifier :

1. Le pare-feu bloque toujours les connexions non autorisees
2. Le chattr +a est toujours actif sur `/etc/encrypted/`
3. Le SFTP chroot fonctionne correctement pour `ds-repl`
4. Le RPi2 n'a toujours pas d'acces Internet
5. Les profils AppArmor sont en mode enforce
6. La replication fonctionne de bout en bout

---

*Document maintenu par l'equipe securite Analyss. Ce guide est applique automatiquement lors du deploiement initial par les scripts d'installation Cryoss.*
