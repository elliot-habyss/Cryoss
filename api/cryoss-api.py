#!/usr/bin/env python3
"""
Cryoss v2 — Remote Control API
=================================
API REST mince qui wrape les scripts bash Cryoss existants.
Accessible localement (127.0.0.1 sur RPi1, 10.42.0.2 sur RPi2)
et via SSH vers le RPi. Le heartbeat phone-home pousse les données
vers Analyss de manière centralisée.

Sécurité :
  - Bind localhost ONLY (jamais 0.0.0.0)
  - API key Bearer token (constant-time comparison)
  - Rate limiting 60 req/min
  - Actions destructives → header X-Cryoss-Confirm: yes
  - Audit log de chaque requête
  - Anti brute-force (500ms delay on bad key)
  - Input validation sur tous les paramètres
  - Whitelist de logs lisibles (anti path traversal)

Usage :
  uvicorn cryoss-api:app --host 127.0.0.1 --port 8420
  # ou via systemd : systemctl start cryoss-api

Accès distant :
  ssh habyss@<CLIENT_IP> -L 8420:localhost:8420
  curl -H "Authorization: Bearer <KEY>" http://localhost:8420/api/v1/status
  curl http://localhost:8420/docs  # Swagger
"""

from __future__ import annotations

import hashlib
import hmac
import os
import re
import socket
import subprocess
import time
from datetime import datetime
from enum import Enum
from pathlib import Path
from typing import Any

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

# ============================================================================
# Config
# ============================================================================

API_VERSION = "2.0.0"
API_PORT = 8420
API_HOST = "127.0.0.1"  # JAMAIS 0.0.0.0

SERIAL_FILE = Path("/etc/cryoss/serial")
API_KEY_FILE = Path("/etc/cryoss/api-key")
CRYOSS_DIR = Path("/etc/cryoss")

# Interco RPi2
INTERCO_RPI2_IP = "10.42.0.2"
INTERCO_ADMIN_USER = "habyss"

# Rate limiting
RATE_LIMIT_WINDOW = 60  # seconds
RATE_LIMIT_MAX = 60     # requests per window
_rate_store: dict[str, list[float]] = {}

# ============================================================================
# Helpers
# ============================================================================


def sh(cmd: str, timeout: int = 30) -> dict[str, Any]:
    """Execute a shell command via sudo, return structured result.

    [A1] L'API tourne en tant que cryoss-api (non-root).
    Les commandes systeme sont executees via sudo (sudoers restreint).
    """
    try:
        r = subprocess.run(
            f"sudo {cmd}", shell=True, capture_output=True,
            text=True, timeout=timeout,
        )
        return {
            "ok": r.returncode == 0,
            "stdout": r.stdout,
            "stderr": r.stderr,
            "rc": r.returncode,
        }
    except subprocess.TimeoutExpired:
        return {"ok": False, "stdout": "", "stderr": f"timeout ({timeout}s)", "rc": -1}
    except Exception as e:
        return {"ok": False, "stdout": "", "stderr": str(e), "rc": -99}


def sh_val(cmd: str, default: str = "N/A") -> str:
    """Execute a command and return stripped stdout, or default on error."""
    r = sh(cmd, timeout=10)
    return r["stdout"].strip() if r["ok"] and r["stdout"].strip() else default


def get_serial() -> str:
    """Read the Cryoss serial number."""
    if SERIAL_FILE.exists():
        return SERIAL_FILE.read_text().strip()
    return "DS-UNKNOWN"


def detect_role() -> str:
    """Detect if this is rpi1 or rpi2."""
    if Path("/usr/local/bin/cryoss-backup.sh").exists():
        return "rpi1"
    if Path("/etc/cryoss/rpi2-role").exists():
        return "rpi2"
    # Fallback: check interco IP
    try:
        import subprocess
        r = subprocess.run("ip addr show 2>/dev/null | grep -q 10.42.0.2", shell=True)
        if r.returncode == 0:
            return "rpi2"
    except:
        pass
    return "unknown"


# ============================================================================
# Auth
# ============================================================================


