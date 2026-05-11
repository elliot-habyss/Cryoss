# Prompt pour Claude Code Analyss — Mise à jour complète

Copier-coller ce prompt entier dans Claude Code dans le projet Analyss.

---

## Contexte

Les agents Cryoss envoient maintenant un heartbeat enrichi et acceptent des
commandes bidirectionnelles. Instance de dev disponible pour tester :
- Serial : `DS-00000001`
- RPi1 : `http://192.168.1.104`
- Analyss dev : `http://192.168.1.220:8001`

Ce doc décrit tout ce qui doit être implémenté côté Analyss :
1. Parsing du nouveau payload heartbeat
2. Alertes enrichies (ransomware, canal backup en erreur, etc.)
3. **Commandes bidirectionnelles** (Analyss → Cryoss via réponse heartbeat)
4. Dashboard avec les nouveaux champs

---

## 1. Nouveau schéma JSON du heartbeat

Reçu sur `POST /api/sync/cryoss/heartbeat` toutes les 5 min :

```json
{
  "serial": "DS-00000001",
  "role": "rpi1",
  "hostname": "cryoss1",
  "timestamp": "2026-04-17T10:39:51",
  "version": "1.0.0",
  "uptime": "up 18 hours, 54 minutes",
  "cpu_temp_c": 58.4,
  "load_1m": 0.0,
  "ram_used_mb": 541,
  "ram_total_mb": 8062,
  "raid": {
    "md0": {"state": "active", "healthy": true},
    "md1": {"state": "active", "healthy": true}
  },
  "disks": {
    "/etc/encrypted": {"used_pct": 3, "used_gb": 27, "total_gb": 938}
  },
  "services": {
    "cryoss-backup.timer": "active",
    "cryoss-api": "active",
    "smbd": "active",
    "ssh": "active",
    "fail2ban": "active"
  },
  "rclone_remotes": ["cryoss-c1-local", "cryoss-c1-crypt", "cryoss-c2-rpi2", "cryoss-c2-crypt"],

  "backup": {
    "last_run": "2026-04-17T09:37:43+02:00",
    "last_status": "success",         // "success" | "error" | "unknown"
    "archive_count": 179,
    "c1_status": "ok",                 // "ok" | "error"
    "c2_status": "ok",
    "c3_status": "ok",
    "restore_test": "ok"               // "ok" | "echec-hash" | "echec-rclone" | "non teste"
  },

  "rpi2": {
    "reachable": true,                 // ping RPi2 depuis RPi1
    "last_ping_ms": 1.42,
    "ssh_error": false,                // true si SSH RPi2 refuse
    "hostname": "cryoss2",
    "uptime": "up 12 minutes",
    "cpu_temp_c": 52.9,
    "load_1m": 0.0,
    "ram_used_mb": 321,
    "ram_total_mb": 8058,
    "raid": {"md0": {"state": "active", "healthy": true}},
    "disks": {"/etc/encrypted": {"used_pct": 3, "used_gb": 27, "total_gb": 938}},
    "services": {"ssh": "active", "fail2ban": "active", "cryoss-api": "active"},
    "reception": {
      "file_count": 498,               // 0 si aucun fichier
      "last_received_age_h": 16,       // int | null (null = jamais reçu)
      "last_received_ts": 1776355157   // int unix ts | null
    }
  },

  "compromised": {
    "active": false,                   // bool — honeypot déclenché ?
    "detected_at": "2026-04-17T10:13:10+02:00",
    "event": "MODIFY",
    "sentinel": "/etc/sauvegarde/__CRYOSS_SENTINEL__"
  }
}
```

---

## 2. Règles d'alertes dans `cryoss_sync.py`

### A. Réplication silencieuse (remplace l'ancienne "493 447h")

```python
rpi2 = heartbeat_data.get("rpi2", {})
reception = rpi2.get("reception", {})
age_h = reception.get("last_received_age_h")
file_count = reception.get("file_count", 0)

if age_h is None or file_count == 0:
    # Pas de donnée -> PAS une alerte (installation neuve)
    resolve_alert(instance_id, "replication_silent")
elif age_h > 50:
    create_or_update_alert(instance_id, "replication_silent",
        severity="critical",
        message=f"Réplication RPi2 silencieuse depuis {age_h}h (seuil critique: 50h)")
elif age_h > 26:
    create_or_update_alert(instance_id, "replication_silent",
        severity="warning",
        message=f"Réplication RPi2 en retard ({age_h}h, seuil: 26h)")
else:
    resolve_alert(instance_id, "replication_silent")
```

