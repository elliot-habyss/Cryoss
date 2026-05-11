#!/usr/bin/env bash
# =============================================================================
#  cryoss-command-runner.sh
#  Executeur de commandes envoyees par Analyss via la reponse du heartbeat.
#
#  FLUX :
#  1. cryoss-heartbeat.sh POST son payload vers Analyss
#  2. Analyss renvoie un JSON avec optionnellement "pending_commands": [...]
#  3. cryoss-heartbeat.sh extrait chaque commande et appelle ce script
#  4. Ce script EXECUTE la commande (whitelist stricte) et ACK via HTTPS
#
#  SECURITE :
#  - Whitelist stricte de commandes (case statement)
#  - Toute commande inconnue => refusee et ACKee en erreur
#  - Timeout strict par commande
#  - Logs complets dans /var/log/cryoss-command.log
#
#  Usage :
#    cryoss-command-runner.sh <command_id> <command_type> [params_json]
#
#  Installation : /usr/local/bin/cryoss-command-runner.sh (chmod 700 root:root)
# =============================================================================

set -uo pipefail
# Pas de -e : on gere les erreurs pour renvoyer un ACK propre meme en cas d'echec

readonly LOG_FILE="/var/log/cryoss-command.log"
readonly CONF_FILE="/etc/cryoss/analyss.conf"
readonly RUNTIME_CONF="/etc/cryoss/config.env"
readonly SHARES_METADATA="/etc/cryoss/shares.conf"
readonly SAMBA_INCLUDE="/etc/samba/cryoss-shares.conf"
readonly DECRYPT_HELPER="/usr/local/bin/cryoss-decrypt-secret"
readonly EMAIL_LIB="/usr/local/lib/cryoss-email.sh"
readonly CMD_TIMEOUT=120          # Timeout maximum par commande (secondes)
readonly CURL_TIMEOUT=15
readonly OUTPUT_MAX_BYTES=8192    # Tronquage strict de l'output ack