_api_key_cache: str = ""
_api_key_mtime: float = 0


def _load_api_key() -> str:
    """Load API key from disk with TTL cache (avoid file I/O on every request)."""
    global _api_key_cache, _api_key_mtime
    if not API_KEY_FILE.exists():
        raise RuntimeError(
            f"API key not found: {API_KEY_FILE}\n"
            f"Generate one: openssl rand -base64 48 > {API_KEY_FILE} && chmod 600 {API_KEY_FILE}"
        )
    mtime = API_KEY_FILE.stat().st_mtime
    if _api_key_cache and mtime == _api_key_mtime:
        return _api_key_cache
    _api_key_cache = API_KEY_FILE.read_text().strip()
    _api_key_mtime = mtime
    return _api_key_cache


async def verify_auth(authorization: str = Header(..., description="Bearer <API_KEY>")) -> str:
    """Verify API key (constant-time). Returns client info string."""
    provided = authorization.removeprefix("Bearer ").strip()
    if not provided:
        raise HTTPException(401, "Missing Bearer token")

    expected = _load_api_key()

    if not hmac.compare_digest(
        hashlib.sha256(provided.encode()).digest(),
        hashlib.sha256(expected.encode()).digest(),
    ):
        # [A2] async-safe delay — ne bloque pas l'event loop
        import asyncio
        await asyncio.sleep(0.5)
        raise HTTPException(401, "Invalid API key")

    return get_serial()


def require_confirm(
    x_cryoss_confirm: str = Header(
        None, alias="X-Cryoss-Confirm",
        description="Must be 'yes' for destructive actions",
    ),
) -> None:
    """Require explicit confirmation for destructive actions."""
    if not x_cryoss_confirm or x_cryoss_confirm.lower() != "yes":
        raise HTTPException(
            428,
            "Destructive action — set header X-Cryoss-Confirm: yes",
        )


# ============================================================================
# Rate Limiting
# ============================================================================


def rate_limit(request: Request) -> None:
    """Simple sliding window rate limiter with memory cleanup."""
    client = request.client.host if request.client else "unknown"
    now = time.time()

    if client not in _rate_store:
        _rate_store[client] = []

    # Clean old entries for this client
    _rate_store[client] = [t for t in _rate_store[client] if now - t < RATE_LIMIT_WINDOW]

    # Periodic cleanup: remove stale clients (every 100 requests), never the current client
    if sum(len(v) for v in _rate_store.values()) % 100 == 0:
        stale = [k for k, v in _rate_store.items() if k != client and (not v or now - max(v) > RATE_LIMIT_WINDOW * 2)]
        for k in stale:
            del _rate_store[k]

    if len(_rate_store.get(client, [])) >= RATE_LIMIT_MAX:
        raise HTTPException(429, f"Rate limit: max {RATE_LIMIT_MAX} req/{RATE_LIMIT_WINDOW}s")

    _rate_store[client].append(now)


# ============================================================================
# Response Models
# ============================================================================


class ApiMeta(BaseModel):
    serial: str = ""
    role: str = ""
    hostname: str = ""
    timestamp: str = ""
    api_version: str = API_VERSION


class ApiResponse(BaseModel):
    ok: bool
    meta: ApiMeta
    data: Any = None
    error: str | None = None


def make_response(data: Any = None, error: str | None = None) -> dict:
    return ApiResponse(
        ok=error is None,
        meta=ApiMeta(
            serial=get_serial(),
            role=detect_role(),
            hostname=socket.gethostname(),
            timestamp=datetime.now().isoformat(),
        ),
        data=data,
        error=error,
    ).model_dump()


# ============================================================================
# App
# ============================================================================

app = FastAPI(
    title="Cryoss Remote API",
    version=API_VERSION,
    description="API de contrôle distant Cryoss — by Analyss",
    docs_url="/docs",
    redoc_url=None,
)


