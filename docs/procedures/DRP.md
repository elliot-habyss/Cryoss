# Plan de Reprise d'Activité (DRP) - Scénario Ransomware

> **Version :** 1.0
> **Date :** 2026-04-16
> **Auteur :** Analyss
> **Classification :** Document opérationnel - CONFIDENTIEL
> **Scénario principal :** Attaque par ransomware sur le réseau client

---

## Vue d'ensemble

Ce plan décrit les étapes à suivre en cas d'attaque par ransomware sur le réseau d'un client protégé par Cryoss. L'objectif est de restaurer les données dans un état sain le plus rapidement possible, en exploitant l'isolation air-gap du RPi2.

---

## Phase 0 : Détection (0 - 5 minutes)

### Signaux d'alerte

| Source | Signal | Action |
|--------|--------|--------|
| **Honeypot (fichier sentinelle)** | Email d'alerte automatique : le fichier sentinelle dans `/etc/sauvegarde` a été modifié ou chiffré | Passer immédiatement en Phase 1 |
| **Signalement client** | Le client rapporte des fichiers inaccessibles, renommés avec des extensions inconnues (`.locked`, `.encrypted`, `.crypt`, etc.) | Passer immédiatement en Phase 1 |
| **Watchdog Cryoss** | Détection d'anomalie : nombre anormal de fichiers modifiés, changement massif d'extensions, taille totale des données modifiée significativement | Passer immédiatement en Phase 1 |

### Actions immédiates

```bash
# Vérifier l'état du fichier sentinelle (depuis RPi1)
ls -la /etc/sauvegarde/.sentinel_file
sha256sum /etc/sauvegarde/.sentinel_file

# Vérifier les logs d'alerte
tail -50 /var/log/cryoss/watchdog.log
```

---

## Phase 1 : Confinement (5 - 15 minutes)

### PRIORITE ABSOLUE : ISOLER LE RESEAU

**Actions critiques dans l'ordre :**

1. **ISOLER les postes clients du réseau**

```
- Débrancher physiquement les câbles réseau des postes affectés
- OU désactiver les ports du switch correspondants
- OU couper le Wi-Fi si applicable
- NE PAS éteindre les postes (préserver les preuves en mémoire)
```

2. **NE PAS toucher RPi1 ni RPi2**

```
- Ne pas redémarrer les RPi
- Ne pas lancer de sauvegarde manuelle
- Ne pas modifier les données
- Les RPi doivent rester dans leur état actuel pour évaluation
```

3. **Documenter l'heure exacte de détection**

```
Date et heure de détection : ____________________
Source de l'alerte : ____________________________
Premiers fichiers affectés constatés : __________
```

4. **Évaluer le périmètre initial**

```bash
# Depuis RPi1 - Lister les fichiers récemment modifiés
find /etc/sauvegarde -mmin -60 -type f | head -50

# Compter les fichiers avec des extensions suspectes
find /etc/sauvegarde -type f \( -name "*.locked" -o -name "*.encrypted" -o -name "*.crypt" -o -name "*.ransom" \) | wc -l
```

---

## Phase 2 : Évaluation (15 - 60 minutes)

### 2.1 État de RPi1 et /etc/sauvegarde

```bash
# Se connecter en SSH à RPi1
ssh admin@rpi1

# Vérifier si les fichiers dans /etc/sauvegarde sont chiffrés par le ransomware
file /etc/sauvegarde/fichier_connu.docx
# Résultat normal : "Microsoft Word 2007+"
# Résultat compromis : "data" ou type inconnu

# Lister les fichiers modifiés dans les dernières 24h
find /etc/sauvegarde -mtime -1 -type f | wc -l

# Comparer avec le manifeste de la dernière sauvegarde
cat /var/log/cryoss/manifest_latest.json | python3 -m json.tool

# Vérifier la taille totale
du -sh /etc/sauvegarde/
```

### 2.2 État de RPi2 (via lien interco)

```bash
# Vérifier la connectivité avec RPi2
ping -c 3 rpi2-interco

# Se connecter à RPi2
ssh admin@rpi2-interco

# Vérifier que les sauvegardes chiffrées sont intactes sur RPi2
# (les fichiers chiffrés par rclone ne doivent PAS avoir été modifiés par le ransomware)
rclone cryptcheck /etc/sauvegarde cryoss-c2-crypt: --one-way 2>&1 | tail -5

# Si cryptcheck échoue, vérifier les dates de modification
find /chemin/vers/c2/encrypted -mmin -60 -type f | wc -l
# Si 0 fichier modifié récemment = RPi2 probablement sain
```