# Roots filesystem (ADR 0001 §F'4 - décisions Console 2026-05-03).
# Override possible via /etc/cryoss/config.env (sourcé plus bas, parser strict).
CRYOSS_SHARE_ROOT="/etc/sauvegarde"
CRYOSS_ARCHIVE_ROOT="/etc/encrypted"
CRYOSS_DECRYPT_DIR="/var/lib/cryoss/decrypted"
CRYOSS_DECRYPT_TTL_HOURS=1

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
log() {
    local level="$1"; shift
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*" >> "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# Charger la config Analyss (URL + API key)
# Parser strict KEY=VALUE (PAS de `source` — un fichier compromis donnerait RCE)
# Whitelist des variables acceptées + vérification permissions root:600.
# -----------------------------------------------------------------------------
load_conf() {
    local conf="$1"
    [[ -f "$conf" ]] || return 1

    # Vérifier permissions strictes (root:600)
    local owner perms
    owner=$(stat -c '%U' "$conf" 2>/dev/null || echo "?")
    perms=$(stat -c '%a' "$conf" 2>/dev/null || echo "?")
    if [[ "$owner" != "root" || "$perms" != "600" ]]; then
        log WARN "Permissions $conf insecure: ${owner}:${perms} (attendu root:600)"
    fi

    # Parsing ligne par ligne, sans exécution shell
    local k v
    while IFS='=' read -r k v || [[ -n "$k" ]]; do
        # Skip commentaires et lignes vides
        [[ "$k" =~ ^[[:space:]]*# ]] && continue
        k="${k// /}"; k="${k//$'\t'/}"
        [[ -z "$k" ]] && continue

        # Strip espaces et guillemets autour de la valeur
        v="${v## }"; v="${v%% }"
        v="${v#\"}"; v="${v%\"}"
        v="${v#\'}"; v="${v%\'}"

        # Whitelist stricte des clés acceptées
        case "$k" in
            ANALYSS_URL|ANALYSS_API_KEY|CLIENT_EMAIL|SERIAL)
                printf -v "$k" '%s' "$v"
                export "$k"
                ;;
            *)
                # Variable non reconnue : log et ignore (pas d'exécution)
                log WARN "Variable inconnue ignorée dans $conf : $k"
                ;;
        esac
    done < "$conf"
}

load_conf "$CONF_FILE" || true

if [[ -z "${ANALYSS_URL:-}" || -z "${ANALYSS_API_KEY:-}" ]]; then
    log ERROR "Config Analyss manquante ou incomplète ($CONF_FILE)"
    exit 1
fi

# -----------------------------------------------------------------------------
# Charger /etc/cryoss/config.env si présent (override roots).
# Parser strict, whitelist limitée aux roots filesystem.
# -----------------------------------------------------------------------------
load_runtime_conf() {
    local conf="$1"
    [[ -f "$conf" ]] || return 0

    local k v
    while IFS='=' read -r k v || [[ -n "$k" ]]; do
        [[ "$k" =~ ^[[:space:]]*# ]] && continue
        k="${k// /}"; k="${k//$'\t'/}"
        [[ -z "$k" ]] && continue
        v="${v## }"; v="${v%% }"
        v="${v#\"}"; v="${v%\"}"
        v="${v#\'}"; v="${v%\'}"
        case "$k" in
            CRYOSS_SHARE_ROOT|CRYOSS_ARCHIVE_ROOT|CRYOSS_DECRYPT_DIR|CRYOSS_DECRYPT_TTL_HOURS)
                printf -v "$k" '%s' "$v"
                ;;
            *)
                log WARN "Variable non-whitelistée ignorée dans $conf : $k"
                ;;
        esac
    done < "$conf"
}
load_runtime_conf "$RUNTIME_CONF"

# Normalisation : trailing slash retiré pour comparaisons préfixe propres
CRYOSS_SHARE_ROOT="${CRYOSS_SHARE_ROOT%/}"
CRYOSS_ARCHIVE_ROOT="${CRYOSS_ARCHIVE_ROOT%/}"
CRYOSS_DECRYPT_DIR="${CRYOSS_DECRYPT_DIR%/}"

# -----------------------------------------------------------------------------
# Helper : extraire une valeur d'un JSON via python3 (parsing fiable, pas regex)
# Usage : VAL=$(json_get "service" "$CMD_PARAMS")
# Sortie vide si clé absente, exit 1 si JSON invalide.
# -----------------------------------------------------------------------------
json_get() {
    local key="$1"
    local json="${2:-{\}}"
    KEY="$key" JSON="$json" python3 -c '
import os, json, sys
try:
    data = json.loads(os.environ.get("JSON") or "{}")
    if not isinstance(data, dict):
        sys.exit(1)
    val = data.get(os.environ["KEY"])
    if val is None:
        sys.exit(0)
    if isinstance(val, (str, int, float, bool)):
        print(val)
    else:
        sys.exit(1)
except (ValueError, KeyError):
    sys.exit(1)
' 2>/dev/null
}

# -----------------------------------------------------------------------------
# json_get_array : extrait un champ JSON list-of-strings sous forme CSV bash.
# Utile pour `valid_users`, `write_list` etc. arrivés en JSON array.
# Retourne une chaîne CSV (espace-separée). Champ absent → vide.
# -----------------------------------------------------------------------------
json_get_array_csv() {
    local key="$1"
    local json="${2:-{\}}"
    KEY="$key" JSON="$json" python3 -c '
import os, json, sys
try:
    d = json.loads(os.environ.get("JSON") or "{}")
    v = d.get(os.environ["KEY"])
    if v is None:
        sys.exit(0)
    if isinstance(v, list):
        # Ne garder que les chaînes simples, pattern strict côté usage
        print(" ".join(str(x) for x in v if isinstance(x, str)))
    elif isinstance(v, str):
        print(v)
except Exception:
    sys.exit(1)
' 2>/dev/null
}

# -----------------------------------------------------------------------------
# decrypt_secret_or_die : déchiffre un param `enc:v1:...` via le helper Python.
# Si le param ne commence pas par `enc:v1:`, retourné tel quel (param non-sensible).
# Si l'échec, ack_error et exit 1 (jamais de cleartext en log).
# Usage : PASS=$(decrypt_secret_or_die "$RAW") || exit 1
# -----------------------------------------------------------------------------
decrypt_secret_or_die() {
    local raw="$1"
    if [[ "$raw" != enc:v1:* ]]; then
        printf '%s' "$raw"
        return 0
    fi
    if [[ ! -x "$DECRYPT_HELPER" ]]; then
        send_ack "error" "missing decrypt helper ($DECRYPT_HELPER) — install python3-cryptography + cryoss-decrypt-secret" 0
        return 1
    fi
    if [[ ! -f /etc/cryoss/master_key ]]; then
        send_ack "error" "missing Cryoss master key (/etc/cryoss/master_key not deployed)" 0
        return 1
    fi
    local plain
    plain=$(CRYOSS_TOKEN="$raw" "$DECRYPT_HELPER" 2>/dev/null) || {
        send_ack "error" "decrypt failed (check master_key validity)" 0
        return 1
    }
    printf '%s' "$plain"
}

# -----------------------------------------------------------------------------
# validate_path_in_root : refuse les paths hors d'une racine.
# Refuse aussi la racine nue (`/etc/sauvegarde` seul) et les .. dans le path.
# Echo 1 si OK, sinon ack_error + exit code != 0.
# -----------------------------------------------------------------------------
validate_path_in_root() {
    local path="$1" root="$2" allow_root="${3:-no}"
    if [[ -z "$path" ]]; then
        send_ack "error" "path parameter required" 0
        return 1
    fi
    # Normaliser : strip trailing /
    path="${path%/}"
    # Refus .. (ne fait pas confiance à la résolution canonique kernel ici)
    if [[ "$path" == *..* ]]; then
        send_ack "error" "path contains '..' (refused)" 0
        return 1
    fi
    if [[ "$path" != "$root"* ]]; then
        send_ack "error" "path '$path' must start with '$root'" 0
        return 1
    fi
    if [[ "$allow_root" != "yes" ]] && [[ "$path" == "$root" ]]; then
        send_ack "error" "bare root path refused (specify a sub-path)" 0
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# valid_samba_name : pattern strict pour noms users + shares.
# [a-z][a-z0-9_-]{1,31} — aligné avec le wizard 11b
# -----------------------------------------------------------------------------
valid_samba_name() {
    [[ "$1" =~ ^[a-z][a-z0-9_-]{1,31}$ ]]
}

# Noms Samba protégés (ne peuvent pas être supprimés/modifiés via runner)
SAMBA_PROTECTED_USERS=("habyss" "ds-user" "ds-repl" "root")
SAMBA_PROTECTED_SHARES=("sauvegarde" "encrypted_backup" "global" "homes" "printers")

is_protected_user() {
    local u="$1" p
    for p in "${SAMBA_PROTECTED_USERS[@]}"; do
        [[ "$p" == "$u" ]] && return 0
    done
    return 1
}

is_protected_share() {
    local s="$1" p
    for p in "${SAMBA_PROTECTED_SHARES[@]}"; do
        [[ "$p" == "$s" ]] && return 0
    done
    return 1
}

# -----------------------------------------------------------------------------
# Manipulation de la metadata partagée wizard CLI ↔ runner
# Format /etc/cryoss/shares.conf :
#   USER  <name> <pass-obscured-or-empty>
#   SHARE <name> <fs-path>
#   PERM  <share> <user> <r|rw|no>
# -----------------------------------------------------------------------------

shares_metadata_init() {
    if [[ ! -f "$SHARES_METADATA" ]]; then
        mkdir -p /etc/cryoss
        chmod 700 /etc/cryoss
        : > "$SHARES_METADATA"
        chmod 600 "$SHARES_METADATA"
    fi
}

# Récupère toutes les lignes USER, SHARE ou PERM. Pas de side-effect.
shares_metadata_get_lines() {
    local kind="$1"
    [[ -f "$SHARES_METADATA" ]] || return 0
    grep -E "^${kind} " "$SHARES_METADATA" 2>/dev/null || true
}

# Régénère atomiquement /etc/samba/cryoss-shares.conf depuis la metadata.
# Reload smbd best-effort. Ack_error si testparm échoue.
samba_shares_regen_and_reload() {
    shares_metadata_init

    local tmp="${SAMBA_INCLUDE}.tmp.$$"
    local users_csv shares_csv perms_csv
    users_csv=$(shares_metadata_get_lines USER)
    shares_csv=$(shares_metadata_get_lines SHARE)
    perms_csv=$(shares_metadata_get_lines PERM)

    {
        echo "# =============================================================================="
        echo "#  Partages Cryoss générés depuis $SHARES_METADATA (source de vérité)"
        echo "#  Régénéré $(date '+%Y-%m-%d %H:%M:%S') par cryoss-command-runner.sh"
        echo "#  NE PAS ÉDITER À LA MAIN — utiliser le wizard CLI ou la Console Analyss."
        echo "# =============================================================================="
        # Pour chaque SHARE, calculer valid_users / write_list / read_list / invalid
        local share path
        while read -r _ share path; do
            [[ -z "$share" ]] && continue
            local valid_users="" write_list="" read_list="" denied=""
            local key share_perm
            while read -r _ ps pu pp; do
                [[ "$ps" != "$share" ]] && continue
                case "$pp" in
                    rw) valid_users+="${pu} "; write_list+="${pu} " ;;
                    r)  valid_users+="${pu} "; read_list+="${pu} " ;;
                    no) denied+="${pu} " ;;
                esac
            done <<< "$perms_csv"
            valid_users="${valid_users% }"
            read_list="${read_list% }"
            write_list="${write_list% }"
            denied="${denied% }"
            [[ -z "$valid_users" ]] && continue
            cat <<SHARE_BLOCK
[$share]
   path = $path
   browseable = yes
   read only = no
   guest ok = no
   valid users = $valid_users
SHARE_BLOCK
            [[ -n "$write_list" ]] && echo "   write list = $write_list"
            [[ -n "$read_list" ]]  && echo "   read list = $read_list"
            [[ -n "$denied" ]]     && echo "   invalid users = $denied"
            cat <<SHARE_BLOCK_TAIL
   create mask = 0660
   directory mask = 2770
   force group = samba-share
   strict allocate = yes
SHARE_BLOCK_TAIL
        done <<< "$shares_csv"
    } > "$tmp"

    chmod 644 "$tmp"
    # Test syntaxique avant rename
    if ! testparm -s --suppress-prompt "$tmp" >/dev/null 2>&1; then
        # Le testparm de l'inclusion seule ne marche pas toujours — fallback :
        # on remplace l'include et on teste smb.conf complet.
        :
    fi
    mv -f "$tmp" "$SAMBA_INCLUDE"

    # Vérification globale post-rename
    local tp_err
    tp_err=$(testparm -s /etc/samba/smb.conf 2>&1 >/dev/null) || true
    if echo "$tp_err" | grep -qiE "error|invalid"; then
        log ERROR "testparm failed after regen: $(echo "$tp_err" | head -3)"
        return 1
    fi

    # Reload best-effort
    if ! smbcontrol all reload-config >/dev/null 2>&1; then
        systemctl reload smbd >/dev/null 2>&1 || systemctl restart smbd >/dev/null 2>&1 || {
            log ERROR "samba reload failed"
            return 1
        }
    fi
    return 0
}

# Cache 60s pour samba_user_list (pdbedit -L -v est lent)
SAMBA_USER_CACHE="/var/cache/cryoss/samba-users.json"
SAMBA_USER_CACHE_TTL=60

