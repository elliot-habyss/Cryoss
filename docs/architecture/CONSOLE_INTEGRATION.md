# Integration avec la Console Analyss

> Document decrivant les mecanismes d'integration entre les noeuds Cryoss deployes chez les clients et la console de supervision Analyss.

---

## Table des matieres

1. [Modele phone-home](#modele-phone-home)
2. [Flux d'enregistrement](#flux-denregistrement)
3. [Flux de heartbeat](#flux-de-heartbeat)
4. [Schema complet du payload heartbeat](#schema-complet-du-payload-heartbeat)
5. [Donnees RPi2 dans le heartbeat](#donnees-rpi2-dans-le-heartbeat)
6. [Detection des alertes](#detection-des-alertes)
7. [Resolution automatique des alertes](#resolution-automatique-des-alertes)
8. [Mode degrade](#mode-degrade)
9. [Securite](#securite)
10. [Flux unidirectionnel](#flux-unidirectionnel)

---

## Modele phone-home

L'integration Cryoss-Analyss repose sur un modele **push** (phone-home) :

```
+------------------+                    +------------------+
|                  |   HTTPS (push)     |                  |
|     RPi1         | -----------------> |  Console Analyss |
|  (chez client)   |   Heartbeat 5min   |  (cloud)         |
|                  |                    |                  |
+------------------+                    +------------------+
        |                                       |
        | SSH (collecte)                        | Aucun flux
        v                                       | vers Cryoss
+------------------+                            |
|     RPi2         |                            X
|  (air-gap)       |
+------------------+
```

**Principes fondamentaux** :

- C'est **toujours le RPi1 qui initie** la communication vers Analyss
- La console Analyss **ne se connecte jamais** aux noeuds Cryoss
- Analyss ne possede **aucun acces direct** aux donnees client
- Si la console est indisponible, les sauvegardes continuent normalement
- Le RPi2 ne communique jamais avec Analyss (il n'a pas Internet)

Ce modele garantit que la compromission de la console Analyss ne peut pas affecter les noeuds Cryoss ni les donnees client.

---

## Flux d'enregistrement

L'enregistrement est la premiere etape lors du deploiement d'un nouveau noeud Cryoss. Il s'effectue une seule fois.

### Sequence

```
RPi1                                    Console Analyss
  |                                           |
  |  POST /api/sync/cryoss/register           |
  |  {                                        |
  |    "serial": "CRYOSS-2026-00042",         |
  |    "hostname": "cryoss-dupont",           |
  |    "client_id": "CL-0042",               |
  |    "version": "1.4.2",                    |
  |    "rpi1_mac": "dc:a6:32:xx:xx:xx",      |
  |    "rpi2_mac": "dc:a6:32:yy:yy:yy"       |
  |  }                                        |
  | ----------------------------------------> |
  |                                           |  Validation
  |                                           |  Creation du noeud
  |                                           |  Generation API key
  |  HTTP 201                                 |
  |  {                                        |
  |    "api_key": "ck_live_...",              |
  |    "node_id": "nd-xxxxxxxx",             |
  |    "heartbeat_interval": 300              |
  |  }                                        |
  | <---------------------------------------- |
  |                                           |
  |  Stockage de l'API key dans               |
  |  /etc/cryoss/analyss.conf                 |
```

### Details de l'enregistrement

| Champ requete | Description |
|---|---|
| `serial` | Numero de serie unique du boitier Cryoss |
| `hostname` | Nom d'hote du RPi1 |
| `client_id` | Identifiant du client dans le SI Analyss |
| `version` | Version du logiciel Cryoss |
| `rpi1_mac` | Adresse MAC du RPi1 (interface LAN) |
| `rpi2_mac` | Adresse MAC du RPi2 |

| Champ reponse | Description |
|---|---|
| `api_key` | Cle API pour l'authentification des heartbeat |
| `node_id` | Identifiant unique du noeud dans Analyss |
| `heartbeat_interval` | Intervalle de heartbeat en secondes (defaut : 300) |

L'API key est stockee dans `/etc/cryoss/analyss.conf` avec des permissions restrictives (`chmod 600`, proprietaire `root`).

---

## Flux de heartbeat

Le heartbeat est envoye toutes les **5 minutes** (configurable via `heartbeat_interval`).

### Sequence

```
RPi1                                    Console Analyss
  |                                           |
  |  [Collecte metriques locales]             |
  |  [SSH vers RPi2 : collecte metriques]     |
  |                                           |
  |  POST /api/sync/cryoss/heartbeat          |
  |  Authorization: Bearer ck_live_...        |
  |  Content-Type: application/json           |
  |  {                                        |
  |    ... payload complet ...                |
  |  }                                        |
  | ----------------------------------------> |
  |                                           |  Traitement
  |                                           |  Mise a jour dashboard
  |                                           |  Evaluation des alertes
  |  HTTP 200                                 |
  |  {                                        |
  |    "status": "ok",                        |
  |    "next_interval": 300                   |
  |  }                                        |
  | <---------------------------------------- |
```

### Etapes de collecte avant envoi

1. Le service `cryoss-heartbeat` interroge l'API locale FastAPI (`127.0.0.1:8420`) pour obtenir les metriques du RPi1
2. Le RPi1 se connecte en SSH au RPi2 (utilisateur `habyss`) pour collecter les metriques du RPi2
3. Les deux jeux de metriques sont assembles dans un payload unique
4. Le payload est envoye en HTTPS vers la console Analyss

---

## Schema complet du payload heartbeat

```json
{
  "node_id": "nd-xxxxxxxx",
  "serial": "CRYOSS-2026-00042",
  "timestamp": "2026-04-16T14:30:00Z",
  "version": "1.4.2",
  "uptime_seconds": 864000,

  "rpi1": {
    "hostname": "cryoss-dupont",
    "ip_lan": "192.168.1.50",
    "ip_interco": "10.42.0.1",

    "system": {
      "cpu_percent": 12.5,
      "memory_percent": 45.2,
      "memory_total_mb": 8192,
      "swap_percent": 0.0,
      "temperature_celsius": 52.3,
      "load_average": [0.45, 0.38, 0.32]
    },

    "raid": {
      "md0": {
        "status": "active",
        "level": "raid1",
        "devices": ["sda", "sdb"],
        "state": "clean",
        "degraded": false,
        "sync_percent": null
      },
      "md1": {
        "status": "active",
        "level": "raid1",
        "devices": ["sdc", "sdd"],
        "state": "clean",
        "degraded": false,
        "sync_percent": null
      }
    },

    "disks": {
      "sda": {
        "model": "WDC WD10SPZX",
        "size_gb": 1000,
        "used_percent": 62.3,
        "temperature_celsius": 38,
        "smart_status": "PASSED",
        "smart_errors": 0
      },
      "sdb": {
        "model": "WDC WD10SPZX",
        "size_gb": 1000,
        "used_percent": 62.3,
        "temperature_celsius": 37,
        "smart_status": "PASSED",
        "smart_errors": 0
      },
      "sdc": {
        "model": "Seagate ST1000LM048",
        "size_gb": 1000,
        "used_percent": 48.1,
        "temperature_celsius": 36,
        "smart_status": "PASSED",
        "smart_errors": 0
      },
      "sdd": {
        "model": "Seagate ST1000LM048",
        "size_gb": 1000,
        "used_percent": 48.1,
        "temperature_celsius": 35,
        "smart_status": "PASSED",
        "smart_errors": 0
      }
    },

    "services": {
      "smbd": "active",
      "cryoss-backup": "active",
      "cryoss-heartbeat": "active",
      "cryoss-watchdog": "active",
      "cryoss-sentinel": "active",
      "cryoss-api": "active",
      "mdadm": "active"
    },

    "backups": {
      "c1": {
        "last_success": "2026-04-16T14:00:00Z",
        "last_duration_seconds": 342,
        "files_transferred": 127,
        "bytes_transferred": 524288000,
        "status": "success",
        "next_scheduled": "2026-04-16T15:00:00Z"
      },
      "c2": {
        "last_success": "2026-04-16T14:06:00Z",
        "last_duration_seconds": 198,
        "files_transferred": 127,
        "bytes_transferred": 524288000,
        "status": "success",
        "next_scheduled": null
      },
      "c3": {
        "last_success": "2026-04-16T02:15:00Z",
        "last_duration_seconds": 1842,
        "files_transferred": 3421,
        "bytes_transferred": 15032385536,
        "status": "success",
        "next_scheduled": "2026-04-17T02:00:00Z",
        "enabled": true
      }
    },

    "sentinel": {
      "status": "intact",
      "last_check": "2026-04-16T14:29:00Z",
      "file_path": "/etc/sauvegarde/.cryoss-sentinel"
    },

    "storage": {
      "sauvegarde_total_gb": 1000,
      "sauvegarde_used_gb": 623,
      "sauvegarde_free_gb": 377,
      "encrypted_total_gb": 1000,
      "encrypted_used_gb": 481,
      "encrypted_free_gb": 519
    }
  },

  "rpi2": {
    "reachable": true,
    "hostname": "cryoss-dupont-rpi2",
    "ip_interco": "10.42.0.2",
    "last_ssh_check": "2026-04-16T14:29:30Z",

    "system": {
      "cpu_percent": 3.1,
      "memory_percent": 22.4,
      "memory_total_mb": 4096,
      "swap_percent": 0.0,
      "temperature_celsius": 45.1,
      "load_average": [0.05, 0.08, 0.06]
    },

    "raid": {
      "md0": {
        "status": "active",
        "level": "raid1",
        "devices": ["sda", "sdb"],
        "state": "clean",
        "degraded": false,
        "sync_percent": null
      }
    },

    "disks": {
      "sda": {
        "model": "WDC WD10SPZX",
        "size_gb": 1000,
        "used_percent": 48.5,
        "temperature_celsius": 34,
        "smart_status": "PASSED",
        "smart_errors": 0
      },
      "sdb": {
        "model": "WDC WD10SPZX",
        "size_gb": 1000,
        "used_percent": 48.5,
        "temperature_celsius": 33,
        "smart_status": "PASSED",
        "smart_errors": 0
      }
    },

    "services": {
      "sshd": "active",
      "mdadm": "active",
      "ufw": "active",
      "fail2ban": "active"
    },

    "storage": {
      "backup_total_gb": 1000,
      "backup_used_gb": 485,
      "backup_free_gb": 515,
      "versions_count": 90,
      "oldest_version": "2026-01-16"
    }
  },

  "alerts": [
    {
      "type": "raid_degraded",
      "severity": "critical",
      "node": "rpi1",
      "device": "md0",
      "message": "RAID md0 degrade : sdb absent",
      "since": "2026-04-16T10:15:00Z",
      "resolved": false
    }
  ]
}
```

---

## Donnees RPi2 dans le heartbeat

Le RPi2 n'ayant aucun acces Internet, ses donnees sont collectees par le RPi1 et incluses dans le heartbeat du RPi1.

### Processus de collecte

```
RPi1                                RPi2
  |                                   |
  |  ssh habyss@10.42.0.2            |
  |  "cryoss-collect-metrics"        |
  | --------------------------------> |
  |                                   |  Execution du script
  |                                   |  de collecte local
  |  JSON metriques RPi2              |
  | <-------------------------------- |
  |                                   |
  |  Integration dans le payload      |
  |  heartbeat (champ "rpi2")         |
```

Le script `cryoss-collect-metrics` est installe sur le RPi2 et retourne un JSON contenant toutes les metriques necessaires. Il est execute via SSH par l'utilisateur `habyss`.

### Cas ou le RPi2 est injoignable

Si le RPi1 ne parvient pas a se connecter au RPi2 en SSH :

```json
{
  "rpi2": {
    "reachable": false,
    "last_ssh_check": "2026-04-16T14:29:30Z",
    "last_successful_check": "2026-04-16T14:14:30Z",
    "error": "ssh: connect to host 10.42.0.2 port 22: Connection timed out"
  }
}
```

Cela declenche une alerte de type `rpi2_unreachable` sur la console Analyss.

---

## Detection des alertes

La console Analyss evalue huit conditions d'alerte a la reception de chaque heartbeat.

### Conditions d'alerte

| # | Type | Severite | Condition de declenchement | Description |
|---|---|---|---|---|
| 1 | `raid_degraded` | **Critique** | Un RAID (`md0`, `md1`) est en etat `degraded` | Un disque est tombe dans une grappe RAID |
| 2 | `disk_failing` | **Critique** | SMART status != "PASSED" ou `smart_errors` > seuil ou temperature > 60C | Un disque presente des signes de defaillance |
| 3 | `service_down` | **Haute** | Un service dans `services` a un etat != "active" | Un service critique est arrete |
| 4 | `high_load` | **Moyenne** | `cpu_percent` > 90% ou `memory_percent` > 95% pendant 3 heartbeat consecutifs | Charge systeme anormalement elevee |
| 5 | `backup_failed` | **Haute** | Dernier backup d'un chemin en `status: "error"` ou `last_success` depasse le delai prevu | Une sauvegarde n'a pas abouti |
| 6 | `rpi2_unreachable` | **Critique** | `rpi2.reachable` = `false` | Le RPi1 ne peut plus joindre le RPi2 |
| 7 | `sentinel_triggered` | **Critique** | `sentinel.status` != "intact" | Le fichier honeypot a ete modifie -- suspicion de ransomware |
| 8 | `node_offline` | **Critique** | Aucun heartbeat recu depuis > 15 minutes | Le noeud Cryoss ne repond plus |

### Logique d'evaluation

```
Pour chaque heartbeat recu :
    Pour chaque condition d'alerte :
        Si condition declenchee ET pas d'alerte active existante :
            -> Creer une nouvelle alerte
            -> Notifier l'administrateur (email, webhook, dashboard)
        Si condition declenchee ET alerte active existante :
            -> Mettre a jour le timestamp de derniere occurrence
        Si condition non declenchee ET alerte active existante :
            -> Marquer l'alerte comme resolue (sauf sentinel_triggered)
```

---

## Resolution automatique des alertes

Les alertes sont automatiquement resolues lorsque le heartbeat suivant montre un retour a la normale.

### Alertes a resolution automatique

| Type d'alerte | Condition de resolution |
|---|---|
| `raid_degraded` | RAID repasse en etat `clean` (apres reconstruction) |
| `disk_failing` | SMART repasse en "PASSED" et temperature normalisee |
| `service_down` | Service repasse en "active" |
| `high_load` | Charge redescend sous les seuils pendant 3 heartbeat consecutifs |
| `backup_failed` | Prochaine sauvegarde reussie |
| `rpi2_unreachable` | `rpi2.reachable` repasse a `true` |
| `node_offline` | Reception d'un nouveau heartbeat |

### Alerte a resolution manuelle

| Type d'alerte | Raison |
|---|---|
| `sentinel_triggered` | La modification du fichier honeypot indique une activite potentiellement malveillante. L'alerte persiste jusqu'a ce qu'un administrateur effectue une investigation et la resolve manuellement depuis la console Analyss. |

---

## Mode degrade

### Console Analyss indisponible

Si la console Analyss est temporairement indisponible (maintenance, panne reseau), le RPi1 reagit de maniere gracieuse :

```
Heartbeat echoue (timeout ou HTTP 5xx)
        |
        v
Tentative de reenvoi apres 30 secondes
        |
        v
Echec ? --> Nouvelle tentative apres 60 secondes
        |
        v
Echec ? --> Nouvelle tentative apres 120 secondes
        |
        v
Echec ? --> Passage en mode degrade
              |
              +-- Les heartbeat sont mis en file d'attente locale
              +-- Les sauvegardes continuent normalement
              +-- La surveillance locale (watchdog) continue
              +-- Les alertes sont journalisees localement
              +-- Tentative de reconnexion toutes les 5 minutes
```

### Comportement en mode degrade

| Composant | Comportement |
|---|---|
| **Sauvegardes (C1, C2, C3)** | Fonctionnement normal -- aucune dependance a Analyss |
| **Surveillance locale** | Le watchdog continue son cycle toutes les 15 minutes |
| **Heartbeat** | File d'attente locale (max 1000 heartbeats = ~3.5 jours) |
| **Alertes** | Journalisees dans `/var/log/cryoss/alerts.log` |
| **API FastAPI** | Fonctionnement normal |

### Reconnexion

Lorsque la console Analyss redevient accessible :

1. Le RPi1 envoie les heartbeat en file d'attente par ordre chronologique
2. La console traite les heartbeat retardes et reconstruit l'historique
3. Les alertes accumulees sont evaluees et declenchees retroactivement si necessaire
4. Le mode normal reprend automatiquement

**Point crucial** : la disponibilite de la console Analyss n'affecte **jamais** le fonctionnement des sauvegardes. Le systeme Cryoss est autonome dans sa mission principale de sauvegarde.

---

## Securite

### Cle API

| Propriete | Detail |
|---|---|
| Format | `ck_live_` + 48 caracteres alphanumeriques aleatoires |
| Generation | Cote serveur Analyss lors de l'enregistrement |
| Stockage local | `/etc/cryoss/analyss.conf` (chmod 600, root:root) |
| Stockage serveur | Hash SHA-256 uniquement -- la cle en clair n'est jamais stockee cote Analyss |
| Transmission | Header `Authorization: Bearer ck_live_...` sur HTTPS uniquement |
| Rotation | Possible via l'API d'administration Analyss |

### HTTPS

- Toutes les communications RPi1 → Analyss utilisent **HTTPS (TLS 1.2+)**
- Verification du certificat serveur activee (pas de `--insecure`)
- Certificat Let's Encrypt ou equivalent sur la console Analyss
- Le RPi1 embarque le bundle CA systeme pour la validation

### Rate limiting

La console Analyss applique un rate limiting pour se proteger contre les abus :

| Endpoint | Limite |
|---|---|
| `/api/sync/cryoss/register` | 5 requetes par heure par IP |
| `/api/sync/cryoss/heartbeat` | 20 requetes par minute par API key |

### Authentification du heartbeat

```
RPi1 envoie :
    Authorization: Bearer ck_live_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789abcdefgh

Console Analyss :
    1. Extrait le token du header
    2. Calcule SHA-256(token)
    3. Recherche le hash dans la base de donnees
    4. Si trouve --> identifie le noeud, traite le heartbeat
    5. Si non trouve --> HTTP 401 Unauthorized
```

---

## Flux unidirectionnel

### Principe de conception

Le flux de donnees est **strictement unidirectionnel** : du RPi1 vers la console Analyss. Il n'existe aucun flux en sens inverse.

```
RPi1  ------>  Console Analyss     (heartbeat, metriques, alertes)
RPi1  <------  Console Analyss     INTERDIT (aucun flux retour)
```

### Ce que la console Analyss ne peut PAS faire

| Action interdite | Raison |
|---|---|
| Se connecter en SSH au RPi1 | Aucun port expose vers Analyss, pas de cle SSH |
| Declencher une sauvegarde | Pas de canal de commande inverse |
| Lire les fichiers client | Aucun acces aux donnees ni aux cles de chiffrement |
| Modifier la configuration du RPi1 | Pas de mecanisme de push de configuration |
| Acceder au RPi2 | RPi2 air-gappe, inaccessible depuis Internet |
| Arreter ou redemarrer les services | Aucun acces d'administration |

### Justification

- **Securite** : si la console Analyss est compromise, l'attaquant ne peut pas atteindre les noeuds Cryoss ni les donnees client
- **Confidentialite** : les donnees client ne transitent jamais par la console -- seules les metriques operationnelles sont envoyees
- **Resilience** : les noeuds Cryoss fonctionnent de maniere autonome, independamment de la disponibilite de la console
- **Conformite** : le modele phone-home garantit qu'aucun tiers (y compris Analyss) ne peut acceder aux donnees de sauvegarde

### Schema recapitulatif des flux

```
+-------------------+         +-------------------+         +-------------------+
|                   |  SFTP   |                   |  HTTPS  |                   |
|      RPi2         | <------ |      RPi1         | ------> | Console Analyss   |
|   (air-gap)       |  (C2)   |   (LAN client)    | (beat)  |   (cloud)         |
|                   |         |                   |         |                   |
| - Recoit fichiers |  SSH    | - Samba share     |         | - Dashboard       |
| - Stocke versions | <------ | - Chiffrement     |         | - Alertes         |
| - Aucune sortie   | (diag)  | - 3 chemins (C*)  |         | - Historique      |
|                   |         | - FastAPI :8420   |         | - Aucun acces     |
|                   |         | - Watchdog        |         |   aux donnees     |
+-------------------+         +-------------------+         +-------------------+
                                      |
                                      | SFTP (C3, optionnel)
                                      v
                              +-------------------+
                              | Serveur distant   |
                              | (datacenter)      |
                              +-------------------+
```

---

*Document maintenu par l'equipe Analyss. Derniere mise a jour : avril 2026.*
