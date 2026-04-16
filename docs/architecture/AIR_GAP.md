# Strategie Air-Gap -- RPi2

> Document de reference decrivant la strategie d'isolation physique (air-gap) du noeud RPi2 dans l'architecture Cryoss.

---

## Table des matieres

1. [Pourquoi un air-gap](#pourquoi-un-air-gap)
2. [Installation physique](#installation-physique)
3. [Configuration reseau](#configuration-reseau)
4. [Protocole de communication](#protocole-de-communication)
5. [Ce qui peut traverser l'air-gap](#ce-qui-peut-traverser-lair-gap)
6. [Ce qui ne peut pas traverser l'air-gap](#ce-qui-ne-peut-pas-traverser-lair-gap)
7. [Regles UFW sur RPi2](#regles-ufw-sur-rpi2)
8. [Fenetres de synchronisation](#fenetres-de-synchronisation)
9. [Durcissement du RPi2](#durcissement-du-rpi2)
10. [Anti-ransomware specifique au RPi2](#anti-ransomware-specifique-au-rpi2)

---

## Pourquoi un air-gap

L'air-gap est la pierre angulaire de la protection Cryoss contre les ransomwares. Le raisonnement est le suivant :

- Un ransomware qui infecte le reseau du client peut atteindre tout equipement connecte au LAN, y compris les partages Samba
- Si le RPi1 est compromis (via Samba ou une autre vulnerabilite), un attaquant dispose potentiellement d'un acces reseau complet
- Le RPi2, physiquement deconnecte de tout reseau accessible, ne peut **jamais** etre atteint par un ransomware qui se propage sur le LAN ou via Internet
- Meme si un attaquant prend le controle total du RPi1, il ne peut envoyer vers le RPi2 que des fichiers chiffres via SFTP -- il ne peut ni supprimer, ni modifier les fichiers existants grace au versioning rclone et aux restrictions du chroot SFTP
- L'air-gap transforme le RPi2 en un coffre-fort physique : les donnees y entrent, mais rien ne peut les alterer ou les extraire sans un acces physique direct

**Principe fondamental** : aucune connexion reseau depuis le RPi2 vers le monde exterieur n'est possible, ni directement, ni indirectement.

---

## Installation physique

### Schema de cablage

```
[RPi1]                          [RPi2]
  |                                |
  | eth1 (ou adaptateur USB)       | eth0
  |                                |
  +--- Cable Ethernet RJ45 -------+
       (point-a-point direct)
       Pas de switch
       Pas de routeur
       Pas de hub
```

### Exigences materielles

| Element | Specification |
|---|---|
| Cable | Ethernet Cat5e ou Cat6, droit (pas croise, les Pi gerent l'auto-MDI/X) |
| Longueur | Aussi court que possible, idealement < 2m (les deux Pi sont cote a cote) |
| Connexion RPi1 | Deuxieme interface Ethernet (adaptateur USB-Ethernet si necessaire) |
| Connexion RPi2 | Interface Ethernet integree (unique interface reseau) |
| Intermediaire | **Aucun** -- le cable relie directement les deux Pi |

### Emplacement physique

- Les deux Raspberry Pi doivent etre installes dans le meme local technique ou armoire reseau
- Le cable Ethernet dedie doit etre clairement identifie (etiquette, couleur distincte) pour eviter toute confusion avec le cablage LAN
- Le RPi2 ne doit avoir **aucun autre cable reseau** branche
- Le port Wi-Fi du RPi2 doit etre desactive au niveau systeme

---

## Configuration reseau

### Adressage

| Noeud | Interface | Adresse IP | Masque | Passerelle |
|---|---|---|---|---|
| RPi1 | eth1 (interco) | 10.42.0.1 | /30 (255.255.255.252) | Aucune |
| RPi2 | eth0 | 10.42.0.2 | /30 (255.255.255.252) | **Aucune** |

Le sous-reseau /30 ne permet que deux adresses utilisables (10.42.0.1 et 10.42.0.2), ce qui est exactement le besoin pour une liaison point-a-point.

### Configuration NetworkManager -- RPi1 (interface interco)

```ini
[connection]
id=interco-rpi2
type=ethernet
interface-name=eth1
autoconnect=true

[ipv4]
method=manual
addresses=10.42.0.1/30
dns=
never-default=true

[ipv6]
method=disabled
```

Le parametre `never-default=true` empeche cette interface de devenir la route par defaut.

### Configuration NetworkManager -- RPi2

```ini
[connection]
id=interco-rpi1
type=ethernet
interface-name=eth0
autoconnect=true

[ipv4]
method=manual
addresses=10.42.0.2/30
dns=
never-default=true

[ipv6]
method=disabled
```

### Desactivation du Wi-Fi sur RPi2

```bash
# /etc/modprobe.d/disable-wifi.conf
blacklist brcmfmac
blacklist brcmutil
```

### Absence de route par defaut sur RPi2

Verification attendue :

```bash
$ ip route show
10.42.0.0/30 dev eth0 proto kernel scope link src 10.42.0.2
```

Il ne doit y avoir **aucune ligne `default via ...`**. Sans route par defaut, le RPi2 ne peut atteindre aucune adresse en dehors du sous-reseau 10.42.0.0/30.

### Desactivation du forwarding IP sur RPi1

```bash
# /etc/sysctl.d/99-cryoss-no-forward.conf
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0
```

Cela garantit que le RPi1 ne fait **jamais** office de routeur entre le LAN client et le RPi2, meme en cas de mauvaise configuration.

---

## Protocole de communication

Toute communication entre le RPi1 et le RPi2 transite par **SSH/SFTP** sur le lien 10.42.0.0/30.

### Utilisateur ds-repl (transfert de fichiers)

| Parametre | Valeur |
|---|---|
| Utilisateur | `ds-repl` |
| Authentification | Cle SSH Ed25519 uniquement |
| Mot de passe | Desactive |
| Shell | Aucun (`/usr/sbin/nologin`) |
| ForceCommand | `internal-sftp` |
| ChrootDirectory | `/home/ds-repl` |
| AllowTcpForwarding | `no` |
| X11Forwarding | `no` |
| PermitTunnel | `no` |

Configuration SSH cote RPi2 (`/etc/ssh/sshd_config.d/cryoss-sftp.conf`) :

```
Match User ds-repl
    ChrootDirectory /home/ds-repl
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
    PermitTunnel no
    PasswordAuthentication no
    AuthorizedKeysFile /etc/ssh/authorized_keys/ds-repl
```

### Utilisateur habyss (administration)

| Parametre | Valeur |
|---|---|
| Utilisateur | `habyss` |
| Authentification | Cle SSH Ed25519 uniquement |
| Mot de passe | Desactive |
| Shell | `/bin/bash` (restreint aux commandes de monitoring) |
| Usage | Collecte de metriques, administration |

L'utilisateur `habyss` permet au RPi1 d'executer des commandes de diagnostic a distance sur le RPi2 (etat RAID, SMART, charge systeme) pour inclure ces informations dans le heartbeat.

---

## Ce qui peut traverser l'air-gap

| Flux | Direction | Protocole | Utilisateur | Description |
|---|---|---|---|---|
| Fichiers chiffres (C2) | RPi1 → RPi2 | SFTP | `ds-repl` | Donnees de sauvegarde chiffrees par rclone crypt |
| Commandes de monitoring | RPi1 → RPi2 | SSH | `habyss` | Collecte de metriques (RAID, disques, charge) |
| Resultats de monitoring | RPi2 → RPi1 | SSH (retour) | `habyss` | Reponses aux commandes de diagnostic |

**Tous les flux sont inities par le RPi1.** Le RPi2 ne peut jamais initier de connexion vers le RPi1 ni vers aucune autre destination.

---

## Ce qui ne peut pas traverser l'air-gap

| Flux interdit | Raison |
|---|---|
| Acces Internet depuis RPi2 | Aucune route par defaut, aucun DNS, aucune passerelle |
| Partage Samba depuis/vers RPi2 | Samba non installe sur RPi2, ports 139/445 fermes |
| Connexion sortante depuis RPi2 | UFW bloque tout le trafic sortant |
| SSH depuis RPi2 vers RPi1 | Non autorise par UFW, aucune cle configuree |
| Toute connexion depuis une IP autre que 10.42.0.1 | UFW refuse tout sauf 10.42.0.1 |
| DNS, NTP, HTTP, HTTPS depuis RPi2 | Aucun service configure, aucune route |
| NAT ou routage via RPi1 | Forwarding IP desactive sur RPi1 |

---

## Regles UFW sur RPi2

### Politique par defaut

```bash
ufw default deny incoming
ufw default deny outgoing
```

**Les deux sens sont bloques par defaut.** Seules les exceptions explicites sont autorisees.

### Regles autorisees

```bash
# SSH/SFTP depuis RPi1 uniquement
ufw allow in from 10.42.0.1 to 10.42.0.2 port 22 proto tcp

# Autoriser les reponses aux connexions etablies (stateful)
ufw allow out to 10.42.0.1 port 1024:65535 proto tcp
```

### Regles resultantes

```
Status: active
Logging: on (low)
Default: deny (incoming), deny (outgoing), disabled (routed)

To                         Action      From
--                         ------      ----
10.42.0.2 22/tcp           ALLOW IN    10.42.0.1
10.42.0.1 1024:65535/tcp   ALLOW OUT   Anywhere
```

### Justification

- **Incoming** : seul le RPi1 (10.42.0.1) peut se connecter au port SSH (22) du RPi2
- **Outgoing** : seules les reponses aux connexions SSH etablies sont autorisees (ports ephemeres vers 10.42.0.1)
- **Tout le reste est refuse** : aucun paquet ne peut sortir vers Internet, le LAN client, ou toute autre destination

---

## Fenetres de synchronisation

### Ordonnancement des sauvegardes

```
Declenchement C1 (timer configurable, defaut : toutes les heures)
        |
        | Chiffrement local sur md1
        |
        v
    C1 termine
        |
        | Declenchement automatique de C2
        v
    C2 : rclone crypt via SFTP vers RPi2
        |
        v
    C2 termine
        |
        | Declenchement optionnel de C3 (si configure)
        v
    C3 : rclone crypt via SFTP distant
```

### Configuration du planning

Le planning est configurable via le fichier `/etc/cryoss/backup.conf` :

```ini
[c1]
schedule=hourly
# Cron personnalise possible : schedule=cron:0 */2 * * *

[c2]
schedule=after_c1
# Demarre automatiquement apres la fin de C1

[c3]
schedule=daily
# Cron personnalise possible : schedule=cron:0 2 * * *
enabled=true
```

### Duree des fenetres

La duree de synchronisation C2 depend du volume de donnees modifiees et de la bande passante du lien Ethernet point-a-point (theoriquement jusqu'a 1 Gbps). En pratique, pour des volumes PME typiques (quelques dizaines de Go modifies par jour), la synchronisation C2 dure generalement de quelques minutes a une heure.

---

## Durcissement du RPi2

### Packages non installes

Le RPi2 est installe avec un systeme minimal. Les packages suivants ne sont **pas installes** et ne doivent jamais l'etre :

- `samba`, `samba-common`, `smbclient` -- aucun partage reseau
- `apache2`, `nginx`, `lighttpd` -- aucun serveur web
- `curl`, `wget` -- aucun telechargement (pas d'Internet de toute facon)
- `NetworkManager-gnome`, interfaces graphiques -- systeme en mode console uniquement
- Tout package lié a un bureau graphique (desktop environment)

### Services actifs (liste exhaustive)

| Service | Justification |
|---|---|
| `sshd` | Reception SFTP (ds-repl) et monitoring (habyss) |
| `mdadm` | Gestion du RAID1 md0 |
| `ufw` | Pare-feu |
| `fail2ban` | Protection anti-brute-force SSH |
| `systemd-timesyncd` | Desactive (pas de NTP, pas d'Internet) |
| `cron` | Taches de maintenance locales |

### fail2ban

Configuration dediee pour le RPi2 (`/etc/fail2ban/jail.d/cryoss.conf`) :

```ini
[sshd]
enabled = true
port = 22
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600
ignoreip = 10.42.0.1
```

- Seul le RPi1 (10.42.0.1) est dans la liste blanche
- Trois tentatives echouees depuis toute autre source entrainent un bannissement d'une heure
- En pratique, aucune autre source ne devrait pouvoir atteindre le RPi2, mais fail2ban constitue une defense en profondeur

### Permissions des fichiers

```bash
# Repertoire de reception SFTP
chown root:root /home/ds-repl
chmod 755 /home/ds-repl

# Sous-repertoire de sauvegarde (ecrit par ds-repl)
chown ds-repl:ds-repl /home/ds-repl/backup
chmod 700 /home/ds-repl/backup

# Cles SSH
chown root:root /etc/ssh/authorized_keys/ds-repl
chmod 644 /etc/ssh/authorized_keys/ds-repl
```

### Mises a jour de securite

Le RPi2 n'ayant pas d'acces Internet, les mises a jour doivent etre appliquees manuellement :

1. Telechargement des paquets sur le RPi1 (qui a acces Internet)
2. Transfert vers le RPi2 via SCP (`habyss`)
3. Installation locale sur le RPi2

Ce processus est orchestrable via un script d'administration sur le RPi1, mais necessite toujours une action deliberee d'un administrateur.

---

## Anti-ransomware specifique au RPi2

### Couche 1 : Versioning rclone (`--backup-dir`)

C'est la protection la plus importante sur le RPi2 :

```
/home/ds-repl/backup/
    |
    +-- current/          <-- fichiers chiffres actuels
    |
    +-- versions/         <-- anciennes versions conservees
         +-- 2026-04-16/  <-- dossier horodate
         +-- 2026-04-15/
         +-- ...
```

**Mecanisme** :

- A chaque synchronisation C2, rclone utilise `--backup-dir /home/ds-repl/backup/versions/YYYY-MM-DD`
- Les fichiers modifies ou supprimes dans `current/` sont **deplaces** (et non supprimes) vers le repertoire de versions
- Un ransomware qui chiffre les fichiers source produira de nouveaux fichiers chiffres (doublement chiffres), mais les versions precedentes restent intactes dans `versions/`

**Politique de retention** :

- Les versions sont conservees pendant une duree configurable (defaut : 90 jours)
- Un cron local sur le RPi2 purge les versions au-dela de la duree de retention
- La purge est la seule operation de suppression autorisee sur le RPi2

### Protection par isolation

Au-dela du versioning, l'air-gap lui-meme constitue la meilleure protection :

- Un ransomware sur le reseau client ne peut pas atteindre le RPi2
- Un ransomware sur le RPi1 ne peut qu'envoyer des fichiers via SFTP (il ne peut pas supprimer les fichiers existants sur le RPi2 grace au chroot et au versioning)
- La seule facon de corrompre les donnees du RPi2 est un acces physique direct

### Scenario d'attaque et reponse

| Scenario | Impact sur RPi2 | Recuperation |
|---|---|---|
| Ransomware sur poste client | Aucun -- RPi2 inaccessible depuis le LAN | Restauration depuis RPi2 |
| Ransomware sur RPi1 | Les nouveaux fichiers envoyes sont corrompus, mais les versions precedentes sont intactes | Restauration depuis `versions/` sur RPi2 |
| Compromission SSH du RPi1 | L'attaquant peut envoyer des fichiers via ds-repl (chroot SFTP), mais ne peut pas supprimer les versions | Restauration depuis `versions/` sur RPi2 |
| Acces physique au RPi2 | Compromission totale possible | Restauration depuis C3 (copie distante) |

---

*Document maintenu par l'equipe Analyss. Derniere mise a jour : avril 2026.*