samba_users_json() {
    mkdir -p "$(dirname "$SAMBA_USER_CACHE")" 2>/dev/null || true
    if [[ -f "$SAMBA_USER_CACHE" ]]; then
        local age
        age=$(( $(date +%s) - $(stat -c %Y "$SAMBA_USER_CACHE" 2>/dev/null || echo 0) ))
        if (( age < SAMBA_USER_CACHE_TTL )); then
            cat "$SAMBA_USER_CACHE"
            return 0
        fi
    fi
    pdbedit -L -v 2>/dev/null | python3 -c '
import sys, json
out = []
cur = {}
for line in sys.stdin:
    line = line.rstrip()
    if line.startswith("Unix username:"):
        if cur:
            out.append(cur)
        cur = {"username": line.split(":",1)[1].strip(), "enabled": True, "last_change": None}
    elif "Account Flags:" in line:
        flags = line.split(":",1)[1].strip()
        cur["enabled"] = "D" not in flags  # D = disabled
    elif "Password last set" in line:
        cur["last_change"] = line.split(":",1)[1].strip()
if cur: out.append(cur)
print(json.dumps(out, ensure_ascii=False))
' > "$SAMBA_USER_CACHE.tmp" 2>/dev/null && mv -f "$SAMBA_USER_CACHE.tmp" "$SAMBA_USER_CACHE"
    cat "$SAMBA_USER_CACHE" 2>/dev/null || echo "[]"
}

# Renvoie la liste JSON des shares depuis la metadata Cryoss
samba_shares_json() {
    [[ -f "$SHARES_METADATA" ]] || { echo "[]"; return 0; }
    SHARES_METADATA="$SHARES_METADATA" python3 -c '
import os, json, collections
shares = collections.OrderedDict()
perms_by_share = collections.defaultdict(lambda: {"valid_users": [], "write_list": [], "read_list": [], "denied": []})
try:
    with open(os.environ["SHARES_METADATA"]) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if not parts: continue
            kind = parts[0]
            if kind == "SHARE" and len(parts) >= 3:
                shares[parts[1]] = {"name": parts[1], "path": parts[2]}
            elif kind == "PERM" and len(parts) >= 4:
                share, user, level = parts[1], parts[2], parts[3]
                if level == "rw":
                    perms_by_share[share]["valid_users"].append(user)
                    perms_by_share[share]["write_list"].append(user)
                elif level == "r":
                    perms_by_share[share]["valid_users"].append(user)
                    perms_by_share[share]["read_list"].append(user)
                elif level == "no":
                    perms_by_share[share]["denied"].append(user)
except FileNotFoundError:
    pass
out = []
for name, info in shares.items():
    p = perms_by_share[name]
    out.append({
        "name": info["name"],
        "path": info["path"],
        "valid_users": p["valid_users"],
        "write_list": p["write_list"],
        "read_only": len(p["write_list"]) == 0,
        "browseable": True,
        "comment": "",
    })
print(json.dumps(out, ensure_ascii=False))
' 2>/dev/null || echo "[]"
}

# -----------------------------------------------------------------------------
# Arguments
# -----------------------------------------------------------------------------
CMD_ID="${1:-}"
CMD_TYPE="${2:-}"
CMD_PARAMS="${3:-{\}}"

if [[ -z "$CMD_ID" || -z "$CMD_TYPE" ]]; then
    log ERROR "Usage : $0 <command_id> <command_type> [params_json]"
    exit 1
fi

