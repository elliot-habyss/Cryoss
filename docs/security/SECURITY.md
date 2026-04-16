# Politique de securite Cryoss

**Produit :** Cryoss -- Sauvegarde chiffree triple-redondance sur paires de Raspberry Pi
**Editeur :** Analyss
**Version du document :** 1.0
**Date :** 2026-04-16

---

## 1. Portee

Cette politique couvre l'ensemble du systeme Cryoss deploye chez un client :

| Composant | Role |
|-----------|------|
| **RPi1** | Serveur de sauvegarde principal (Samba, chiffrement, RAID logiciel) |
| **RPi2** | Replique air-gap (SFTP chroot, aucun acces Internet) |
| **Lien interco** | Liaison point-a-point 10.42.0.0/30 entre RPi1 et RPi2 |
| **Console Analyss** | Supervision a distance (heartbeat, alertes) |

La politique s'applique a tous les intervenants : administrateurs Analyss, techniciens de deploiement et utilisateurs finaux du partage Samba.

---

## 2. Principes fondamentaux

### 2.1 Defense en profondeur

Chaque couche de securite est independante. La compromission d'une couche ne suffit pas a atteindre les donnees claires. Les couches principales sont :

1. Chiffrement au repos (rclone crypt)
2. Controle d'acces systeme (utilisateurs, permissions, sudo)
3. Securite reseau (UFW, fail2ban, isolation)
4. Detection et reaction (honeypot, watchdog, alertes)

### 2.2 Moindre privilege

Chaque utilisateur et service dispose uniquement des droits necessaires a sa fonction. Aucun compte n'est omnipotent ; meme le compte administrateur `habyss` est soumis a une liste blanche sudo limitee.

### 2.3 Air-gap

Le RPi2 n'a aucune connexion au reseau local du client ni a Internet. Sa seule interface reseau est le lien point-a-point avec le RPi1. Il ne peut ni initier de connexion sortante ni etre contacte depuis le LAN.

---

## 3. Chiffrement au repos

### 3.1 Algorithme

Cryoss utilise **rclone crypt** avec le couple :

- **XSalsa20** pour le chiffrement symetrique des donnees
- **Poly1305** pour l'authentification des blocs (AEAD)

### 3.2 Gestion des cles

Le systeme genere **3 paires de cles independantes**, une par copie de sauvegarde :

| Copie | Emplacement des cles | Stockage des archives |
|-------|---------------------|-----------------------|
| C1 (locale) | `/root/.config/rclone/rclone.conf` sur RPi1 | `/etc/encrypted/` sur RPi1 (RAID1) |
| C2 (interco) | `/root/.config/rclone/rclone.conf` sur RPi1 | `/var/lib/ds-repl/data/` sur RPi2 |
| C3 (distante) | `/root/.config/rclone/rclone.conf` sur RPi1 | Serveur SFTP distant |

Les fichiers `rclone.conf` sont accessibles uniquement par `root` (permissions `0600`). Les cles ne sont jamais transmises en clair sur le reseau : seules les donnees deja chiffrees transitent vers RPi2 et C3.

### 3.3 Rotation des cles

La rotation des cles necessite un re-chiffrement complet de la copie concernee. La procedure est documentee dans le runbook operationnel et doit etre realisee par un administrateur Analyss.

---

## 4. Chiffrement en transit

| Flux | Protocole | Detail |
|------|-----------|--------|
| RPi1 vers RPi2 | **SFTP** (SSH) | Authentification par cle, chroot, port 22 sur interco |
| RPi1 vers C3 | **SFTP** (SSH) | Authentification par cle, serveur distant Analyss |
| Heartbeat / API | **HTTPS** (TLS 1.2+) | Certificat valide, authentification par cle API |
| Administration | **SSH** | Cle Ed25519, pas de mot de passe, pas de root |

Aucun flux en clair n'est autorise. Le protocole SMB entre les postes clients et le RPi1 utilise le chiffrement SMB3 (`smb encrypt = required`).

---

## 5. Controle d'acces

### 5.1 Comptes systeme

| Utilisateur | Role | Shell | Acces |
|-------------|------|-------|-------|
| `ds-user` | Partage Samba (lecture/ecriture) | `/usr/sbin/nologin` | Samba uniquement |
| `habyss` | Administration | `/bin/bash` | SSH par cle, sudo (liste blanche) |
| `ds-repl` | Replication vers RPi2 | `/usr/sbin/nologin` | SFTP chroot uniquement |
| `cryoss-api` | Service API | `/usr/sbin/nologin` | Execution du service, non-root |

### 5.2 Sudo -- Liste blanche