### 2.3 État de C3 (si disponible)

```bash
# Vérifier la connectivité avec le serveur distant
rclone lsd cryoss-c3:

# Vérifier l'intégrité des données distantes
rclone cryptcheck /etc/sauvegarde cryoss-c3-crypt: --one-way 2>&1 | tail -5
```

### 2.4 Déterminer la dernière sauvegarde saine

```bash
# Lister les versions disponibles sur RPi2
rclone lsd cryoss-versions:

# Pour chaque version, vérifier un fichier témoin
rclone cat cryoss-versions:2026-04-15/fichier_temoin.txt | file -
# Résultat attendu : texte ASCII ou type connu

# Trouver la date la plus récente avec des fichiers sains
# Remonter jour par jour si nécessaire
for date in 2026-04-16 2026-04-15 2026-04-14; do
    echo "=== Vérification $date ==="
    rclone ls cryoss-versions:$date/ 2>/dev/null | wc -l
    rclone cat cryoss-versions:$date/fichier_temoin.txt 2>/dev/null | file -
done
```

---

## Phase 3 : Restauration (1 - 4 heures)

### Scénario A : RPi2 est sain (cas le plus probable)

L'air-gap protège RPi2 des attaques réseau. C'est le scénario le plus courant.

#### Étape 1 : Identifier la dernière version saine

```bash
# Lister les versions
rclone lsd cryoss-versions:

# Vérifier la version choisie
rclone ls cryoss-versions:2026-04-15/ | wc -l
rclone cat cryoss-versions:2026-04-15/fichier_temoin.txt | file -
```

#### Étape 2 : Nettoyer /etc/sauvegarde

```bash
# ATTENTION : Cette commande supprime TOUTES les données compromises
# S'assurer que la version de restauration est confirmée

# Sauvegarder l'état compromis pour analyse forensique (optionnel)
tar czf /tmp/compromised_backup_$(date +%Y%m%d_%H%M%S).tar.gz /etc/sauvegarde/

# Nettoyer le répertoire
rm -rf /etc/sauvegarde/*
```

#### Étape 3 : Restaurer depuis les versions RPi2

```bash
# Restauration complète depuis la version saine
rclone sync cryoss-versions:2026-04-15/ /etc/sauvegarde/ --checksum --progress

# Vérifier le nombre de fichiers restaurés
find /etc/sauvegarde -type f | wc -l

# Vérifier l'intégrité par échantillonnage
file /etc/sauvegarde/fichier_connu.docx
sha256sum /etc/sauvegarde/fichier_temoin.txt
```

#### Étape 4 : Si la version est trop ancienne, compléter avec l'état courant C2

```bash
# L'état courant de C2 (miroir) peut contenir les données les plus récentes
# mais potentiellement compromises si la sauvegarde a tourné après l'attaque

# Comparer l'état courant C2 avec la version choisie
rclone check cryoss-c2-crypt: cryoss-versions:2026-04-15/ --one-way 2>&1 | head -20
```

### Scénario B : RPi2 compromis (improbable mais possible)

Si RPi2 est également compromis (attaque physique, compromission du lien interco) :

```bash
# Restaurer depuis C3 (serveur distant)
rclone sync cryoss-c3-crypt: /etc/sauvegarde/ --checksum --progress

# Vérifier l'intégrité
rclone cryptcheck /etc/sauvegarde cryoss-c3-crypt: --one-way
```

### Étape finale : Vérification et relance

```bash
# Vérification globale de l'intégrité des données restaurées
find /etc/sauvegarde -type f -exec sha256sum {} \; > /tmp/restore_verification.txt
wc -l /tmp/restore_verification.txt

# Relancer un cycle de sauvegarde complet pour synchroniser C1 et C2
sudo /opt/cryoss/backup.sh

# Vérifier que tous les chemins sont synchronisés
rclone cryptcheck /etc/sauvegarde cryoss-c1-crypt: --one-way
rclone cryptcheck /etc/sauvegarde cryoss-c2-crypt: --one-way
```