@app.middleware("http")
async def audit_log(request: Request, call_next):
    """Log every request for audit trail."""
    start = time.time()
    response = await call_next(request)
    duration = time.time() - start
    client = request.client.host if request.client else "?"
    print(
        f"[AUDIT] {datetime.now().isoformat()} | "
        f"{client} | {request.method} {request.url.path} | "
        f"{response.status_code} | {duration:.3f}s",
        flush=True,
    )
    return response


# ============================================================================
# Routes : Status & System
# ============================================================================


@app.get("/api/v1/status")
def status(serial: str = Depends(verify_auth), _=Depends(rate_limit)):
    """Vue globale complète du système."""
    role = detect_role()

    # RAID
    raid_raw = sh_val("cat /proc/mdstat")
    raid_md0 = sh("mdadm --detail /dev/md0 2>/dev/null | grep -E 'State|Active|Failed'")
    raid_md1 = sh("mdadm --detail /dev/md1 2>/dev/null | grep -E 'State|Active|Failed'") if role == "rpi1" else None

    # Disks
    mounts = ["/etc/sauvegarde", "/etc/encrypted"] if role == "rpi1" else ["/etc/encrypted"]
    disks = {}
    for m in mounts:
        r = sh(f"df -h {m} 2>/dev/null | tail -1")
        if r["ok"]:
            parts = r["stdout"].split()
            if len(parts) >= 5:
                disks[m] = {"used": parts[2], "total": parts[1], "pct": parts[4]}

    # Services
    svcs_to_check = ["smbd", "ssh", "fail2ban"] if role == "rpi1" else ["ssh", "fail2ban"]
    services = {}
    for s in svcs_to_check:
        services[s] = sh_val(f"systemctl is-active {s}")

    # Cryoss-specific services
    for s in ["cryoss-backup.timer", "cryoss-health-daily.timer",
              "cryoss-watchdog.timer", "cryoss-api", "cryoss-heartbeat.timer"]:
        state = sh_val(f"systemctl is-active {s}")
        if state != "N/A":
            services[s] = state

    return make_response({
        "serial": get_serial(),
        "role": role,
        "hostname": socket.gethostname(),
        "uptime": sh_val("uptime -p"),
        "cpu_temp_c": sh_val("awk '{printf \"%.1f\", $1/1000}' /sys/class/thermal/thermal_zone0/temp"),
        "load": sh_val("cat /proc/loadavg"),
        "ram": sh_val("free -h --si | awk '/Mem:/{print $3\"/\"$2}'"),
        "raid": {
            "mdstat": raid_raw,
            "md0": raid_md0["stdout"].strip() if raid_md0 and raid_md0["ok"] else "N/A",
            "md1": raid_md1["stdout"].strip() if raid_md1 and raid_md1["ok"] else None,
        },
        "disks": disks,
        "services": services,
    })


@app.get("/api/v1/system/raid")
def raid_detail(serial: str = Depends(verify_auth), _=Depends(rate_limit)):
    """Status RAID détaillé (mdadm --detail complet)."""
    return make_response({
        "mdstat": sh("cat /proc/mdstat"),
        "md0": sh("mdadm --detail /dev/md0 2>/dev/null"),
        "md1": sh("mdadm --detail /dev/md1 2>/dev/null"),
    })


@app.get("/api/v1/system/smart/{disk}")
def smart(disk: str, serial: str = Depends(verify_auth), _=Depends(rate_limit)):
    """Données SMART pour un disque."""
    if not re.match(r"^(sd[a-z]|nvme\d+n\d+|mmcblk\d+)$", disk):
        raise HTTPException(400, f"Invalid disk name: {disk}")
    return make_response(sh(f"smartctl -H -A /dev/{disk} 2>/dev/null"))


@app.get("/api/v1/system/disk")
def disk_usage(serial: str = Depends(verify_auth), _=Depends(rate_limit)):
    """Usage disque détaillé."""
    return make_response(sh("df -h"))


@app.get("/api/v1/system/services")
def services_status(serial: str = Depends(verify_auth), _=Depends(rate_limit)):
    """Status de tous les services Cryoss."""
    return make_response(sh("systemctl list-units --all --no-pager | grep -iE 'cryoss|cryoss-backup|smbd|fail2ban|ssh'"))