Le compte `habyss` dispose d'un acces sudo restreint a **17 commandes** specifiques (systemctl, mdadm, rclone, etc.). L'execution de commandes arbitraires via sudo n'est pas autorisee. La liste complete figure dans `/etc/sudoers.d/habyss`.

### 5.3 Permissions fichiers

- `/etc/sauvegarde/` : propriete `ds-user:ds-user`, mode `0770`
- `/etc/encrypted/` : propriete `root:root`, attribut `chattr +a` (ajout seul)
- `/root/.config/rclone/rclone.conf` : propriete `root:root`, mode `0600`
- `/var/lib/ds-repl/data/` : propriete `ds-repl:ds-repl`, chroot SFTP

---

## 6. Securite reseau

### 6.1 RPi1 -- Regles UFW

```
Default: deny incoming, allow outgoing
Allow SSH (22/tcp) from LAN
Allow Samba (445/tcp) from LAN
Allow SSH (22/tcp) from 10.42.0.2 (interco RPi2)
Allow API port from console Analyss uniquement
```

### 6.2 RPi2 -- Regles UFW

```
Default: deny incoming, deny outgoing
Allow SSH (22/tcp) from 10.42.0.1 uniquement
```

Le RPi2 n'a aucun port ouvert vers le LAN ni vers Internet. Il ne peut initier aucune connexion sortante.

### 6.3 Fail2ban

Actif sur les deux RPi avec le jail `sshd` :

- `maxretry = 3`
- `bantime = 3600` (1 heure)
- `findtime = 600` (10 minutes)

---

## 7. Surveillance et monitoring

### 7.1 Watchdog

Un service watchdog surveille en continu :

- L'etat du RAID (mdadm)
- L'espace disque disponible
- L'etat des services critiques (smbd, cryoss-backup, cryoss-api)
- La connectivite interco vers RPi2

### 7.2 Health checks

Des verifications de sante periodiques sont executees :

- Integrite des archives chiffrees (checksums)
- Coherence entre les 3 copies
- Etat de la replication

### 7.3 Heartbeat et alertes

Le systeme envoie un heartbeat regulier a la console Analyss via HTTPS. En cas de :

- Heartbeat manquant depuis plus de 15 minutes
- RAID degrade
- Echec de sauvegarde
- Detection d'activite suspecte (honeypot)

Une alerte est declenchee et transmise a l'equipe Analyss.

---

## 8. Politique de mise a jour

### 8.1 Mecanisme

Les mises a jour sont deployees via le script `update.sh` qui :

1. Telecharge la nouvelle version depuis le depot Analyss
2. Sauvegarde la configuration existante
3. Applique la mise a jour sans ecraser les fichiers de configuration
4. Redemarre les services concernes
5. Verifie le bon fonctionnement post-mise a jour

### 8.2 Garanties

- **Aucune operation destructrice** : `update.sh` ne supprime jamais de donnees client
- **Preservation de la configuration** : les fichiers `rclone.conf`, les cles SSH et les parametres specifiques au client sont preserves
- **Rollback** : en cas d'echec, la version precedente est restauree automatiquement

### 8.3 Frequence

Les mises a jour de securite critiques sont deployees des que disponibles. Les mises a jour fonctionnelles suivent un cycle mensuel.

---

## 9. Signalement d'incidents

### 9.1 Contact

Pour signaler un incident de securite :

- **Email :** support@analyss.fr
- **Objet :** `[SECURITE] [NOM_CLIENT] -- Description breve`
- **Delai de reponse :** 4 heures ouvrables pour les incidents critiques

### 9.2 Informations a fournir

1. Date et heure de detection
2. Nature de l'incident (ransomware, intrusion, panne, etc.)
3. Composants affectes (RPi1, RPi2, reseau)
4. Actions deja entreprises
5. Captures d'ecran ou logs si disponibles

### 9.3 Classification

| Niveau | Description | Delai de traitement |
|--------|-------------|---------------------|
| **Critique** | Ransomware detecte, compromission confirmee | 4 heures |
| **Eleve** | RAID degrade, echec de replication | 8 heures |
| **Moyen** | Alerte fail2ban, tentative d'intrusion bloquee | 24 heures |
| **Bas** | Anomalie de monitoring, avertissement | 48 heures |

---

## 10. Conformite et audit

Analyss s'engage a :

- Realiser un audit de securite annuel de l'infrastructure Cryoss
- Maintenir a jour la documentation de securite
- Informer les clients de toute vulnerabilite decouverte affectant leur installation
- Fournir sur demande les rapports d'audit aux clients

---

*Document maintenu par l'equipe securite Analyss. Toute modification doit etre validee par le responsable securite.*