### B. Compromission honeypot

```python
compromised = heartbeat_data.get("compromised", {})
if compromised.get("active"):
    create_or_update_alert(instance_id, "ransomware_detected",
        severity="critical",
        message=f"HONEYPOT DÉCLENCHÉ: {compromised.get('event')} sur {compromised.get('sentinel')}",
        detected_at=compromised.get("detected_at"))
    instance.status = "compromised"
else:
    resolve_alert(instance_id, "ransomware_detected")
```

### C. Backup détaillé par canal

```python
backup = heartbeat_data.get("backup", {})

if backup.get("last_status") == "error":
    create_or_update_alert(instance_id, "backup_failed", severity="critical",
        message=f"Dernière sauvegarde échouée ({backup.get('last_run')})")
else:
    resolve_alert(instance_id, "backup_failed")

# Alertes par canal
for canal in ("c1", "c2", "c3"):
    status = backup.get(f"{canal}_status")
    alert_type = f"backup_{canal}_error"
    if status == "error":
        sev = "critical" if canal == "c1" else "warning"
        create_or_update_alert(instance_id, alert_type, severity=sev,
            message=f"Canal {canal.upper()} en erreur")
    else:
        resolve_alert(instance_id, alert_type)

# Restore test
rt = backup.get("restore_test")
if rt in ("echec-hash", "echec-rclone"):
    create_or_update_alert(instance_id, "restore_test_failed", severity="warning",
        message=f"Test de restauration: {rt}")
else:
    resolve_alert(instance_id, "restore_test_failed")
```

### D. RPi2 injoignable / SSH down

```python
if not rpi2.get("reachable"):
    create_or_update_alert(instance_id, "rpi2_unreachable", severity="critical",
        message="RPi2 ne répond plus au ping")
elif rpi2.get("ssh_error"):
    create_or_update_alert(instance_id, "rpi2_ssh_down", severity="warning",
        message="RPi2 joignable mais SSH refuse la connexion")
else:
    resolve_alert(instance_id, "rpi2_unreachable")
    resolve_alert(instance_id, "rpi2_ssh_down")

# RAID dégradé
for rpi_key in ("", "rpi2"):
    source = heartbeat_data if rpi_key == "" else heartbeat_data.get("rpi2", {})
    for md, info in (source.get("raid") or {}).items():
        if not info.get("healthy", True):
            create_or_update_alert(instance_id, f"raid_degraded_{rpi_key or 'rpi1'}_{md}",
                severity="critical",
                message=f"RAID {md} dégradé sur {'RPi2' if rpi_key else 'RPi1'}")
```

### E. Disque plein

```python
for rpi_key, disks in (("rpi1", heartbeat_data.get("disks", {})),
                       ("rpi2", (heartbeat_data.get("rpi2", {}) or {}).get("disks", {}))):
    for mount, info in (disks or {}).items():
        pct = info.get("used_pct", 0)
        alert_type = f"disk_full_{rpi_key}_{mount.replace('/', '_')}"
        if pct >= 90:
            create_or_update_alert(instance_id, alert_type, severity="critical",
                message=f"Disque {mount} plein à {pct}% sur {rpi_key.upper()}")
        elif pct >= 80:
            create_or_update_alert(instance_id, alert_type, severity="warning",
                message=f"Disque {mount} à {pct}% sur {rpi_key.upper()}")
        else:
            resolve_alert(instance_id, alert_type)
```

---

## 3. **Commandes bidirectionnelles Analyss → Cryoss**

Le script `cryoss-heartbeat.sh` sur les Cryoss lit les `pending_commands` dans
la réponse du heartbeat et les exécute via `cryoss-command-runner.sh`. Chaque
commande ACK son résultat via `POST /api/sync/cryoss/command-ack`.

### 3.1. Modèle de données

Nouvelle table SQL :