@app.get("/api/v1/system/timers")
def timers(serial: str = Depends(verify_auth), _=Depends(rate_limit)):
    """Status de tous les timers systemd Cryoss."""
    return make_response(sh("systemctl list-timers --all --no-pager | grep -i cryoss"))


# ============================================================================
# Routes : Health & Monitoring
# ============================================================================


@app.get("/api/v1/health/{mode}")
def health(mode: str, serial: str = Depends(verify_auth), _=Depends(rate_limit)):
    """Exécute le script de health check (daily/weekly/alert)."""
    if mode not in ("daily", "weekly", "alert"):
        raise HTTPException(400, "Mode must be: daily, weekly, alert")
    return make_response(sh(f"/usr/local/bin/cryoss-health.sh {mode}", timeout=120))


@app.get("/api/v1/watchdog")
def watchdog(serial: str = Depends(verify_auth), _=Depends(rate_limit)):
    """Exécute un check watchdog ponctuel."""
    return make_response(sh("/usr/local/bin/cryoss-health.sh alert", timeout=60))


# ============================================================================
# Routes : Backup (RPi1 only)
# ============================================================================


@app.post("/api/v1/backup/run")
def backup_run(
    serial: str = Depends(verify_auth),
    _=Depends(rate_limit),
    __=Depends(require_confirm),
):
    """Lance un backup triple-chemin. Nécessite X-Cryoss-Confirm: yes."""
    if detect_role() != "rpi1":
        raise HTTPException(400, "Backup only available on RPi1")
    return make_response(sh("systemctl start cryoss-backup.service", timeout=5))


@app.get("/api/v1/backup/status")
def backup_status(serial: str = Depends(verify_auth), _=Depends(rate_limit)):
    """Status du dernier backup (journal systemd)."""
    return make_response({
        "service": sh("systemctl show cryoss-backup.service --property=ActiveState,SubState,Result,ExecMainStartTimestamp --no-pager"),
        "journal": sh("journalctl -u cryoss-backup.service --no-pager -n 40 --output short-iso"),
    })


@app.get("/api/v1/backup/history")
def backup_history(
    lines: int = Query(default=50, ge=1, le=500),
    serial: str = Depends(verify_auth),
    _=Depends(rate_limit),
):
    """Historique des backups depuis le journal."""
    return make_response(sh(f"journalctl -u cryoss-backup.service --no-pager -n {lines} --output short-iso"))


@app.get("/api/v1/backup/archives")
def backup_archives(serial: str = Depends(verify_auth), _=Depends(rate_limit)):
    """Liste des archives chiffrées locales (rclone crypt)."""
    return make_response({
        "files": sh("ls -lhrt /etc/encrypted/ 2>/dev/null | tail -30"),
        "count": sh_val("find /etc/encrypted -maxdepth 2 -type f 2>/dev/null | wc -l", "0"),
        "total_size": sh_val("du -sh /etc/encrypted/ 2>/dev/null | awk '{print $1}'"),
    })


@app.post("/api/v1/backup/sftp-sync")
def sftp_sync(
    serial: str = Depends(verify_auth),
    _=Depends(rate_limit),
    __=Depends(require_confirm),
):
    """Lance une sync SFTP incrémentale. Nécessite X-Cryoss-Confirm: yes."""
    return make_response(sh("systemctl start cryoss-sftp-sync.service", timeout=5))


@app.get("/api/v1/backup/sftp-versions")
def sftp_versions(serial: str = Depends(verify_auth), _=Depends(rate_limit)):
    """Liste les versions SFTP disponibles."""
    return make_response(sh("rclone lsd cryoss-versions: --contimeout 15s --timeout 15s 2>/dev/null", timeout=30))


# ============================================================================
# Routes : Replication
# ============================================================================