# Scrubber les params sensibles avant log : password, enc:v1:* tokens
# Tout est remplacé par "***" pour défense en profondeur (pas de replay-attack
# fenêtre via les logs si la master key n'est pas tournée à temps).
CMD_PARAMS_LOG=$(JSON="$CMD_PARAMS" python3 -c '
import os, json, re
try:
    d = json.loads(os.environ.get("JSON") or "{}")
    if isinstance(d, dict):
        for k, v in list(d.items()):
            if k in ("password", "shutdown_reason"):
                if k == "shutdown_reason":
                    continue  # cleartext mandatory, log OK
                d[k] = "***"
            elif isinstance(v, str) and v.startswith("enc:v1:"):
                d[k] = "enc:v1:***"
    print(json.dumps(d, ensure_ascii=False))
except Exception:
    print("***scrub-failed***")
' 2>/dev/null || echo '***scrub-failed***')

log INFO "Commande recue : id=$CMD_ID type=$CMD_TYPE params=$CMD_PARAMS_LOG"

# -----------------------------------------------------------------------------
# Envoyer l'ACK (resultat) au serveur Analyss
# Construit le JSON via Python pour escaper proprement tous les caracteres
# (quotes, backslashes, control chars, unicode) - bien plus fiable que sed.
# -----------------------------------------------------------------------------
send_ack() {
    local status="$1"      # ok | error
    local output="$2"      # sortie brute (peut contenir n'importe quoi)
    local duration_s="$3"

    # Tronquer a OUTPUT_MAX_BYTES (8192) AVANT le JSON encoding
    local truncated_output
    truncated_output=$(printf '%s' "$output" | head -c "$OUTPUT_MAX_BYTES")

    # Construire le payload JSON via Python (escaping automatique et correct)
    local payload
    payload=$(CMD_ID="$CMD_ID" CMD_TYPE="$CMD_TYPE" STATUS="$status" \
              DURATION="$duration_s" OUTPUT="$truncated_output" \
              python3 -c '
import os, json, datetime
data = {
    "command_id": os.environ.get("CMD_ID", ""),
    "command_type": os.environ.get("CMD_TYPE", ""),
    "status": os.environ.get("STATUS", ""),
    "duration_s": int(os.environ.get("DURATION", "0") or "0"),
    "output": os.environ.get("OUTPUT", ""),
    "timestamp": datetime.datetime.now().isoformat(),
}
print(json.dumps(data, ensure_ascii=False))
' 2>/dev/null)

    # Fallback si python3 absent : JSON construit manuellement (moins robuste)
    if [[ -z "$payload" ]]; then
        local safe_output
        safe_output=$(printf '%s' "$truncated_output" | tr -d '\000-\037\r' | sed 's/\\/\\\\/g; s/"/\\"/g')
        payload="{\"command_id\":\"$CMD_ID\",\"command_type\":\"$CMD_TYPE\",\"status\":\"$status\",\"duration_s\":$duration_s,\"output\":\"$safe_output\",\"timestamp\":\"$(date -Iseconds)\"}"
    fi

    local endpoint="${ANALYSS_URL}/api/sync/cryoss/command-ack"

    # Capturer body + code HTTP (pour debug si 4xx/5xx)
    local response http_code body
    response=$(curl -s -w "\n__HTTP_CODE__%{http_code}" \
        --connect-timeout 5 --max-time "$CURL_TIMEOUT" \
        -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${ANALYSS_API_KEY}" \
        -d "$payload" \
        "$endpoint" 2>/dev/null || echo -e "\n__HTTP_CODE__000")

    http_code=$(echo "$response" | grep -oP '__HTTP_CODE__\K.+$' | tail -1)
    body=$(echo "$response" | sed 's/__HTTP_CODE__.*$//' | sed '$d')

    if [[ "$http_code" == "200" || "$http_code" == "201" || "$http_code" == "204" ]]; then
        log INFO "ACK envoye (HTTP $http_code) pour $CMD_ID status=$status"
    else
        log WARN "ACK echoue (HTTP $http_code) pour $CMD_ID : ${body:0:300}"
    fi
}

# -----------------------------------------------------------------------------
# Wrapper pour executer une commande avec timeout + capture output
# -----------------------------------------------------------------------------
run_cmd() {
    local cmd_desc="$1"; shift
    local start_ts end_ts duration
    local output rc

    start_ts=$(date +%s)
    log INFO "Execution : $cmd_desc"

    # Execution avec timeout strict
    output=$(timeout "$CMD_TIMEOUT" "$@" 2>&1) || rc=$?
    rc="${rc:-0}"

    end_ts=$(date +%s)
    duration=$(( end_ts - start_ts ))

    if (( rc == 0 )); then
        log INFO "OK (${duration}s) : $cmd_desc"
        send_ack "ok" "$output" "$duration"
        return 0
    else
        log ERROR "KO (rc=$rc, ${duration}s) : $cmd_desc"
        send_ack "error" "[rc=$rc] $output" "$duration"
        return "$rc"
    fi
}

# -----------------------------------------------------------------------------
# Dispatcher : whitelist stricte des commandes autorisees
# Toute commande non listee => refusee (ACK error)
# -----------------------------------------------------------------------------
case "$CMD_TYPE" in

    # ────────────────────────────────────────────────────────────────────────
    # BACKUP
    # ────────────────────────────────────────────────────────────────────────
    backup_now)
        # Declenche un backup complet immediatement (asynchrone via systemd)
        run_cmd "systemctl start cryoss-backup.service" \
            systemctl start cryoss-backup.service
        ;;

    backup_sftp_now)
        # Declenche uniquement la sync SFTP (plus rapide)
        if systemctl list-units --all | grep -q cryoss-sftp-sync; then
            run_cmd "systemctl start cryoss-sftp-sync.service" \
                systemctl start cryoss-sftp-sync.service
        else
            send_ack "error" "Service cryoss-sftp-sync non installe (SFTP distant desactive)" 0
        fi
        ;;

    # ────────────────────────────────────────────────────────────────────────
    # SAMBA
    # ────────────────────────────────────────────────────────────────────────
    restart_samba)
        # Redemarre smbd (apres incident honeypot par exemple)
        run_cmd "systemctl restart smbd" systemctl restart smbd
        ;;

    stop_samba)
        # Arrete smbd (action d'urgence)
        run_cmd "systemctl stop smbd" systemctl stop smbd
        ;;

    start_samba)
        # Demarre smbd (si stoppe)
        run_cmd "systemctl start smbd" systemctl start smbd
        ;;

    # ────────────────────────────────────────────────────────────────────────
    # HONEYPOT / INCIDENT
    # ────────────────────────────────────────────────────────────────────────
    resolve_compromised)
        # Marquer l'incident comme resolu (operateur a verifie)
        # Supprime le flag pour que le prochain heartbeat dise active=false
        if [[ -f /var/lib/cryoss/compromised ]]; then
            run_cmd "rm /var/lib/cryoss/compromised + restart samba" \
                bash -c 'rm -f /var/lib/cryoss/compromised && rm -f /var/lib/cryoss/honeypot-alert.ts && systemctl start smbd 2>/dev/null; echo "Flag efface et Samba relance"'
        else
            send_ack "ok" "Aucun flag compromis actif" 0
        fi
        ;;

    test_honeypot)
        # Simule un declenchement pour tester l'alerte (dev uniquement)
        run_cmd "test honeypot" bash -c 'echo "test-from-analyss-$(date +%s)" >> /etc/sauvegarde/__CRYOSS_SENTINEL__; echo "Sentinel modifie"'
        ;;

    # ────────────────────────────────────────────────────────────────────────
    # HEALTH / MONITORING
    # ────────────────────────────────────────────────────────────────────────
    run_health_check)
        # Force un run du watchdog (envoi d'alertes si anomalies)
        run_cmd "cryoss-health.sh alert" /usr/local/bin/cryoss-health.sh alert
        ;;

    run_daily_report)
        # Force l'envoi du rapport quotidien (normalement 07h00)
        run_cmd "cryoss-health.sh daily" /usr/local/bin/cryoss-health.sh daily
        ;;

    run_weekly_report)
        # Force le rapport hebdo
        run_cmd "cryoss-health.sh weekly" /usr/local/bin/cryoss-health.sh weekly
        ;;

    test_email)
        # Envoi d'un email de test pour valider msmtp
        run_cmd "envoi email test" bash -c '
            {
                echo "To: support@habyss.fr"
                echo "Subject: [Cryoss TEST] Email de test depuis Analyss"
                echo ""
                echo "Email declenche depuis la console Analyss a $(date)"
            } | msmtp support@habyss.fr 2>&1 && echo "Email envoye"
        '
        ;;

    # ────────────────────────────────────────────────────────────────────────
    # SYSTEME
    # ────────────────────────────────────────────────────────────────────────
    restart_service)
        # Redemarrer un service systemd (whitelist stricte)
        # Note : pas de "local" dans un case (seulement dans les fonctions)
        SERVICE_NAME=$(json_get "service" "$CMD_PARAMS")
        case "$SERVICE_NAME" in
            cryoss-api|cryoss-backup.timer|cryoss-watchdog.timer|cryoss-health-daily.timer|cryoss-heartbeat.timer|cryoss-honeypot|fail2ban|smbd|ssh)
                run_cmd "systemctl restart $SERVICE_NAME" systemctl restart "$SERVICE_NAME"
                ;;
            *)
                send_ack "error" "Service non autorise : $SERVICE_NAME" 0
                ;;
        esac
        ;;

    get_logs)
        # Retourne les N dernieres lignes d'un log (whitelist)
        LOG_NAME=$(json_get "log" "$CMD_PARAMS")
        LOG_LINES=$(json_get "lines" "$CMD_PARAMS")
        # Validation stricte : entier 1..1000
        if ! [[ "$LOG_LINES" =~ ^[0-9]+$ ]] || (( LOG_LINES < 1 || LOG_LINES > 1000 )); then
            LOG_LINES=50
        fi
        LOG_FILE_PATH=""
        case "$LOG_NAME" in
            backup)    LOG_FILE_PATH="/var/log/cryoss-backup.log" ;;
            health)    LOG_FILE_PATH="/var/log/cryoss-health.log" ;;
            heartbeat) LOG_FILE_PATH="/var/log/cryoss-heartbeat.log" ;;
            honeypot)  LOG_FILE_PATH="/var/log/cryoss-honeypot.log" ;;
            command)   LOG_FILE_PATH="/var/log/cryoss-command.log" ;;
            rclone)    LOG_FILE_PATH="/var/log/rclone_cryoss_c1.log" ;;
            msmtp)     LOG_FILE_PATH="/var/log/msmtp.log" ;;
            *)
                send_ack "error" "Log non autorise : $LOG_NAME" 0
                exit 0
                ;;
        esac
        if [[ -f "$LOG_FILE_PATH" ]]; then
            run_cmd "tail -$LOG_LINES $LOG_FILE_PATH" tail -n "$LOG_LINES" "$LOG_FILE_PATH"
        else
            send_ack "error" "Fichier inexistant : $LOG_FILE_PATH" 0
        fi
        ;;

    reboot)
        # Reboot complet du RPi1 (apres ACK, avec delai 30s pour laisser le curl partir)
        send_ack "ok" "Reboot programme dans 30s" 0
        log WARN "REBOOT programme par Analyss (cmd=$CMD_ID)"
        (sleep 30 && systemctl reboot) &
        ;;

    ping)
        # Simple ping pour tester la chaine de commandes
        send_ack "ok" "pong" 0
        ;;

    # ────────────────────────────────────────────────────────────────────────
    # FAIL2BAN
    # ────────────────────────────────────────────────────────────────────────
    fail2ban_status)
        # Etat global fail2ban + liste des jails
        run_cmd "fail2ban-client status" fail2ban-client status
        ;;

    fail2ban_jail_status)
        # Detail d'une jail : bannis courants, total, IPs
        F2B_JAIL=$(json_get "jail" "$CMD_PARAMS")
        # Whitelist des noms de jail acceptes (evite injection)
        case "$F2B_JAIL" in
            sshd|ssh|samba|apache-auth|nginx-http-auth|recidive)
                run_cmd "fail2ban-client status $F2B_JAIL" fail2ban-client status "$F2B_JAIL"
                ;;
            *)
                send_ack "error" "Jail non autorisee : $F2B_JAIL (allowed: sshd, samba, recidive, etc.)" 0
                ;;
        esac
        ;;

    fail2ban_banned_list)
        # Liste de TOUTES les IPs bannies dans TOUTES les jails
        # Sortie formatee : jail:ip
        run_cmd "liste IPs bannies" bash -c '
            jails=$(fail2ban-client status 2>/dev/null | grep "Jail list" | sed "s/.*://;s/,//g" | xargs)
            for jail in $jails; do
                ips=$(fail2ban-client status "$jail" 2>/dev/null | grep "Banned IP list" | sed "s/.*Banned IP list:\s*//")
                if [[ -n "$ips" ]]; then
                    for ip in $ips; do
                        echo "$jail:$ip"
                    done
                fi
            done
        '
        ;;

    fail2ban_unban)
        # Debannir une IP dans une jail specifique
        F2B_JAIL=$(json_get "jail" "$CMD_PARAMS")
        F2B_IP=$(json_get "ip" "$CMD_PARAMS")

        # Validations strictes
        case "$F2B_JAIL" in
            sshd|ssh|samba|apache-auth|nginx-http-auth|recidive) ;;
            *) send_ack "error" "Jail non autorisee : $F2B_JAIL" 0; exit 1 ;;
        esac
        # Valider format IP (IPv4 basique ou CIDR)
        if ! [[ "$F2B_IP" =~ ^[0-9]+(\.[0-9]+){3}(/[0-9]+)?$ ]]; then
            send_ack "error" "Format IP invalide : $F2B_IP" 0
            exit 1
        fi
        run_cmd "fail2ban-client set $F2B_JAIL unbanip $F2B_IP" \
            fail2ban-client set "$F2B_JAIL" unbanip "$F2B_IP"
        ;;

    fail2ban_ban)
        # Bannir manuellement une IP (en cas d'attaque identifiee)
        F2B_JAIL=$(json_get "jail" "$CMD_PARAMS")
        F2B_IP=$(json_get "ip" "$CMD_PARAMS")

        case "$F2B_JAIL" in
            sshd|ssh|samba|apache-auth|nginx-http-auth|recidive) ;;
            *) send_ack "error" "Jail non autorisee : $F2B_JAIL" 0; exit 1 ;;
        esac
        if ! [[ "$F2B_IP" =~ ^[0-9]+(\.[0-9]+){3}(/[0-9]+)?$ ]]; then
            send_ack "error" "Format IP invalide : $F2B_IP" 0
            exit 1
        fi
        # Refuser de bannir les IPs de l'interco (anti-deadlock)
        if [[ "$F2B_IP" == "10.42.0.1" || "$F2B_IP" == "10.42.0.2" ]]; then
            send_ack "error" "Refus de bannir l'IP d'interco : $F2B_IP" 0
            exit 1
        fi
        run_cmd "fail2ban-client set $F2B_JAIL banip $F2B_IP" \
            fail2ban-client set "$F2B_JAIL" banip "$F2B_IP"
        ;;

    fail2ban_unban_all)
        # Debannir TOUTES les IPs dans toutes les jails (action operateur)
        run_cmd "unban all" bash -c '
            jails=$(fail2ban-client status 2>/dev/null | grep "Jail list" | sed "s/.*://;s/,//g" | xargs)
            count=0
            for jail in $jails; do
                ips=$(fail2ban-client status "$jail" 2>/dev/null | grep "Banned IP list" | sed "s/.*Banned IP list:\s*//")
                for ip in $ips; do
                    [[ -n "$ip" ]] && fail2ban-client set "$jail" unbanip "$ip" >/dev/null 2>&1 && count=$((count+1))
                done
            done
            echo "$count IP(s) debannie(s) au total"
        '
        ;;

    fail2ban_reload)
        # Recharger la config fail2ban (apres modif jail.d/*.conf par exemple)
        run_cmd "fail2ban-client reload" fail2ban-client reload
        ;;

    fail2ban_stats)
        # Statistiques compactes : nombre de bannis par jail + total 24h + total 7j
        run_cmd "stats fail2ban" bash -c '
            jails=$(fail2ban-client status 2>/dev/null | grep "Jail list" | sed "s/.*://;s/,//g" | xargs)
            echo "=== JAILS ACTIVES ==="
            for jail in $jails; do
                currently=$(fail2ban-client status "$jail" 2>/dev/null | grep "Currently banned" | awk "{print \$NF}")
                total=$(fail2ban-client status "$jail" 2>/dev/null | grep "Total banned" | awk "{print \$NF}")
                echo "  $jail : ${currently:-0} bannie(s) actuellement / ${total:-0} total"
            done
            echo ""
            echo "=== BANS 24H ==="
            bans24h=$(journalctl -u fail2ban --since "24 hours ago" 2>/dev/null | awk "/ Ban /{c++} END{print c+0}")
            echo "  $bans24h ban(s) dans les dernieres 24h"
            echo ""
            echo "=== BANS 7 JOURS ==="
            bans7d=$(journalctl -u fail2ban --since "7 days ago" 2>/dev/null | awk "/ Ban /{c++} END{print c+0}")
            echo "  $bans7d ban(s) dans les 7 derniers jours"
            echo ""
            echo "=== TOP 10 IPs ATTAQUANTES (7j) ==="
            journalctl -u ssh --since "7 days ago" 2>/dev/null | \
                grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | \
                sort | uniq -c | sort -rn | head -10
        '
        ;;

    # ════════════════════════════════════════════════════════════════════════
    # §F'4 — DIAGNOSTICS READ-ONLY (12 commandes)
    # ════════════════════════════════════════════════════════════════════════

    disk_usage)
        # Toutes les partitions montees (output formate)
        run_cmd "disk_usage" df -h --output=source,size,used,avail,pcent,target
        ;;

    raid_status)
        # /proc/mdstat + detail md0/md1 si présents
        run_cmd "raid_status" bash -c '
            cat /proc/mdstat 2>/dev/null
            for md in /dev/md0 /dev/md1; do
                [[ -b "$md" ]] || continue
                echo
                echo "=== $md ==="
                mdadm --detail "$md" 2>/dev/null | grep -E "State |Active|Failed|Spare|Working|UUID" || true
            done
        '
        ;;

    smart_status)
        # SMART résumé pour tous les disques physiques (sda..sdd)
        run_cmd "smart_status" bash -c '
            for d in /dev/sd?; do
                [[ -b "$d" ]] || continue
                echo "=== $d ==="
                smartctl -H "$d" 2>/dev/null | grep -E "test result|overall-health" || echo "  N/A"
                smartctl -A "$d" 2>/dev/null | awk "/Temperature|Reallocated|Pending|Power_On_Hours/ {print \"  \"\$0}" || true
            done
        '
        ;;

    system_info)
        run_cmd "system_info" bash -c '
            echo "=== HOSTNAME ==="; hostname
            echo "=== UPTIME ==="; uptime
            echo "=== KERNEL ==="; uname -a
            echo "=== OS ==="; cat /etc/os-release 2>/dev/null | grep -E "PRETTY_NAME|VERSION" || true
            echo "=== CPU ==="; lscpu 2>/dev/null | grep -E "Model name|Architecture|CPU\(s\)" | head -5
            echo "=== MEM ==="; free -h
            echo "=== LOAD ==="; cat /proc/loadavg
        '
        ;;

    network_status)
        run_cmd "network_status" bash -c '
            echo "=== INTERFACES ==="
            ip -br addr 2>/dev/null | grep -v "DOWN.*lo "
            echo
            echo "=== ROUTES ==="
            ip route
            echo
            echo "=== ACTIVE NM CONNECTIONS ==="
            nmcli -t -f NAME,DEVICE,STATE connection show --active 2>/dev/null || echo "(nmcli unavailable)"
        '
        ;;

    firewall_status)
        # ufw status verbose + nb règles, sans IPs sensibles dump
        run_cmd "firewall_status" bash -c '
            echo "=== UFW STATUS ==="
            ufw status verbose 2>/dev/null || echo "(ufw not configured)"
        '
        ;;

    samba_sessions)
        # Sessions Samba actives — smbstatus sans options sensibles
        run_cmd "samba_sessions" bash -c '
            smbstatus -p 2>/dev/null | head -30
            echo
            echo "=== SHARES ==="
            smbstatus -S 2>/dev/null | head -30
        '
        ;;

    samba_testconfig)
        # testparm en mode silencieux + erreurs/warnings
        run_cmd "samba_testconfig" bash -c '
            testparm -s --suppress-prompt /etc/samba/smb.conf 2>&1 | head -80
        '
        ;;

    last_logins)
        run_cmd "last_logins" bash -c '
            last -F -n 30 2>/dev/null | head -40
        '
        ;;

    failed_logins)
        # Param "lines" optionnel, default 50, max 500
        FL_LINES=$(json_get "lines" "$CMD_PARAMS")
        if ! [[ "$FL_LINES" =~ ^[0-9]+$ ]] || (( FL_LINES < 1 || FL_LINES > 500 )); then
            FL_LINES=50
        fi
        run_cmd "failed_logins" bash -c "
            if [[ -f /var/log/auth.log ]]; then
                grep -E 'Failed password|authentication failure' /var/log/auth.log 2>/dev/null \
                    | tail -n $FL_LINES
            elif command -v journalctl >/dev/null; then
                journalctl _COMM=sshd --since '7 days ago' 2>/dev/null \
                    | grep -E 'Failed password|authentication failure' \
                    | tail -n $FL_LINES
            else
                echo '(no auth log available)'
            fi
        "
        ;;

    backup_status)
        # Etat des derniers backups + timer prochain trigger
        run_cmd "backup_status" bash -c '
            echo "=== DERNIER BACKUP ==="
            tail -n 30 /var/log/cryoss-backup.log 2>/dev/null || echo "(no backup log)"
            echo
            echo "=== TIMERS ==="
            systemctl list-timers "cryoss-*" --all 2>/dev/null | head -20
        '
        ;;

    rclone_status)
        # Listemotes rclone + dernier sync log
        run_cmd "rclone_status" bash -c '
            echo "=== REMOTES ==="
            rclone listremotes 2>/dev/null
            echo
            echo "=== DERNIER SYNC SFTP ==="
            tail -n 20 /var/log/rclone_cryoss_c1.log 2>/dev/null || echo "(no rclone c1 log)"
        '
        ;;

    service_status)
        SVC_NAME=$(json_get "service" "$CMD_PARAMS")
        case "$SVC_NAME" in
            cryoss-api|cryoss-backup.timer|cryoss-watchdog.timer|cryoss-health-daily.timer|\
            cryoss-heartbeat.timer|cryoss-honeypot|fail2ban|smbd|ssh|nmbd|postfix|cryoss-sftp-sync.timer)
                run_cmd "service_status $SVC_NAME" systemctl status --no-pager --lines=15 "$SVC_NAME"
                ;;
            *)
                send_ack "error" "Service non autorise : $SVC_NAME" 0
                ;;
        esac
        ;;

    # ════════════════════════════════════════════════════════════════════════
    # §F'4 — WRITE / SYSTEME (3 commandes)
    # ════════════════════════════════════════════════════════════════════════

    apt_update_check)
        # Mappé sur update.sh --check (dry-run, respecte les versions pinned)
        if [[ -x /usr/local/bin/update.sh ]] || [[ -x /opt/Cryoss/update.sh ]]; then
            UPDATE_BIN=$(command -v update.sh 2>/dev/null || echo /opt/Cryoss/update.sh)
            run_cmd "update.sh --check" "$UPDATE_BIN" --check
        else
            send_ack "error" "update.sh introuvable (cryoss non à jour ?)" 0
        fi
        ;;

    apt_upgrade)
        # Mappé sur update.sh complet (snapshot RAID + upgrade + verif post)
        UPDATE_BIN=""
        for cand in /usr/local/bin/update.sh /opt/Cryoss/update.sh; do
            [[ -x "$cand" ]] && { UPDATE_BIN="$cand"; break; }
        done
        if [[ -z "$UPDATE_BIN" ]]; then
            send_ack "error" "update.sh introuvable" 0
        else
            # Long : timeout étendu pour cette commande
            CMD_TIMEOUT=1800 run_cmd "update.sh (apt_upgrade)" "$UPDATE_BIN"
        fi
        ;;

    shutdown)
        SHUTDOWN_REASON=$(json_get "shutdown_reason" "$CMD_PARAMS")
        if [[ -z "$SHUTDOWN_REASON" ]]; then
            send_ack "error" "shutdown_reason parameter required" 0
            exit 1
        fi
        # Persister la raison pour audit local
        mkdir -p /var/lib/cryoss
        {
            echo "ts=$(date -Iseconds)"
            echo "command_id=$CMD_ID"
            printf 'reason=%s\n' "$SHUTDOWN_REASON"
        } > /var/lib/cryoss/last-shutdown.txt
        chmod 600 /var/lib/cryoss/last-shutdown.txt
        log WARN "SHUTDOWN programme par Analyss (cmd=$CMD_ID, reason=$SHUTDOWN_REASON)"
        send_ack "ok" "Shutdown programme dans 30s, reason=$SHUTDOWN_REASON" 0
        # Muter le watchdog local pendant la fenetre 30s : il fire toutes les 15min
        # et detecterait les services en cours d'arret -> alerte email parasite
        # (cf. P0 fix v4 §5). En attente de expected_silence_minutes cote Console.
        systemctl stop cryoss-watchdog.timer 2>/dev/null || true
        (sleep 30 && systemctl poweroff) &
        ;;

    # ════════════════════════════════════════════════════════════════════════
    # §G — DECHIFFREMENT PAR CHEMIN
    # ════════════════════════════════════════════════════════════════════════

    list_backups)
        # Enumération JSON via rclone ls sur les 3 chaînes crypt.
        # Output : [{path, size_bytes, modified_at, encrypted, chain}]
        run_cmd "list_backups" bash -c '
            python3 - <<'"'"'PYEOF'"'"'
