# Modele de menaces Cryoss

**Methodologie :** STRIDE (Spoofing, Tampering, Repudiation, Information Disclosure, Denial of Service, Elevation of Privilege)
**Produit :** Cryoss -- Sauvegarde chiffree triple-redondance
**Editeur :** Analyss
**Version du document :** 1.0
**Date :** 2026-04-16

---

## 1. Actifs a proteger

### 1.1 Donnees

| Actif | Emplacement | Criticite | Description |
|-------|-------------|-----------|-------------|
| Donnees client en clair | `/etc/sauvegarde/` sur RPi1 | **Critique** | Fichiers partages via Samba, donnees de production du client |
| Archives chiffrees C1 | `/etc/encrypted/` sur RPi1 (RAID1) | **Elevee** | Copie locale chiffree (XSalsa20-Poly1305) |
| Archives chiffrees C2 | `/var/lib/ds-repl/data/` sur RPi2 | **Elevee** | Replique air-gap, independante de C1 |
| Archives chiffrees C3 | Serveur SFTP distant | **Elevee** | Copie hors site |
| Cles de chiffrement | `/root/.config/rclone/rclone.conf` sur RPi1 | **Critique** | 3 paires de cles independantes |
| Cles SSH | `/root/.ssh/`, `/home/habyss/.ssh/` | **Critique** | Authentification inter-machines |
| Configuration systeme | `/etc/` (UFW, fail2ban, sysctl, AppArmor) | **Elevee** | Parametres de durcissement |
| Cles API | Configuration cryoss-api | **Elevee** | Authentification aupres de la console Analyss |

### 1.2 Services

| Service | Port | Exposition | Criticite |
|---------|------|------------|-----------|
| Samba (smbd) | 445/tcp | LAN client | **Elevee** |
| SSH (sshd) | 22/tcp | LAN + interco | **Critique** |
| cryoss-api | Variable | Console Analyss | **Moyenne** |
| SFTP (RPi2) | 22/tcp | Interco uniquement | **Elevee** |

---

## 2. Acteurs de menace

| Acteur | Motivation | Capacite | Probabilite |
|--------|-----------|----------|-------------|
| **Ransomware** | Extorsion financiere | Chiffrement massif via Samba, propagation laterale | **Elevee** |
| **Attaquant interne** | Malveillance, negligence | Acces physique au LAN, connaissances du reseau local | **Moyenne** |
| **Attaquant physique** | Vol de materiel, espionnage | Acces physique aux RPi, extraction de disques | **Faible** |
| **Console Analyss compromise** | Acces distant non autorise | Commandes via API, tentative d'exfiltration | **Faible** |
| **Attaquant reseau externe** | Intrusion, exfiltration | Exploitation de services exposes, brute force SSH | **Moyenne** |

---

## 3. Scenarios de menace

### 3.1 Ransomware via Samba

**Categorie STRIDE :** Tampering, Denial of Service

**Description :**
Un poste client infecte par un ransomware utilise le partage Samba pour chiffrer les fichiers dans `/etc/sauvegarde/`. Le ransomware tente de modifier ou supprimer les fichiers accessibles via le partage reseau.

**Chaine d'attaque :**
1. Le poste client est compromis (phishing, exploit)
2. Le ransomware decouvre le partage Samba sur RPi1
3. Il chiffre/modifie les fichiers via le compte `ds-user`
4. Il tente d'acceder aux archives chiffrees

**Mesures de protection (4 couches anti-ransomware) :**

| Couche | Mecanisme | Effet |
|--------|-----------|-------|
| 1 -- Detection | **Honeypot inotify** : fichier piege dans le partage Samba | Detection immediate de toute modification suspecte, alerte declenchee |
| 2 -- Immutabilite | **chattr +a** sur `/etc/encrypted/` | Les archives chiffrees ne peuvent etre que completees, jamais modifiees ni supprimees |
| 3 -- Isolation | **Air-gap RPi2** | Le RPi2 n'est pas accessible depuis le LAN ; le ransomware ne peut pas l'atteindre |
| 4 -- Redondance | **Copie C3 distante** | Meme si RPi1 est entierement compromis, la copie hors site reste intacte |

**Impact residuel :** Les donnees en clair dans `/etc/sauvegarde/` peuvent etre chiffrees par le ransomware, mais la restauration est possible depuis C2 (RPi2) ou C3 (distant).

---

### 3.2 RPi1 entierement compromis

**Categorie STRIDE :** Spoofing, Tampering, Information Disclosure, Elevation of Privilege

**Description :**
Un attaquant obtient un acces root complet au RPi1 via une vulnerabilite non corrigee, une escalade de privileges ou un acces physique.

**Chaine d'attaque :**
1. Exploitation d'une vulnerabilite sur un service expose (Samba, SSH, API)
2. Escalade de privileges vers root
3. Acces aux donnees en clair, aux cles de chiffrement et a la configuration