```sql
CREATE TABLE cryoss_commands (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    instance_id UUID NOT NULL REFERENCES cryoss_instances(id) ON DELETE CASCADE,
    command_type VARCHAR(64) NOT NULL,
    params JSONB DEFAULT '{}',
    status VARCHAR(16) DEFAULT 'pending',   -- pending | sent | ack_ok | ack_error | timeout
    created_at TIMESTAMPTZ DEFAULT NOW(),
    sent_at TIMESTAMPTZ,
    acked_at TIMESTAMPTZ,
    duration_s INTEGER,
    output TEXT,
    created_by VARCHAR(128)                 -- user qui a queue la commande
);

CREATE INDEX idx_cryoss_commands_pending
    ON cryoss_commands(instance_id, status)
    WHERE status IN ('pending', 'sent');
```

### 3.2. Endpoint : l'opérateur queue une commande

```
POST /api/cryoss/{serial}/command
Body: {"command_type": "backup_now", "params": {}}
Auth: user session (opérateur Analyss)

Response:
{
  "id": "a1b2c3d4-...",
  "status": "pending",
  "queued_at": "2026-04-17T11:00:00Z"
}
```

Implémentation :

```python
@router.post("/cryoss/{serial}/command")
def queue_command(serial: str, body: CommandRequest, current_user: User = Depends(...)):
    instance = db.query(CryossInstance).filter_by(serial=serial).first()
    if not instance:
        raise HTTPException(404)

    # Valider le type de commande (whitelist stricte)
    if body.command_type not in ALLOWED_COMMANDS:
        raise HTTPException(400, f"Commande non supportée: {body.command_type}")

    cmd = CryossCommand(
        instance_id=instance.id,
        command_type=body.command_type,
        params=body.params or {},
        status="pending",
        created_by=current_user.email
    )
    db.add(cmd)
    db.commit()
    return {"id": str(cmd.id), "status": "pending", "queued_at": cmd.created_at}
```

### 3.3. Modifier le handler heartbeat pour inclure les pending_commands

```python
@router.post("/sync/cryoss/heartbeat")
def handle_heartbeat(body: dict, authorization: str = Header(...)):
    # ... code existant : verif API key, parse body, update instance, alertes ...

    # Charger les commandes en attente pour cette instance
    pending = db.query(CryossCommand).filter_by(
        instance_id=instance.id,
        status="pending"
    ).order_by(CryossCommand.created_at).limit(5).all()

    pending_commands = [
        {
            "id": str(c.id),
            "type": c.command_type,
            "params": c.params or {}
        }
        for c in pending
    ]

    # Marquer comme "sent" (en cours d'exécution)
    for c in pending:
        c.status = "sent"
        c.sent_at = datetime.utcnow()
    db.commit()

    return {
        "status": "ok",
        "pending_commands": pending_commands
    }
```

### 3.4. Endpoint ACK : Cryoss confirme l'exécution

```
POST /api/sync/cryoss/command-ack
Body: {
    "command_id": "a1b2c3d4-...",
    "command_type": "backup_now",
    "status": "ok",             // "ok" | "error"
    "duration_s": 12,
    "output": "Service started",
    "timestamp": "2026-04-17T11:00:12Z"
}
Auth: Bearer <API_KEY>
```

```python
@router.post("/sync/cryoss/command-ack")
def handle_command_ack(body: CommandAck, authorization: str = Header(...)):
    cmd = db.query(CryossCommand).filter_by(id=body.command_id).first()
    if not cmd:
        raise HTTPException(404)

    # Vérifier que l'API key correspond à l'instance de la commande
    instance = db.query(CryossInstance).filter_by(id=cmd.instance_id).first()
    if not verify_api_key(authorization, instance):
        raise HTTPException(401)

    cmd.status = "ack_ok" if body.status == "ok" else "ack_error"
    cmd.acked_at = datetime.utcnow()
    cmd.duration_s = body.duration_s
    cmd.output = body.output[:8000]  # cap
    db.commit()
    return {"status": "ok"}
```

### 3.5. Whitelist des commandes autorisées

Doit matcher EXACTEMENT ce que `cryoss-command-runner.sh` accepte :

