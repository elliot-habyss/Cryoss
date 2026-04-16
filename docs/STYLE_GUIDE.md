# Cryoss -- Conventions de code

> Regles de style et bonnes pratiques pour le projet Cryoss.

---

## Bash

### En-tete et options

Tous les scripts d'installation et de backup utilisent le mode strict :

```bash
set -euo pipefail
```

Exception : les scripts de monitoring (`cryoss-health.sh`, `cryoss-heartbeat.sh`) utilisent `set -uo pipefail` sans `-e` pour eviter les arrets silencieux qui casseraient les timers systemd.

### Fonctions

Noms en minuscules avec underscores. Fonctions courtes et descriptives.

```bash
check_raid() { ... }
send_alert_html() { ... }
nuke_disk() { ... }
```

### Codes couleur pour la sortie

Utiliser les fonctions standardisees presentes dans tous les scripts :

```bash
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "${GREEN}[v]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }
step() { echo -e "\n${BOLD}${BLUE}--- $1 ---${NC}"; }
```

### Heredocs pour les fichiers generes

Les scripts d'installation generent des fichiers de configuration et des services systemd via heredocs. Utiliser `<<'EOF'` (avec quotes) pour empecher l'expansion des variables dans le contenu genere, sauf quand l'injection de valeurs est necessaire.

```bash
# Variables expansees (pas de quotes sur EOF)
cat > /etc/systemd/system/cryoss-backup.timer <<TMR_EOF
[Timer]
OnCalendar=*-*-* ${BACKUP_HOUR}:00:00
TMR_EOF

# Pas d'expansion (quotes sur EOF)
cat > /usr/local/bin/cryoss-health.sh << 'HEALTH_EOF'
#!/bin/bash
LOG="/var/log/cryoss-health.log"
HEALTH_EOF
```

### Idempotence

Tous les scripts doivent pouvoir etre relances sans effet de bord. Verifier l'etat avant d'agir :

```bash
# Bon : verifier avant de creer
id ds-repl &>/dev/null || useradd -r -s /usr/sbin/nologin ds-repl

# Bon : supprimer avant de recreer
nmcli connection delete "$CON_NAME" 2>/dev/null || true
nmcli connection add ...
```

### Verification root

Tous les scripts d'installation commencent par :

```bash
[[ $EUID -ne 0 ]] && err "Executer en root : sudo bash $0"
```

---

## Python (API)

### Framework et dependances

- **FastAPI** pour l'API REST.
- **Pydantic** pour la validation des modeles.
- **uvicorn** comme serveur ASGI.
- Type hints obligatoires sur toutes les fonctions.

### Wrapper systeme

L'API utilise un wrapper `sh()` pour executer les commandes systeme via `sudo`. L'API ne tourne pas en root — les commandes autorisees sont definies dans `/etc/sudoers.d/cryoss-api`.

```python
def sh(cmd: str, timeout: int = 30) -> dict[str, Any]:
    """Execute une commande shell via sudo, retourne un resultat structure."""
    ...

def sh_val(cmd: str, default: str = "N/A") -> str:
    """Execute une commande et retourne stdout, ou default en cas d'erreur."""
    ...
```

### Structure des reponses

Toutes les reponses suivent le modele `ApiResponse` :

```python
class ApiResponse(BaseModel):
    ok: bool
    meta: ApiMeta       # serial, role, hostname, timestamp, api_version
    data: Any = None
    error: str | None = None
```

### Securite API

- Bind sur `127.0.0.1` uniquement (jamais `0.0.0.0`).
- Authentification par Bearer token avec comparaison en temps constant (`hmac.compare_digest`).
- Rate limiting (60 req/min par client).
- Actions destructives protegees par le header `X-Cryoss-Confirm: yes`.
- Validation des entrees (noms de disques, noms de logs) pour prevenir l'injection.
- Whitelist de fichiers de log lisibles (anti path traversal).

### Async

Utiliser `async` quand la fonction fait de l'I/O non-bloquante. Les appels a `sh()` sont synchrones (subprocess) — les endpoints qui les utilisent restent synchrones.

---

## Configuration