**Mesures de protection :**

| Mesure | Effet |
|--------|-------|
| **RPi2 independant** | Les copies C2 sur RPi2 sont chiffrees avec des cles stockees sur RPi1 mais RPi2 est un systeme distinct ; l'attaquant ne peut pas supprimer les archives deja ecrites |
| **SFTP chroot** | Le compte `ds-repl` est restreint a `/var/lib/ds-repl/data/` sur RPi2 ; aucun acces au systeme RPi2 |
| **Copie C3** | La copie distante est independante du RPi1 |
| **AppArmor** | Les profils AppArmor limitent les actions des services meme en cas de compromission partielle |
| **Sudo whitelist** | Meme `habyss` ne peut executer que 17 commandes via sudo |

**Impact residuel :** Les donnees en clair et les cles de chiffrement sont exposees. Les archives sur RPi2 et C3 restent intactes mais pourraient theoriquement etre dechiffrees si les cles sont exfiltrees. Voir section 5 (risques residuels).

---

### 3.3 Vol physique du RPi1

**Categorie STRIDE :** Information Disclosure

**Description :**
Un attaquant vole physiquement le RPi1 ou extrait les disques du boitier RAID.

**Chaine d'attaque :**
1. Acces physique aux locaux du client
2. Vol du RPi1 ou des disques
3. Tentative de lecture des donnees

**Mesures de protection :**

| Mesure | Effet |
|--------|-------|
| **RAID1 chiffre** | Les donnees sur `/etc/encrypted/` sont chiffrees par rclone crypt |
| **Cles dans rclone.conf** | Les cles sont stockees dans `/root/.config/rclone/rclone.conf` (root-only, mode 0600) sur le meme systeme -- accessible en cas de vol du RPi1 complet |
| **RPi2 preserve** | Le RPi2, situe dans un emplacement distinct, reste intact |

**Impact residuel :** Si le RPi1 complet est vole (carte SD + disques), l'attaquant dispose des cles et des archives chiffrees, et peut potentiellement dechiffrer les donnees. Les copies C2 et C3 ne sont pas affectees. **Recommandation :** chiffrement LUKS du systeme de fichiers racine pour une protection supplementaire.

---

### 3.4 Console Analyss compromise

**Categorie STRIDE :** Spoofing, Tampering

**Description :**
Un attaquant compromet la console de supervision Analyss et tente d'utiliser cet acces pour atteindre les installations Cryoss des clients.

**Chaine d'attaque :**
1. Compromission de l'infrastructure Analyss
2. Recuperation des cles API des instances Cryoss
3. Tentative de commande a distance via l'API

**Mesures de protection :**

| Mesure | Effet |
|--------|-------|
| **Push unidirectionnel** | C'est le RPi1 qui pousse les donnees vers Analyss (heartbeat), pas l'inverse ; la console ne peut pas extraire de donnees |
| **Cles API par instance** | Chaque installation Cryoss a sa propre cle API ; la compromission d'une cle n'affecte pas les autres installations |
| **API non-root** | Le service `cryoss-api` tourne sous un utilisateur dedie sans privileges root |
| **Rate limiting** | L'API limite le nombre de requetes pour empecher les attaques par force brute |
| **Authentification constant-time** | La verification des cles API utilise une comparaison en temps constant pour prevenir les attaques par timing |

**Impact residuel :** Avec une cle API valide, un attaquant pourrait envoyer des commandes limitees via l'API, mais sans acces root ni acces aux donnees. L'impact est limite aux fonctions exposees par l'API (statut, declenchement de sauvegarde).

---

### 3.5 Acces physique au RPi2

**Categorie STRIDE :** Information Disclosure

**Description :**
Un attaquant obtient un acces physique au RPi2 et tente d'extraire les donnees.

**Chaine d'attaque :**
1. Localisation et acces physique au RPi2
2. Extraction de la carte SD ou du disque
3. Tentative de lecture des donnees

**Mesures de protection :**

| Mesure | Effet |
|--------|-------|
| **Donnees chiffrees uniquement** | Le RPi2 ne contient que des archives chiffrees par rclone crypt |
| **Cles sur RPi1** | Les cles de dechiffrement sont stockees sur le RPi1, pas sur le RPi2 |
| **Pas de rclone.conf** | Aucun fichier de configuration rclone n'est present sur le RPi2 |

**Impact residuel :** L'attaquant obtient des archives chiffrees sans les cles correspondantes. Sans acces au RPi1, le dechiffrement est computationnellement infaisable (XSalsa20-Poly1305).

---

### 3.6 Fuite de credentials SFTP (ds-repl)

**Categorie STRIDE :** Spoofing, Information Disclosure

**Description :**
Les identifiants ou la cle SSH du compte `ds-repl` sont compromis, permettant a un attaquant de se connecter au RPi2 via SFTP.