```python
ALLOWED_COMMANDS = {
    # Backup
    "backup_now":        {"label": "Lancer sauvegarde complète",    "params": []},
    "backup_sftp_now":   {"label": "Lancer sync SFTP seule",         "params": []},

    # Samba
    "restart_samba":     {"label": "Redémarrer Samba",               "params": []},
    "stop_samba":        {"label": "Arrêter Samba (urgence)",        "params": []},
    "start_samba":       {"label": "Démarrer Samba",                 "params": []},

    # Honeypot / incident
    "resolve_compromised": {"label": "Résoudre incident honeypot (débloque + relance Samba)", "params": []},
    "test_honeypot":     {"label": "Test honeypot (dev)",            "params": []},

    # Health
    "run_health_check":  {"label": "Lancer watchdog",                "params": []},
    "run_daily_report":  {"label": "Envoyer rapport quotidien",      "params": []},
    "run_weekly_report": {"label": "Envoyer rapport hebdo",          "params": []},
    "test_email":        {"label": "Test email (msmtp)",             "params": []},

    # Système
    "restart_service":   {"label": "Redémarrer un service",          "params": ["service"]},
    "get_logs":          {"label": "Récupérer les logs",             "params": ["log", "lines"]},
    "reboot":            {"label": "Redémarrer le RPi",              "params": [], "danger": True},
    "ping":              {"label": "Ping de test",                   "params": []},

    # Fail2ban / sécurité
    "fail2ban_status":      {"label": "Statut global fail2ban",                       "params": []},
    "fail2ban_jail_status": {"label": "Détail d'une jail",                            "params": ["jail"]},
    "fail2ban_banned_list": {"label": "Liste des IPs bannies (toutes jails)",         "params": []},
    "fail2ban_unban":       {"label": "Débannir une IP",                              "params": ["jail", "ip"]},
    "fail2ban_ban":         {"label": "Bannir manuellement une IP",                   "params": ["jail", "ip"]},
    "fail2ban_unban_all":   {"label": "Débannir TOUTES les IPs",                      "params": [], "danger": True},
    "fail2ban_reload":      {"label": "Recharger config fail2ban",                    "params": []},
    "fail2ban_stats":       {"label": "Statistiques + top IPs attaquantes",           "params": []},
}
```

### 3.6. Endpoint liste des commandes (historique UI)

```
GET /api/cryoss/{serial}/commands?limit=50
Response: [
    {
        "id": "...",
        "command_type": "backup_now",
        "status": "ack_ok",
        "created_at": "2026-04-17T11:00:00Z",
        "acked_at": "2026-04-17T11:00:12Z",
        "duration_s": 12,
        "output": "Started cryoss-backup.service",
        "created_by": "operator@analyss.fr"
    },
    ...
]
```

---

## 4. Dashboard Frontend

### 4.1. Page détail instance Cryoss

**Bandeau critique en haut** (si `compromised.active == true`) :

```tsx
{compromised?.active && (
  <Alert severity="critical" variant="filled">
    <AlertTitle>⚠️ HONEYPOT DÉCLENCHÉ</AlertTitle>
    Événement <strong>{compromised.event}</strong> sur {compromised.sentinel}<br/>
    Détecté le {formatDate(compromised.detected_at)}
    <Button color="inherit" onClick={() => sendCommand("resolve_compromised")}>
      Résoudre l'incident
    </Button>
  </Alert>
)}
```

**Section Actions (nouveau)** — boutons pour chaque commande :

```tsx
<Card title="Actions rapides">
  <ButtonGroup>
    <Button onClick={() => send("backup_now")}>Lancer sauvegarde</Button>
    <Button onClick={() => send("run_health_check")}>Check santé</Button>
    <Button onClick={() => send("test_email")}>Test email</Button>
    <Button onClick={() => send("restart_samba")}>Redémarrer Samba</Button>
    <Button color="danger" onClick={() => confirmAndSend("reboot")}>Redémarrer RPi</Button>
  </ButtonGroup>

  <Select onChange={(svc) => send("restart_service", {service: svc})}>
    <option>Redémarrer un service...</option>
    <option value="cryoss-api">cryoss-api</option>
    <option value="fail2ban">fail2ban</option>
    <option value="smbd">smbd</option>
  </Select>

  <Select onChange={(log) => fetchLogs(log)}>
    <option>Voir un log...</option>
    <option value="backup">cryoss-backup.log</option>
    <option value="heartbeat">cryoss-heartbeat.log</option>
    <option value="honeypot">cryoss-honeypot.log</option>
    <option value="msmtp">msmtp.log</option>
  </Select>
</Card>
```