---

## Phase 4 : Remédiation

### 4.1 Identification du vecteur d'attaque

- Analyser les logs des postes compromis
- Identifier l'email/le lien/la vulnérabilité exploitée
- Documenter le type de ransomware (famille, variante)
- Conserver les preuves pour un éventuel dépôt de plainte

### 4.2 Nettoyage des postes affectés

```
- Réimager les postes compromis (ne pas tenter de désinfecter)
- Réinstaller le système d'exploitation depuis un support propre
- Réinstaller les applications métier
- NE PAS restaurer de données utilisateur depuis les postes compromis
```

### 4.3 Changement de tous les mots de passe

```
- Mots de passe Active Directory / comptes locaux
- Mots de passe Wi-Fi
- Mots de passe d'accès au partage Samba
- Clés SSH (si compromission suspectée)
- Mots de passe des comptes email
- Accès VPN
```

### 4.4 Reconnexion au réseau

```
1. Reconnecter les postes réimagés un par un
2. Vérifier que chaque poste accède correctement au partage Samba
3. Surveiller le trafic réseau pour détecter toute activité suspecte
4. Activer la journalisation renforcée sur le pare-feu
```

### 4.5 Surveillance post-incident

```
- Surveillance renforcée pendant 48 heures minimum
- Vérifier les logs Cryoss toutes les 4 heures
- Vérifier l'intégrité du fichier sentinelle toutes les heures
- Alerter Analyss immédiatement en cas de nouvelle anomalie
```

```bash
# Vérification manuelle post-incident
sha256sum /etc/sauvegarde/.sentinel_file
tail -20 /var/log/cryoss/watchdog.log
rclone cryptcheck /etc/sauvegarde cryoss-c1-crypt: --one-way 2>&1 | tail -3
```

---

## Matrice de priorité

| Scénario | RPO | RTO | Source de restauration | Procédure |
|----------|-----|-----|----------------------|-----------|
| Fichier unique supprimé | 24h | 15 min | C1 (local chiffré) | Restauration standard |
| Ransomware (réseau) | 24h | 2h | C2 versions (RPi2 air-gap) | Phase 3 scénario A |
| RPi1 détruit | 24h | 4h | C2 état courant (RPi2) | Restauration complète RPi2 |
| Les deux RPi détruits | 8h | 8h | C3 (SFTP distant) | Restauration sinistre total |
| RPi2 compromis (rare) | 8h | 4h | C3 (SFTP distant) | Phase 3 scénario B |

---

## Contacts d'urgence

| Rôle | Contact | Disponibilité |
|------|---------|---------------|
| **Astreinte Analyss** | À compléter | 24/7 |
| **Responsable client** | À compléter | Heures ouvrées |
| **Hébergeur C3** | À compléter | Selon contrat |

---

## Checklist de synthèse

### En cas de ransomware détecté :

- [ ] **Phase 0** : Alerte reçue (honeypot / client / watchdog)
- [ ] **Phase 1** : Postes clients isolés du réseau
- [ ] **Phase 1** : RPi1 et RPi2 laissés intacts
- [ ] **Phase 1** : Heure de détection documentée
- [ ] **Phase 2** : État de /etc/sauvegarde vérifié
- [ ] **Phase 2** : État de RPi2 vérifié via interco
- [ ] **Phase 2** : État de C3 vérifié (si disponible)
- [ ] **Phase 2** : Dernière sauvegarde saine identifiée
- [ ] **Phase 3** : Données compromises archivées (forensique)
- [ ] **Phase 3** : Restauration depuis version saine effectuée
- [ ] **Phase 3** : Intégrité des données restaurées vérifiée
- [ ] **Phase 3** : Cycle de sauvegarde relancé
- [ ] **Phase 4** : Vecteur d'attaque identifié
- [ ] **Phase 4** : Postes compromis réimagés
- [ ] **Phase 4** : Tous les mots de passe changés
- [ ] **Phase 4** : Postes reconnectés au réseau
- [ ] **Phase 4** : Surveillance renforcée 48h activée

---

## Révision

Ce plan est révisé :

- Après chaque incident de sécurité
- Au minimum une fois par an
- À chaque changement d'infrastructure
- Après chaque exercice de simulation (recommandé : 1x/an)