@app.get("/api/v1/replication/status")
def replication_status(serial: str = Depends(verify_auth), _=Depends(rate_limit)):
    """État de la réplication (RPi1→RPi2 ou réception RPi2)."""
    role = detect_role()

    if role == "rpi1":
        # Vérifie depuis RPi1 : les fichiers sur RPi2
        return make_response({
            "rpi2_reachable": sh(f"ssh -o BatchMode=yes -o ConnectTimeout=5 {INTERCO_ADMIN_USER}@{INTERCO_RPI2_IP} 'echo ok' 2>/dev/null")["ok"],
            "rpi2_latest": sh(f"ssh -o ConnectTimeout=5 {INTERCO_ADMIN_USER}@{INTERCO_RPI2_IP} 'ls -lt /etc/encrypted/rpi1/ 2>/dev/null | head -5'"),
            "rpi2_count": sh_val(f"ssh -o ConnectTimeout=5 {INTERCO_ADMIN_USER}@{INTERCO_RPI2_IP} 'find /etc/encrypted/rpi1 -type f 2>/dev/null | wc -l'"),
            "rpi2_disk": sh(f"ssh -o ConnectTimeout=5 {INTERCO_ADMIN_USER}@{INTERCO_RPI2_IP} 'df -h /etc/encrypted'"),
        })
    else:
        # RPi2 : montre la réception locale
        newest_ts = sh_val(
            "find /etc/encrypted/rpi1 -type f -printf '%T@\\n' 2>/dev/null | sort -rn | head -1"
        )
        age_h = None
        if newest_ts:
            try:
                import time
                age_s = time.time() - float(newest_ts)
                if 0 <= age_s < 31536000:  # < 1 an = valeur raisonnable
                    age_h = round(age_s / 3600, 1)
            except (ValueError, TypeError):
                pass
        return make_response({
            "latest": sh("ls -lt /etc/encrypted/rpi1/ 2>/dev/null | head -10"),
            "file_count": sh_val("find /etc/encrypted/rpi1 -type f 2>/dev/null | wc -l"),
            "disk": sh("df -h /etc/encrypted"),
            "last_received_age_h": age_h,
            "last_received_ts": int(float(newest_ts)) if newest_ts else None,
        })


# ============================================================================
# Routes : Logs
# ============================================================================

ALLOWED_LOGS = {
    "backup": "/var/log/cryoss-backup.log",
    "rclone": "/var/log/rclone_cryoss.log",
    "health": "/var/log/cryoss-health.log",
    "honeypot": "/var/log/cryoss-honeypot.log",
    "msmtp": "/var/log/msmtp.log",
    "syslog": "/var/log/syslog",
    "auth": "/var/log/auth.log",
    "samba": "/var/log/samba/log.smbd",
}


@app.get("/api/v1/logs/{name}")
def tail_log(
    name: str,
    lines: int = Query(default=100, ge=1, le=1000),
    serial: str = Depends(verify_auth),
    _=Depends(rate_limit),
):
    """Tail d'un fichier log. Logs autorisés : backup, rclone, health, honeypot, msmtp, syslog, auth, samba."""
    if name not in ALLOWED_LOGS:
        raise HTTPException(400, f"Unknown log '{name}'. Allowed: {list(ALLOWED_LOGS.keys())}")
    return make_response(sh(f"tail -n {lines} {ALLOWED_LOGS[name]} 2>/dev/null"))


@app.get("/api/v1/logs/{name}/search")
def search_log(
    name: str,
    q: str = Query(..., min_length=1, max_length=200),
    lines: int = Query(default=200, ge=1, le=1000),
    serial: str = Depends(verify_auth),
    _=Depends(rate_limit),
):
    """Recherche dans un log (grep)."""
    if name not in ALLOWED_LOGS:
        raise HTTPException(400, f"Unknown log '{name}'.")
    # Sanitize query to prevent injection
    safe_q = q.replace("'", "'\\''")
    return make_response(sh(f"grep -i '{safe_q}' {ALLOWED_LOGS[name]} 2>/dev/null | tail -n {lines}"))


# ============================================================================
# Routes : Security
# ============================================================================


