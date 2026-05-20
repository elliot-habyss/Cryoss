#!/usr/bin/env bash
# =============================================================================
# cryoss-heartbeat.sh
# Script de heartbeat Cryoss - Modele agent "phone-home" (DeepGiciel)
#
# Fonction : Collecte les donnees de sante du Raspberry Pi et les envoie
#            au serveur central Analyss via HTTPS toutes les 5 minutes.
#
# Usage :
#   cryoss-heartbeat.sh              # Heartbeat normal (mode par defaut)
#   cryoss-heartbeat.sh register     # Enregistrement initial aupres d'Analyss
#
# Configuration : /etc/cryoss/analyss.conf
# Logs :          /var/log/cryoss-heartbeat.log
# =============================================================================

set -uo pipefail
# Pas de -e : on gere les erreurs manuellement pour eviter les arrets silencieux
# qui casseraient le timer systemd.

# -----------------------------------------------------------------------------
# Constantes
# -----------------------------------------------------------------------------
readonly CONF_FILE="/etc/cryoss/analyss.conf"
readonly LOG_FILE="/var/log/cryoss-heartbeat.log"
readonly CONF_DIR="/etc/cryoss"
readonly VERSION="1.0.0"

# Timeout curl (secondes) - on ne bloque pas le timer trop longtemps
readonly CURL_TIMEOUT=15
readonly CURL_CONNECT_TIMEOUT=10

# Adresse IP du RPi2 sur le reseau interne
readonly RPI2_IP="10.42.0.2"

# Services a surveiller
readonly -a SERVICES=(
    "cryoss-backup.timer"
    "cryoss-health-daily.timer"
    "cryoss-watchdog.timer"
    "cryoss-api"
    "smbd"
    "ssh"
    "fail2ban"
)

# -----------------------------------------------------------------------------
# Fonctions utilitaires
# -----------------------------------------------------------------------------