### 4.2. Historique des commandes (panneau latéral)

Polling toutes les 5s pour voir le status évoluer (pending → sent → ack_ok/ack_error).

### 4.3. Section RPi1 + RPi2

Grid à 2 colonnes :
- **Colonne RPi1** : hostname, uptime, cpu_temp, load, RAM, RAID (md0, md1), disques, services
- **Colonne RPi2 (air-gapped)** :
  - Badge reachable/unreachable (+ ping ms)
  - Si ssh_error : warning "SSH RPi2 refuse"
  - hostname, uptime, cpu_temp, load, RAM, RAID md0, disque /etc/encrypted
  - Services : ssh, fail2ban, cryoss-api, cryoss-health-daily.timer
  - **Réception** :
    - `file_count` fichiers reçus
    - Si `last_received_age_h`:
      - null : "Aucune donnée reçue"
      - 0 : "Reçu il y a moins d'1h ✅"
      - < 26 : "Reçu il y a {X}h ✅"
      - 26-50 : "Reçu il y a {X}h ⚠️"
      - \> 50 : "Reçu il y a {X}h 🔴"
    - `last_received_ts` → afficher en date humaine

### 4.4. Section Fail2ban (gestion des prisons)

Page dédiée ou section dans le détail d'une instance.

**4.4.1. Vue d'ensemble — appel `fail2ban_stats`**

```tsx
<Card title="Fail2Ban — Sécurité">
  <Button onClick={() => send("fail2ban_stats").then(setStatsOutput)}>
    Rafraîchir les stats
  </Button>
  <pre>{statsOutput}</pre>
</Card>
```

Exemple de sortie formatée par le runner (affichable tel quel dans un `<pre>`) :
```
=== JAILS ACTIVES ===
  sshd : 3 bannie(s) actuellement / 47 total
  samba : 0 bannie(s) actuellement / 2 total

=== BANS 24H ===
  12 ban(s) dans les dernières 24h

=== BANS 7 JOURS ===
  47 ban(s) dans les 7 derniers jours

=== TOP 10 IPs ATTAQUANTES (7j) ===
     23 192.241.XX.XX
     18 45.142.XX.XX
     ...
```

**4.4.2. Gestion des bannis — UI interactive**

```tsx
<Card title="IPs bannies">
  <Button onClick={fetchBanned}>Lister les bannis</Button>
  <Table>
    {bannedList.map(({jail, ip}) => (
      <TableRow>
        <Cell>{jail}</Cell>
        <Cell>{ip}</Cell>
        <Cell>
          <Button color="warning" onClick={() => send("fail2ban_unban", {jail, ip})}>
            Débannir
          </Button>
        </Cell>
      </TableRow>
    ))}
  </Table>
  <Button color="danger" onClick={() => confirmAndSend("fail2ban_unban_all")}>
    Débannir TOUT (opération d'urgence)
  </Button>
</Card>

<Card title="Bannir manuellement une IP">
  <form onSubmit={(e) => {
    e.preventDefault();
    send("fail2ban_ban", {jail: e.target.jail.value, ip: e.target.ip.value});
  }}>
    <Select name="jail">
      <option value="sshd">sshd</option>
      <option value="samba">samba</option>
    </Select>
    <Input name="ip" placeholder="ex: 192.0.2.45" pattern="^\d+\.\d+\.\d+\.\d+$" required />
    <Button type="submit">Bannir</Button>
  </form>
</Card>
```

**4.4.3. Parser la sortie `fail2ban_banned_list`**

Le runner renvoie les IPs ligne par ligne au format `jail:ip` :
```
sshd:192.0.2.45
sshd:198.51.100.1
samba:203.0.113.9
```

Côté frontend :
```tsx
const parseBannedOutput = (output: string) =>
  output.split("\n")
        .filter(Boolean)
        .map(line => {
          const [jail, ip] = line.split(":");
          return {jail, ip};
        });
```