import json, subprocess, sys
out = []
for chain in ("c1", "c2", "c3"):
    remote = f"cryoss-{chain}-crypt:"
    if not subprocess.run(["rclone", "listremotes"], capture_output=True, text=True).stdout.count(remote):
        continue
    try:
        r = subprocess.run(
            ["rclone", "lsjson", "-R", remote, "--no-mimetype"],
            capture_output=True, text=True, timeout=60
        )
        if r.returncode != 0:
            continue
        for entry in json.loads(r.stdout or "[]"):
            if entry.get("IsDir"):
                continue
            out.append({
                "path": entry.get("Path"),
                "size_bytes": entry.get("Size"),
                "modified_at": entry.get("ModTime"),
                "encrypted": True,
                "chain": chain,
            })
    except (subprocess.TimeoutExpired, json.JSONDecodeError):
        continue
print(json.dumps(out, ensure_ascii=False))
PYEOF
        '
        ;;

    decrypt_path)
        # Contrat v4 : params `chain` + `rclone_path` (chain-relative, pas de
        # FS prefix). c2/c3 sont SFTP-backed donc /etc/encrypted n'est PAS
        # leur namespace storage — le runner passe rclone_path verbatim au
        # remote crypt et ne touche pas le FS local.
        DECRYPT_CHAIN=$(json_get "chain" "$CMD_PARAMS")
        DECRYPT_RPATH=$(json_get "rclone_path" "$CMD_PARAMS")

        case "$DECRYPT_CHAIN" in
            c1|c2|c3) ;;
            *)
                send_ack "error" "chain parameter required (c1|c2|c3)" 0
                exit 1
                ;;
        esac

        # Validation rclone_path (defense in depth — la Console valide deja)
        if [[ -z "$DECRYPT_RPATH" ]]; then
            send_ack "error" "rclone_path parameter required" 0; exit 1
        fi
        if (( ${#DECRYPT_RPATH} > 499 )); then
            send_ack "error" "rclone_path too long (>499 chars)" 0; exit 1
        fi
        if [[ "$DECRYPT_RPATH" == /* ]]; then
            send_ack "error" "rclone_path must not start with '/'" 0; exit 1
        fi
        if [[ "$DECRYPT_RPATH" == *..* ]]; then
            send_ack "error" "rclone_path contains '..'" 0; exit 1
        fi
        if [[ "$DECRYPT_RPATH" == *//* ]]; then
            send_ack "error" "rclone_path contains '//'" 0; exit 1
        fi
        if [[ ! "$DECRYPT_RPATH" =~ ^[A-Za-z0-9_./-]+$ ]]; then
            send_ack "error" "rclone_path invalid charset (allowed: A-Z a-z 0-9 _ . / -)" 0; exit 1
        fi

        DECRYPT_DEST="${CRYOSS_DECRYPT_DIR}/${CMD_ID}"
        mkdir -p "$DECRYPT_DEST"
        chmod 700 "$DECRYPT_DEST"
        chown root:root "$DECRYPT_DEST"

        # Marker pour le timer de cleanup (TTL en heures)
        date -d "+${CRYOSS_DECRYPT_TTL_HOURS} hours" +%s > "$DECRYPT_DEST/.expires_at" 2>/dev/null || true

        # Audit immédiat : alerte email (From: alertes@habyss.fr via msmtp)
        if [[ -f "$EMAIL_LIB" ]]; then
            ( source "$EMAIL_LIB" 2>/dev/null
              if declare -F send_email_wrapped &>/dev/null; then
                BODY=$(alert_banner "Déchiffrement à la demande déclenché" "warn")
                BODY+=$(section_open "REQUEST")
                BODY+=$(mrow "Command ID"  "$CMD_ID")
                BODY+=$(mrow "Chain"       "$DECRYPT_CHAIN")
                BODY+=$(mrow "rclone path" "$DECRYPT_RPATH")
                BODY+=$(mrow "Destination" "$DECRYPT_DEST")
                BODY+=$(mrow "TTL"         "${CRYOSS_DECRYPT_TTL_HOURS}h")
                BODY+=$(section_close)
                send_email_wrapped \
                    "[Cryoss] AUDIT — decrypt_path déclenché ($DECRYPT_CHAIN)" \
                    "Déchiffrement à la demande" \
                    "$BODY" "warn" || true
              fi
            ) &
        fi

        REMOTE="cryoss-${DECRYPT_CHAIN}-crypt:${DECRYPT_RPATH}"
        log INFO "decrypt_path: $REMOTE -> $DECRYPT_DEST (cmd=$CMD_ID)"

        if rclone copy "$REMOTE" "$DECRYPT_DEST" --contimeout 30s --timeout 120s 2>>/var/log/cryoss-command.log; then
            EXPIRES_AT=$(date -d "+${CRYOSS_DECRYPT_TTL_HOURS} hours" -Iseconds 2>/dev/null || echo "")
            JSON_OUTPUT=$(CHAIN="$DECRYPT_CHAIN" DEST="$DECRYPT_DEST" EXP="$EXPIRES_AT" python3 -c '
import os, json
print(json.dumps({
    "decrypted_path": os.environ["DEST"],
    "chain": os.environ["CHAIN"],
    "expires_at": os.environ["EXP"],
}))')
            send_ack "ok" "$JSON_OUTPUT" 0
        else
            rm -rf "$DECRYPT_DEST" 2>/dev/null || true
            send_ack "error" "rclone decrypt failed (chain=$DECRYPT_CHAIN, see /var/log/cryoss-command.log)" 0
        fi
        ;;

    # ════════════════════════════════════════════════════════════════════════
    # §I — SAMBA USERS (6 commandes, profil Cryoss : pas de create_system_user)
    # ════════════════════════════════════════════════════════════════════════

    samba_user_list)
        # Output JSON depuis pdbedit -L -v (parsing Python). Cache 60s.
        OUT=$(samba_users_json)
        send_ack "ok" "$OUT" 0
        ;;

    samba_user_add)
        SU_NAME=$(json_get "username" "$CMD_PARAMS")
        SU_PWD_RAW=$(json_get "password" "$CMD_PARAMS")
        if ! valid_samba_name "$SU_NAME"; then
            send_ack "error" "invalid username (pattern [a-z][a-z0-9_-]{1,31})" 0
            exit 1
        fi
        if is_protected_user "$SU_NAME"; then
            send_ack "error" "user '$SU_NAME' is protected (cannot add)" 0
            exit 1
        fi
        # Etat partiel : user dans /etc/passwd OU dans Samba ?
        UNIX_EXISTS=no; SMB_EXISTS=no
        id "$SU_NAME" &>/dev/null && UNIX_EXISTS=yes
        pdbedit -L 2>/dev/null | grep -q "^${SU_NAME}:" && SMB_EXISTS=yes
        if [[ "$UNIX_EXISTS" == yes && "$SMB_EXISTS" == yes ]]; then
            send_ack "error" "user '$SU_NAME' already exists (Unix+Samba) — refusing silent overwrite" 0
            exit 1
        fi
        if [[ "$UNIX_EXISTS" == yes && "$SMB_EXISTS" == no ]]; then
            send_ack "error" "partial state: '$SU_NAME' exists in Unix but not Samba — manual review required" 0
            exit 1
        fi
        if [[ "$UNIX_EXISTS" == no && "$SMB_EXISTS" == yes ]]; then
            send_ack "error" "partial state: '$SU_NAME' exists in Samba but not Unix — manual review required" 0
            exit 1
        fi
        # Decrypt password (param sensible)
        SU_PWD=$(decrypt_secret_or_die "$SU_PWD_RAW") || exit 1
        if (( ${#SU_PWD} < 8 )); then
            unset SU_PWD
            send_ack "error" "password too short (min 8 chars)" 0
            exit 1
        fi
        # Création stricte (profil Cryoss)
        groupadd -f samba-share
        if ! useradd -r -M -s /usr/sbin/nologin -d /nonexistent -G samba-share "$SU_NAME"; then
            unset SU_PWD
            send_ack "error" "useradd failed" 0
            exit 1
        fi
        passwd -l "$SU_NAME" >/dev/null 2>&1 || true
        if ! printf '%s\n%s\n' "$SU_PWD" "$SU_PWD" | smbpasswd -s -a "$SU_NAME" >/dev/null 2>&1; then
            unset SU_PWD
            userdel "$SU_NAME" 2>/dev/null || true   # rollback Unix
            send_ack "error" "smbpasswd failed" 0
            exit 1
        fi
        smbpasswd -e "$SU_NAME" >/dev/null 2>&1 || true
        unset SU_PWD
        # Persister dans la metadata wizard
        shares_metadata_init
        echo "USER $SU_NAME" >> "$SHARES_METADATA"
        rm -f "$SAMBA_USER_CACHE" 2>/dev/null
        send_ack "ok" "user '$SU_NAME' created (samba-only)" 0
        ;;

    samba_user_delete)
        SU_NAME=$(json_get "username" "$CMD_PARAMS")
        if ! valid_samba_name "$SU_NAME"; then
            send_ack "error" "invalid username" 0; exit 1
        fi
        if is_protected_user "$SU_NAME"; then
            send_ack "error" "user '$SU_NAME' is protected" 0; exit 1
        fi
        if ! id "$SU_NAME" &>/dev/null && ! pdbedit -L 2>/dev/null | grep -q "^${SU_NAME}:"; then
            send_ack "error" "user '$SU_NAME' does not exist" 0; exit 1
        fi
        smbpasswd -x "$SU_NAME" >/dev/null 2>&1 || true
        userdel "$SU_NAME" >/dev/null 2>&1 || true
        # Retirer de la metadata + perms associées
        if [[ -f "$SHARES_METADATA" ]]; then
            sed -i "/^USER ${SU_NAME}\([[:space:]]\|$\)/d" "$SHARES_METADATA"
            sed -i "/^PERM [^[:space:]]\+ ${SU_NAME} /d" "$SHARES_METADATA"
        fi
        samba_shares_regen_and_reload || true
        rm -f "$SAMBA_USER_CACHE" 2>/dev/null
        send_ack "ok" "user '$SU_NAME' deleted" 0
        ;;

    samba_user_set_password)
        SU_NAME=$(json_get "username" "$CMD_PARAMS")
        SU_PWD_RAW=$(json_get "password" "$CMD_PARAMS")
        if ! valid_samba_name "$SU_NAME"; then
            send_ack "error" "invalid username" 0; exit 1
        fi
        if is_protected_user "$SU_NAME"; then
            send_ack "error" "user '$SU_NAME' is protected" 0; exit 1
        fi
        if ! pdbedit -L 2>/dev/null | grep -q "^${SU_NAME}:"; then
            send_ack "error" "user '$SU_NAME' does not exist in Samba" 0; exit 1
        fi
        SU_PWD=$(decrypt_secret_or_die "$SU_PWD_RAW") || exit 1
        if (( ${#SU_PWD} < 8 )); then
            unset SU_PWD
            send_ack "error" "password too short (min 8 chars)" 0; exit 1
        fi
        if printf '%s\n%s\n' "$SU_PWD" "$SU_PWD" | smbpasswd -s "$SU_NAME" >/dev/null 2>&1; then
            unset SU_PWD
            rm -f "$SAMBA_USER_CACHE" 2>/dev/null
            send_ack "ok" "password updated for '$SU_NAME'" 0
        else
            unset SU_PWD
            send_ack "error" "smbpasswd failed" 0
        fi
        ;;

    samba_user_disable)
        SU_NAME=$(json_get "username" "$CMD_PARAMS")
        if ! valid_samba_name "$SU_NAME" || is_protected_user "$SU_NAME"; then
            send_ack "error" "invalid or protected username" 0; exit 1
        fi
        if smbpasswd -d "$SU_NAME" >/dev/null 2>&1; then
            rm -f "$SAMBA_USER_CACHE" 2>/dev/null
            send_ack "ok" "user '$SU_NAME' disabled in Samba" 0
        else
            send_ack "error" "smbpasswd -d failed" 0
        fi
        ;;

    samba_user_enable)
        SU_NAME=$(json_get "username" "$CMD_PARAMS")
        if ! valid_samba_name "$SU_NAME" || is_protected_user "$SU_NAME"; then
            send_ack "error" "invalid or protected username" 0; exit 1
        fi
        if smbpasswd -e "$SU_NAME" >/dev/null 2>&1; then
            rm -f "$SAMBA_USER_CACHE" 2>/dev/null
            send_ack "ok" "user '$SU_NAME' enabled in Samba" 0
        else
            send_ack "error" "smbpasswd -e failed" 0
        fi
        ;;

    # ════════════════════════════════════════════════════════════════════════
    # §I — SAMBA SHARES (4 commandes)
    # ════════════════════════════════════════════════════════════════════════

    samba_share_list)
        # Output JSON depuis la metadata (source de vérité)
        OUT=$(samba_shares_json)
        send_ack "ok" "$OUT" 0
        ;;

    samba_share_add)
        SH_NAME=$(json_get "name" "$CMD_PARAMS")
        SH_PATH=$(json_get "path" "$CMD_PARAMS")
        SH_VALID=$(json_get_array_csv "valid_users" "$CMD_PARAMS")
        SH_WRITE=$(json_get_array_csv "write_list" "$CMD_PARAMS")
        SH_RO=$(json_get "read_only" "$CMD_PARAMS")
        if ! valid_samba_name "$SH_NAME"; then
            send_ack "error" "invalid share name" 0; exit 1
        fi
        if is_protected_share "$SH_NAME"; then
            send_ack "error" "share '$SH_NAME' is protected" 0; exit 1
        fi
        validate_path_in_root "$SH_PATH" "$CRYOSS_SHARE_ROOT" "no" || exit 1
        # Idempotence : refuser overwrite silencieux
        if [[ -f "$SHARES_METADATA" ]] && grep -qE "^SHARE ${SH_NAME} " "$SHARES_METADATA"; then
            send_ack "error" "share '$SH_NAME' already exists — use samba_share_modify" 0; exit 1
        fi
        # Créer le dossier (idempotent)
        mkdir -p "$SH_PATH"
        chown root:samba-share "$SH_PATH"
        chmod 2770 "$SH_PATH"
        # Ecrire metadata
        shares_metadata_init
        {
            echo "SHARE $SH_NAME $SH_PATH"
            for u in $SH_VALID; do
                # Si user dans write_list ET valid_users → rw, sinon r
                level="r"
                for w in $SH_WRITE; do
                    [[ "$w" == "$u" ]] && level="rw"
                done
                # Si read_only true ET pas dans write_list → forcer r
                if [[ "${SH_RO:-false}" == "true" ]] && [[ "$level" == "rw" ]]; then
                    # write_list ⊆ valid_users mais read_only=true → contradiction → ignore RW
                    level="r"
                fi
                echo "PERM $SH_NAME $u $level"
            done
        } >> "$SHARES_METADATA"
        if samba_shares_regen_and_reload; then
            send_ack "ok" "share '$SH_NAME' created at $SH_PATH" 0
        else
            send_ack "error" "share metadata written but Samba reload failed (testparm or smbcontrol)" 0
        fi
        ;;

    samba_share_modify)
        SH_NAME=$(json_get "name" "$CMD_PARAMS")
        SH_PATH=$(json_get "path" "$CMD_PARAMS")
        SH_VALID=$(json_get_array_csv "valid_users" "$CMD_PARAMS")
        SH_WRITE=$(json_get_array_csv "write_list" "$CMD_PARAMS")
        SH_RO=$(json_get "read_only" "$CMD_PARAMS")
        if ! valid_samba_name "$SH_NAME"; then
            send_ack "error" "invalid share name" 0; exit 1
        fi
        if is_protected_share "$SH_NAME"; then
            send_ack "error" "share '$SH_NAME' is protected" 0; exit 1
        fi
        if [[ -n "$SH_PATH" ]]; then
            validate_path_in_root "$SH_PATH" "$CRYOSS_SHARE_ROOT" "no" || exit 1
        fi
        if [[ ! -f "$SHARES_METADATA" ]] || ! grep -qE "^SHARE ${SH_NAME} " "$SHARES_METADATA"; then
            send_ack "error" "share '$SH_NAME' does not exist" 0; exit 1
        fi
        # Retirer les anciennes lignes de ce share
        sed -i "/^SHARE ${SH_NAME} /d" "$SHARES_METADATA"
        sed -i "/^PERM ${SH_NAME} /d" "$SHARES_METADATA"
        # Path : si non fourni, on récupère l'ancien (déjà supprimé) → erreur. Imposer fourni.
        if [[ -z "$SH_PATH" ]]; then
            send_ack "error" "path parameter required for samba_share_modify" 0; exit 1
        fi
        mkdir -p "$SH_PATH"
        chown root:samba-share "$SH_PATH"
        chmod 2770 "$SH_PATH"
        {
            echo "SHARE $SH_NAME $SH_PATH"
            for u in $SH_VALID; do
                level="r"
                for w in $SH_WRITE; do
                    [[ "$w" == "$u" ]] && level="rw"
                done
                if [[ "${SH_RO:-false}" == "true" ]] && [[ "$level" == "rw" ]]; then
                    level="r"
                fi
                echo "PERM $SH_NAME $u $level"
            done
        } >> "$SHARES_METADATA"
        if samba_shares_regen_and_reload; then
            send_ack "ok" "share '$SH_NAME' modified" 0
        else
            send_ack "error" "metadata updated but Samba reload failed" 0
        fi
        ;;

    samba_share_delete)
        SH_NAME=$(json_get "name" "$CMD_PARAMS")
        if ! valid_samba_name "$SH_NAME"; then
            send_ack "error" "invalid share name" 0; exit 1
        fi
        if is_protected_share "$SH_NAME"; then
            send_ack "error" "share '$SH_NAME' is protected" 0; exit 1
        fi
        if [[ ! -f "$SHARES_METADATA" ]] || ! grep -qE "^SHARE ${SH_NAME} " "$SHARES_METADATA"; then
            send_ack "error" "share '$SH_NAME' does not exist" 0; exit 1
        fi
        # IMPORTANT : on ne supprime PAS les fichiers sur disque (don't-delete-data)
        sed -i "/^SHARE ${SH_NAME} /d" "$SHARES_METADATA"
        sed -i "/^PERM ${SH_NAME} /d" "$SHARES_METADATA"
        if samba_shares_regen_and_reload; then
            send_ack "ok" "share '$SH_NAME' deleted (files on disk preserved)" 0
        else
            send_ack "error" "metadata updated but Samba reload failed" 0
        fi
        ;;

    # ────────────────────────────────────────────────────────────────────────
    # DEFAULT : commande inconnue
    # ────────────────────────────────────────────────────────────────────────
    *)
        log ERROR "Commande inconnue (refusee) : $CMD_TYPE"
        send_ack "error" "Commande inconnue : $CMD_TYPE" 0
        exit 1
        ;;
esac