# Journalise un message dans le fichier de log avec horodatage
log() {
    local level="$1"
    shift
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*" >> "$LOG_FILE"
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

# Termine proprement avec un code 0 (ne pas casser le timer systemd)
die_graceful() {
    log_warn "$1"
    exit 0
}

# -----------------------------------------------------------------------------
# Chargement de la configuration
# -----------------------------------------------------------------------------
load_config() {
    # Creer le repertoire de config s'il n'existe pas
    if [[ ! -d "$CONF_DIR" ]]; then
        mkdir -p "$CONF_DIR" 2>/dev/null || {
            log_error "Impossible de creer $CONF_DIR"
            return 1
        }
    fi

    # Creer le fichier de config par defaut s'il n'existe pas
    if [[ ! -f "$CONF_FILE" ]]; then
        cat > "$CONF_FILE" <<'CONF'
# Configuration Cryoss Heartbeat
# URL du serveur Analyss central
ANALYSS_URL="https://app.analyss.fr"

# Cle API (remplie automatiquement lors de l'enregistrement)
ANALYSS_API_KEY=""
CONF
        chmod 600 "$CONF_FILE"
        log_info "Fichier de configuration cree : $CONF_FILE"
    fi

    # Charger la configuration
    # shellcheck source=/etc/cryoss/analyss.conf
    source "$CONF_FILE" || {
        log_error "Impossible de lire $CONF_FILE"
        return 1
    }

    # Valider l'URL
    if [[ -z "${ANALYSS_URL:-}" ]]; then
        log_error "ANALYSS_URL non definie dans $CONF_FILE"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Detection du role (rpi1 ou rpi2)
# -----------------------------------------------------------------------------
detect_role() {
    # Si le script de backup existe, c'est le RPi1 (serveur principal)
    if [[ -f "/usr/local/bin/cryoss-backup.sh" ]]; then
        echo "rpi1"
        return
    fi

    # Si l'adresse IP 10.42.0.2 est configuree, c'est le RPi2 (replique)
    if ip addr show 2>/dev/null | grep -q "$RPI2_IP"; then
        echo "rpi2"
        return
    fi

    # Role inconnu - on continue quand meme
    echo "unknown"
}

# -----------------------------------------------------------------------------
# Recuperation du numero de serie Cryoss
# -----------------------------------------------------------------------------
get_serial() {
    # Numero de serie stocke dans la config Cryoss
    if [[ -f "/etc/cryoss/serial" ]]; then
        cat "/etc/cryoss/serial" 2>/dev/null
        return
    fi

    # Fallback : numero de serie materiel du Raspberry Pi
    if [[ -f "/proc/cpuinfo" ]]; then
        grep -i "serial" /proc/cpuinfo 2>/dev/null | awk '{print $3}' | head -1
        return
    fi

    echo "UNKNOWN"
}

# -----------------------------------------------------------------------------
# Collecte des metriques systeme
# -----------------------------------------------------------------------------

# Temperature CPU en degres Celsius
get_cpu_temp() {
    local temp_file="/sys/class/thermal/thermal_zone0/temp"
    if [[ -f "$temp_file" ]]; then
        local raw
        raw=$(cat "$temp_file" 2>/dev/null)
        if [[ -n "$raw" ]]; then
            # Conversion millidegres -> degres via awk (toujours dispo, pas bc)
            awk -v v="$raw" 'BEGIN{printf "%.1f", v/1000}' 2>/dev/null || echo "0"
            return
        fi
    fi
    echo "0"
}

# Charge systeme (1 minute)
get_load_1m() {
    awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0"
}

# Utilisation memoire (en Mo)
get_ram_info() {
    # Retourne "used_mb total_mb"
    free -m 2>/dev/null | awk '/^Mem:/ {print $3, $2}' || echo "0 0"
}

# Uptime lisible
get_uptime() {
    uptime -p 2>/dev/null || uptime 2>/dev/null | sed 's/.*up /up /' | sed 's/,.*//'
}

# Nettoyer une valeur pour insertion dans un JSON string :
# - supprime les caracteres de controle (qui causent "Invalid control character")
# - supprime les quotes (evite de casser le JSON)
# - supprime les backslashes (evite les echappements malform)
# - trim les espaces/newlines en debut et fin
_clean_json_string() {
    printf '%s' "$1" | tr -d '\000-\037' | sed 's/["\\]//g' | awk '{$1=$1}1' | tr -d '\n'
}

# -----------------------------------------------------------------------------
# Etat du RAID (mdstat)
# -----------------------------------------------------------------------------
get_raid_json() {
    local raid_json="{"
    local first=true

    if [[ ! -f "/proc/mdstat" ]]; then
        echo "{}"
        return
    fi

    # Parcourir chaque peripherique md dans /proc/mdstat
    while IFS= read -r md_device; do
        local md_name
        md_name=$(echo "$md_device" | awk '{print $1}')

        # Lire la ligne d'etat (celle avec les [UU])
        local state_line
        state_line=$(grep -A 2 "^${md_name}" /proc/mdstat 2>/dev/null | tail -1)

        # Verifier si tous les disques sont actifs (UU = sain, _U ou U_ = degrade)
        local healthy="true"
        if echo "$state_line" | grep -q "_"; then
            healthy="false"
        fi

        # Determiner l'etat general
        local state="active"
        if [[ "$healthy" == "false" ]]; then
            state="degraded"
        fi

        if [[ "$first" == "true" ]]; then
            first=false
        else
            raid_json+=","
        fi

        raid_json+="\"${md_name}\":{\"state\":\"${state}\",\"healthy\":${healthy}}"
    done < <(grep "^md" /proc/mdstat 2>/dev/null | awk '{print $1}')

    raid_json+="}"
    echo "$raid_json"
}

# -----------------------------------------------------------------------------
# Utilisation disque
# -----------------------------------------------------------------------------
get_disk_json() {
    local disk_json="{"
    local first=true
    local -a mount_points=("/etc/sauvegarde" "/etc/encrypted")

    for mp in "${mount_points[@]}"; do
        if [[ -d "$mp" ]]; then
            # df en Go, avec pourcentage
            local df_line
            df_line=$(df -BG "$mp" 2>/dev/null | tail -1)

            if [[ -n "$df_line" ]]; then
                local used_gb total_gb used_pct
                # Extraire les valeurs (enlever le suffixe 'G')
                total_gb=$(echo "$df_line" | awk '{gsub(/G/,"",$2); print $2}')
                used_gb=$(echo "$df_line" | awk '{gsub(/G/,"",$3); print $3}')
                used_pct=$(echo "$df_line" | awk '{gsub(/%/,"",$5); print $5}')

                if [[ "$first" == "true" ]]; then
                    first=false
                else
                    disk_json+=","
                fi

                disk_json+="\"${mp}\":{\"used_pct\":${used_pct:-0},\"used_gb\":${used_gb:-0},\"total_gb\":${total_gb:-0}}"
            fi
        fi
    done

    disk_json+="}"
    echo "$disk_json"
}

# -----------------------------------------------------------------------------
# Etat des services systemd
# -----------------------------------------------------------------------------
get_services_json() {
    local svc_json="{"
    local first=true

    for svc in "${SERVICES[@]}"; do
        local status
        status=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")

        if [[ "$first" == "true" ]]; then
            first=false
        else
            svc_json+=","
        fi

        svc_json+="\"${svc}\":\"${status}\""
    done

    svc_json+="}"
    echo "$svc_json"
}

# -----------------------------------------------------------------------------
# Informations de backup (RPi1)
# Source de verite : manifeste JSON ecrit par cryoss-backup.sh a chaque run.
# Fonctionne pour les runs systemd ET manuels (CLI).
# Fallback 1 : parser le log /var/log/cryoss-backup.log (ligne "Bilan")
# Fallback 2 : journalctl (systemd uniquement)
# -----------------------------------------------------------------------------
get_backup_json_rpi1() {
    local last_run="" last_status="unknown" archive_count=0
    local c1_status="unknown" c2_status="unknown" c3_status="unknown" restore_status="unknown"

    # 1. Source primaire : manifeste JSON le plus recent
    local latest_manifest
    latest_manifest=$(ls -t /var/lib/cryoss/manifests/manifest-*.json 2>/dev/null | head -1)
    if [[ -n "$latest_manifest" && -f "$latest_manifest" ]]; then
        # Nettoyer chaque champ pour eviter les caracteres de controle
        last_run=$(_clean_json_string "$(grep -oP '"timestamp"\s*:\s*"\K[^"]*' "$latest_manifest" 2>/dev/null | head -1)")
        c1_status=$(_clean_json_string "$(grep -oP '"c1_status"\s*:\s*"\K[^"]*' "$latest_manifest" 2>/dev/null | head -1)")
        c2_status=$(_clean_json_string "$(grep -oP '"c2_status"\s*:\s*"\K[^"]*' "$latest_manifest" 2>/dev/null | head -1)")
        c3_status=$(_clean_json_string "$(grep -oP '"c3_status"\s*:\s*"\K[^"]*' "$latest_manifest" 2>/dev/null | head -1)")
        restore_status=$(_clean_json_string "$(grep -oP '"restore_test"\s*:\s*"\K[^"]*' "$latest_manifest" 2>/dev/null | head -1)")

        # Determiner le statut global
        # "success" uniquement si C1 et C2 OK et restore non-echec
        # (C3 peut etre desactive, on l'ignore dans ce cas)
        if [[ "$c1_status" == "ok" && "$c2_status" == "ok" ]] \
           && [[ "$restore_status" != "echec-hash" && "$restore_status" != "echec-rclone" ]]; then
            last_status="success"
        elif [[ "$c1_status" == "error" || "$c2_status" == "error" || "$restore_status" == "echec-hash" ]]; then
            last_status="error"
        fi
    fi

    # 2. Fallback : parser le log /var/log/cryoss-backup.log (ligne "Bilan")
    if [[ "$last_status" == "unknown" ]] && [[ -f "/var/log/cryoss-backup.log" ]]; then
        local bilan_line
        bilan_line=$(grep "======== Bilan" /var/log/cryoss-backup.log 2>/dev/null | tail -1)
        if [[ -n "$bilan_line" ]]; then
            # Timestamp au debut de la ligne : [2026-04-17 08:53:41]
            if [[ -z "$last_run" ]]; then
                last_run=$(echo "$bilan_line" | grep -oP '^\[\K[^]]*' | sed 's/ /T/')
            fi
            local total
            total=$(echo "$bilan_line" | grep -oP 'total=\K[0-9]+')
            if [[ "$total" == "0" ]]; then
                last_status="success"
            elif [[ -n "$total" ]]; then
                last_status="error"
            fi
        fi
    fi

    # 3. Dernier fallback : journalctl pour le timestamp si rien trouve
    if [[ -z "$last_run" ]]; then
        last_run=$(journalctl -u cryoss-backup.service --no-pager -n 1 \
            --output=short-iso 2>/dev/null | head -1 | awk '{print $1}')
    fi

    # Nombre d'archives dans /etc/encrypted
    if [[ -d "/etc/encrypted" ]]; then
        archive_count=$(find /etc/encrypted -maxdepth 1 -type f 2>/dev/null | wc -l)
    fi

    echo "{\"last_run\":\"${last_run}\",\"last_status\":\"${last_status}\",\"archive_count\":${archive_count},\"c1_status\":\"${c1_status}\",\"c2_status\":\"${c2_status}\",\"c3_status\":\"${c3_status}\",\"restore_test\":\"${restore_status}\"}"
}

# -----------------------------------------------------------------------------
# Donnees completes du RPi2 (collectees depuis RPi1 via SSH interco)
# RPi2 est air-gapped — il ne communique PAS directement avec Analyss.
# RPi1 collecte ses donnees et les inclut dans son propre heartbeat.
# -----------------------------------------------------------------------------
get_rpi2_full_json() {
    # Specifier explicitement la cle SSH - sinon SSH cherche dans les defaults
    # de l'utilisateur qui lance le script (root via systemd). La cle cryoss_rpi2
    # est dans /root/.ssh/ et n'est pas un nom par defaut (id_rsa, id_ed25519).
    local SSH_KEY="/root/.ssh/cryoss_rpi2"
    local SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no"
    [[ -f "$SSH_KEY" ]] && SSH_OPTS="-i $SSH_KEY $SSH_OPTS"
    local SSH="ssh $SSH_OPTS habyss@${RPI2_IP}"

    # Test de connectivite
    local ping_result
    ping_result=$(ping -c 1 -W 3 "$RPI2_IP" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        echo "{\"reachable\":false}"
        return
    fi

    local ping_ms
    ping_ms=$(echo "$ping_result" | grep "time=" | sed 's/.*time=\([0-9.]*\).*/\1/')
    ping_ms="${ping_ms:-0}"

    # Collecter les donnees via SSH (une seule connexion, script inline)
    local rpi2_data
    rpi2_data=$($SSH bash 2>/dev/null <<'REMOTE_EOF'
# Script execute sur RPi2 via SSH depuis RPi1
# Hostname
HN=$(hostname 2>/dev/null || echo "unknown")

# Uptime
UP=$(uptime -p 2>/dev/null || echo "unknown")

# CPU temp
TEMP=0
[[ -f /sys/class/thermal/thermal_zone0/temp ]] && \
    TEMP=$(awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "0")

# Load
LOAD=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0")

# RAM
RAM_USED=$(free -m 2>/dev/null | awk '/^Mem:/{print $3}' || echo "0")
RAM_TOTAL=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0")

# RAID
RAID_HEALTHY="true"
RAID_STATE="active"
if grep -q "_" /proc/mdstat 2>/dev/null; then
    RAID_HEALTHY="false"
    RAID_STATE="degraded"
fi

# Disque /etc/encrypted
DISK_USED_PCT=$(df /etc/encrypted 2>/dev/null | tail -1 | awk '{gsub(/%/,"",$5); print $5}')
DISK_USED_GB=$(df -BG /etc/encrypted 2>/dev/null | tail -1 | awk '{gsub(/G/,"",$3); print $3}')
DISK_TOTAL_GB=$(df -BG /etc/encrypted 2>/dev/null | tail -1 | awk '{gsub(/G/,"",$2); print $2}')
DISK_USED_PCT="${DISK_USED_PCT:-0}"
DISK_USED_GB="${DISK_USED_GB:-0}"
DISK_TOTAL_GB="${DISK_TOTAL_GB:-0}"

# Services
SVC_SSH=$(systemctl is-active ssh 2>/dev/null || echo "unknown")
SVC_F2B=$(systemctl is-active fail2ban 2>/dev/null || echo "unknown")
SVC_API=$(systemctl is-active cryoss-api 2>/dev/null || echo "unknown")
SVC_HEALTH=$(systemctl is-active cryoss-health-daily.timer 2>/dev/null || echo "unknown")

# Reception (fichiers rclone chiffres recus depuis RPi1)
# Chercher dans /etc/encrypted/rpi1 (convention) puis fallback /etc/encrypted
RECV_DIR="/etc/encrypted/rpi1"
[[ ! -d "$RECV_DIR" ]] && RECV_DIR="/etc/encrypted"
RECV_COUNT=$(find "$RECV_DIR" -type f 2>/dev/null | wc -l)
RECV_NEWEST=$(find "$RECV_DIR" -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
RECV_AGE_H="null"
RECV_TIMESTAMP="null"
if [[ -n "$RECV_NEWEST" && "$RECV_NEWEST" != "0" ]]; then
    NOW=$(date +%s)
    RECV_TS_INT="${RECV_NEWEST%.*}"
    AGE_S=$((NOW - RECV_TS_INT))
    if [[ "$AGE_S" -ge 0 && "$AGE_S" -lt 31536000 ]]; then
        # Age raisonnable (< 1 an) — calculer en heures
        RECV_AGE_H=$((AGE_S / 3600))
        RECV_TIMESTAMP="$RECV_TS_INT"
    fi
fi

# Sortir le JSON
cat <<RJSON
{
  "hostname":"${HN}",
  "uptime":"${UP}",
  "cpu_temp_c":${TEMP},
  "load_1m":${LOAD},
  "ram_used_mb":${RAM_USED},
  "ram_total_mb":${RAM_TOTAL},
  "raid":{"md0":{"state":"${RAID_STATE}","healthy":${RAID_HEALTHY}}},
  "disks":{"/etc/encrypted":{"used_pct":${DISK_USED_PCT},"used_gb":${DISK_USED_GB},"total_gb":${DISK_TOTAL_GB}}},
  "services":{"ssh":"${SVC_SSH}","fail2ban":"${SVC_F2B}","cryoss-api":"${SVC_API}","cryoss-health-daily.timer":"${SVC_HEALTH}"},
  "reception":{"file_count":${RECV_COUNT},"last_received_age_h":${RECV_AGE_H},"last_received_ts":${RECV_TIMESTAMP}}
}
RJSON
REMOTE_EOF
    )

    # Si SSH echoue, retourner un JSON minimal
    if [[ -z "$rpi2_data" ]]; then
        echo "{\"reachable\":true,\"last_ping_ms\":${ping_ms},\"ssh_error\":true}"
        return
    fi

    # Injecter reachable + ping dans le JSON du RPi2
    # On enleve le { initial du rpi2_data et on le remplace
    local rpi2_inner="${rpi2_data#\{}"
    echo "{\"reachable\":true,\"last_ping_ms\":${ping_ms},${rpi2_inner}"
}

# -----------------------------------------------------------------------------
# Sante des remotes rclone
# -----------------------------------------------------------------------------
get_rclone_remotes_json() {
    local remotes_json="["
    local first=true

    if command -v rclone &>/dev/null; then
        while IFS= read -r remote; do
            [[ -z "$remote" ]] && continue
            # Enlever le ':' final
            remote="${remote%:}"

            if [[ "$first" == "true" ]]; then
                first=false
            else
                remotes_json+=","
            fi

            remotes_json+="\"${remote}\""
        done < <(rclone listremotes 2>/dev/null)
    fi

    remotes_json+="]"
    echo "$remotes_json"
}

# -----------------------------------------------------------------------------
# Construction du payload JSON complet
# -----------------------------------------------------------------------------
build_heartbeat_payload() {
    local role="$1"
    local serial
    serial=$(_clean_json_string "$(get_serial)")

    local hostname_val
    hostname_val=$(_clean_json_string "$(hostname 2>/dev/null || echo unknown)")

    local timestamp
    timestamp=$(date '+%Y-%m-%dT%H:%M:%S')

    local uptime_val
    uptime_val=$(_clean_json_string "$(get_uptime)")

    local cpu_temp
    cpu_temp=$(_clean_json_string "$(get_cpu_temp)")
    # Si cpu_temp n'est pas un nombre valide, fallback 0
    [[ "$cpu_temp" =~ ^[0-9]+(\.[0-9]+)?$ ]] || cpu_temp="0"

    local load_1m
    load_1m=$(_clean_json_string "$(get_load_1m)")
    [[ "$load_1m" =~ ^[0-9]+(\.[0-9]+)?$ ]] || load_1m="0"

    local ram_info
    ram_info=$(get_ram_info)
    local ram_used ram_total
    ram_used=$(_clean_json_string "$(echo "$ram_info" | awk '{print $1}')")
    ram_total=$(_clean_json_string "$(echo "$ram_info" | awk '{print $2}')")
    [[ "$ram_used" =~ ^[0-9]+$ ]] || ram_used="0"
    [[ "$ram_total" =~ ^[0-9]+$ ]] || ram_total="0"

    local raid_json
    raid_json=$(get_raid_json)

    local disk_json
    disk_json=$(get_disk_json)

    local services_json
    services_json=$(get_services_json)

    local rclone_json
    rclone_json=$(get_rclone_remotes_json)

    # Construction du JSON de base
    local payload
    payload=$(cat <<JSON
{
  "serial": "${serial}",
  "role": "${role}",
  "hostname": "${hostname_val}",
  "timestamp": "${timestamp}",
  "version": "${VERSION}",
  "uptime": "${uptime_val}",
  "cpu_temp_c": ${cpu_temp},
  "load_1m": ${load_1m},
  "ram_used_mb": ${ram_used},
  "ram_total_mb": ${ram_total},
  "raid": ${raid_json},
  "disks": ${disk_json},
  "services": ${services_json},
  "rclone_remotes": ${rclone_json}
JSON
    )

    # Ajout des donnees specifiques RPi1
    # Note : RPi2 est air-gapped, il n'envoie PAS de heartbeat.
    # RPi1 collecte les donnees de RPi2 via SSH interco et les inclut ici.
    if [[ "$role" == "rpi1" ]]; then
        local backup_json
        backup_json=$(get_backup_json_rpi1)

        local rpi2_json
        rpi2_json=$(get_rpi2_full_json)

        payload+=",
  \"backup\": ${backup_json},
  \"rpi2\": ${rpi2_json}"
    fi

    # Flag compromised (honeypot declenche)
    # /var/lib/cryoss/compromised existe si le honeypot a detecte un incident
    local compromised_json='{"active":false}'
    if [[ -f /var/lib/cryoss/compromised ]]; then
        local cmp_ts cmp_event cmp_sentinel
        cmp_ts=$(_clean_json_string "$(grep -oP '^timestamp=\K.*' /var/lib/cryoss/compromised 2>/dev/null | head -1)")
        cmp_event=$(_clean_json_string "$(grep -oP '^event=\K.*' /var/lib/cryoss/compromised 2>/dev/null | head -1)")
        cmp_sentinel=$(_clean_json_string "$(grep -oP '^sentinel=\K.*' /var/lib/cryoss/compromised 2>/dev/null | head -1)")
        compromised_json="{\"active\":true,\"detected_at\":\"${cmp_ts}\",\"event\":\"${cmp_event}\",\"sentinel\":\"${cmp_sentinel}\"}"
    fi
    payload+=",
  \"compromised\": ${compromised_json}"

    payload+="
}"

    echo "$payload"
}

# -----------------------------------------------------------------------------
# Traitement des commandes envoyees par Analyss (bidirectionnel)
#
# Format attendu dans la reponse du heartbeat :
#   {
#     "status": "ok",
#     "pending_commands": [
#       {"id": "uuid-1", "type": "backup_now", "params": {}},
#       {"id": "uuid-2", "type": "restart_service", "params": {"service": "smbd"}}
#     ]
#   }
#
# Chaque commande est dispatchee vers cryoss-command-runner.sh qui ACK le resultat.
# -----------------------------------------------------------------------------
process_pending_commands() {
    local response_body="$1"

    # Pas de pending_commands dans la reponse ?
    if ! echo "$response_body" | grep -q '"pending_commands"'; then
        return 0
    fi

    # Parser les commandes avec python (plus robuste que grep/sed pour JSON)
    if ! command -v python3 &>/dev/null; then
        log_warn "python3 absent - pending_commands ignorees"
        return 0
    fi

    # Extraire les commandes ligne par ligne : id<TAB>type<TAB>params_json
    local commands
    commands=$(echo "$response_body" | python3 -c '
import sys, json
try:
    data = json.loads(sys.stdin.read())
    cmds = data.get("pending_commands", []) or []
    for c in cmds:
        cid = c.get("id", "")
        ctype = c.get("type", "")
        params = json.dumps(c.get("params", {}))
        # Escape tabs in output
        print(f"{cid}\t{ctype}\t{params}")
except Exception as e:
    sys.stderr.write(f"parse_error: {e}\n")
' 2>/dev/null)

    if [[ -z "$commands" ]]; then
        return 0
    fi

    # Verifier que le runner existe
    local runner="/usr/local/bin/cryoss-command-runner.sh"
    if [[ ! -x "$runner" ]]; then
        log_warn "Runner absent ($runner) - commandes ignorees"
        return 0
    fi

    # Dispatcher chaque commande (en background pour ne pas bloquer le heartbeat)
    local count=0
    while IFS=$'\t' read -r cid ctype cparams; do
        [[ -z "$cid" || -z "$ctype" ]] && continue
        log_info "Dispatch commande : id=$cid type=$ctype"
        # Lancer en background : le runner ACK de son cote, le heartbeat continue
        ( "$runner" "$cid" "$ctype" "$cparams" >/dev/null 2>&1 ) &
        ((count++)) || true
    done <<< "$commands"

    if (( count > 0 )); then
        log_info "$count commande(s) dispatch-ee(s) en background"
    fi
}

# -----------------------------------------------------------------------------
# Envoi du heartbeat au serveur Analyss
# -----------------------------------------------------------------------------
send_heartbeat() {
    local payload="$1"
    local endpoint="${ANALYSS_URL}/api/sync/cryoss/heartbeat"

    # Validation JSON avant envoi (detecte les control chars qui donnent HTTP 422)
    if command -v python3 &>/dev/null; then
        if ! echo "$payload" | python3 -c "import sys, json; json.loads(sys.stdin.read())" 2>/dev/null; then
            log_error "Payload JSON invalide - envoi annule. Payload sauve dans /tmp/hb-invalid.json"
            echo "$payload" > /tmp/hb-invalid.json 2>/dev/null || true
            return 1
        fi
    fi

    # Verification de la cle API
    if [[ -z "${ANALYSS_API_KEY:-}" ]]; then
        die_graceful "Cle API non configuree. Lancez '$0 register' pour enregistrer ce Cryoss."
    fi

    local http_code
    local response
    response=$(curl -s -w "\n%{http_code}" \
        --connect-timeout "$CURL_CONNECT_TIMEOUT" \
        --max-time "$CURL_TIMEOUT" \
        -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${ANALYSS_API_KEY}" \
        -d "$payload" \
        "$endpoint" 2>/dev/null) || {
        die_graceful "Analyss injoignable ($endpoint) - heartbeat reporte"
    }

    # Separer le code HTTP de la reponse
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    case "$http_code" in
        200|201|204)
            log_info "Heartbeat envoye avec succes (HTTP $http_code)"
            # Traiter les pending_commands dans la reponse (execution bidirectionnelle)
            process_pending_commands "$body"
            ;;
        401|403)
            log_error "Authentification refusee (HTTP $http_code) - verifiez ANALYSS_API_KEY"
            ;;
        *)
            log_warn "Reponse inattendue du serveur (HTTP $http_code) : $body"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Enregistrement initial aupres d'Analyss
# -----------------------------------------------------------------------------
do_register() {
    log_info "Debut de l'enregistrement aupres d'Analyss..."

    local serial
    serial=$(get_serial)
    local role
    role=$(detect_role)
    local hostname_val
    hostname_val=$(hostname 2>/dev/null || echo "unknown")

    local endpoint="${ANALYSS_URL}/api/sync/cryoss/register"

    # Payload d'enregistrement avec les informations publiques
    local register_payload
    register_payload=$(cat <<JSON
{
  "serial": "${serial}",
  "role": "${role}",
  "hostname": "${hostname_val}",
  "version": "${VERSION}",
  "timestamp": "$(date '+%Y-%m-%dT%H:%M:%S')"
}
JSON
    )

    log_info "Envoi de la demande d'enregistrement a $endpoint"

    local response
    local http_code
    response=$(curl -s -w "\n%{http_code}" \
        --connect-timeout "$CURL_CONNECT_TIMEOUT" \
        --max-time "$CURL_TIMEOUT" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$register_payload" \
        "$endpoint" 2>/dev/null) || {
        log_error "Analyss injoignable ($endpoint) - enregistrement impossible"
        echo "ERREUR : Impossible de contacter le serveur Analyss."
        echo "Verifiez la connectivite reseau et l'URL dans $CONF_FILE"
        exit 1
    }

    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" && "$http_code" != "201" ]]; then
        log_error "Enregistrement refuse (HTTP $http_code) : $body"
        echo "ERREUR : Enregistrement refuse par Analyss (HTTP $http_code)"
        echo "Reponse : $body"
        exit 1
    fi

    # Extraire la cle API de la reponse JSON
    # On utilise grep/sed pour eviter la dependance a jq
    local api_key
    api_key=$(echo "$body" | grep -o '"api_key"\s*:\s*"[^"]*"' | sed 's/.*"api_key"\s*:\s*"\([^"]*\)".*/\1/')

    if [[ -z "$api_key" ]]; then
        # Essai avec le champ "token" comme alternative
        api_key=$(echo "$body" | grep -o '"token"\s*:\s*"[^"]*"' | sed 's/.*"token"\s*:\s*"\([^"]*\)".*/\1/')
    fi

    if [[ -z "$api_key" ]]; then
        log_error "Reponse d'enregistrement invalide : cle API absente"
        echo "ERREUR : La reponse du serveur ne contient pas de cle API."
        echo "Reponse brute : $body"
        exit 1
    fi

    # Sauvegarder la cle API dans le fichier de configuration
    if grep -q "^ANALYSS_API_KEY=" "$CONF_FILE" 2>/dev/null; then
        # Remplacer la ligne existante
        sed -i "s|^ANALYSS_API_KEY=.*|ANALYSS_API_KEY=\"${api_key}\"|" "$CONF_FILE"
    else
        # Ajouter la ligne
        echo "ANALYSS_API_KEY=\"${api_key}\"" >> "$CONF_FILE"
    fi

    # Securiser le fichier de configuration
    chmod 600 "$CONF_FILE"

    log_info "Enregistrement reussi ! Cle API sauvegardee dans $CONF_FILE"
    echo "Enregistrement reussi aupres d'Analyss."
    echo "  Serial   : $serial"
    echo "  Role     : $role"
    echo "  Hostname : $hostname_val"
    echo "  Cle API  : ${api_key:0:8}...${api_key: -4} (stockee dans $CONF_FILE)"
    echo ""
    echo "Le heartbeat sera envoye automatiquement toutes les 5 minutes."
}

# -----------------------------------------------------------------------------
# Point d'entree principal
# -----------------------------------------------------------------------------
main() {
    # Creer le fichier de log s'il n'existe pas
    touch "$LOG_FILE" 2>/dev/null || true

    # Charger la configuration
    load_config || die_graceful "Erreur de configuration"

    # Mode enregistrement
    if [[ "${1:-}" == "register" ]]; then
        do_register
        exit $?
    fi

    # Mode heartbeat (par defaut)
    local role
    role=$(detect_role)

    if [[ "$role" == "unknown" ]]; then
        log_warn "Role non detecte (ni rpi1 ni rpi2) - heartbeat envoye quand meme"
    fi

    # Verifier que la cle API est configuree
    if [[ -z "${ANALYSS_API_KEY:-}" ]]; then
        die_graceful "Cle API manquante. Lancez '$0 register' pour l'enregistrement initial."
    fi

    # Construire et envoyer le heartbeat
    local payload
    payload=$(build_heartbeat_payload "$role")

    send_heartbeat "$payload"
}

# Lancement
main "$@"
