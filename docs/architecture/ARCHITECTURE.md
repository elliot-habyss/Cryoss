# Architecture Cryoss

> Systeme de sauvegarde chiffree a triple redondance sur paires de Raspberry Pi, concu pour les PME.
> Produit developpe par **Analyss**.

---

## Table des matieres

1. [Vue d'ensemble](#vue-densemble)
2. [Diagramme general](#diagramme-general)
3. [RPi1 -- Noeud principal](#rpi1--noeud-principal)
4. [RPi2 -- Noeud air-gap](#rpi2--noeud-air-gap)
5. [Topologie reseau](#topologie-reseau)
6. [Flux de donnees -- Chemins de sauvegarde](#flux-de-donnees--chemins-de-sauvegarde)
7. [Chiffrement par chemin](#chiffrement-par-chemin)
8. [Services systemd et timers](#services-systemd-et-timers)
9. [Supervision et monitoring](#supervision-et-monitoring)

---

## Vue d'ensemble

Cryoss deploie une paire de Raspberry Pi chez chaque client PME. Le **RPi1** est connecte au reseau local du client et expose un partage Samba. Le **RPi2** est physiquement isole (air-gap) et ne communique qu'avec le RPi1 via un cable Ethernet dedie. Les donnees traversent jusqu'a trois chemins de sauvegarde chiffres independants, garantissant une resilience maximale face aux ransomwares, pannes materielles et sinistres.

La console **Analyss** recoit les battements de coeur (heartbeat) de chaque RPi1 deploye, sans jamais acceder directement aux donnees client.

---

## Diagramme general

```
                          INTERNET
                             |
                             | HTTPS (heartbeat)
                             v
                    +------------------+
                    |  Console Analyss |
                    |  (Dashboard,     |
                    |   Alertes)       |
                    +------------------+
                             ^
                             | Heartbeat toutes les 5 min
                             |
=====[ Reseau LAN Client ]====================================
|                                                             |
|    +--------------------------------------------------+     |
|    |               RPi1 (noeud principal)              |     |
|    |                                                   |     |
|    |  Samba share  -->  /etc/sauvegarde (RAID1 md0)    |     |
|    |                     sda + sdb                     |     |
|    |                                                   |     |
|    |  rclone crypt --> /etc/encrypted (RAID1 md1) [C1] |     |
|    |                     sdc + sdd                     |     |
|    |                                                   |     |
|    |  rclone crypt --> SFTP vers RPi2             [C2] |     |
|    |                                                   |     |
|    |  rclone crypt --> SFTP distant (optionnel)   [C3] |     |
|    |                                                   |     |
|    |  FastAPI :8420 (localhost uniquement)              |     |
|    +--------------------------------------------------+     |
|                    |                                         |
|                    | Ethernet dedie (10.42.0.0/30)           |
|                    | Cable point-a-point                     |
|                    |                                         |
|    +--------------------------------------------------+     |
|    |               RPi2 (noeud air-gap)                |     |
|    |                                                   |     |
|    |  SFTP chroot (ds-repl) <-- reception C2           |     |
|    |  /etc/sauvegarde (RAID1 md0)                      |     |
|    |     sda + sdb                                     |     |
|    |                                                   |     |
|    |  Aucun acces Internet                             |     |
|    |  Surveille par RPi1 via SSH interco               |     |
|    +--------------------------------------------------+     |
|                                                             |
===============================================================
```

---

## RPi1 -- Noeud principal

### Materiel

| Composant | Detail |
|---|---|
| Carte | Raspberry Pi 4 / 5 |
| HAT | Penta SATA HAT (Radxa / compatible) |
| Disques | 4 HDD (2.5" ou 3.5" selon boitier) |
| Stockage brut | `sda` + `sdb` → RAID1 `md0` (donnees claires) |
| Stockage chiffre | `sdc` + `sdd` → RAID1 `md1` (donnees chiffrees C1) |
| Reseau | Ethernet Gigabit vers LAN client + Ethernet dedie vers RPi2 |
| Alimentation | Alimentation 12V dediee via HAT |

### Composants logiciels

| Composant | Role |
|---|---|
| **Samba** (`smbd`) | Partage reseau pour les postes clients |
| **mdadm** | Gestion des grappes RAID1 (`md0`, `md1`) |
| **rclone** | Chiffrement et synchronisation (C1, C2, C3) |
| **FastAPI** | API locale sur le port 8420, ecoute uniquement sur `127.0.0.1` |
| **cryoss-backup** | Service principal d'orchestration des sauvegardes |
| **cryoss-heartbeat** | Envoi des heartbeat vers la console Analyss |
| **cryoss-watchdog** | Surveillance locale toutes les 15 minutes |
| **cryoss-health** | Verification de sante quotidienne et hebdomadaire |
| **inotifywait** | Surveillance du fichier sentinelle honeypot |
| **AppArmor** | Profils de confinement pour `smbd` et `cryoss-backup` |
| **UFW** | Pare-feu local |
| **fail2ban** | Protection contre les tentatives de brute-force |

### Flux de donnees interne RPi1

```
Postes clients (SMB)
        |
        v
/etc/sauvegarde  (md0: sda+sdb, RAID1, donnees claires)
        |
        +---> rclone crypt ---> /etc/encrypted  (md1: sdc+sdd, RAID1) [C1]
        |
        +---> rclone crypt ---> SFTP 10.42.0.2 (RPi2)                [C2]
        |
        +---> rclone crypt ---> SFTP distant (optionnel)              [C3]
```

### API FastAPI

L'API FastAPI ecoute sur `127.0.0.1:8420` et n'est pas exposee sur le reseau. Elle sert a :

- Declencher des sauvegardes manuelles
- Consulter l'etat des services et des RAID
- Recuperer les metriques pour le heartbeat
- Gerer la configuration locale

---

## RPi2 -- Noeud air-gap

### Materiel

| Composant | Detail |
|---|---|
| Carte | Raspberry Pi 4 / 5 |
| HAT | Penta SATA HAT |
| Disques | 2 HDD → RAID1 `md0` (`sda` + `sdb`) |
| Reseau | Un seul port Ethernet, cable point-a-point vers RPi1 |
| Alimentation | Alimentation 12V dediee |

### Principe air-gap

Le RPi2 n'a **aucun acces a Internet**. Il n'est connecte a aucun switch, routeur ou point d'acces. Son unique interface reseau est reliee directement au RPi1 par un cable Ethernet dedie. Voir le document [AIR_GAP.md](./AIR_GAP.md) pour le detail complet de la strategie.

### SFTP chroot

Le RPi2 accepte les connexions SFTP entrantes depuis le RPi1 via l'utilisateur `ds-repl` :

- **ForceCommand** : `internal-sftp`
- **ChrootDirectory** : `/home/ds-repl`
- **Authentification** : cle SSH uniquement (mot de passe desactive)
- **Restrictions** : aucun shell interactif, aucun tunnel, aucun port forwarding

Un second utilisateur (`habyss`) est autorise en SSH depuis le RPi1 pour les taches d'administration et de monitoring.

### Monitoring du RPi2

Le RPi2 ne peut pas envoyer de donnees vers l'exterieur. C'est le RPi1 qui se connecte periodiquement en SSH au RPi2 pour collecter :

- Etat du RAID `md0`
- Utilisation disque et temperatures
- Etat des services
- Charge CPU et memoire

Ces informations sont incluses dans le heartbeat envoye par le RPi1 vers la console Analyss.

---

## Topologie reseau

```
                    INTERNET
                       |
                   [Routeur / Box client]
                       |
               [Switch LAN client]
                    /       \
           [Postes]         [RPi1]
            clients      eth0: DHCP ou IP fixe
                             |
                             | eth1 (ou USB-Ethernet)
                             | Cable Ethernet dedie
                             | point-a-point
                             |
                          [RPi2]
                       eth0: 10.42.0.2/30
```

### Sous-reseaux

| Reseau | Plage | Usage |
|---|---|---|
| LAN client | Variable (ex. 192.168.1.0/24) | Postes clients, RPi1 |
| Interconnexion | 10.42.0.0/30 | RPi1 (10.42.0.1) ↔ RPi2 (10.42.0.2) |

### Regles reseau cles

- Le RPi1 a deux interfaces : une sur le LAN client, une sur l'interconnexion
- Le RPi2 n'a qu'une seule interface, sur l'interconnexion
- **Aucune route par defaut** n'est configuree sur le RPi2
- **Aucun NAT** n'est configure sur le RPi1 pour le RPi2
- Le forwarding IP est desactive sur le RPi1 (`net.ipv4.ip_forward = 0`)

---

## Flux de donnees -- Chemins de sauvegarde

### Chemin C1 -- Chiffrement local

```
/etc/sauvegarde (md0, clair)
        |
        | rclone crypt (paire de cles C1)
        v
/etc/encrypted (md1, chiffre)
```

- **Source** : donnees claires sur RAID1 `md0`
- **Destination** : donnees chiffrees sur RAID1 `md1`
- **Chiffrement** : rclone crypt avec paire de cles C1
- **Frequence** : configurable (defaut : toutes les heures)
- **Objectif** : copie chiffree locale en cas de compromission du partage Samba

### Chemin C2 -- Replication vers RPi2

```
/etc/sauvegarde (md0, clair)
        |
        | rclone crypt (paire de cles C2)
        v
SFTP 10.42.0.2:/home/ds-repl/backup/ (RPi2, md0, chiffre)
```

- **Source** : donnees claires sur RPi1
- **Destination** : RPi2 via SFTP chroot
- **Chiffrement** : rclone crypt avec paire de cles C2 (independante de C1)
- **Frequence** : se declenche apres la fin de C1
- **Objectif** : copie hors-ligne sur noeud air-gap, inaccessible aux ransomwares

### Chemin C3 -- Replication distante (optionnel)

```
/etc/sauvegarde (md0, clair)
        |
        | rclone crypt (paire de cles C3)
        v
SFTP distant (serveur tiers ou datacenter)
```

- **Source** : donnees claires sur RPi1
- **Destination** : serveur SFTP distant via Internet
- **Chiffrement** : rclone crypt avec paire de cles C3 (independante de C1 et C2)
- **Frequence** : configurable, generalement quotidienne
- **Objectif** : copie hors-site en cas de sinistre physique (incendie, vol)

---

## Chiffrement par chemin

| Chemin | Algorithme contenu | Algorithme noms de fichiers | Paire de cles | Stockage des cles |
|---|---|---|---|---|
| C1 | XSalsa20-Poly1305 | AES-256-EME | Cles C1 | `/etc/cryoss/keys-backup.conf` + `rclone.conf` |
| C2 | XSalsa20-Poly1305 | AES-256-EME | Cles C2 | `/etc/cryoss/keys-backup.conf` + `rclone.conf` |
| C3 | XSalsa20-Poly1305 | AES-256-EME | Cles C3 | `/etc/cryoss/keys-backup.conf` + `rclone.conf` |

**Points importants** :

- Chaque chemin utilise une **paire de cles independante** (password + password2 dans la terminologie rclone)
- La compromission d'une paire de cles ne permet pas de dechiffrer les donnees des autres chemins
- Les cles sont stockees dans `/etc/cryoss/keys-backup.conf` (backup) et dans le fichier `rclone.conf` (utilisation operationnelle)
- `XSalsa20-Poly1305` assure le chiffrement authentifie du contenu des fichiers
- `AES-256-EME` assure l'obfuscation deterministe des noms de fichiers

---

## Services systemd et timers

### Services permanents

| Service | Description | Redemarrage |
|---|---|---|
| `cryoss-backup.service` | Orchestrateur principal des sauvegardes | `on-failure`, delai 30s |
| `cryoss-heartbeat.service` | Envoi des heartbeat vers Analyss | `on-failure`, delai 10s |
| `cryoss-watchdog.service` | Surveillance locale (RAID, disques, services) | `on-failure`, delai 10s |
| `cryoss-sentinel.service` | Surveillance inotify du fichier honeypot | `always` |
| `smbd.service` | Serveur Samba (partage reseau) | `on-failure` |
| `cryoss-api.service` | FastAPI sur localhost:8420 | `on-failure`, delai 5s |

### Timers

| Timer | Frequence | Service declenche | Description |
|---|---|---|---|
| `cryoss-backup-c1.timer` | Configurable (defaut : 1h) | `cryoss-backup-c1.service` | Chiffrement local C1 |
| `cryoss-backup-c2.timer` | Apres C1 | `cryoss-backup-c2.service` | Replication vers RPi2 C2 |
| `cryoss-backup-c3.timer` | Configurable (defaut : quotidien) | `cryoss-backup-c3.service` | Replication distante C3 |
| `cryoss-health-daily.timer` | Quotidien a 02h00 | `cryoss-health-daily.service` | Verification de sante quotidienne |
| `cryoss-health-weekly.timer` | Hebdomadaire (dimanche 03h00) | `cryoss-health-weekly.service` | Verification de sante approfondie |
| `cryoss-heartbeat.timer` | Toutes les 5 minutes | `cryoss-heartbeat.service` | Heartbeat vers console Analyss |
| `cryoss-watchdog.timer` | Toutes les 15 minutes | `cryoss-watchdog.service` | Surveillance locale |

---

## Supervision et monitoring

### Niveaux de surveillance

| Niveau | Frequence | Portee | Description |
|---|---|---|---|
| **Watchdog** | 15 min | RPi1 + RPi2 | Verification rapide : RAID, services actifs, espace disque, temperatures |
| **Health quotidien** | 24h | RPi1 + RPi2 | Verification complete : integrite RAID, SMART disques, logs d'erreurs, coherence des sauvegardes |
| **Health hebdomadaire** | 7 jours | RPi1 + RPi2 | Verification approfondie : scrub RAID, test SMART etendu, verification d'integrite des fichiers chiffres |
| **Heartbeat** | 5 min | RPi1 → Analyss | Envoi de l'etat complet vers la console Analyss |

### Metriques collectees

**RPi1** :
- Etat des grappes RAID (`md0`, `md1`)
- Utilisation et temperatures des disques (SMART)
- Etat de chaque service systemd
- Charge CPU, memoire, swap
- Dernier backup reussi par chemin (C1, C2, C3)
- Etat du fichier sentinelle honeypot
- Nombre de fichiers et taille totale par destination

**RPi2** (collecte via SSH depuis RPi1) :
- Etat de la grappe RAID `md0`
- Utilisation et temperatures des disques
- Etat des services
- Charge CPU et memoire
- Espace disponible

### Alertes

Huit conditions declenchent une alerte vers la console Analyss :

1. **RAID degrade** : un disque tombe dans une grappe RAID
2. **Disque defaillant** : erreurs SMART critiques ou temperature excessive
3. **Service arrete** : un service cryoss ou smbd est inactif
4. **CPU/memoire** : charge anormalement elevee sur une periode prolongee
5. **Backup en echec** : un chemin de sauvegarde n'a pas abouti dans le delai prevu
6. **RPi2 injoignable** : le RPi1 ne peut plus se connecter au RPi2 via SSH
7. **Honeypot declenche** : le fichier sentinelle a ete modifie (suspicion de ransomware)
8. **Offline** : la console Analyss ne recoit plus de heartbeat d'un RPi1

Les alertes sont automatiquement resolues lorsque la condition revient a la normale, sauf pour le honeypot qui necessite une intervention manuelle.

---

## Anti-ransomware -- 4 couches de protection

| Couche | Mecanisme | Emplacement | Description |
|---|---|---|---|
| 1 | **Versioning rclone** | RPi2 | `--backup-dir` conserve les versions precedentes lors de chaque synchronisation. Un ransomware chiffrant les fichiers source produira de nouveaux fichiers chiffres, mais les anciennes versions restent intactes. |
| 2 | **Honeypot inotify** | RPi1 | Un fichier sentinelle est place dans le partage Samba. Toute modification declenche une alerte immediate et peut suspendre les sauvegardes. |
| 3 | **chattr +a** | RPi1 | Le drapeau append-only est applique sur `/etc/encrypted`, empechant la suppression ou la modification des fichiers chiffres existants. |
| 4 | **AppArmor** | RPi1 | Profils de confinement pour `smbd` et `cryoss-backup`, limitant les chemins accessibles et les operations autorisees. |

---

*Document maintenu par l'equipe Analyss. Derniere mise a jour : avril 2026.*