### Repertoire principal

Toute la configuration Cryoss est dans `/etc/cryoss/` :

| Fichier | Permissions | Contenu |
|---------|------------|---------|
| `serial` | 644 | Numero de serie DS-XXXXXXXX |
| `api-key` | 600 (root:cryoss-api 640) | Cle API Bearer token |
| `keys-backup.conf` | 600 | Sauvegarde des 3 paires de cles rclone |
| `analyss.conf` | 600 | Configuration heartbeat (URL + cle Analyss) |

### Permissions

- **600** pour tout fichier contenant des secrets (cles, mots de passe, tokens).
- **644** pour les fichiers publics (serial, configs sans secret).
- **700** pour les scripts executables contenant de la logique sensible.
- **640** avec `root:cryoss-api` pour les fichiers lus par l'API.

---

## Systemd

### Types de services

- **oneshot** pour les taches ponctuelles (backup, health check, cleanup).
- **simple** pour les services permanents (API, honeypot, tunnel).

### Timers plutot que cron

Cryoss n'utilise **jamais** cron. Toute planification passe par les timers systemd avec `Persistent=true` pour rattraper les executions manquees.

```ini
[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
```

### Timers standards

| Timer | Heure | Fonction |
|-------|-------|----------|
| `cryoss-backup.timer` | 02h00 | Sauvegarde triple chemin |
| `cryoss-sftp-sync.timer` | 08h/14h/20h | Sync SFTP intermediaire |
| `cryoss-health-daily.timer` | 07h00 | Rapport quotidien |
| `cryoss-health-weekly.timer` | Lundi 08h00 | Rapport hebdomadaire + SMART |
| `cryoss-watchdog.timer` | Toutes les 15 min | Alertes immediates |
| `cryoss-heartbeat.timer` | Toutes les 5 min | Phone-home vers Analyss |

---

## Nommage

### Prefixe `cryoss-*`

Tous les elements du systeme portent le prefixe `cryoss-` :

- Scripts : `cryoss-backup.sh`, `cryoss-health.sh`, `cryoss-honeypot.sh`
- Services : `cryoss-backup.service`, `cryoss-api.service`
- Timers : `cryoss-backup.timer`, `cryoss-watchdog.timer`
- Configs : `99-cryoss.conf` (SSH, fail2ban, sysctl)
- Remotes rclone : `cryoss-c1-crypt`, `cryoss-c2-crypt`, `cryoss-c3-crypt`

### Fichiers de log

Tous dans `/var/log/` avec le prefixe `cryoss-` :

| Fichier | Contenu |
|---------|---------|
| `cryoss-backup.log` | Execution du backup triple chemin |
| `cryoss-health.log` | Rapports de sante et alertes |
| `cryoss-honeypot.log` | Evenements du honeypot anti-ransomware |
| `cryoss-api.log` | Logs de l'API (audit trail) |
| `cryoss-heartbeat.log` | Envois heartbeat vers Analyss |
| `rclone_cryoss_c*.log` | Logs rclone par chemin (c1, c2, c3) |

Logrotate est configure pour tous ces fichiers (rotation hebdomadaire, 8 semaines, compression).

---

## Securite

### API jamais en root

L'API tourne sous l'utilisateur dedie `cryoss-api` avec un sudoers restreint. Seules les commandes de monitoring et de lancement de backup sont autorisees.

### Whitelist sudo

Les commandes autorisees pour `cryoss-api` sont listees dans `/etc/sudoers.d/cryoss-api`. Toute nouvelle commande doit y etre ajoutee explicitement.

### Pas de secrets dans les logs

Les scripts ne doivent jamais afficher de cles, mots de passe ou tokens dans les logs ou la sortie standard. Utiliser des marqueurs partiels si necessaire (`${key:0:8}...`).

### Validation des entrees

Toute donnee venant de l'exterieur (parametres API, noms de fichiers) doit etre validee par regex avant utilisation dans une commande shell.

```python
if not re.match(r"^(sd[a-z]|nvme\d+n\d+)$", disk):
    raise HTTPException(400, f"Invalid disk name: {disk}")
```
