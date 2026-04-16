# Politique de sauvegarde Cryoss

> **Version :** 1.0
> **Date :** 2026-04-16
> **Auteur :** Analyss
> **Classification :** Document opérationnel interne

---

## 1. Conformité à la règle 3-2-1-1-0

La solution Cryoss applique la règle **3-2-1-1-0** pour garantir la résilience des données :

| Critère | Mise en oeuvre |
|---------|---------------|
| **3 copies** | `/etc/sauvegarde` (clair, source), `/etc/encrypted` via C1 (chiffré local RPi1), RPi2 via C2 (chiffré air-gap), SFTP distant via C3 (chiffré distant) |
| **2 supports différents** | RAID1 sur RPi1 (`md0` + `md1`), RAID1 sur RPi2 (`md0`) |
| **1 copie hors-site** | C3 via SFTP distant (optionnel) ou RPi2 si physiquement séparé du site principal |
| **1 copie air-gap** | RPi2 : isolé du réseau, accessible uniquement via lien interco dédié |
| **0 erreur** | `cryptcheck` après chaque synchronisation, test de restauration SHA-256, health check quotidien |

---

## 2. Objectifs de récupération

| Indicateur | Valeur | Détail |
|------------|--------|--------|
| **RPO** (Recovery Point Objective) | **24h** | Sauvegarde quotidienne à 02:00 (C1 + C2). Réduit à **8h** si C3 activé (3x/jour). |
| **RTO** (Recovery Time Objective) | **1h** | Restauration locale depuis C1. **2h** depuis RPi2 (C2). **4h+** depuis C3 (distant). |

---

## 3. Planification des sauvegardes

| Chemin | Cible | Fréquence | Heure | Type |
|--------|-------|-----------|-------|------|
| **C1** | `/etc/encrypted` (RPi1 local) | Quotidien | 02:00 | Miroir chiffré |
| **C2** | RPi2 via interco | Quotidien | 02:00 | Miroir chiffré + versioning |
| **C3** | Serveur SFTP distant | 3x/jour (si activé) | 08:00, 14:00, 20:00 | Miroir chiffré |

Les sauvegardes C1 et C2 sont déclenchées simultanément par le script principal. C3 est déclenché indépendamment selon sa propre planification cron.

---

## 4. Politique de rétention

| Chemin | Mode | Rétention |
|--------|------|-----------|
| **C1** (local chiffré) | Miroir (`rclone sync`) | État courant uniquement (pas de versioning) |
| **C2** (RPi2) | Miroir + versioning (`rclone sync --backup-dir`) | État courant + **30 jours** de versions dans `_versions/YYYY-MM-DD/` |
| **C3** (distant) | Miroir (`rclone sync`) | Dépend de la capacité du stockage distant |

Les anciennes versions sur RPi2 sont purgées automatiquement après 30 jours par le script de nettoyage.

---

## 5. Périmètre de sauvegarde

### Ce qui est sauvegardé

Tout le contenu du répertoire `/etc/sauvegarde`, qui correspond au partage Samba accessible par le client. Cela inclut :

- Documents bureautiques
- Fichiers métier
- Bases de données exportées
- Tout fichier déposé par le client dans le partage réseau

### Ce qui n'est PAS sauvegardé

| Élément | Raison |
|---------|--------|
| Système d'exploitation (Raspberry Pi OS) | Réinstallable via les scripts d'installation |
| Scripts Cryoss (`/opt/cryoss/`) | Récupérables depuis le dépôt ou le package d'installation |
| Fichiers temporaires | Non critiques, recréés automatiquement |
| Logs système | Rotation automatique, non essentiels à la reprise |

---

## 6. Chiffrement

Toutes les sauvegardes sont chiffrées avec **rclone crypt** :

| Paramètre | Valeur |
|-----------|--------|
| **Algorithme** | XSalsa20-Poly1305 |
| **Chiffrement des noms de fichiers** | Activé (standard) |
| **Clés** | Indépendantes par chemin (C1, C2, C3) |

Chaque chemin de sauvegarde possède sa propre paire de clés (`password` + `password2`). La compromission d'un chemin ne compromet pas les autres.

### Stockage des clés

- Les clés sont stockées dans la configuration rclone (`/root/.config/rclone/rclone.conf`)
- Une sauvegarde des clés est conservée dans `keys-backup.conf` sur RPi2
- Les clés C3 sont également fournies au client dans une enveloppe scellée (si C3 activé)

---

## 7. Vérification et intégrité

Après chaque cycle de sauvegarde, les vérifications suivantes sont effectuées automatiquement :

### 7.1 Vérification cryptographique (`cryptcheck`)

```bash
rclone cryptcheck /etc/sauvegarde cryoss-c1-crypt: --one-way
rclone cryptcheck /etc/sauvegarde cryoss-c2-crypt: --one-way
```

Compare les fichiers source (en clair) avec leur version chiffrée pour s'assurer que le chiffrement est cohérent et que les fichiers sont intacts.

### 7.2 Test de restauration SHA-256

```bash
# Restauration d'un fichier témoin depuis C1
rclone copy cryoss-c1-crypt:fichier_temoin.txt /tmp/restore_test/
# Comparaison du hash
sha256sum /etc/sauvegarde/fichier_temoin.txt /tmp/restore_test/fichier_temoin.txt
```

Ce test vérifie que la chaîne complète (chiffrement, stockage, déchiffrement) fonctionne correctement.

### 7.3 Health check quotidien

- Vérification de l'état RAID (`mdadm --detail`)
- Vérification de l'espace disque
- Vérification de la connectivité RPi2
- Vérification de la connectivité C3 (si activé)

---

## 8. Manifeste de sauvegarde

Un fichier JSON est généré après chaque cycle de sauvegarde avec les informations suivantes :

```json
{
  "timestamp": "2026-04-16T02:15:32+02:00",
  "paths": {
    "c1": {
      "status": "success",
      "files_count": 1547,
      "total_size_bytes": 8573952000,
      "duration_seconds": 142,
      "cryptcheck": "pass"
    },
    "c2": {
      "status": "success",
      "files_count": 1547,
      "total_size_bytes": 8573952000,
      "duration_seconds": 310,
      "cryptcheck": "pass",
      "versions_purged": 12
    },
    "c3": {
      "status": "disabled",
      "files_count": 0
    }
  },
  "restore_test": {
    "file": "fichier_temoin.txt",
    "sha256_match": true
  },
  "health": {
    "raid_rpi1_md0": "active",
    "raid_rpi1_md1": "active",
    "raid_rpi2_md0": "active",
    "disk_usage_rpi1": "45%",
    "disk_usage_rpi2": "32%"
  }
}
```

Le manifeste est stocké dans `/var/log/cryoss/` et conservé 90 jours.

---

## 9. Responsabilités

| Rôle | Responsabilité |
|------|---------------|
| **Analyss** | Installation, configuration, maintenance, supervision, intervention en cas d'alerte |
| **Client** | Dépôt des fichiers dans le partage Samba, signalement des anomalies, participation aux restaurations (principe des 4 yeux) |

---

## 10. Révision

Cette politique est révisée :

- À chaque modification de l'infrastructure
- Au minimum une fois par an
- Après tout incident de sécurité