@app.get("/api/v1/security/fail2ban")
def fail2ban_status(serial: str = Depends(verify_auth), _=Depends(rate_limit)):
    """Status fail2ban : jails actives, IPs bannies."""
    return make_response({
        "status": sh("fail2ban-client status sshd 2>/dev/null"),
        "banned_ips": sh_val("fail2ban-client status sshd 2>/dev/null | grep 'Banned IP' | cut -d: -f2"),
        "bans_24h": sh_val("journalctl -u fail2ban --since '24 hours ago' --no-pager 2>/dev/null | grep -c Ban || echo 0"),
    })


@app.get("/api/v1/security/ufw")
def ufw_status(serial: str = Depends(verify_auth), _=Depends(rate_limit)):
    """Status UFW et règles actives."""
    return make_response(sh("ufw status verbose"))


@app.get("/api/v1/security/honeypot")
def honeypot_status(serial: str = Depends(verify_auth), _=Depends(rate_limit)):
    """Status du honeypot (RPi1)."""
    sentinel = Path("/etc/sauvegarde/__CRYOSS_SENTINEL__")
    cooldown_file = Path("/var/lib/cryoss/honeypot-alert.ts")

    last_alert = None
    if cooldown_file.exists():
        try:
            ts = int(cooldown_file.read_text().strip())
            last_alert = datetime.fromtimestamp(ts).isoformat()
        except (ValueError, OSError):
            pass

    return make_response({
        "service_active": sh_val("systemctl is-active cryoss-honeypot") == "active",
        "sentinel_exists": sentinel.exists(),
        "last_alert": last_alert,
        "log_tail": sh("tail -20 /var/log/cryoss-honeypot.log 2>/dev/null"),
    })


@app.get("/api/v1/security/apparmor")
def apparmor_status(serial: str = Depends(verify_auth), _=Depends(rate_limit)):
    """Status AppArmor."""
    return make_response({
        "status": sh("aa-status 2>/dev/null"),
        "denied_recent": sh("grep 'apparmor=\"DENIED\"' /var/log/syslog 2>/dev/null | tail -10"),
    })


# ============================================================================
# Routes : Config
# ============================================================================


@app.get("/api/v1/config")
def get_config(serial: str = Depends(verify_auth), _=Depends(rate_limit)):
    """Affiche la config active (secrets masqués)."""
    # Ne retourne PAS les clés de chiffrement ni les mots de passe
    return make_response({
        "serial": get_serial(),
        "role": detect_role(),
        "hostname": socket.gethostname(),
        "samba": sh("testparm -s 2>/dev/null | head -40"),
        "ssh": sh("cat /etc/ssh/sshd_config.d/99-cryoss.conf 2>/dev/null"),
        "ufw_rules": sh("ufw status numbered 2>/dev/null"),
        "fail2ban": sh("cat /etc/fail2ban/jail.d/99-cryoss.conf 2>/dev/null"),
        "timers": sh("systemctl list-timers --all --no-pager"),
        "rclone_remotes": sh("rclone listremotes 2>/dev/null"),
        "network": sh("ip addr show 2>/dev/null"),
    })


# ============================================================================
# Routes : RPi2 Proxy (RPi1 → RPi2 via interco)
# ============================================================================


@app.get("/api/v1/rpi2/status")
def rpi2_status(serial: str = Depends(verify_auth), _=Depends(rate_limit)):
    """Status complet RPi2 (via SSH interco)."""
    base = f"ssh -o BatchMode=yes -o ConnectTimeout=10 {INTERCO_ADMIN_USER}@{INTERCO_RPI2_IP}"

    # Test connexion d'abord
    reachable = sh(f"{base} 'echo ok' 2>/dev/null")
    if not reachable["ok"]:
        return make_response(None, error="RPi2 unreachable via interco")

    return make_response({
        "reachable": True,
        "raid": sh(f"{base} 'cat /proc/mdstat'"),
        "disk": sh(f"{base} 'df -h /etc/encrypted'"),
        "services": sh(f"{base} 'systemctl is-active ssh fail2ban'"),
        "uptime": sh_val(f"{base} 'uptime -p'"),
        "temp": sh_val(f"{base} \"awk '{{printf \\\"%.1f\\\", \\$1/1000}}' /sys/class/thermal/thermal_zone0/temp\""),
        "reception": sh(f"{base} 'ls -lt /etc/encrypted/rpi1/ 2>/dev/null | head -10'"),
        "reception_count": sh_val(f"{base} 'find /etc/encrypted/rpi1 -type f 2>/dev/null | wc -l'"),
    })