**Chaine d'attaque :**
1. Exfiltration de la cle SSH de `ds-repl` depuis RPi1
2. Connexion SFTP au RPi2 via l'interco
3. Tentative d'acces aux donnees ou au systeme

**Mesures de protection :**

| Mesure | Effet |
|--------|-------|
| **Chroot SFTP** | Le compte `ds-repl` est confine a `/var/lib/ds-repl/data/` ; aucun acces au reste du systeme de fichiers |
| **ForceCommand internal-sftp** | Impossible d'executer des commandes shell ; seul le protocole SFTP est autorise |
| **Ecriture seule** | Les permissions limitent l'acces a l'ecriture dans le repertoire chroot ; pas de lecture des autres chemins |
| **Interco uniquement** | La connexion n'est possible que depuis 10.42.0.1 (RPi1), pas depuis le LAN |

**Impact residuel :** Un attaquant avec ces credentials pourrait ecrire des fichiers dans le repertoire chroot, mais ne peut ni lire les donnees existantes sur d'autres chemins, ni executer de commandes, ni sortir du chroot.

---

## 4. Matrice des mesures d'attenuation

| Menace | Mesure | Composant | Categorie STRIDE |
|--------|--------|-----------|------------------|
| Ransomware | Honeypot inotify | RPi1 | T, D |
| Ransomware | chattr +a | RPi1 | T |
| Ransomware | Air-gap RPi2 | RPi2 | T, D |
| Compromission RPi1 | SFTP chroot | RPi2 | S, E |
| Compromission RPi1 | AppArmor | RPi1 | E |
| Compromission RPi1 | Sudo whitelist | RPi1 | E |
| Vol physique RPi1 | Chiffrement rclone | RPi1 | I |
| Vol physique RPi2 | Cles sur RPi1 uniquement | RPi1/RPi2 | I |
| Console compromise | Push unidirectionnel | RPi1 | S, T |
| Console compromise | Cles API par instance | RPi1 | S |
| Brute force SSH | fail2ban | RPi1, RPi2 | S, D |
| Brute force SSH | Authentification par cle | RPi1, RPi2 | S |
| Mouvement lateral | UFW strict | RPi1, RPi2 | T, E |
| Fuite SFTP | Chroot + ForceCommand | RPi2 | S, I, E |
| Elevation de privileges | AppArmor enforce | RPi1 | E |
| Elevation de privileges | Sysctl hardening | RPi1, RPi2 | E |

---

## 5. Risques residuels et acceptation

### 5.1 Risques identifies

| # | Risque residuel | Probabilite | Impact | Acceptation |
|---|----------------|-------------|--------|-------------|
| R1 | Vol physique du RPi1 complet (cles + donnees chiffrees) permettant le dechiffrement | Faible | Critique | **Accepte avec recommandation** : deploiement de LUKS sur la carte SD pour chiffrer le systeme de fichiers racine |
| R2 | Compromission simultanee du RPi1 et du RPi2 (attaque physique coordonnee) | Tres faible | Critique | **Accepte** : la copie C3 distante reste intacte |
| R3 | Vulnerabilite 0-day sur OpenSSH permettant un acces non autorise | Faible | Eleve | **Accepte avec attenuation** : fail2ban, AppArmor, et politique de mise a jour rapide |
| R4 | Exfiltration des cles depuis RPi1 compromis puis dechiffrement des copies C2/C3 | Faible | Critique | **Accepte avec recommandation** : rotation des cles apres tout incident sur RPi1 |
| R5 | Corruption silencieuse des donnees non detectee par les health checks | Tres faible | Eleve | **Accepte avec attenuation** : checksums d'integrite et triple redondance |
| R6 | Attaque par canal auxiliaire sur le lien interco (ecoute physique du cable) | Tres faible | Moyen | **Accepte** : les donnees transitant sont deja chiffrees par SSH |

### 5.2 Mesures complementaires recommandees

1. **LUKS sur RPi1** : chiffrement complet du systeme de fichiers pour proteger les cles en cas de vol physique
2. **MFA pour SSH** : ajout d'un second facteur d'authentification pour le compte `habyss`
3. **Segmentation VLAN** : placement du RPi1 dans un VLAN dedie pour isoler le trafic Samba
4. **Sauvegarde des cles hors-bande** : stockage d'une copie des cles de chiffrement dans un coffre physique ou un HSM

---

## 6. Revue et mise a jour

Ce modele de menaces est revu :

- **Annuellement** dans le cadre de l'audit de securite Analyss
- **Apres tout incident** de securite affectant une installation Cryoss
- **Lors de modifications architecturales** majeures du systeme

Chaque revue est documentee et les modifications sont tracees dans l'historique du document.

---

*Document maintenu par l'equipe securite Analyss. Classification : interne.*