**4.4.4. Cas d'usage typiques**

| Scénario | Action |
|---|---|
| Une IP client légitime s'est fait bannir à tort | Bouton "Débannir" sur la ligne |
| Rapport montre 200 bans/24h d'une même IP | Bouton "Bannir" avec la jail `recidive` |
| Changement de règles (ex: nouveau jail.local) | `fail2ban_reload` après modif via `restart_service` |
| Audit régulier | `fail2ban_stats` + affichage top 10 attaquantes |
| Debug : pourquoi cette IP est bannie ? | `fail2ban_jail_status` avec `{jail: "sshd"}` |

**4.4.5. Note sécurité**

Le runner côté Cryoss applique ces **garde-fous stricts** :
- Whitelist de noms de jails (`sshd`, `samba`, `recidive`, etc.) — tout autre nom = rejeté
- Validation regex de l'IP (IPv4 + optional CIDR) — format invalide = rejeté
- **Refus absolu de bannir `10.42.0.1` ou `10.42.0.2`** (IPs interco Cryoss — éviterait le deadlock qu'on a déjà rencontré)

Analyss n'a **pas besoin de dupliquer ces validations** (l'agent les fera), mais
c'est bien de les valider côté UI pour un meilleur UX (feedback immédiat).

---

### 4.5. Section Backup (canaux + restore)

```tsx
<Card title="Sauvegarde">
  <Grid cols={3}>
    <Cell label="C1 (RAID local)" value={<Badge status={backup.c1_status} />} />
    <Cell label="C2 (RPi2 interco)" value={<Badge status={backup.c2_status} />} />
    <Cell label="C3 (SFTP distant)" value={<Badge status={backup.c3_status} />} />
  </Grid>
  <Row>
    <Cell label="Dernière exécution" value={formatDate(backup.last_run)} />
    <Cell label="Statut global" value={<Badge status={backup.last_status} />} />
    <Cell label="Fichiers archivés" value={backup.archive_count} />
    <Cell label="Test restauration" value={<Badge status={backup.restore_test} />} />
  </Row>
</Card>
```

---

## 5. Nettoyage des alertes buggées existantes

```sql
-- Résoudre l'ancienne alerte "493447h"
UPDATE cryoss_alerts
SET is_resolved = true, resolved_at = NOW(), resolve_reason = 'Bug corrigé côté Cryoss'
WHERE (alert_type IN ('replication_silent', 'repl_rpi2_late')
       OR message LIKE '%493%'
       OR message LIKE '%silencieuse%')
  AND is_resolved = false;
```

---

## 6. Test de validation

Après déploiement, sur DS-00000001 :

1. Dashboard affiche :
   - Instance status = `ok` (pas `alert`)
   - Aucune alerte active
   - RPi2 complet avec 498 fichiers reçus, ~16h de dernière réception

2. Depuis le bouton "Lancer sauvegarde" :
   - Commande queue en DB (status=pending)
   - Au prochain heartbeat (< 5min), status devient `sent`
   - Dans les minutes suivantes, status `ack_ok` + output "Service started"
   - Le backup tourne réellement sur le RPi1

3. Vérifier la sécurité :
   - Commande inconnue refusée 400 côté API
   - Commande avec mauvaise API key refusée 401 sur l'ACK
   - Tenter d'envoyer `"command_type": "rm -rf /"` → rejeté par la whitelist

---

## Récapitulatif des changements code

**Backend Analyss** :
- `cryoss_sync.py` : nouveau parsing + nouvelles alertes
- Nouveau fichier `cryoss_commands.py` : endpoints command/command-ack
- Migration SQL : nouvelle table `cryoss_commands`

**Frontend Analyss** :
- Nouveau composant `<CryossActions>` avec boutons d'action
- Nouveau composant `<CryossRpi2Card>`
- Nouveau composant `<CryossBackupCard>`
- Hook `useCryossCommand(serial)` pour l'UI

**Déjà fait côté Cryoss** (nothing to do, tout est prêt) :
- Heartbeat envoie le nouveau format
- `cryoss-command-runner.sh` installé et appelé automatiquement
- Whitelist stricte côté agent