@app.get("/api/v1/rpi2/raid")
def rpi2_raid(serial: str = Depends(verify_auth), _=Depends(rate_limit)):
    """RAID détaillé RPi2."""
    base = f"ssh -o BatchMode=yes -o ConnectTimeout=10 {INTERCO_ADMIN_USER}@{INTERCO_RPI2_IP}"
    return make_response(sh(f"{base} 'mdadm --detail /dev/md0 2>/dev/null'"))


@app.get("/api/v1/rpi2/smart/{disk}")
def rpi2_smart(disk: str, serial: str = Depends(verify_auth), _=Depends(rate_limit)):
    """SMART RPi2."""
    if not re.match(r"^(sd[a-z]|nvme\d+n\d+)$", disk):
        raise HTTPException(400, f"Invalid disk: {disk}")
    base = f"ssh -o BatchMode=yes -o ConnectTimeout=10 {INTERCO_ADMIN_USER}@{INTERCO_RPI2_IP}"
    return make_response(sh(f"{base} 'smartctl -H -A /dev/{disk} 2>/dev/null'"))


@app.get("/api/v1/rpi2/logs/{name}")
def rpi2_logs(
    name: str,
    lines: int = Query(default=50, ge=1, le=500),
    serial: str = Depends(verify_auth),
    _=Depends(rate_limit),
):
    """Logs RPi2 via SSH."""
    rpi2_logs_map = {
        "health": "/var/log/cryoss-health.log",
        "syslog": "/var/log/syslog",
        "auth": "/var/log/auth.log",
    }
    if name not in rpi2_logs_map:
        raise HTTPException(400, f"RPi2 logs allowed: {list(rpi2_logs_map.keys())}")
    base = f"ssh -o BatchMode=yes -o ConnectTimeout=10 {INTERCO_ADMIN_USER}@{INTERCO_RPI2_IP}"
    return make_response(sh(f"{base} 'tail -n {lines} {rpi2_logs_map[name]} 2>/dev/null'"))


# ============================================================================
# Routes : Heartbeat (phone-home vers Analyss)
# ============================================================================


@app.get("/api/v1/heartbeat/status")
def heartbeat_status(serial: str = Depends(verify_auth), _=Depends(rate_limit)):
    """Status du heartbeat vers Analyss."""
    conf_file = Path("/etc/cryoss/analyss.conf")
    log_file = Path("/var/log/cryoss-heartbeat.log")

    configured = conf_file.exists()
    last_line = ""
    if log_file.exists():
        last_line = sh_val(f"tail -1 {log_file}")

    return make_response({
        "configured": configured,
        "timer_active": sh_val("systemctl is-active cryoss-heartbeat.timer") == "active",
        "last_heartbeat": last_line,
        "analyss_url": sh_val("grep ANALYSS_URL /etc/cryoss/analyss.conf 2>/dev/null | cut -d'\"' -f2") if configured else None,
    })


# ============================================================================
# Routes : Serial
# ============================================================================


@app.get("/api/v1/serial")
def serial_info(serial: str = Depends(verify_auth), _=Depends(rate_limit)):
    """Informations sur le numéro de série."""
    return make_response({
        "serial": get_serial(),
        "role": detect_role(),
        "hostname": socket.gethostname(),
    })


# ============================================================================
# Health check (sans auth — pour monitoring externe)
# ============================================================================


@app.get("/healthz")
def healthz():
    """Health check simple (sans auth). Ne retourne PAS le serial (securite)."""
    return {"status": "ok", "ts": datetime.now().isoformat()}
