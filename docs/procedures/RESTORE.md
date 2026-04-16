# Procédures de restauration Cryoss

> **Version :** 1.0
> **Date :** 2026-04-16
> **Auteur :** Analyss
> **Classification :** Document opérationnel interne

---

## Table des matières

1. [Restauration standard (fichier supprimé)](#1-restauration-standard-fichier-supprimé-accidentellement)
2. [Restauration d'une version antérieure](#2-restauration-dune-version-antérieure)
3. [Restauration complète depuis RPi2](#3-restauration-complète-depuis-rpi2-sinistre-rpi1)
4. [Restauration air-gap (principe des 4 yeux)](#4-restauration-air-gap-principe-des-4-yeux)
5. [Restauration après sinistre total](#5-restauration-après-sinistre-total-les-deux-rpi-détruits)

---

## 1. Restauration standard (fichier supprimé accidentellement)

**Scénario :** Un utilisateur a supprimé un fichier par erreur depuis le partage Samba.
**RPO :** 24h | **RTO :** 15 min

### Étape 1 : Vérifier si le fichier est encore présent

Parfois, Samba renomme les fichiers au lieu de les supprimer (corbeille réseau, renommage accidentel).

```bash
# Rechercher le fichier dans /etc/sauvegarde
find /etc/sauvegarde -iname "*nom_du_fichier*" -type f
```

Si le fichier est trouvé, il suffit de le remettre en place. Fin de la procédure.

### Étape 2 : Restaurer depuis C1 (chiffré local)

C1 est le miroir chiffré local sur RPi1. C'est la source la plus rapide.

```bash
# Lister le fichier dans C1 pour confirmer sa présence
rclone ls cryoss-c1-crypt: --include "*/nom_du_fichier"

# Restaurer le fichier
rclone copy cryoss-c1-crypt:chemin/vers/le/fichier /etc/sauvegarde/chemin/vers/

# Vérifier l'intégrité
sha256sum /etc/sauvegarde/chemin/vers/le/fichier
```

### Étape 3 : Si C1 est corrompu, restaurer depuis C2 (RPi2)

Si C1 est indisponible ou corrompu, utiliser la copie air-gap sur RPi2.

```bash
# Lister le fichier dans C2
rclone ls cryoss-c2-crypt: --include "*/nom_du_fichier"

# Restaurer depuis C2
rclone copy cryoss-c2-crypt:chemin/vers/le/fichier /etc/sauvegarde/chemin/vers/

# Vérifier l'intégrité
sha256sum /etc/sauvegarde/chemin/vers/le/fichier
```

> **Note :** Après restauration, le fichier sera automatiquement re-sauvegardé lors du prochain cycle (C1 + C2 à 02:00).

---

## 2. Restauration d'une version antérieure

**Scénario :** Un fichier a été modifié ou corrompu et il faut revenir à une version précédente.
**RPO :** 24h | **RTO :** 15 min
**Rétention :** 30 jours de versions sur RPi2.

### Étape 1 : Lister les versions disponibles

Les versions sont stockées sur RPi2 dans `_versions/YYYY-MM-DD/`.

```bash
# Lister tous les jours de version disponibles
rclone lsd cryoss-versions:

# Exemple de sortie :
#   -1 2026-04-15 00:00:00 -1 2026-04-15
#   -1 2026-04-14 00:00:00 -1 2026-04-14
#   -1 2026-04-13 00:00:00 -1 2026-04-13
```

### Étape 2 : Trouver le fichier dans la bonne date

```bash
# Lister le contenu d'une version spécifique
rclone ls cryoss-versions:2026-04-15/

# Rechercher un fichier précis dans une version
rclone ls cryoss-versions:2026-04-15/ --include "*/nom_du_fichier"
```

### Étape 3 : Restaurer la version souhaitée

```bash
# Restaurer un fichier spécifique depuis la version du 15 avril
rclone copy cryoss-versions:2026-04-15/chemin/vers/le/fichier /etc/sauvegarde/chemin/vers/

# Vérifier l'intégrité
sha256sum /etc/sauvegarde/chemin/vers/le/fichier
```

### Étape 4 : Restaurer un répertoire complet (version antérieure)

```bash
# Restaurer tout un répertoire depuis une date précise
rclone copy cryoss-versions:2026-04-15/chemin/vers/repertoire/ /etc/sauvegarde/chemin/vers/repertoire/

# Vérification par lot
find /etc/sauvegarde/chemin/vers/repertoire/ -type f -exec sha256sum {} \;
```

> **Attention :** `rclone copy` ne supprime pas les fichiers existants. Si des fichiers ont été ajoutés après la date de version, ils resteront en place. Utiliser `rclone sync` si un retour exact à l'état antérieur est souhaité (cela supprimera les fichiers plus récents).

---

## 3. Restauration complète depuis RPi2 (sinistre RPi1)

**Scénario :** RPi1 est détruit (panne matérielle, incendie, vol). Un nouveau RPi1 doit être mis en service.
**RPO :** 24h | **RTO :** 4h

### Étape 1 : Installer le nouveau RPi1

```bash
# Flasher Raspberry Pi OS sur la carte SD du nouveau RPi1
# Connecter les disques USB (RAID1)

# Exécuter le script d'installation RPi1
sudo bash install_rpi1.sh
```

Le script crée automatiquement :
- Le RAID1 (`md0` + `md1`)
- Les répertoires `/etc/sauvegarde` et `/etc/encrypted`
- La configuration réseau
- Les nouvelles clés rclone (C1 et C3)

### Étape 2 : Importer les clés C2 depuis la sauvegarde

Les clés C2 sont nécessaires pour déchiffrer les données sur RPi2.

```bash
# Récupérer le fichier de sauvegarde des clés depuis RPi2
scp utilisateur@rpi2:/chemin/vers/keys-backup.conf /tmp/

# Ou si les clés ont été fournies sur support physique :
# Copier keys-backup.conf depuis la clé USB
```

### Étape 3 : Configurer rclone avec les clés C2

```bash
# Éditer la configuration rclone pour ajouter les remotes C2
sudo nano /root/.config/rclone/rclone.conf

# Ajouter les sections [cryoss-c2] et [cryoss-c2-crypt]
# avec les clés récupérées depuis keys-backup.conf
```

### Étape 4 : Restaurer les données depuis C2

```bash
# Restauration complète avec vérification par checksum
rclone sync cryoss-c2-crypt: /etc/sauvegarde/ --checksum --progress

# Vérifier l'intégrité globale
rclone cryptcheck /etc/sauvegarde cryoss-c2-crypt: --one-way
```

### Étape 5 : Relancer le cycle de sauvegarde

```bash
# Les nouvelles clés C1 (générées par install_rpi1.sh) sont différentes des anciennes.
# Il faut re-chiffrer toutes les données avec les nouvelles clés.

# Lancer manuellement le premier cycle de sauvegarde
sudo /opt/cryoss/backup.sh

# Vérifier que C1 et C2 sont synchronisés
rclone cryptcheck /etc/sauvegarde cryoss-c1-crypt: --one-way
rclone cryptcheck /etc/sauvegarde cryoss-c2-crypt: --one-way
```

> **Important :** Les anciennes clés C1 ne fonctionnent plus. Les données dans `/etc/encrypted` sont re-chiffrées avec les nouvelles clés C1. Si C3 est activé, les données distantes seront aussi re-chiffrées avec les nouvelles clés C3.

---

## 4. Restauration air-gap (principe des 4 yeux)

**Scénario :** Restauration depuis RPi2 nécessitant une validation à 4 yeux.
**Condition :** Toute restauration depuis RPi2 doit être effectuée en présence de deux personnes.

### Personnes requises

| Rôle | Personne |
|------|----------|
| **Technicien Analyss** | Exécute les commandes de restauration |
| **Représentant client** | Valide le périmètre et confirme la restauration |

### Procédure

1. **Documentation préalable** : Remplir le formulaire de restauration :
   - Date et heure
   - Identité du technicien Analyss
   - Identité du représentant client
   - Raison de la restauration
   - Périmètre exact (fichiers/répertoires concernés)

2. **Validation conjointe** : Les deux parties confirment le périmètre de restauration.

3. **Exécution** : Le technicien Analyss exécute les commandes de restauration (cf. sections précédentes).

4. **Vérification d'intégrité** :

```bash
# Générer les hashes des fichiers restaurés
find /etc/sauvegarde/chemin/restaure/ -type f -exec sha256sum {} \; > /tmp/restore_hashes.txt

# Vérifier visuellement avec le représentant client
cat /tmp/restore_hashes.txt
```

5. **Signature du PV** : Les deux parties signent le procès-verbal de restauration.

### Modèle de procès-verbal

```
PROCÈS-VERBAL DE RESTAURATION
==============================
Date : ____________________
Heure début : _____________
Heure fin : _______________

Technicien Analyss : ____________________
Représentant client : ___________________

Raison : _________________________________
Périmètre : ______________________________
Source : C1 / C2 / C3 / Versions (entourer)
Date de la version restaurée : ____________

Fichiers restaurés : ___ fichiers, ___ Go
Vérification SHA-256 : OK / NOK

Signature technicien : ___________________
Signature client : _______________________
```

---

## 5. Restauration après sinistre total (les deux RPi détruits)

**Scénario :** RPi1 et RPi2 sont tous deux détruits (incendie, catastrophe naturelle). Seule la copie C3 distante est disponible.
**RPO :** 8h (dernière synchro C3) | **RTO :** 8h+
**Prérequis :** C3 doit avoir été activé et les clés C3 doivent être accessibles.

### Étape 1 : Récupérer les clés C3

Les clés C3 ont été fournies au client dans une enveloppe scellée lors de l'installation, ou sont disponibles dans le système de gestion des clés d'Analyss.

### Étape 2 : Installer le nouveau matériel

```bash
# Nouveau RPi1 + disques
sudo bash install_rpi1.sh

# Nouveau RPi2 + disques (si nécessaire)
sudo bash install_rpi2.sh
```

### Étape 3 : Configurer rclone avec les clés C3

```bash
# Éditer la configuration rclone
sudo nano /root/.config/rclone/rclone.conf

# Ajouter les sections [cryoss-c3] et [cryoss-c3-crypt]
# avec les clés récupérées depuis l'enveloppe scellée
```

### Étape 4 : Restaurer depuis C3

```bash
# Restauration complète depuis le serveur SFTP distant
rclone sync cryoss-c3-crypt: /etc/sauvegarde/ --checksum --progress

# Vérifier l'intégrité
rclone cryptcheck /etc/sauvegarde cryoss-c3-crypt: --one-way
```

### Étape 5 : Rétablir le cycle complet

```bash
# Relancer les sauvegardes pour re-chiffrer avec les nouvelles clés C1/C2
sudo /opt/cryoss/backup.sh

# Vérifier tous les chemins
rclone cryptcheck /etc/sauvegarde cryoss-c1-crypt: --one-way
rclone cryptcheck /etc/sauvegarde cryoss-c2-crypt: --one-way
rclone cryptcheck /etc/sauvegarde cryoss-c3-crypt: --one-way
```

> **Attention :** Cette procédure est la plus longue car elle dépend de la bande passante réseau pour télécharger les données depuis le serveur distant. Prévoir un temps de restauration proportionnel au volume de données.

---

## Récapitulatif des commandes clés

| Action | Commande |
|--------|----------|
| Lister un fichier dans C1 | `rclone ls cryoss-c1-crypt: --include "*/fichier"` |
| Restaurer depuis C1 | `rclone copy cryoss-c1-crypt:chemin/fichier /etc/sauvegarde/chemin/` |
| Restaurer depuis C2 | `rclone copy cryoss-c2-crypt:chemin/fichier /etc/sauvegarde/chemin/` |
| Lister les versions | `rclone lsd cryoss-versions:` |
| Restaurer une version | `rclone copy cryoss-versions:YYYY-MM-DD/chemin/fichier /etc/sauvegarde/chemin/` |
| Restauration complète C2 | `rclone sync cryoss-c2-crypt: /etc/sauvegarde/ --checksum` |
| Restauration complète C3 | `rclone sync cryoss-c3-crypt: /etc/sauvegarde/ --checksum` |
| Vérification intégrité | `rclone cryptcheck /etc/sauvegarde cryoss-cX-crypt: --one-way` |
| Hash d'un fichier | `sha256sum /etc/sauvegarde/chemin/vers/fichier` |
