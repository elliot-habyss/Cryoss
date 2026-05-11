#!/bin/bash
# =============================================================================
#  Chemin 1 : rclone crypt (XSalsa20-Poly1305) -> /etc/encrypted (RAID local)
#  Chemin 2 : rclone crypt (XSalsa20-Poly1305) -> RPi2 via SFTP interco
#  Chemin 3 : rclone crypt (XSalsa20-Poly1305) -> SFTP distant + versioning
#  Chemin 3 : rclone crypt        → Serveur SFTP          (optionnel, incrémental + versioning)
#
#  Usage :
#    sudo bash install_rpi1.sh                    # installation standard
#    sudo bash install_rpi1.sh --resume           # reprend après le dernier checkpoint OK
#    sudo bash install_rpi1.sh --from-step ID     # repart à partir d'une étape (ex: 11-samba)
#    sudo bash install_rpi1.sh --list-steps       # liste des étapes avec statut
#    sudo bash install_rpi1.sh --reset            # efface l'état (réinstall complète)
#    sudo bash install_rpi1.sh --help             # aide
# =============================================================================

set -euo pipefail

# =============================================================================
#  COULEURS — palette Cryoss
# =============================================================================
RED='\033[0;31m';     GREEN='\033[0;32m';   YELLOW='\033[1;33m'
BLUE='\033[0;34m';    CYAN='\033[0;36m';    MAGENTA='\033[0;35m'
BOLD='\033[1m';       DIM='\033[2m';        NC='\033[0m'
# Bleu glace Cryoss (256 colors)
CRY='\033[38;5;39m';  CRY_DARK='\033[38;5;33m';  CRY_LIGHT='\033[38;5;117m'

# =============================================================================
#  ÉTAT & FICHIERS DE PERSISTANCE (resume)
# =============================================================================
CRYOSS_STATE_DIR="/var/lib/cryoss"
CRYOSS_STATE_FILE="${CRYOSS_STATE_DIR}/install.state"
CRYOSS_ENV_FILE="${CRYOSS_STATE_DIR}/install.env"
CRYOSS_INSTALL_LOG="/var/log/cryoss-install.log"

# Liste ordonnée des étapes (ID:Titre) — utilisée pour --list-steps et la reprise
CRYOSS_STEPS=(
    "01-packages:Paquets de base"
    "02-network:IP fixe (NetworkManager)"
    "03-raid:RAID 1 (mdadm)"
    "04-mounts:Répertoires et montage"
    "05-users:Utilisateurs système et permissions"
    "06-rclone:Configuration rclone (3 chemins chiffrés)"
    "07-ssh-rpi2:Clé SSH pour réplication RPi2"
    "09-msmtp:msmtp + relais SMTP"
    "09b-emaillib:Librairie email HTML"
    "10-backup-script:Script cryoss-backup.sh"
    "11-samba:Samba (partages de base)"
    "11b-samba-wizard:Partages personnalisés (interactif)"
    "12-systemd:Services et timers systemd"
    "13-hardening:Durcissement système"
    "14-monitoring:Monitoring et rapports HTML"
    "15-master-key:Master key Console Analyss (Fernet)"
)

# =============================================================================
#  CLI — parsing
# =============================================================================
CRYOSS_MODE="install"        # install | resume | from-step | only-step | list | reset | help
CRYOSS_FROM_STEP=""
CRYOSS_ONLY_STEP=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --resume)       CRYOSS_MODE="resume" ;;
        --from-step)    CRYOSS_MODE="from-step"; shift; CRYOSS_FROM_STEP="${1:-}" ;;
        --only-step)    CRYOSS_MODE="only-step"; shift; CRYOSS_ONLY_STEP="${1:-}" ;;
        --list-steps)   CRYOSS_MODE="list" ;;
        --reset)        CRYOSS_MODE="reset" ;;
        --help|-h)      CRYOSS_MODE="help" ;;
        *)              echo "Argument inconnu : $1" >&2; CRYOSS_MODE="help" ;;
    esac
    shift || true
done

# =============================================================================
#  HELPERS DE BASE — log/info/ok/warn/err
# =============================================================================
ok()    { echo -e "${GREEN}[✓]${NC} $1"; }
info()  { echo -e "${CRY}[i]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step()  { echo -e "\n${BOLD}${CRY}━━━ $1 ━━━${NC}"; }
hdr()   { echo -e "${BOLD}${CRY}$1${NC}"; }

# =============================================================================
#  LIBRAIRIE UI CRYOSS — banner, spinner, barre, runner
# =============================================================================

# Glyphes Unicode pour les barres et le spinner (compatibles UTF-8)
CRYOSS_BAR_FILL='█'
CRYOSS_BAR_EMPTY='░'
CRYOSS_SPINNER=('⣾' '⣽' '⣻' '⢿' '⡿' '⣟' '⣯' '⣷')

cryoss_banner() {
    # Affiche la bannière ASCII Cryoss en bleu glace
    echo
    echo -e "${CRY}"
    cat <<'BANNER'
   ██████╗██████╗ ██╗   ██╗ ██████╗ ███████╗███████╗
  ██╔════╝██╔══██╗╚██╗ ██╔╝██╔═══██╗██╔════╝██╔════╝
  ██║     ██████╔╝ ╚████╔╝ ██║   ██║███████╗███████╗
  ██║     ██╔══██╗  ╚██╔╝  ██║   ██║╚════██║╚════██║
  ╚██████╗██║  ██║   ██║   ╚██████╔╝███████║███████║
   ╚═════╝╚═╝  ╚═╝   ╚═╝    ╚═════╝ ╚══════╝╚══════╝
BANNER
    echo -e "${DIM}        Triple chiffrement rclone (XSalsa20-Poly1305 ×3)${NC}"
    echo -e "${DIM}              Installation RPi1 — Primaire${NC}"
    echo
}

# cryoss_bar PERCENT [LABEL] — barre de progression sur une ligne (largeur 40)
cryoss_bar() {
    local pct="$1" label="${2:-}"
    local width=40
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar=""
    local i
    for (( i=0; i<filled; i++ )); do bar+="${CRYOSS_BAR_FILL}"; done
    for (( i=0; i<empty; i++ ));  do bar+="${CRYOSS_BAR_EMPTY}"; done
    printf "\r${CRY}┃${NC} ${CRY_LIGHT}%s${NC} ${BOLD}%3d%%${NC} ${DIM}%s${NC}" \
        "$bar" "$pct" "$label"
}

# cryoss_run "Label affiché" -- cmd args...
# Exécute la commande, redirige stdout/stderr vers le log, anime un spinner.
# Affiche ✓ ou ✗ + temps écoulé. Sur échec, affiche les 20 dernières lignes du log.
cryoss_run() {
    local label="$1"
    shift
    [[ "${1:-}" == "--" ]] && shift
    local start_ts elapsed rc=0 spin_pid frame=0
    mkdir -p "$(dirname "$CRYOSS_INSTALL_LOG")" 2>/dev/null || true
    : > /tmp/.cryoss_run.$$.log

    start_ts=$(date +%s)
    # Lancer la commande en arrière-plan
    ( "$@" >>/tmp/.cryoss_run.$$.log 2>&1 ) &
    local cmd_pid=$!

    # Spinner (suspendu si stdout n'est pas un terminal)
    if [[ -t 1 ]]; then
        ( while kill -0 "$cmd_pid" 2>/dev/null; do
            local f="${CRYOSS_SPINNER[$((frame % ${#CRYOSS_SPINNER[@]}))]}"
            local now=$(date +%s)
            printf "\r${CRY}┃${NC} ${CRY}%s${NC} ${BOLD}%s${NC} ${DIM}(%ds)${NC}     " \
                "$f" "$label" "$((now - start_ts))"
            frame=$((frame + 1))
            sleep 0.1
          done ) &
        spin_pid=$!
    fi

    wait "$cmd_pid"; rc=$?
    [[ -n "${spin_pid:-}" ]] && { kill "$spin_pid" 2>/dev/null || true; wait "$spin_pid" 2>/dev/null || true; }
    elapsed=$(( $(date +%s) - start_ts ))

    # Concaténer le log de cette commande dans le log global
    cat "/tmp/.cryoss_run.$$.log" >> "$CRYOSS_INSTALL_LOG" 2>/dev/null || true

    if (( rc == 0 )); then
        printf "\r${CRY}┃${NC} ${GREEN}✓${NC} ${BOLD}%s${NC} ${DIM}(%ds)${NC}%-20s\n" "$label" "$elapsed" ""
    else
        printf "\r${CRY}┃${NC} ${RED}✗${NC} ${BOLD}%s${NC} ${DIM}(échec après %ds, code %d)${NC}\n" "$label" "$elapsed" "$rc"
        echo -e "${DIM}---- 20 dernières lignes (${CRYOSS_INSTALL_LOG}) ----${NC}"
        tail -n 20 "/tmp/.cryoss_run.$$.log" | sed "s/^/  /"
        echo -e "${DIM}-------------------------------------------------${NC}"
    fi
    rm -f "/tmp/.cryoss_run.$$.log"
    return $rc
}

# cryoss_apt_install pkg1 pkg2 ... — apt-get install avec barre de progression
cryoss_apt_install() {
    local pkgs=("$@")
    local total=${#pkgs[@]}
    local label="apt-get install (${total} paquet(s))"
    DEBIAN_FRONTEND=noninteractive cryoss_run "$label" -- \
        apt-get install -y -o Dpkg::Use-Pty=0 "${pkgs[@]}"
}

# cryoss_download URL DEST [LABEL] — télécharge avec barre de progression curl stylée
cryoss_download() {
    local url="$1" dest="$2" label="${3:-Téléchargement}"
    cryoss_run "$label" -- curl -fsSL --retry 3 -o "$dest" "$url"
}

# =============================================================================
#  RESUME FRAMEWORK
# =============================================================================

cryoss_state_init() {
    mkdir -p "$CRYOSS_STATE_DIR"
    chmod 700 "$CRYOSS_STATE_DIR"
    touch "$CRYOSS_STATE_FILE"
    chmod 600 "$CRYOSS_STATE_FILE"
}

# Marque une étape comme complétée
cryoss_mark_done() {
    cryoss_state_init
    grep -qxF "$1" "$CRYOSS_STATE_FILE" 2>/dev/null || echo "$1" >> "$CRYOSS_STATE_FILE"
}

# Renvoie 0 si l'étape est déjà complétée (à skipper), 1 sinon
cryoss_is_done() {
    [[ -f "$CRYOSS_STATE_FILE" ]] && grep -qxF "$1" "$CRYOSS_STATE_FILE"
}

# Ouvre une étape : affiche l'en-tête. Renvoie 0 = exécuter, 1 = skip.
# Usage : if cryoss_step "01-packages" "1. Paquets"; then ... cryoss_done "01-packages"; fi
cryoss_step() {
    local id="$1" title="$2"
    if cryoss_is_done "$id"; then
        echo -e "\n${DIM}${CRY}┃ ⊘ ${title} (déjà fait — skip)${NC}"
        return 1
    fi
    echo -e "\n${BOLD}${CRY}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CRY}║${NC} ${BOLD}${title}${NC}"
    echo -e "${BOLD}${CRY}╚══════════════════════════════════════════════════════════╝${NC}"
    return 0
}

cryoss_done() {
    cryoss_mark_done "$1"
    echo -e "${CRY}┃ ${GREEN}✓ Étape ${BOLD}$1${NC}${GREEN} validée${NC}"
}

# Sauvegarde toutes les variables collectées dans /var/lib/cryoss/install.env (600 root)
cryoss_save_env() {
    cryoss_state_init
    umask 077
    {
        echo "# Cryoss — variables d'installation (généré $(date '+%Y-%m-%d %H:%M:%S'))"
        echo "# CONFIDENTIEL : contient mots de passe SMTP/SFTP en clair, mode 600 root."
        echo "# Sourcé automatiquement par install_rpi1.sh --resume"
        for var in CLIENT_NAME \
                   SMTP_HOST SMTP_PORT SMTP_FROM SMTP_USER SMTP_PASS \
                   EMAIL_TO EMAIL_TO_2 \
                   NET_IFACE NET_IP NET_CIDR NET_GW NET_DNS1 NET_DNS2 \
                   INTERCO_IFACE INTERCO_IP_RPI1 INTERCO_IP_RPI2 INTERCO_CIDR INTERCO_CON \
                   RPI2_IP RPI2_SSH_PORT RPI2_USER RPI2_DIR \
                   ENABLE_SFTP SFTP_HOST SFTP_PORT SFTP_USER SFTP_PASS SFTP_REMOTE_DIR \
                   DISK1 DISK2 DISK3 DISK4 \
                   DS_PASS HABYSS_PASS; do
            if [[ -n "${!var:-}" ]]; then
                printf '%s=%q\n' "$var" "${!var}"
            fi
        done
    } > "$CRYOSS_ENV_FILE"
    chmod 600 "$CRYOSS_ENV_FILE"
}

cryoss_load_env() {
    if [[ ! -f "$CRYOSS_ENV_FILE" ]]; then
        err "Aucun environnement sauvegardé (${CRYOSS_ENV_FILE}) — impossible de reprendre"
    fi
    # shellcheck disable=SC1090
    source "$CRYOSS_ENV_FILE"
    info "Environnement rechargé depuis ${CRYOSS_ENV_FILE}"
}

# Affiche la liste des étapes avec leur statut
cryoss_list_steps() {
    cryoss_banner
    hdr "Liste des étapes Cryoss RPi1"
    echo
    local entry id title status
    for entry in "${CRYOSS_STEPS[@]}"; do
        id="${entry%%:*}"
        title="${entry#*:}"
        if cryoss_is_done "$id"; then
            status="${GREEN}✓ fait${NC}"
        else
            status="${DIM}○ à faire${NC}"
        fi
        printf "  ${CRY}%-22s${NC} %b  %s\n" "$id" "$status" "$title"
    done
    echo
    if [[ -f "$CRYOSS_ENV_FILE" ]]; then
        info "Variables sauvegardées : ${CRYOSS_ENV_FILE} (600 root)"
    else
        info "Aucune variable sauvegardée — première installation"
    fi
}

# Purge l'état à partir d'une étape donnée (incluse)
cryoss_reset_from() {
    local from_id="$1"
    [[ ! -f "$CRYOSS_STATE_FILE" ]] && return 0
    local entry id keep=1
    local tmp="${CRYOSS_STATE_FILE}.tmp"
    : > "$tmp"
    for entry in "${CRYOSS_STEPS[@]}"; do
        id="${entry%%:*}"
        [[ "$id" == "$from_id" ]] && keep=0
        if (( keep )) && grep -qxF "$id" "$CRYOSS_STATE_FILE"; then
            echo "$id" >> "$tmp"
        fi
    done
    mv "$tmp" "$CRYOSS_STATE_FILE"
    chmod 600 "$CRYOSS_STATE_FILE"
}

cryoss_reset_all() {
    rm -f "$CRYOSS_STATE_FILE" "$CRYOSS_ENV_FILE"
    info "État effacé : ${CRYOSS_STATE_FILE} et ${CRYOSS_ENV_FILE}"
}

cryoss_show_help() {
    cryoss_banner
    cat <<'HELP'
Usage : sudo bash install_rpi1.sh [OPTION]

  (sans option)         Installation standard : collecte interactive puis exécution
                        de toutes les étapes. Si un état partiel existe, propose
                        de reprendre.
  --resume              Reprend après le dernier checkpoint OK (utilise l'env sauvegardé).
  --from-step ID        Repart à partir d'une étape précise (ex: 11-samba). Toutes les
                        étapes suivantes sont rejouées. Utilise l'env sauvegardé.
  --only-step ID        Rejoue UNIQUEMENT l'étape donnée (ex: 11b-samba-wizard pour
                        ajouter des partages sans toucher au reste). Utilise l'env.
  --list-steps          Affiche la liste des étapes avec leur statut (fait / à faire).
  --reset               Efface l'état et l'env sauvegardé (réinstall complète).
  --help, -h            Affiche cette aide.

Fichiers d'état :
  /var/lib/cryoss/install.state   Étapes complétées (1 ID/ligne, 600 root).
  /var/lib/cryoss/install.env     Variables collectées (600 root, sensible).
  /var/log/cryoss-install.log     Log brut de toutes les commandes encapsulées.
HELP
}

# =============================================================================
#  HELP / LIST — accessibles sans root (lecture seule)
# =============================================================================
case "$CRYOSS_MODE" in
    help)
        cryoss_show_help
        exit 0
        ;;
    list)
        cryoss_list_steps
        exit 0
        ;;
esac

# =============================================================================
#  ROOT CHECK — requis pour tous les autres modes
# =============================================================================
[[ $EUID -ne 0 ]] && err "Exécuter en root : sudo bash $0"

# =============================================================================
#  TRAITEMENT DES MODES CLI (root requis)
# =============================================================================
case "$CRYOSS_MODE" in
    reset)
        cryoss_banner
        warn "Cela va effacer l'état d'installation et l'env sauvegardé."
        read -rp "Confirmer la réinitialisation ? [o/N] : " _r
        [[ "${_r,,}" == "o" ]] || err "Annulé."
        cryoss_reset_all
        ok "État réinitialisé. Relancez sans option pour une installation fraîche."
        exit 0
        ;;
    resume)
        cryoss_banner
        cryoss_load_env
        info "Mode reprise : les étapes déjà validées seront skippées."
        ;;
    from-step)
        cryoss_banner
        if [[ -z "$CRYOSS_FROM_STEP" ]]; then
            err "--from-step requiert un ID d'étape (ex: 11-samba). Voir --list-steps."
        fi
        if ! printf '%s\n' "${CRYOSS_STEPS[@]}" | grep -q "^${CRYOSS_FROM_STEP}:"; then
            err "ID inconnu : ${CRYOSS_FROM_STEP}. Voir --list-steps."
        fi
        cryoss_load_env
        cryoss_reset_from "$CRYOSS_FROM_STEP"
        info "Mode --from-step : l'étape ${CRYOSS_FROM_STEP} et les suivantes vont être rejouées."
        ;;
    only-step)
        cryoss_banner
        if [[ -z "$CRYOSS_ONLY_STEP" ]]; then
            err "--only-step requiert un ID d'étape (ex: 11b-samba-wizard). Voir --list-steps."
        fi
        if ! printf '%s\n' "${CRYOSS_STEPS[@]}" | grep -q "^${CRYOSS_ONLY_STEP}:"; then
            err "ID inconnu : ${CRYOSS_ONLY_STEP}. Voir --list-steps."
        fi
        cryoss_load_env
        # Retire UNIQUEMENT l'étape ciblée du state (les autres restent "fait" et seront skippées)
        if [[ -f "$CRYOSS_STATE_FILE" ]]; then
            grep -vxF "$CRYOSS_ONLY_STEP" "$CRYOSS_STATE_FILE" > "${CRYOSS_STATE_FILE}.tmp" || true
            mv "${CRYOSS_STATE_FILE}.tmp" "$CRYOSS_STATE_FILE"
            chmod 600 "$CRYOSS_STATE_FILE"
        fi
        info "Mode --only-step : seule l'étape ${CRYOSS_ONLY_STEP} sera rejouée."
        ;;
    install)
        cryoss_banner
        # Si un état partiel existe, proposer de reprendre
        if [[ -f "$CRYOSS_STATE_FILE" ]] && [[ -s "$CRYOSS_STATE_FILE" ]]; then
            warn "Une installation partielle a été détectée :"
            echo
            CRYOSS_DONE_COUNT=$(wc -l < "$CRYOSS_STATE_FILE" 2>/dev/null || echo 0)
            echo -e "  ${CRY}Étapes déjà validées : ${BOLD}${CRYOSS_DONE_COUNT}${NC} / ${#CRYOSS_STEPS[@]}"
            echo -e "  ${CRY}État : ${CRYOSS_STATE_FILE}${NC}"
            echo
            echo "  [1] Reprendre (skip les étapes déjà faites)"
            echo "  [2] Recommencer depuis une étape précise (--from-step)"
            echo "  [3] Lister les étapes avec leur statut"
            echo "  [4] Tout effacer et repartir de zéro (--reset)"
            echo "  [5] Annuler"
            read -rp "Votre choix [1-5] : " _choice
            case "$_choice" in
                1) cryoss_load_env; CRYOSS_MODE="resume" ;;
                2) cryoss_list_steps
                   read -rp "ID de l'étape à rejouer : " CRYOSS_FROM_STEP
                   cryoss_load_env
                   cryoss_reset_from "$CRYOSS_FROM_STEP"
                   CRYOSS_MODE="from-step" ;;
                3) cryoss_list_steps; exit 0 ;;
                4) cryoss_reset_all; CRYOSS_MODE="install" ;;
                5) err "Annulé." ;;
                *) err "Choix invalide." ;;
            esac
        fi
        ;;
esac

# =============================================================================
#  COLLECTE — skippée si on reprend (env déjà chargé)
# =============================================================================
if [[ "$CRYOSS_MODE" == "install" ]]; then

step "Identification"
read -rp "  Nom du client : " CLIENT_NAME

step "Chiffrement"
info "Les 3 paires de cles rclone (XSalsa20-Poly1305 + AES-256-EME)"
info "seront auto-generees et sauvegardees dans /etc/cryoss/keys-backup.conf"
info "Chaque chemin (local, RPi2, SFTP) a ses propres cles independantes."

step "Email (msmtp)"
# Valeurs fixes Analyss — ne changent jamais
SMTP_HOST="ex5.mail.ovh.net"
SMTP_PORT="587"
SMTP_FROM="alertes@habyss.fr"
SMTP_USER="alertes@habyss.fr"
info "SMTP : $SMTP_USER via $SMTP_HOST:$SMTP_PORT"
read -rsp "  Mot de passe SMTP ($SMTP_USER) : " SMTP_PASS; echo
[[ -z "$SMTP_PASS" ]] && err "Mot de passe SMTP obligatoire"
# Destinataire 1 = toujours support@habyss.fr (Analyss)
EMAIL_TO="support@habyss.fr"
info "Destinataire 1 (fixe) : $EMAIL_TO"
read -rp "  Email destinataire client (optionnel) : " EMAIL_TO_2
EMAIL_TO_2="${EMAIL_TO_2:-}"

step "Reseau RPi1 (IP fixe)"
echo "  Interfaces :"; ip -o link show | awk -F': ' '{print "   "$2}' | grep -v lo; echo
read -rp "  Interface   (ex: eth0)          : " NET_IFACE
read -rp "  IP fixe     (ex: 192.168.1.50)  : " NET_IP
read -rp "  CIDR        (ex: 24)            : " NET_CIDR
read -rp "  Passerelle  (ex: 192.168.1.1)   : " NET_GW
read -rp "  DNS1        (ex: 1.1.1.1)       : " NET_DNS1
read -rp "  DNS2        (ex: 8.8.8.8)       : " NET_DNS2

step "Interface eth1 USB (réseau inter-RPi — câble direct vers RPi2)"
echo "  Le câble Ethernet direct RPi1(eth1-USB) ↔ RPi2 utilise un réseau dédié :"
echo "    RPi1 : 10.42.0.1/30   RPi2 : 10.42.0.2/30"
echo "  Ces IPs sont identiques dans install_rpi2.sh."
echo ""
ip -o link show | awk -F': ' '{print "    " $2}' | grep -v lo
echo
read -rp "  Interface eth1 USB vers RPi2 (ex: eth1) : " INTERCO_IFACE

# IPs inter-RPi — identiques dans install_rpi2.sh
INTERCO_IP_RPI1="10.42.0.1"
INTERCO_IP_RPI2="10.42.0.2"
INTERCO_CIDR="30"
INTERCO_CON="cryoss-interco"

# Paramètres SSH RPi2 — fixes car réseau dédié connu
RPI2_IP="${INTERCO_IP_RPI2}"
RPI2_SSH_PORT="22"
RPI2_USER="ds-repl"
read -rp "  Repertoire destination sur RPi2 : " RPI2_DIR

step "Sauvegarde SFTP distante (chemin 3 — optionnel)"
echo "  Le chemin 3 chiffre et synchronise les données vers un serveur SFTP distant."
echo "  Utile pour une copie hors-site. Peut être activé plus tard."
echo ""
read -rp "  Activer le chemin 3 SFTP/rclone ? [o/N] : " _SFTP_CHOICE
ENABLE_SFTP="no"
SFTP_HOST=""; SFTP_PORT="22"; SFTP_USER=""; SFTP_PASS=""; SFTP_REMOTE_DIR=""
if [[ "${_SFTP_CHOICE,,}" == "o" ]]; then
    ENABLE_SFTP="yes"
    read -rp "  Hote SFTP                       : " SFTP_HOST
    read -rp "  Port SFTP      (defaut: 22)     : " SFTP_PORT
    SFTP_PORT="${SFTP_PORT:-22}"
    read -rp "  Utilisateur SFTP                : " SFTP_USER
    read -rsp "  Mot de passe SFTP              : " SFTP_PASS; echo
    read -rp "  Repertoire distant SFTP         : " SFTP_REMOTE_DIR
fi

step "RAID 1 (4 disques)"
echo "  Disques :"; lsblk -d -o NAME,SIZE,MODEL 2>/dev/null | grep -v "^NAME\|mmcblk\|nvme" || true; echo
# Layout fixe : md0=sda+sdb (sauvegarde), md1=sdc+sdd (encrypted)
DISK1="/dev/sda"; DISK2="/dev/sdb"
DISK3="/dev/sdc"; DISK4="/dev/sdd"
info "RAID md0 : $DISK1 + $DISK2 -> /etc/sauvegarde"
info "RAID md1 : $DISK3 + $DISK4 -> /etc/encrypted"

step "Utilisateurs"
DS_PASS=$(openssl rand -base64 16)
HABYSS_PASS=$(openssl rand -base64 16)
warn "Mots de passe generes :"
echo -e "  ${BOLD}ds-user${NC} : ${BOLD}${DS_PASS}${NC}"
echo -e "  ${BOLD}habyss${NC}  : ${BOLD}${HABYSS_PASS}${NC}"
read -rp "  Notez-les puis Entree..."

echo -e "\n${BOLD}=== Recapitulatif RPi1 ===${NC}"
echo "  Client  : $CLIENT_NAME"
echo "  IP      : ${NET_IP}/${NET_CIDR}  GW: $NET_GW"
echo "  RAID    : md0($DISK1+$DISK2)/sauvegarde | md1($DISK3+$DISK4)/encrypted"
echo "  Ch.1    : rclone crypt (XSalsa20-Poly1305, KEY_C1) -> /etc/encrypted"
echo "  Ch.2    : rclone crypt (XSalsa20-Poly1305, KEY_C2) via SFTP interco -> RPi2"
if [[ "$ENABLE_SFTP" == "yes" ]]; then
    echo "  Ch.3    : rclone crypt → sftp://$SFTP_USER@$SFTP_HOST/$SFTP_REMOTE_DIR"
else
    echo "  Ch.3    : SFTP DESACTIVE (peut etre active via install_security.sh)"
fi
echo "  Email1  : $EMAIL_TO"
[[ -n "$EMAIL_TO_2" ]] && echo "  Email2  : $EMAIL_TO_2"
echo
read -rp "Confirmer ? [o/N] : " CONFIRM
[[ "${CONFIRM,,}" != "o" ]] && err "Annule."

# Variables collectées → persistées pour permettre la reprise
cryoss_save_env
ok "Variables sauvegardées dans ${CRYOSS_ENV_FILE} (600 root)"

fi  # fin du bloc COLLECTE (skippé en mode resume / from-step)

# =============================================================================
#  INSTALLATION — chaque étape est encapsulée dans cryoss_step / cryoss_done
# =============================================================================

if cryoss_step "01-packages" "1. Paquets de base"; then
    # TOUS les paquets ici — avant toute manipulation réseau ou UFW
    cryoss_run "apt-get update" -- apt-get update -qq
    # msmtp-mta fournit mail-transport-agent — postfix entre en conflit, on le vire
    cryoss_run "Désinstallation postfix (conflit msmtp-mta)" -- bash -c \
        'apt-get remove -y postfix 2>/dev/null || true'
    cryoss_apt_install openssl msmtp msmtp-mta samba mdadm ufw fail2ban curl smartmontools

    # rclone est OBLIGATOIRE (utilise pour les 3 chemins de chiffrement)
    if ! command -v rclone &>/dev/null; then
        cryoss_run "Téléchargement et installation rclone" -- bash -c \
            'curl -fsSL https://rclone.org/install.sh | bash' \
            || err "Installation rclone echouee — installez manuellement : https://rclone.org/install/"
    else
        ok "rclone deja present ($(rclone version --check 2>/dev/null | head -1 || echo 'version inconnue'))"
    fi
    cryoss_done "01-packages"
fi

# =============================================================================
if cryoss_step "02-network" "2. IP fixe (NetworkManager)"; then

NM_CON="cryoss-static"
if ! systemctl is-active --quiet NetworkManager 2>/dev/null; then
    cryoss_apt_install network-manager
    systemctl enable NetworkManager; systemctl start NetworkManager; sleep 3
fi
nmcli connection delete "$NM_CON" 2>/dev/null || true
nmcli connection add type ethernet ifname "$NET_IFACE" con-name "$NM_CON" \
    ipv4.method manual \
    ipv4.addresses "${NET_IP}/${NET_CIDR}" \
    ipv4.gateway "$NET_GW" \
    ipv4.dns "$NET_DNS1 $NET_DNS2" \
    ipv6.method disabled \
    connection.autoconnect yes
DHCP_CON=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null \
    | grep ":${NET_IFACE}$" | cut -d: -f1 | grep -v "$NM_CON" || true)
[[ -n "$DHCP_CON" ]] && nmcli connection modify "$DHCP_CON" connection.autoconnect no 2>/dev/null || true
nmcli connection up "$NM_CON"
ok "IP fixe : ${NET_IP}/${NET_CIDR} sur $NET_IFACE"

# Lien dédié inter-RPi sur eth1 USB
nmcli connection delete "$INTERCO_CON" 2>/dev/null || true
nmcli connection add type ethernet ifname "$INTERCO_IFACE" con-name "$INTERCO_CON" \
    ipv4.method manual \
    ipv4.addresses "${INTERCO_IP_RPI1}/${INTERCO_CIDR}" \
    ipv4.gateway "" \
    ipv4.dns "" \
    ipv6.method disabled \
    connection.autoconnect yes
nmcli connection up "$INTERCO_CON" 2>/dev/null || true
ok "IP inter-RPi : ${INTERCO_IP_RPI1}/${INTERCO_CIDR} sur $INTERCO_IFACE (cable direct vers RPi2)"
info "RPi2 utilisera ${INTERCO_IP_RPI2} sur son interface de replication"
    cryoss_done "02-network"
fi

# =============================================================================
if cryoss_step "03-raid" "3. RAID 1 (mdadm)"; then

nuke_disk() {
    local disk=$1; info "Nettoyage $disk..."
    for part in $(lsblk -ln -o NAME "$disk" | tail -n +2); do
        umount -f "/dev/$part" 2>/dev/null || true
    done
    umount -f "$disk" 2>/dev/null || true
    for md in $(grep "^md" /proc/mdstat 2>/dev/null | awk '{print $1}'); do
        mdadm --detail "/dev/$md" 2>/dev/null | grep -q "$disk" && \
            mdadm --stop "/dev/$md" 2>/dev/null || true
    done
    mdadm --zero-superblock --force "$disk" 2>/dev/null || true
    wipefs -a -f "$disk" 2>/dev/null || true
    dd if=/dev/zero of="$disk" bs=1M count=10 conv=fsync 2>/dev/null || true
    parted -s "$disk" mklabel gpt 2>/dev/null || true
    ok "$disk nettoye"
}

for MD in /dev/md0 /dev/md1; do
    [ -b "$MD" ] && { umount -f "$MD" 2>/dev/null || true; mdadm --stop "$MD" 2>/dev/null || true; }
done
for DISK in "$DISK1" "$DISK2" "$DISK3" "$DISK4"; do nuke_disk "$DISK"; done
sleep 2; partprobe "$DISK1" "$DISK2" "$DISK3" "$DISK4" 2>/dev/null || true; sleep 2

cryoss_run "Création RAID md0 ($DISK1 + $DISK2)" -- bash -c \
    "mdadm --create /dev/md0 --level=1 --raid-devices=2 --bitmap=internal --run --force '$DISK1' '$DISK2' <<< yes"

cryoss_run "Création RAID md1 ($DISK3 + $DISK4)" -- bash -c \
    "mdadm --create /dev/md1 --level=1 --raid-devices=2 --bitmap=internal --run --force '$DISK3' '$DISK4' <<< yes"

sleep 10; cat /proc/mdstat
cryoss_run "Formatage ext4 md0"  -- mkfs.ext4 -F -q /dev/md0
cryoss_run "Formatage ext4 md1"  -- mkfs.ext4 -F -q /dev/md1
    cryoss_done "03-raid"
fi

# =============================================================================
if cryoss_step "04-mounts" "4. Répertoires et montage"; then

mkdir -p /etc/sauvegarde /etc/encrypted
mount /dev/md0 /etc/sauvegarde && ok "md0 -> /etc/sauvegarde" || warn "deja monte"
mount /dev/md1 /etc/encrypted  && ok "md1 -> /etc/encrypted"  || warn "deja monte"

sed -i '/^ARRAY/d' /etc/mdadm/mdadm.conf; mdadm --detail --scan >> /etc/mdadm/mdadm.conf
update-initramfs -u -k all &>/dev/null
ok "Config mdadm persistee"

UUID_MD0=$(blkid -s UUID -o value /dev/md0)
UUID_MD1=$(blkid -s UUID -o value /dev/md1)
sed -i '/\/etc\/sauvegarde/d;/\/etc\/encrypted/d' /etc/fstab
echo "UUID=$UUID_MD0   /etc/sauvegarde   ext4   defaults,nodev,nosuid   0   2" >> /etc/fstab
echo "UUID=$UUID_MD1   /etc/encrypted    ext4   defaults,nodev,nosuid   0   2" >> /etc/fstab
ok "fstab mis a jour"
    cryoss_done "04-mounts"
fi

# =============================================================================
if cryoss_step "05-users" "5. Utilisateurs système et permissions"; then

groupadd -f samba-share

if id ds-user &>/dev/null; then
    usermod -s /usr/sbin/nologin -G samba-share ds-user
else
    useradd -r -s /usr/sbin/nologin -M -G samba-share ds-user
fi
echo "ds-user:${DS_PASS}" | chpasswd
printf '%s\n%s\n' "$DS_PASS" "$DS_PASS" | smbpasswd -s -a ds-user
smbpasswd -e ds-user
ok "ds-user configure"

if id habyss &>/dev/null; then
    usermod -aG sudo,samba-share habyss
else
    useradd -m -s /bin/bash -G sudo,samba-share habyss
fi
echo "habyss:${HABYSS_PASS}" | chpasswd
printf '%s\n%s\n' "$HABYSS_PASS" "$HABYSS_PASS" | smbpasswd -s -a habyss
smbpasswd -e habyss
ok "habyss configure"

chown root:samba-share /etc/sauvegarde /etc/encrypted
chmod 2770 /etc/sauvegarde /etc/encrypted
ok "Permissions repertoires OK"
    cryoss_done "05-users"
fi

# =============================================================================
if cryoss_step "06-rclone" "6. Configuration rclone — 3 chemins chiffrés indépendants"; then
# =============================================================================
# =============================================================================
# Architecture chiffrement :
#   Chemin 1 (local)  : rclone crypt → RAID local     (XSalsa20-Poly1305, KEY_C1)
#   Chemin 2 (RPi2)   : rclone crypt → RPi2 via SFTP  (XSalsa20-Poly1305, KEY_C2)
#   Chemin 3 (distant) : rclone crypt → SFTP distant   (XSalsa20-Poly1305, KEY_C3)
#
# Chaque chemin a ses propres cles de chiffrement (independance totale).
# XSalsa20-Poly1305 = chiffrement authentifie (AEAD) — detecte toute alteration.
# AES-256-EME pour l'obfuscation des noms de fichiers sur les 3 chemins.
# =============================================================================

RCLONE_CONF_DIR="/root/.config/rclone"
RCLONE_CONF="$RCLONE_CONF_DIR/rclone.conf"
mkdir -p "$RCLONE_CONF_DIR"; chmod 700 "$RCLONE_CONF_DIR"

# Generer 3 paires de cles independantes (obscurcies par rclone)
info "Generation des cles de chiffrement (3 paires independantes)..."
KEY_C1_PASS=$(rclone obscure "$(openssl rand -base64 32)")
KEY_C1_SALT=$(rclone obscure "$(openssl rand -base64 32)")
KEY_C2_PASS=$(rclone obscure "$(openssl rand -base64 32)")
KEY_C2_SALT=$(rclone obscure "$(openssl rand -base64 32)")
KEY_C3_PASS=$(rclone obscure "$(openssl rand -base64 32)")
KEY_C3_SALT=$(rclone obscure "$(openssl rand -base64 32)")

# Sauvegarder les cles en clair pour restauration d'urgence
mkdir -p /etc/cryoss; chmod 700 /etc/cryoss
cat > /etc/cryoss/keys-backup.conf <<KEYS_EOF
# Cryoss — Cles de chiffrement (CONFIDENTIEL)
# Generees le $(date '+%Y-%m-%d %H:%M:%S')
# CONSERVER EN LIEU SUR — necessaire pour restauration
# Format : rclone obscure (XSalsa20-Poly1305 + AES-256-EME)
KEY_C1_PASS="$KEY_C1_PASS"
KEY_C1_SALT="$KEY_C1_SALT"
KEY_C2_PASS="$KEY_C2_PASS"
KEY_C2_SALT="$KEY_C2_SALT"
KEY_C3_PASS="$KEY_C3_PASS"
KEY_C3_SALT="$KEY_C3_SALT"
KEYS_EOF
chmod 600 /etc/cryoss/keys-backup.conf
ok "Cles sauvegardees dans /etc/cryoss/keys-backup.conf (600 root)"

# --- Construire rclone.conf ---

cat > "$RCLONE_CONF" <<RCLONE_EOF
# =============================================
# Cryoss rclone configuration — 3 chemins
# Chiffrement : XSalsa20-Poly1305 (contenu)
#             + AES-256-EME (noms de fichiers)
# =============================================

# --- CHEMIN 1 : Chiffrement local RAID ---
[cryoss-c1-local]
type = alias
remote = /etc/encrypted

[cryoss-c1-crypt]
type = crypt
remote = cryoss-c1-local:
filename_encryption = standard
directory_name_encryption = true
password = $KEY_C1_PASS
password2 = $KEY_C1_SALT

# --- CHEMIN 2 : RPi2 via SFTP interco ---
[cryoss-c2-rpi2]
type = sftp
host = ${INTERCO_IP_RPI2}
user = ds-repl
port = 22
key_file = /root/.ssh/cryoss_rpi2
shell_type = unix
md5sum_command = none
sha1sum_command = none

[cryoss-c2-crypt]
type = crypt
remote = cryoss-c2-rpi2:/data
filename_encryption = standard
directory_name_encryption = true
password = $KEY_C2_PASS
password2 = $KEY_C2_SALT
RCLONE_EOF

# --- CHEMIN 3 : SFTP distant (optionnel) ---
if [[ "$ENABLE_SFTP" == "yes" ]]; then
    SFTP_PASS_OBS=$(rclone obscure "$SFTP_PASS")

    cat >> "$RCLONE_CONF" <<RCLONE_SFTP_EOF

# --- CHEMIN 3 : SFTP distant ---
[cryoss-c3-sftp]
type = sftp
host = $SFTP_HOST
port = $SFTP_PORT
user = $SFTP_USER
pass = $SFTP_PASS_OBS
shell_type = unix
md5sum_command = md5sum
sha1sum_command = sha1sum

[cryoss-c3-crypt]
type = crypt
remote = cryoss-c3-sftp:$SFTP_REMOTE_DIR
filename_encryption = standard
directory_name_encryption = true
password = $KEY_C3_PASS
password2 = $KEY_C3_SALT

# --- Versioning SFTP (--backup-dir) ---
[cryoss-c3-versions]
type = crypt
remote = cryoss-c3-sftp:${SFTP_REMOTE_DIR}/versions
filename_encryption = standard
directory_name_encryption = true
password = $KEY_C3_PASS
password2 = $KEY_C3_SALT
RCLONE_SFTP_EOF

    ok "Chemin 3 (SFTP distant) configure"

    info "Test connexion SFTP..."
    if rclone lsd cryoss-c3-sftp: --contimeout 10s --timeout 10s &>/dev/null; then
        rclone mkdir "cryoss-c3-sftp:$SFTP_REMOTE_DIR" 2>/dev/null || true
        ok "SFTP operationnel — repertoire distant pret"
    else
        warn "SFTP inaccessible — verifiez les identifiants"
    fi
else
    info "Chemin 3 (SFTP distant) desactive"
fi

chmod 600 "$RCLONE_CONF"
chown root:root "$RCLONE_CONF"
ok "rclone.conf installe avec 3 chemins chiffres independants"
    cryoss_done "06-rclone"
fi

# =============================================================================
if cryoss_step "07-ssh-rpi2" "7. Clé SSH pour réplication RPi2"; then

SSH_KEY_PATH="/root/.ssh/cryoss_rpi2"
mkdir -p /root/.ssh; chmod 700 /root/.ssh

if [[ ! -f "$SSH_KEY_PATH" ]]; then
    ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "cryoss-rpi1-to-rpi2"
    ok "Cle ED25519 generee : $SSH_KEY_PATH"
else
    warn "Cle SSH RPi2 deja presente — conservee"
fi

grep -q "Host cryoss-rpi2" /root/.ssh/config 2>/dev/null || cat >> /root/.ssh/config <<SSHEOF

# Cryoss - Replication RPi2
Host cryoss-rpi2
    HostName ${INTERCO_IP_RPI2}
    Port ${RPI2_SSH_PORT}
    User $RPI2_USER
    IdentityFile $SSH_KEY_PATH
    StrictHostKeyChecking yes
    BatchMode yes
    ConnectTimeout 10
SSHEOF
chmod 600 /root/.ssh/config

# Copier la cle SSH vers RPi2 pour acces sans mot de passe
info "Copie de la cle SSH vers RPi2..."
if ssh-copy-id -i /root/.ssh/cryoss_rpi2.pub -o StrictHostKeyChecking=accept-new habyss@10.42.0.2 2>/dev/null; then
    ok "Cle SSH copiee vers RPi2 (habyss@10.42.0.2)"
else
    warn "Copie de la cle SSH vers RPi2 echouee — faites-le manuellement :"
    warn "  ssh-copy-id -i /root/.ssh/cryoss_rpi2.pub habyss@10.42.0.2"
fi

info "Test SSH RPi2..."
if ssh -o ConnectTimeout=5 cryoss-rpi2 "mkdir -p $RPI2_DIR && echo OK" 2>/dev/null; then
    ok "SSH RPi2 operationnel"
else
    warn "SSH RPi2 echoue — test : ssh cryoss-rpi2 'echo ok'"
fi
    cryoss_done "07-ssh-rpi2"
fi

# =============================================================================
if cryoss_step "09-msmtp" "9. msmtp + relais SMTP"; then

cat > /etc/msmtprc <<MSMTP_EOF
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        alertes
host           $SMTP_HOST
port           $SMTP_PORT
from           $SMTP_FROM
user           $SMTP_USER
password       $SMTP_PASS

account default : alertes
MSMTP_EOF
chmod 600 /etc/msmtprc; chown root:root /etc/msmtprc
ok "msmtp configuré (RPi1)"

# Relais SMTP local pour RPi2 (hors LAN — passe par RPi1 pour envoyer ses emails)
# RPi2 envoie ses emails vers 10.42.0.1:25 → RPi1 les relaie via son compte SMTP
info "Configuration du relais SMTP local pour RPi2 (port 25 sur 10.42.0.1)..."
if command -v postfix &>/dev/null; then
    # Configuration null-client : accepte seulement depuis l'interco, relaie via msmtp
    postconf -e "inet_interfaces = 10.42.0.1"
    postconf -e "inet_protocols = ipv4"
    postconf -e "mynetworks = 10.42.0.0/30"
    postconf -e "relayhost = [$SMTP_HOST]:$SMTP_PORT"
    postconf -e "smtp_sasl_auth_enable = yes"
    postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
    postconf -e "smtp_sasl_security_options = noanonymous"
    postconf -e "smtp_tls_security_level = encrypt"
    postconf -e "smtp_tls_wrappermode = no"
    postconf -e "smtp_use_tls = yes"
    postconf -e "smtp_sender_dependent_authentication = no"
    postconf -e "myhostname = cryoss-rpi1.local"
    postconf -e "mydestination = "
    postconf -e "local_transport = error:local delivery disabled"
    postconf -e "smtpd_relay_restrictions = permit_mynetworks, reject"
    # Credentials SMTP
    echo "[$SMTP_HOST]:$SMTP_PORT    $SMTP_USER:$SMTP_PASS" > /etc/postfix/sasl_passwd
    chmod 600 /etc/postfix/sasl_passwd
    postmap /etc/postfix/sasl_passwd
    # UFW : autoriser port 25 depuis RPi2 sur le lien interco uniquement
    ufw allow from "10.42.0.2" to "10.42.0.1" port 25 comment "Relais SMTP RPi2 vers RPi1" 2>/dev/null || true
    systemctl enable postfix
    systemctl restart postfix
    ok "Relais SMTP postfix actif — RPi2 envoie ses emails via RPi1 (${INTERCO_IP_RPI1}:25)"
else
    warn "Relais SMTP non configuré — RPi2 ne pourra pas envoyer d'emails de monitoring"
fi
    cryoss_done "09-msmtp"
fi

# =============================================================================
if cryoss_step "09b-emaillib" "9b. Librairie email HTML partagée"; then

# Librairie de templates email HTML - utilisee par cryoss-backup, cryoss-health,
# cryoss-honeypot et alertes RPi2. Evite la duplication et harmonise le look.
mkdir -p /usr/local/lib
cat > /usr/local/lib/cryoss-email.sh << 'EMAILLIB_EOF'
#!/usr/bin/env bash
# CRYOSS - Librairie templates email HTML (partagee)

: "${CLIENT_NAME:=CRYOSS}"
: "${EMAIL_TO:=}"
: "${EMAIL_TO_2:=}"
: "${HOSTNAME_VAL:=$(hostname 2>/dev/null || echo unknown)}"
: "${LOG:=/var/log/cryoss-email.log}"

_tshort() { date '+%d/%m/%Y %H:%M'; }

_elog() {
    [[ -n "${LOG:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [email] $1" >> "$LOG" 2>/dev/null || true
}

badge() {
    local lbl="$1" t="$2"
    case "$t" in
        ok)   echo "<span style='background:#ecfdf5;color:#059669;padding:2px 9px;border-radius:3px;font-size:11px;font-weight:700;border:1px solid #a7f3d0;'>$lbl</span>" ;;
        warn) echo "<span style='background:#fffbeb;color:#d97706;padding:2px 9px;border-radius:3px;font-size:11px;font-weight:700;border:1px solid #fde68a;'>$lbl</span>" ;;
        crit) echo "<span style='background:#fef2f2;color:#dc2626;padding:2px 9px;border-radius:3px;font-size:11px;font-weight:700;border:1px solid #fecaca;'>$lbl</span>" ;;
        info) echo "<span style='background:#eef2ff;color:#6366f1;padding:2px 9px;border-radius:3px;font-size:11px;font-weight:700;border:1px solid #c7d2fe;'>$lbl</span>" ;;
        *)    echo "<span style='background:#f1f5f9;color:#475569;padding:2px 9px;border-radius:3px;font-size:11px;font-weight:700;border:1px solid #cbd5e1;'>$lbl</span>" ;;
    esac
}

section_open() {
    echo "<table width='100%' cellpadding='0' cellspacing='0' style='margin-bottom:18px;'><tr><td style='padding-bottom:7px;border-bottom:1px solid #e2e8f0;'><span style='color:#2563eb;font-size:11px;font-weight:700;letter-spacing:1.5px;text-transform:uppercase;'>$1</span></td></tr><tr><td style='padding-top:10px;'><table width='100%' cellpadding='0' cellspacing='0'>"
}
section_close() { echo "</table></td></tr></table>"; }

mrow() {
    echo "<tr><td style='padding:5px 0;color:#64748b;font-size:13px;width:48%;'>$1</td><td style='padding:5px 0;color:#1e293b;font-size:13px;font-weight:600;'>$2 $3</td></tr>"
}

alert_banner() {
    local msg="$1" type="${2:-crit}"
    case "$type" in
        ok)   echo "<div style='background:#f0fdf4;border-left:4px solid #059669;padding:11px 14px;border-radius:0 6px 6px 0;margin-bottom:18px;'><span style='color:#059669;font-weight:700;font-size:14px;'>&#10003; $msg</span></div>" ;;
        warn) echo "<div style='background:#fffbeb;border-left:4px solid #d97706;padding:11px 14px;border-radius:0 6px 6px 0;margin-bottom:18px;'><span style='color:#d97706;font-weight:700;font-size:14px;'>&#9888; $msg</span></div>" ;;
        info) echo "<div style='background:#eff6ff;border-left:4px solid #2563eb;padding:11px 14px;border-radius:0 6px 6px 0;margin-bottom:18px;'><span style='color:#2563eb;font-weight:700;font-size:14px;'>&#8505; $msg</span></div>" ;;
        crit|*) echo "<div style='background:#fef2f2;border-left:4px solid #dc2626;padding:11px 14px;border-radius:0 6px 6px 0;margin-bottom:18px;'><span style='color:#dc2626;font-weight:700;font-size:14px;'>&#9888; $msg</span></div>" ;;
    esac
}

code_block() {
    echo "<pre style='font-family:monospace;font-size:11px;color:#1e293b;background:#f1f5f9;padding:10px;border-radius:5px;overflow-x:auto;margin:6px 0;white-space:pre-wrap;word-break:break-all;border:1px solid #e2e8f0;'>$1</pre>"
}

wrap_email() {
    local title="$1" body="$2" accent="${3:-info}"
    local accent_color
    case "$accent" in
        ok)   accent_color="#059669" ;;
        warn) accent_color="#d97706" ;;
        crit) accent_color="#dc2626" ;;
        *)    accent_color="#2563eb" ;;
    esac
    cat << TMPL
<!DOCTYPE html>
<html lang="fr">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:0;background:#f8f9fa;font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#f8f9fa;">
<tr><td align="center" style="padding:28px 12px;">
<table width="620" cellpadding="0" cellspacing="0" style="max-width:620px;width:100%;background:#ffffff;border-radius:8px;border:1px solid #e2e8f0;overflow:hidden;">
  <tr><td style="background:#ffffff;padding:24px 36px;border-bottom:2px solid ${accent_color};">
    <table width="100%" cellpadding="0" cellspacing="0"><tr>
      <td><span style="font-size:20px;font-weight:800;color:#1e293b;letter-spacing:1px;">CRYOSS</span>
      <p style="margin:4px 0 0;color:#64748b;font-size:11px;letter-spacing:2px;text-transform:uppercase;">Monitoring</p></td>
      <td align="right" valign="middle"><span style="background:#eff6ff;border:1px solid ${accent_color};color:${accent_color};padding:5px 13px;border-radius:16px;font-size:12px;font-weight:700;letter-spacing:1px;">${CLIENT_NAME}</span></td>
    </tr></table>
  </td></tr>
  <tr><td style="padding:24px 36px 6px;">
    <h1 style="margin:0;color:#1e293b;font-size:18px;font-weight:700;">${title}</h1>
    <p style="margin:5px 0 0;color:#64748b;font-size:12px;">$(_tshort) &nbsp;&bull;&nbsp; ${HOSTNAME_VAL}</p>
  </td></tr>
  <tr><td style="padding:14px 36px 28px;">${body}</td></tr>
  <tr><td style="background:#f8f9fa;padding:16px 36px;border-top:1px solid #e2e8f0;">
    <table width="100%" cellpadding="0" cellspacing="0"><tr>
      <td style="color:#94a3b8;font-size:11px;">Cryoss &copy; <a href="https://analyss.fr" style="color:#2563eb;text-decoration:none;">Analyss</a> &mdash; Rapport automatique</td>
      <td align="right"><a href="https://analyss.fr" style="color:#2563eb;font-size:11px;text-decoration:none;">analyss.fr</a></td>
    </tr></table>
  </td></tr>
</table></td></tr></table>
</body></html>
TMPL
}

send_html_email() {
    local subject="$1" full_html="$2"
    local rc=0
    for DEST in "$EMAIL_TO" "$EMAIL_TO_2"; do
        [[ -z "$DEST" ]] && continue
        {
            echo "To: $DEST"
            echo "Subject: $subject"
            echo "MIME-Version: 1.0"
            echo "Content-Type: text/html; charset=UTF-8"
            echo ""
            echo "$full_html"
        } | msmtp "$DEST" 2>/dev/null || { _elog "WARN: email vers $DEST echoue"; rc=1; }
    done
    return $rc
}

send_email_wrapped() {
    local subject="$1" title="$2" body="$3" accent="${4:-info}"
    local full_html
    full_html=$(wrap_email "$title" "$body" "$accent")
    send_html_email "$subject" "$full_html"
}
EMAILLIB_EOF
chmod 644 /usr/local/lib/cryoss-email.sh
chown root:root /usr/local/lib/cryoss-email.sh
ok "Librairie email HTML installee : /usr/local/lib/cryoss-email.sh"
    cryoss_done "09b-emaillib"
fi

# =============================================================================
if cryoss_step "10-backup-script" "10. Script cryoss-backup.sh"; then

# On ecrit le script avec des placeholders puis on les remplace
# pour eviter les problemes d'expansion dans le heredoc
cat > /usr/local/bin/cryoss-backup.sh << 'SCRIPT_HEREDOC'
#!/bin/bash
# =============================================================================
#  CRYOSS — Triple sauvegarde chiffree via rclone
#
#  3 chemins independants, 3 cles independantes, chiffrement authentifie :
#    C1 : rclone crypt (XSalsa20-Poly1305 + AES-256-EME) → RAID local
#    C2 : rclone crypt (XSalsa20-Poly1305 + AES-256-EME) → RPi2 via SFTP interco
#    C3 : rclone crypt (XSalsa20-Poly1305 + AES-256-EME) → SFTP distant + versioning
#
#  Chaque chemin a ses propres cles — compromission d'un chemin != compromission des autres.
#  XSalsa20-Poly1305 = chiffrement authentifie (AEAD) : detecte toute alteration.
#  AES-256-EME = obfuscation des noms de fichiers sur les 3 chemins.
#  Noms de fichiers JAMAIS visibles en clair sur aucune destination.
#
#  Isolation : l'echec d'un chemin ne bloque JAMAIS les autres.
#  Versioning C3 : --backup-dir conserve les fichiers remplaces.
# =============================================================================

set -uo pipefail   # PAS -e : gestion manuelle des erreurs par chemin

# ── Configuration ─────────────────────────────────────────────────────────────
EMAIL_TO="DS_EMAIL_TO"
EMAIL_TO_2="DS_EMAIL_TO_2"
CLIENT_NAME="DS_CLIENT_NAME"
ENABLE_SFTP="DS_ENABLE_SFTP"
SRC_DIR="/etc/sauvegarde"
LOCAL_ENC="/etc/encrypted"
LOG="/var/log/cryoss-backup.log"
HOSTNAME_VAL="$(hostname 2>/dev/null || echo cryoss1)"

# Sourcer la librairie email HTML partagee
if [[ -f /usr/local/lib/cryoss-email.sh ]]; then
    # shellcheck source=/usr/local/lib/cryoss-email.sh
    source /usr/local/lib/cryoss-email.sh
fi

# [F3] Lockfile — alerte par email HTML si backup deja en cours
LOCKFILE="/var/run/cryoss-backup.lock"
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    MSG="[$(date '+%Y-%m-%d %H:%M:%S')] ABORT: backup deja en cours (lockfile: $LOCKFILE)"
    echo "$MSG" >> "$LOG"; echo "$MSG" >&2
    if declare -F send_email_wrapped &>/dev/null; then
        LOCK_BODY=$(alert_banner "Sauvegarde deja en cours — execution annulee" "warn")
        LOCK_BODY+=$(section_open "DETAILS")
        LOCK_BODY+=$(mrow "Lockfile" "$LOCKFILE")
        LOCK_BODY+=$(mrow "Action" "Nouvelle execution annulee (evite la corruption)")
        LOCK_BODY+=$(mrow "Recommandation" "Verifier qu'un backup precedent n'est pas bloque")
        LOCK_BODY+=$(section_close)
        send_email_wrapped \
            "[Cryoss $CLIENT_NAME] WARN — backup lock (deja en cours)" \
            "Sauvegarde verrouillee" \
            "$LOCK_BODY" \
            "warn"
    fi
    exit 1
fi
BACKUP_DATE=$(date +%Y-%m-%d)

# Compteurs par chemin
ERR_C1=0; ERR_C2=0; ERR_C3=0

log() { local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"; echo "$msg" >> "$LOG"; echo "$msg" >&2; }

# ── Preflight ─────────────────────────────────────────────────────────────────
preflight_check() {
    local abort=0
    if ! mountpoint -q "$SRC_DIR" 2>/dev/null && [[ ! -d "$SRC_DIR" ]]; then
        log "FATAL: $SRC_DIR inaccessible"; abort=1
    fi
    if ! mountpoint -q "$LOCAL_ENC" 2>/dev/null && [[ ! -d "$LOCAL_ENC" ]]; then
        log "FATAL: $LOCAL_ENC inaccessible (RAID monte ?)"; abort=1
    fi
    # Verifier que rclone.conf existe avec les 3 remotes
    if ! rclone listremotes 2>/dev/null | grep -q "cryoss-c1-crypt"; then
        log "FATAL: remote cryoss-c1-crypt absent dans rclone.conf"; abort=1
    fi
    if ! rclone listremotes 2>/dev/null | grep -q "cryoss-c2-crypt"; then
        log "FATAL: remote cryoss-c2-crypt absent dans rclone.conf"; abort=1
    fi
    local free_pct
    free_pct=$(df "$LOCAL_ENC" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print 100-$5}')
    if [[ -n "$free_pct" ]] && (( free_pct < 5 )); then
        log "FATAL: moins de 5% libre sur $LOCAL_ENC (${free_pct}%)"; abort=1
    fi
    # Verifier qu'il y a des fichiers source (hors sentinel)
    local count
    count=$(find "$SRC_DIR" -maxdepth 1 -type f ! -name "__CRYOSS_SENTINEL__" 2>/dev/null | wc -l)
    if (( count == 0 )); then
        log "FATAL: aucun fichier dans $SRC_DIR"; abort=1
    fi
    (( abort )) && return 1
    log "  $count fichier(s) source, $(( 100 - ${free_pct:-0} ))% utilise sur $LOCAL_ENC"
    return 0
}

# ── Email HTML ───────────────────────────────────────────────────────────────
# Utilise la librairie /usr/local/lib/cryoss-email.sh (sourcee plus haut).
# Fallback plain-text si la lib n'est pas disponible.
send_email() {
    local status="$1"
    local total_err=$(( ERR_C1 + ERR_C2 + ERR_C3 ))
    local subject

    # Badges d'etat par chemin
    local c1_badge c2_badge c3_badge c3_label
    if (( ERR_C1 == 0 )); then c1_badge=$(badge "OK" ok); else c1_badge=$(badge "ERREUR" crit); fi
    if (( ERR_C2 == 0 )); then c2_badge=$(badge "OK" ok); else c2_badge=$(badge "ERREUR" crit); fi
    if [[ "$ENABLE_SFTP" != "yes" ]]; then
        c3_badge=$(badge "DESACTIVE" info)
        c3_label="C3 (SFTP distant)"
    elif (( ERR_C3 == 0 )); then
        c3_badge=$(badge "OK" ok)
        c3_label="C3 (SFTP distant + versioning)"
    else
        c3_badge=$(badge "ERREUR" crit)
        c3_label="C3 (SFTP distant)"
    fi

    # Metadonnees
    local src_count src_size restore_status manifest_path
    src_count=$(find "$SRC_DIR" -maxdepth 1 -type f ! -name "__CRYOSS_SENTINEL__" 2>/dev/null | wc -l)
    src_size=$(du -sh "$SRC_DIR" 2>/dev/null | awk '{print $1}')
    restore_status="${RESTORE_OK:-non teste}"
    manifest_path="${MANIFEST:-N/A}"

    # Corps HTML
    local body=""
    if [[ "$status" == "success" ]]; then
        subject="[Cryoss $CLIENT_NAME] Sauvegarde OK — $BACKUP_DATE"
        body+=$(alert_banner "Sauvegarde triple chiffrement reussie — $BACKUP_DATE" "ok")

        body+=$(section_open "CHEMINS DE SAUVEGARDE")
        body+=$(mrow "C1 (RAID local)" "XSalsa20-Poly1305" "$c1_badge")
        body+=$(mrow "C2 (RPi2 interco)" "XSalsa20-Poly1305" "$c2_badge")
        body+=$(mrow "$c3_label" "XSalsa20-Poly1305" "$c3_badge")
        body+=$(section_close)

        body+=$(section_open "DONNEES SAUVEGARDEES")
        body+=$(mrow "Fichiers source" "$src_count fichier(s)" "")
        body+=$(mrow "Taille source" "${src_size:-N/A}" "")
        body+=$(mrow "Test restauration" "$restore_status" "$(if [[ "$restore_status" == "ok" ]]; then badge "OK" ok; else badge "$restore_status" warn; fi)")
        body+=$(section_close)

        body+=$(section_open "SECURITE")
        body+=$(mrow "Chiffrement" "XSalsa20-Poly1305 (AEAD)" "")
        body+=$(mrow "Noms de fichiers" "AES-256-EME (obfusques)" "")
        body+=$(mrow "Cles independantes" "3 cles distinctes par chemin" "$(badge "ISOLE" info)")
        body+=$(section_close)
    else
        subject="[Cryoss $CLIENT_NAME] ECHEC sauvegarde ($total_err err) — $BACKUP_DATE"
        body+=$(alert_banner "Echec sauvegarde — $total_err erreur(s) detectee(s)" "crit")

        body+=$(section_open "CHEMINS DE SAUVEGARDE")
        body+=$(mrow "C1 (RAID local)" "XSalsa20-Poly1305" "$c1_badge")
        body+=$(mrow "C2 (RPi2 interco)" "XSalsa20-Poly1305" "$c2_badge")
        body+=$(mrow "$c3_label" "XSalsa20-Poly1305" "$c3_badge")
        body+=$(section_close)

        body+=$(section_open "DONNEES")
        body+=$(mrow "Fichiers source" "$src_count fichier(s)" "")
        body+=$(mrow "Test restauration" "$restore_status" "")
        body+=$(section_close)

        body+=$(section_open "LOGS A CONSULTER")
        body+=$(code_block "Principal : $LOG
C1 rclone : /var/log/rclone_cryoss_c1.log
C2 rclone : /var/log/rclone_cryoss_c2.log
C3 rclone : /var/log/rclone_cryoss_c3.log
Manifeste : $manifest_path")
        body+=$(section_close)
    fi

    # Envoi via la lib (HTML) ou fallback plain text
    if declare -F send_email_wrapped &>/dev/null; then
        local accent="ok"
        [[ "$status" != "success" ]] && accent="crit"
        send_email_wrapped "$subject" "${subject#*] }" "$body" "$accent" \
            || log "WARN: envoi email HTML echoue — fallback plain"
    else
        # Fallback plain text si la lib est absente
        local plain_body="Sauvegarde $BACKUP_DATE — status: $status
C1: $( (( ERR_C1 )) && echo ERREUR || echo OK )
C2: $( (( ERR_C2 )) && echo ERREUR || echo OK )
C3: $( [[ "$ENABLE_SFTP" != "yes" ]] && echo DESACTIVE || { (( ERR_C3 )) && echo ERREUR || echo OK; } )
Logs: $LOG"
        for DEST in "$EMAIL_TO" "$EMAIL_TO_2"; do
            [[ -z "$DEST" ]] && continue
            { echo "To: $DEST"; echo "Subject: $subject"; echo ""; echo "$plain_body"; } \
                | msmtp "$DEST" 2>/dev/null || log "WARN: email vers $DEST echoue"
        done
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
log "======== Cryoss backup [$CLIENT_NAME] $BACKUP_DATE ========"
if ! preflight_check; then send_email "failure"; exit 1; fi

# =============================================================================
# CHEMIN 1 : rclone crypt → RAID local (/etc/encrypted)
# Remote : cryoss-c1-crypt (XSalsa20-Poly1305, KEY_C1)
# Noms de fichiers chiffres par AES-256-EME (obfuscation totale)
# =============================================================================
log "-- C1 : rclone sync -> cryoss-c1-crypt (RAID local) --"

RCLONE_LOG_C1="/var/log/rclone_cryoss_c1.log"

# [C3] Retrait temporaire de chattr +a — rclone doit pouvoir supprimer/renommer
# les fichiers (sinon echec sur .partial residuels ou mises a jour).
# On reposera chattr +a apres le sync + cryptcheck.
chattr -R -a "$LOCAL_ENC" 2>/dev/null || log "  [C1 WARN] chattr -a partiel (normal si pas active)"

set +e
rclone sync "$SRC_DIR" cryoss-c1-crypt: \
    --exclude "__CRYOSS_SENTINEL__" \
    --checksum \
    --transfers 2 \
    --retries 3 \
    --bwlimit 50M \
    --log-file "$RCLONE_LOG_C1" \
    --log-level INFO \
    2>/dev/null
RC_C1=$?
set -e

if (( RC_C1 == 0 )); then
    # [I1] Verification integrite post-sync : cryptcheck valide que les fichiers
    # chiffres sur la destination sont decryptables et matchent la source
    set +e
    rclone cryptcheck "$SRC_DIR" cryoss-c1-crypt: \
        --exclude "__CRYOSS_SENTINEL__" \
        --one-way 2>>"$RCLONE_LOG_C1"
    RC_CHECK=$?
    set -e
    if (( RC_CHECK == 0 )); then
        log "  [C1 OK] sync + integrite verifiee (cryptcheck pass)"
    else
        log "  [C1 WARN] sync OK mais cryptcheck echoue (rc=$RC_CHECK) — verifier $RCLONE_LOG_C1"
        ERR_C1=1
    fi
else
    log "  [C1 ERREUR] rclone sync rc=$RC_C1"
    ERR_C1=1
fi

if [[ -x /usr/local/bin/cryoss-cleanup.sh ]]; then
    /usr/local/bin/cryoss-cleanup.sh 2>/dev/null || log "  [C1 WARN] cleanup echoue"
fi

# Repose chattr +a sur /etc/encrypted apres le sync C1 + cryptcheck + cleanup
chattr -R +a "$LOCAL_ENC" 2>/dev/null || log "  [C1 WARN] chattr +a non repose"

# =============================================================================
# CHEMIN 2 : rclone crypt → RPi2 via SFTP interco (10.42.0.x)
# =============================================================================
log "-- C2 : rclone sync -> cryoss-c2-crypt (RPi2 SFTP interco) --"

RCLONE_LOG_C2="/var/log/rclone_cryoss_c2.log"
set +e
rclone sync "$SRC_DIR" cryoss-c2-crypt: \
    --exclude "__CRYOSS_SENTINEL__" \
    --checksum \
    --transfers 2 \
    --retries 3 \
    --bwlimit 0 \
    --contimeout 15s \
    --timeout 30s \
    --log-file "$RCLONE_LOG_C2" \
    --log-level INFO \
    2>/dev/null
RC_C2=$?
set -e

if (( RC_C2 == 0 )); then
    # [I1] Verification integrite : rclone cryptcheck impossible cross-host
    # (source plain sur RPi1, dest crypt sur RPi2 via SFTP — cryptcheck exige
    # les deux accessibles en decryption depuis la meme machine).
    # On verifie plutot que le nombre de fichiers cote dest correspond a la source.
    set +e
    SRC_COUNT=$(find "$SRC_DIR" -maxdepth 1 -type f ! -name "__CRYOSS_SENTINEL__" 2>/dev/null | wc -l)
    DST_COUNT=$(rclone size cryoss-c2-crypt: 2>/dev/null | grep -oP 'Total objects: \K[0-9,]+' | tr -d ',')
    set -e
    DST_COUNT="${DST_COUNT:-0}"
    if [[ "$SRC_COUNT" -gt 0 ]] && [[ "$DST_COUNT" -ge "$SRC_COUNT" ]]; then
        log "  [C2 OK] sync OK — $SRC_COUNT fichier(s) source, $DST_COUNT cote RPi2"
    else
        log "  [C2 WARN] sync OK mais ecart comptage (src=$SRC_COUNT dst=$DST_COUNT)"
        ERR_C2=1
    fi
else
    log "  [C2 ERREUR] rclone sync rc=$RC_C2 — RPi2 peut-etre inaccessible"
    ERR_C2=1
fi

# =============================================================================
# CHEMIN 3 : rclone crypt → SFTP distant + versioning
# --backup-dir : fichiers remplaces conserves dans cryoss-c3-versions:DATE/
# =============================================================================
if [[ "$ENABLE_SFTP" != "yes" ]]; then
    log "-- C3 : SFTP distant desactive — ignore"
else
    log "-- C3 : rclone sync -> cryoss-c3-crypt (SFTP distant + versioning) --"

    RCLONE_LOG_C3="/var/log/rclone_cryoss_c3.log"
    set +e
    rclone sync "$SRC_DIR" cryoss-c3-crypt: \
        --backup-dir "cryoss-c3-versions:${BACKUP_DATE}" \
        --exclude "__CRYOSS_SENTINEL__" \
        --checksum \
        --transfers 2 \
        --retries 3 \
        --low-level-retries 5 \
        --bwlimit 10M \
        --contimeout 30s \
        --timeout 60s \
        --log-file "$RCLONE_LOG_C3" \
        --log-level INFO \
        2>/dev/null
    RC_C3=$?
    set -e

    if (( RC_C3 == 0 )); then
        # [I1] Verification integrite post-sync
        set +e
        rclone cryptcheck "$SRC_DIR" cryoss-c3-crypt: \
            --exclude "__CRYOSS_SENTINEL__" \
            --one-way 2>>"$RCLONE_LOG_C3"
        RC_CHECK=$?
        set -e
        if (( RC_CHECK == 0 )); then
            SYNCED=$(grep -c "Copied\b" "$RCLONE_LOG_C3" 2>/dev/null || echo 0)
            log "  [C3 OK] $SYNCED fichier(s), integrite verifiee, versions dans cryoss-c3-versions:${BACKUP_DATE}"
        else
            log "  [C3 WARN] sync OK mais cryptcheck echoue (rc=$RC_CHECK)"
            ERR_C3=1
        fi
        [[ -x /usr/local/bin/cryoss-versions-purge.sh ]] && \
            /usr/local/bin/cryoss-versions-purge.sh 2>/dev/null || log "  [C3 WARN] purge versions echouee"
    else
        log "  [C3 ERREUR] rclone sync rc=$RC_C3 — voir $RCLONE_LOG_C3"
        ERR_C3=1
    fi
fi

# =============================================================================
# [I2/RE1] TEST DE RESTAURATION — verifie qu'un fichier est restaurable
# Un backup non teste n'existe pas. On restaure 1 fichier aleatoire de C1
# dans /tmp et on compare le hash SHA-256 avec l'original.
# =============================================================================
RESTORE_OK="non teste"
TEST_FILE=$(find "$SRC_DIR" -maxdepth 1 -type f ! -name "__CRYOSS_SENTINEL__" 2>/dev/null | shuf -n 1)
if [[ -n "$TEST_FILE" ]] && (( ERR_C1 == 0 )); then
    log "-- Test restauration : $(basename "$TEST_FILE") depuis C1 --"
    RESTORE_DIR=$(mktemp -d /tmp/cryoss-restore-test.XXXXXX)
    set +e
    rclone copy "cryoss-c1-crypt:$(basename "$TEST_FILE")" "$RESTORE_DIR/" 2>/dev/null
    RC_RESTORE=$?
    set -e
    if (( RC_RESTORE == 0 )) && [[ -f "$RESTORE_DIR/$(basename "$TEST_FILE")" ]]; then
        HASH_SRC=$(sha256sum "$TEST_FILE" | awk '{print $1}')
        HASH_DST=$(sha256sum "$RESTORE_DIR/$(basename "$TEST_FILE")" | awk '{print $1}')
        if [[ "$HASH_SRC" == "$HASH_DST" ]]; then
            log "  [RESTORE OK] SHA-256 identique — backup C1 restaurable"
            RESTORE_OK="ok"
        else
            log "  [RESTORE ECHEC] SHA-256 different ! Source=$HASH_SRC Restore=$HASH_DST"
            RESTORE_OK="echec-hash"
            ERR_C1=1
        fi
    else
        log "  [RESTORE ECHEC] rclone copy echoue (rc=$RC_RESTORE)"
        RESTORE_OK="echec-rclone"
    fi
    rm -rf "$RESTORE_DIR"
else
    log "  [RESTORE] pas de fichier test ou C1 en erreur"
fi

# =============================================================================
# [I3] MANIFESTE — stocke les metadonnees independamment des archives
# =============================================================================
MANIFEST_DIR="/var/lib/cryoss/manifests"
mkdir -p "$MANIFEST_DIR"
MANIFEST="$MANIFEST_DIR/manifest-${BACKUP_DATE}.json"
{
    echo "{"
    echo "  \"date\": \"$BACKUP_DATE\","
    echo "  \"timestamp\": \"$(date -Iseconds)\","
    echo "  \"client\": \"$CLIENT_NAME\","
    echo "  \"source_files\": $(find "$SRC_DIR" -maxdepth 1 -type f ! -name "__CRYOSS_SENTINEL__" | wc -l),"
    echo "  \"source_size_bytes\": $(du -sb "$SRC_DIR" 2>/dev/null | awk '{print $1}'),"
    echo "  \"c1_status\": \"$( (( ERR_C1 == 0 )) && echo ok || echo error )\","
    echo "  \"c2_status\": \"$( (( ERR_C2 == 0 )) && echo ok || echo error )\","
    echo "  \"c3_status\": \"$( (( ERR_C3 == 0 )) && echo ok || echo error )\","
    echo "  \"restore_test\": \"$RESTORE_OK\""
    echo "}"
} > "$MANIFEST"
log "  Manifeste : $MANIFEST"

# Garder les 90 derniers manifestes (3 mois)
find "$MANIFEST_DIR" -name "manifest-*.json" -mtime +90 -delete 2>/dev/null || true

# =============================================================================
# BILAN
# =============================================================================
TOTAL_ERR=$(( ERR_C1 + ERR_C2 + ERR_C3 ))
log "======== Bilan : C1=$ERR_C1 | C2=$ERR_C2 | C3=$ERR_C3 | restore=$RESTORE_OK (total=$TOTAL_ERR) ========"

if (( TOTAL_ERR == 0 )); then
    send_email "success"
else
    send_email "failure"; exit 1
fi
SCRIPT_HEREDOC

# Injecter les variables dans le script genere
sed -i \
    -e "s|DS_ENABLE_SFTP|${ENABLE_SFTP}|g" \
    -e "s|DS_EMAIL_TO_2|${EMAIL_TO_2:-}|g" \
    -e "s|DS_EMAIL_TO|${EMAIL_TO}|g" \
    -e "s|DS_CLIENT_NAME|${CLIENT_NAME}|g" \
    /usr/local/bin/cryoss-backup.sh

chmod 700 /usr/local/bin/cryoss-backup.sh
chown root:root /usr/local/bin/cryoss-backup.sh
ok "Script cryoss-backup.sh installe (3 chemins rclone independants)"
    cryoss_done "10-backup-script"
fi

# =============================================================================
if cryoss_step "11-samba" "11. Samba (configuration de base)"; then

# smb.conf : global + 2 partages de base + include pour les partages dynamiques (wizard)
cat > /etc/samba/smb.conf <<SAMBA_EOF
[global]
   workgroup = WORKGROUP
   server string = Cryoss RPi1 [$CLIENT_NAME]
   server role = standalone server
   security = user
   map to guest = never
   guest ok = no
   restrict anonymous = 2
   client min protocol = SMB2
   server min protocol = SMB2
   smb encrypt = required
   ntlm auth = no
   lanman auth = no
   disable netbios = yes
   dns proxy = no
   usershare allow guests = no
   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file
   # Partages dynamiques (gérés par le wizard interactif — étape 11b)
   include = /etc/samba/cryoss-shares.conf

[sauvegarde]
   comment = Depot source [$CLIENT_NAME]
   path = /etc/sauvegarde
   browseable = no
   read only = no
   guest ok = no
   valid users = ds-user habyss
   write list = ds-user habyss
   create mask = 0660
   directory mask = 2770
   force group = samba-share
   vfs objects = fruit streams_xattr
   fruit:metadata = stream
   fruit:model = MacSamba
   fruit:posix_rename = yes
   fruit:veto_appledouble = no
   fruit:nfs_aces = no
   fruit:wipe_intentionally_left_blank_rfork = yes
   fruit:delete_empty_adfiles = yes
   strict allocate = yes

[encrypted_backup]
   comment = Archives chiffrees [$CLIENT_NAME] (lecture seule)
   path = /etc/encrypted
   browseable = no
   read only = yes
   guest ok = no
   valid users = habyss
SAMBA_EOF

# Fichier d'inclusion pour le wizard — vide au départ, alimenté par l'étape 11b
[[ -f /etc/samba/cryoss-shares.conf ]] || {
    cat > /etc/samba/cryoss-shares.conf <<'SH_EOF'
# =============================================================================
#  Partages dynamiques Cryoss — généré par le wizard interactif (étape 11b).
#  NE PAS ÉDITER À LA MAIN : utilisez `install_rpi1.sh --from-step 11b-samba-wizard`
#  pour rejouer le wizard, ou éditez /etc/cryoss/shares.conf puis régénérez.
# =============================================================================
SH_EOF
    chmod 644 /etc/samba/cryoss-shares.conf
}

cryoss_run "Redémarrage smbd" -- bash -c "systemctl restart smbd && systemctl enable smbd"
ok "Samba configure (SMB2+, chiffrement force)"
    cryoss_done "11-samba"
fi

# =============================================================================
#  Étape 11b : WIZARD SAMBA INTERACTIF
#  - Crée des dossiers-partages sous /etc/sauvegarde (ou chemin libre)
#  - Crée des utilisateurs Samba *purs* (service Unix nologin + locked, jamais shell/sudo)
#  - Définit une matrice user × partage avec niveaux R / RW / refus explicite
#  - Persiste la config dans /etc/cryoss/shares.conf (rejouable, éditable)
# =============================================================================

# Charge la config wizard existante (utile à la reprise / rejeu)
# IMPORTANT : `declare -ga` / `-gA` pour rendre les variables globales depuis une fonction.
cryoss_wizard_load_config() {
    declare -ga WIZ_USERS=()
    declare -ga WIZ_SHARES=()
    declare -gA WIZ_SHARE_PATH=()
    declare -gA WIZ_USER_PASS=()
    declare -gA WIZ_PERMS=()        # clé "share|user" → "r" | "rw" | "no"

    [[ -f /etc/cryoss/shares.conf ]] || return 0
    local kind a b c
    while IFS=' ' read -r kind a b c; do
        [[ -z "$kind" || "$kind" == "#"* ]] && continue
        case "$kind" in
            USER)   WIZ_USERS+=("$a"); WIZ_USER_PASS["$a"]="${b:-}" ;;
            SHARE)  WIZ_SHARES+=("$a"); WIZ_SHARE_PATH["$a"]="$b" ;;
            PERM)   WIZ_PERMS["${a}|${b}"]="$c" ;;
        esac
    done < /etc/cryoss/shares.conf
}

cryoss_wizard_save_config() {
    mkdir -p /etc/cryoss; chmod 700 /etc/cryoss
    {
        echo "# Cryoss — configuration des partages dynamiques (wizard)"
        echo "# Format : USER <nom> <pass-obscured> | SHARE <nom> <chemin> | PERM <share> <user> <r|rw|no>"
        echo "# Généré $(date '+%Y-%m-%d %H:%M:%S')"
        local u s key
        for u in "${WIZ_USERS[@]}"; do
            printf 'USER %s %s\n' "$u" "${WIZ_USER_PASS[$u]:-}"
        done
        for s in "${WIZ_SHARES[@]}"; do
            printf 'SHARE %s %s\n' "$s" "${WIZ_SHARE_PATH[$s]}"
        done
        for key in "${!WIZ_PERMS[@]}"; do
            local sh="${key%|*}" us="${key#*|}"
            printf 'PERM %s %s %s\n' "$sh" "$us" "${WIZ_PERMS[$key]}"
        done
    } > /etc/cryoss/shares.conf
    chmod 600 /etc/cryoss/shares.conf
}

# Vérifie la validité d'un nom (alphanumérique + tirets, 2-32 chars)
cryoss_wizard_valid_name() {
    [[ "$1" =~ ^[a-z][a-z0-9_-]{1,31}$ ]]
}

# Liste les utilisateurs (numérotés)
cryoss_wizard_list_users() {
    if (( ${#WIZ_USERS[@]} == 0 )); then
        echo -e "  ${DIM}(aucun utilisateur Samba personnalisé)${NC}"
        return
    fi
    local i=1 u
    for u in "${WIZ_USERS[@]}"; do
        printf "  ${CRY}%2d)${NC} %s\n" "$i" "$u"
        i=$((i+1))
    done
}

# Liste les partages (numérotés)
cryoss_wizard_list_shares() {
    if (( ${#WIZ_SHARES[@]} == 0 )); then
        echo -e "  ${DIM}(aucun partage personnalisé)${NC}"
        return
    fi
    local i=1 s
    for s in "${WIZ_SHARES[@]}"; do
        printf "  ${CRY}%2d)${NC} %-20s ${DIM}→ %s${NC}\n" "$i" "$s" "${WIZ_SHARE_PATH[$s]}"
        i=$((i+1))
    done
}

# Affiche la matrice user × partage
cryoss_wizard_show_matrix() {
    if (( ${#WIZ_SHARES[@]} == 0 )) || (( ${#WIZ_USERS[@]} == 0 )); then
        echo -e "  ${DIM}(matrice vide — ajoutez d'abord utilisateurs et partages)${NC}"
        return
    fi
    printf "  ${BOLD}%-18s${NC}" "PARTAGE \\ USER"
    local u
    for u in "${WIZ_USERS[@]}"; do printf " ${BOLD}%-10s${NC}" "$u"; done
    echo
    local s perm color
    for s in "${WIZ_SHARES[@]}"; do
        printf "  ${CRY}%-18s${NC}" "$s"
        for u in "${WIZ_USERS[@]}"; do
            perm="${WIZ_PERMS[${s}|${u}]:-no}"
            case "$perm" in
                rw) color="${GREEN}RW${NC}      " ;;
                r)  color="${YELLOW}R${NC}       " ;;
                no) color="${RED}–${NC}       " ;;
            esac
            printf " %b" "$color"
        done
        echo
    done
}

# Ajoute un utilisateur Samba (jamais système : nologin + Unix password locked)
cryoss_wizard_add_user() {
    local name pass1 pass2
    while true; do
        read -rp "  Nom du nouvel utilisateur Samba (a-z, 0-9, _, -) : " name
        if ! cryoss_wizard_valid_name "$name"; then
            warn "Nom invalide. Doit commencer par une lettre, 2 à 32 caractères [a-z0-9_-]."
            continue
        fi
        if printf '%s\n' "${WIZ_USERS[@]}" 2>/dev/null | grep -qxF "$name"; then
            warn "Cet utilisateur existe déjà dans la config wizard."
            continue
        fi
        if id "$name" &>/dev/null && [[ "$name" != "$name" ]]; then
            : # placeholder
        fi
        # Refus de réutiliser des comptes "humains" existants
        if [[ "$name" == "habyss" || "$name" == "root" || "$name" == "ds-user" ]]; then
            warn "'$name' est un compte protégé du système Cryoss. Choisissez un autre nom."
            continue
        fi
        break
    done
    while true; do
        read -rsp "  Mot de passe Samba pour $name : " pass1; echo
        read -rsp "  Confirmer le mot de passe        : " pass2; echo
        if [[ "$pass1" != "$pass2" ]]; then
            warn "Les mots de passe ne correspondent pas."
        elif (( ${#pass1} < 8 )); then
            warn "Mot de passe trop court (min 8 caractères)."
        else
            break
        fi
    done
    WIZ_USERS+=("$name")
    WIZ_USER_PASS["$name"]="$pass1"
    ok "Utilisateur Samba '$name' ajouté à la config (sera créé à l'application)."
}

cryoss_wizard_add_share() {
    local name path
    while true; do
        read -rp "  Nom du partage (a-z, 0-9, _, -) : " name
        if ! cryoss_wizard_valid_name "$name"; then
            warn "Nom invalide."
            continue
        fi
        if [[ "$name" == "sauvegarde" || "$name" == "encrypted_backup" || "$name" == "global" ]]; then
            warn "'$name' est réservé. Choisissez un autre nom."
            continue
        fi
        if printf '%s\n' "${WIZ_SHARES[@]}" 2>/dev/null | grep -qxF "$name"; then
            warn "Ce partage existe déjà dans la config wizard."
            continue
        fi
        break
    done
    read -rp "  Chemin (défaut: /etc/sauvegarde/$name) : " path
    path="${path:-/etc/sauvegarde/$name}"
    if [[ "$path" != /* ]]; then
        warn "Chemin absolu requis. Préfixe automatique avec /etc/sauvegarde/"
        path="/etc/sauvegarde/$path"
    fi
    WIZ_SHARES+=("$name")
    WIZ_SHARE_PATH["$name"]="$path"
    ok "Partage '$name' ajouté (chemin : $path). Définissez maintenant les droits."
}

cryoss_wizard_set_perms() {
    if (( ${#WIZ_SHARES[@]} == 0 )); then
        warn "Aucun partage à configurer. Ajoutez-en un d'abord."
        return
    fi
    if (( ${#WIZ_USERS[@]} == 0 )); then
        warn "Aucun utilisateur à configurer. Ajoutez-en un d'abord (ou utilisez habyss/ds-user)."
        return
    fi
    echo
    info "Partages disponibles :"
    cryoss_wizard_list_shares
    read -rp "  Numéro du partage : " idx
    [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#WIZ_SHARES[@]} )) \
        || { warn "Numéro invalide."; return; }
    local share="${WIZ_SHARES[$((idx-1))]}"

    echo
    info "Utilisateurs disponibles :"
    cryoss_wizard_list_users
    echo -e "  ${DIM}(comptes système prédéfinis également : habyss, ds-user — saisir le nom directement)${NC}"
    read -rp "  Numéro ou nom de l'utilisateur : " uref
    local user
    if [[ "$uref" =~ ^[0-9]+$ ]] && (( uref >= 1 && uref <= ${#WIZ_USERS[@]} )); then
        user="${WIZ_USERS[$((uref-1))]}"
    else
        user="$uref"
        # Vérifier que l'utilisateur existe (wizard ou système prédéfini)
        if ! printf '%s\n' "${WIZ_USERS[@]}" "habyss" "ds-user" 2>/dev/null | grep -qxF "$user"; then
            warn "Utilisateur '$user' inconnu (ni wizard ni système Cryoss)."
            return
        fi
    fi

    echo "  Niveau de droit :"
    echo "    [1] R   — lecture seule"
    echo "    [2] RW  — lecture + écriture"
    echo "    [3] –   — refus explicite (révoque l'accès)"
    read -rp "  Choix [1-3] : " plvl
    case "$plvl" in
        1) WIZ_PERMS["${share}|${user}"]="r" ;;
        2) WIZ_PERMS["${share}|${user}"]="rw" ;;
        3) WIZ_PERMS["${share}|${user}"]="no" ;;
        *) warn "Choix invalide."; return ;;
    esac
    ok "Droits définis : $share × $user → ${WIZ_PERMS[${share}|${user}]}"
}

cryoss_wizard_remove_item() {
    echo "  [1] Supprimer un partage"
    echo "  [2] Supprimer un utilisateur (révoque tous ses droits wizard)"
    read -rp "  Choix [1-2] : " kind
    case "$kind" in
        1)
            cryoss_wizard_list_shares
            read -rp "  Numéro du partage à supprimer : " idx
            [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#WIZ_SHARES[@]} )) \
                || { warn "Invalide."; return; }
            local s="${WIZ_SHARES[$((idx-1))]}"
            unset 'WIZ_SHARES[idx-1]'
            WIZ_SHARES=("${WIZ_SHARES[@]}")
            unset 'WIZ_SHARE_PATH[$s]'
            local key
            for key in "${!WIZ_PERMS[@]}"; do
                [[ "$key" == "${s}|"* ]] && unset 'WIZ_PERMS[$key]'
            done
            ok "Partage '$s' retiré de la config (le dossier sur disque est conservé)."
            ;;
        2)
            cryoss_wizard_list_users
            read -rp "  Numéro de l'utilisateur à supprimer : " idx
            [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#WIZ_USERS[@]} )) \
                || { warn "Invalide."; return; }
            local u="${WIZ_USERS[$((idx-1))]}"
            unset 'WIZ_USERS[idx-1]'
            WIZ_USERS=("${WIZ_USERS[@]}")
            unset 'WIZ_USER_PASS[$u]'
            local key
            for key in "${!WIZ_PERMS[@]}"; do
                [[ "$key" == *"|${u}" ]] && unset 'WIZ_PERMS[$key]'
            done
            warn "Utilisateur '$u' retiré (sera dé-provisionné Samba à l'application)."
            ;;
        *) warn "Choix invalide." ;;
    esac
}

# Applique la configuration : crée users (Samba-only), dossiers, écrit smb.conf
cryoss_wizard_apply() {
    local u s perm
    info "Application de la configuration wizard..."

    # 1) Créer les utilisateurs Samba-only (nologin + Unix password verrouillé)
    for u in "${WIZ_USERS[@]}"; do
        if ! getent passwd "$u" >/dev/null 2>&1; then
            useradd -r -M -s /usr/sbin/nologin -d /nonexistent -G samba-share "$u" \
                || { warn "Échec création UNIX $u — skip"; continue; }
            ok "Compte service Unix créé : $u (nologin, no-home)"
        else
            usermod -s /usr/sbin/nologin -d /nonexistent -G samba-share "$u" 2>/dev/null || true
            info "Compte Unix '$u' déjà présent — réajusté en service nologin"
        fi
        # Verrouiller le mot de passe Unix : impossibilité absolue de login local/SSH
        passwd -l "$u" >/dev/null 2>&1 || true
        # Définir le mot de passe Samba (depuis WIZ_USER_PASS)
        local pw="${WIZ_USER_PASS[$u]}"
        if [[ -n "$pw" ]]; then
            printf '%s\n%s\n' "$pw" "$pw" | smbpasswd -s -a "$u" >/dev/null
            smbpasswd -e "$u" >/dev/null
            ok "Mot de passe Samba défini et compte activé : $u"
        fi
    done

    # 2) Créer les dossiers partagés avec ownership et perms strictes
    for s in "${WIZ_SHARES[@]}"; do
        local p="${WIZ_SHARE_PATH[$s]}"
        mkdir -p "$p"
        chown root:samba-share "$p"
        chmod 2770 "$p"  # SetGID pour propagation du groupe + sticky d'écriture du groupe
        ok "Dossier partagé : $p (root:samba-share, 2770)"
    done

    # 3) Générer /etc/samba/cryoss-shares.conf à partir de la matrice
    {
        echo "# =============================================================================="
        echo "#  Partages Cryoss générés par le wizard interactif"
        echo "#  Régénéré le $(date '+%Y-%m-%d %H:%M:%S')"
        echo "#  Source de vérité : /etc/cryoss/shares.conf"
        echo "# =============================================================================="
        for s in "${WIZ_SHARES[@]}"; do
            local valid_users="" read_list="" write_list="" denied=""
            for u in "${WIZ_USERS[@]}" habyss ds-user; do
                perm="${WIZ_PERMS[${s}|${u}]:-}"
                case "$perm" in
                    rw)
                        valid_users+="${u} "
                        write_list+="${u} "
                        ;;
                    r)
                        valid_users+="${u} "
                        read_list+="${u} "
                        ;;
                    no)
                        denied+="${u} "
                        ;;
                esac
            done
            valid_users="${valid_users% }"
            read_list="${read_list% }"
            write_list="${write_list% }"
            denied="${denied% }"
            # Skipper les partages sans aucun valid_users (pas accessibles)
            [[ -z "$valid_users" ]] && {
                warn "Partage '$s' sans utilisateur autorisé — skip dans smb.conf"
                continue
            }
            cat <<SHARE_BLOCK
[$s]
   comment = Cryoss partage [$CLIENT_NAME] — $s
   path = ${WIZ_SHARE_PATH[$s]}
   browseable = yes
   read only = no
   guest ok = no
   valid users = $valid_users
$( [[ -n "$write_list" ]] && echo "   write list = $write_list" )
$( [[ -n "$read_list" ]] && echo "   read list = $read_list" )
$( [[ -n "$denied" ]]     && echo "   invalid users = $denied" )
   create mask = 0660
   directory mask = 2770
   force group = samba-share
   strict allocate = yes
SHARE_BLOCK
        done
    } > /etc/samba/cryoss-shares.conf
    chmod 644 /etc/samba/cryoss-shares.conf

    # 4) Persister la config wizard
    cryoss_wizard_save_config

    # 5) Recharger Samba
    cryoss_run "Vérification syntaxe smb.conf (testparm)" -- testparm -s /etc/samba/smb.conf
    cryoss_run "Rechargement smbd" -- systemctl reload-or-restart smbd
    ok "Configuration wizard appliquée — ${#WIZ_SHARES[@]} partage(s), ${#WIZ_USERS[@]} utilisateur(s)"
}

cryoss_wizard_main() {
    cryoss_wizard_load_config
    while true; do
        echo
        echo -e "${BOLD}${CRY}┏━━━ WIZARD SAMBA — partages personnalisés ━━━┓${NC}"
        echo -e "${CRY}┃${NC} État actuel :"
        echo -e "${CRY}┃${NC}   Utilisateurs Samba (purs) :"
        cryoss_wizard_list_users | sed "s/^/${CRY}┃${NC}     /"
        echo -e "${CRY}┃${NC}   Partages personnalisés :"
        cryoss_wizard_list_shares | sed "s/^/${CRY}┃${NC}     /"
        echo -e "${CRY}┃${NC}   Matrice des droits :"
        cryoss_wizard_show_matrix | sed "s/^/${CRY}┃${NC}     /"
        echo -e "${BOLD}${CRY}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
        echo
        echo "  [1] Ajouter un partage (dossier)"
        echo "  [2] Ajouter un utilisateur Samba (jamais système — nologin + verrouillé)"
        echo "  [3] Définir / modifier des droits (matrice user × partage)"
        echo "  [4] Supprimer un partage ou un utilisateur"
        echo "  [5] Visualiser la configuration en cours"
        echo "  [0] Terminer et appliquer"
        read -rp "  Choix : " choice
        case "$choice" in
            1) cryoss_wizard_add_share ;;
            2) cryoss_wizard_add_user ;;
            3) cryoss_wizard_set_perms ;;
            4) cryoss_wizard_remove_item ;;
            5) ;;  # juste réafficher (boucle)
            0)
                if (( ${#WIZ_SHARES[@]} == 0 )) && (( ${#WIZ_USERS[@]} == 0 )); then
                    info "Aucun partage/utilisateur ajouté — wizard terminé sans modification."
                else
                    cryoss_wizard_apply
                fi
                break
                ;;
            *) warn "Choix invalide." ;;
        esac
    done
}

if cryoss_step "11b-samba-wizard" "11b. Partages Samba personnalisés (wizard interactif)"; then
    info "Le wizard permet d'ajouter des dossiers-partages, des utilisateurs Samba purs"
    info "(nologin, sans accès SSH/console) et de définir des droits R/RW/refus."
    info "Vous pouvez le passer si vous n'avez pas besoin de partages supplémentaires."
    echo
    read -rp "Lancer le wizard de partages personnalisés ? [O/n] : " _w
    if [[ "${_w,,}" != "n" ]]; then
        cryoss_wizard_main
    else
        info "Wizard ignoré — aucune configuration de partage personnalisé."
    fi
    cryoss_done "11b-samba-wizard"
fi

# =============================================================================
if cryoss_step "12-systemd" "12. Services et timers systemd"; then

# Service sauvegarde complete (3 chemins rclone crypt independants)
cat > /etc/systemd/system/cryoss-backup.service <<SVC_EOF
[Unit]
Description=CRYOSS - Triple sauvegarde chiffree [$CLIENT_NAME]
After=network.target local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cryoss-backup.sh
StandardOutput=journal
StandardError=append:/var/log/cryoss-backup.log
User=root
NoNewPrivileges=yes
ProtectSystem=no
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
SVC_EOF

# Timer quotidien 02h00
cat > /etc/systemd/system/cryoss-backup.timer <<TMR_EOF
[Unit]
Description=CRYOSS - Sauvegarde quotidienne 02h00 [$CLIENT_NAME]

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
Unit=cryoss-backup.service

[Install]
WantedBy=timers.target
TMR_EOF

if [[ "$ENABLE_SFTP" == "yes" ]]; then
# Service rclone seul (sync SFTP incremental toutes les 6h)
cat > /etc/systemd/system/cryoss-sftp-sync.service <<SFTP_SVC_EOF
[Unit]
Description=CRYOSS - Sync rclone SFTP incremental [$CLIENT_NAME]
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'rclone sync /etc/sauvegarde cryoss-c3-crypt: \
    --backup-dir "cryoss-c3-versions:$(date +%%Y-%%m-%%d)" \
    --exclude "__CRYOSS_SENTINEL__" \
    --checksum --transfers 2 --retries 3 \
    --contimeout 30s --timeout 60s \
    --log-file /var/log/rclone_cryoss.log --log-level INFO'
User=root

[Install]
WantedBy=multi-user.target
SFTP_SVC_EOF

# Timer toutes les 6h
cat > /etc/systemd/system/cryoss-sftp-sync.timer <<SFTP_TMR_EOF
[Unit]
Description=CRYOSS - Sync SFTP 6h [$CLIENT_NAME]

[Timer]
OnCalendar=*-*-* 08,14,20:00:00
Persistent=true
Unit=cryoss-sftp-sync.service

[Install]
WantedBy=timers.target
SFTP_TMR_EOF

fi  # fin if ENABLE_SFTP sftp-sync service

systemctl daemon-reload
systemctl enable cryoss-backup.timer
systemctl start  cryoss-backup.timer
if [[ "$ENABLE_SFTP" == "yes" ]]; then
    systemctl enable cryoss-sftp-sync.timer
    systemctl start  cryoss-sftp-sync.timer
    ok "Timers : sauvegarde complete 02h | sync SFTP 02/08/14/20h"
else
    ok "Timer : sauvegarde complete 02h (SFTP desactive)"
fi
    cryoss_done "12-systemd"
fi

# =============================================================================
if cryoss_step "13-hardening" "13. Durcissement système"; then

cat > /etc/ssh/sshd_config.d/99-cryoss.conf <<SSH_EOF
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers habyss
Banner /etc/ssh/banner
SSH_EOF
echo "[ Cryoss - Acces restreint ]" > /etc/ssh/banner
systemctl restart ssh
ok "SSH durci (AllowUsers=habyss)"

LAN_SUBNET_RPI1="${NET_IP%.*}.0/24"
ufw --force reset
ufw default deny incoming; ufw default allow outgoing
ufw allow from "$LAN_SUBNET_RPI1"  to any port 22  comment "Cryoss SSH LAN"
ufw allow from "$LAN_SUBNET_RPI1"  to any port 445 comment "Cryoss SMB LAN"
ufw allow from "10.42.0.2"         to any port 22  comment "Cryoss SSH RPi2 interco (admin)"
ufw allow from "10.42.0.2"         to "10.42.0.1" port 25 comment "Relais SMTP RPi2"
ufw --force enable
ok "UFW : SSH+SMB LAN($LAN_SUBNET_RPI1) + SSH/SMTP RPi2(10.42.0.2)"

cat > /etc/fail2ban/jail.d/99-cryoss.conf <<F2B_EOF
[DEFAULT]
# Ne jamais bannir le RPi2 (lien interco Cryoss) - evite le deadlock si la
# replication genere trop de connexions SSH (rclone sync)
ignoreip = 127.0.0.1/8 ::1 ${INTERCO_IP_RPI2}/32

[sshd]
enabled=true
port=ssh
maxretry=5
bantime=3600
findtime=600

[samba]
enabled=true
port=139,445
maxretry=5
bantime=3600
findtime=600
F2B_EOF
systemctl enable fail2ban; systemctl restart fail2ban
ok "Fail2Ban configure (RPi2 ${INTERCO_IP_RPI2} whitelisted)"

for SVC in bluetooth avahi-daemon cups triggerhappy; do
    systemctl disable --now "$SVC" 2>/dev/null && warn "$SVC desactive" || true
done

cat > /etc/sysctl.d/99-cryoss.conf <<SYSCTL_EOF
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.all.log_martians=1
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
kernel.dmesg_restrict=1
kernel.kptr_restrict=2
fs.protected_hardlinks=1
fs.protected_symlinks=1
SYSCTL_EOF
sysctl --system &>/dev/null
ok "Sysctl durci"

sed -i 's/NOPASSWD://g' /etc/sudoers 2>/dev/null || true
id pi &>/dev/null && gpasswd -d pi sudo 2>/dev/null && warn "'pi' retire de sudo" || true
grep -q "umask 027" /etc/profile || echo "umask 027" >> /etc/profile

cat > /etc/logrotate.d/cryoss <<LR_EOF
/var/log/cryoss-backup.log
/var/log/rclone_cryoss_c1.log
/var/log/rclone_cryoss_c2.log
/var/log/rclone_cryoss_c3.log
{
    weekly
    rotate 8
    compress
    missingok
    notifempty
    create 640 root root
}
LR_EOF
ok "Logrotate configure"
    cryoss_done "13-hardening"
fi

# =============================================================================
if cryoss_step "14-monitoring" "14. Monitoring et rapports HTML"; then

mkdir -p /var/lib/cryoss/alerts /var/lib/cryoss

# Injecter le script de monitoring directement dans une variable shell
# (le script principal est écrit via heredoc avec placeholders puis sed)
cat > /usr/local/bin/cryoss-health.sh << 'HEALTH_SCRIPT'
#!/bin/bash
# =============================================================================
#  CRYOSS - Monitoring & Rapports de sante
#  Usage : cryoss-health.sh [daily|weekly|alert]
#  daily   = rapport quotidien 07h (leger)
#  weekly  = rapport hebdo lundi 08h (SMART complet, tendances)
#  alert   = watchdog anomalies (toutes les 15min)
# =============================================================================
# [F2] PAS de set -e — les erreurs de collecte ne doivent pas avorter le rapport.
# On utilise set -uo pipefail : variables non definies = erreur, mais pas les commandes.
set -uo pipefail

# --- Configuration injectee par install_rpi1.sh ---
CLIENT_NAME="__CLIENT_NAME__"
EMAIL_TO_1="__EMAIL_TO_1__"
EMAIL_TO_2="__EMAIL_TO_2__"
PHYSICAL_DISKS="__PHYSICAL_DISKS__"
RPI2_DIR="__RPI2_DIR__"
SFTP_HOST="__SFTP_HOST__"
ENABLE_SFTP="__ENABLE_SFTP__"
HOSTNAME_RPI1=$(hostname -s 2>/dev/null || echo "rpi1")

# --- Chemins ---
LOG_BACKUP="/var/log/cryoss-backup.log"
LOG_RCLONE_C1="/var/log/rclone_cryoss_c1.log"
LOG_RCLONE_C2="/var/log/rclone_cryoss_c2.log"
LOG_RCLONE_C3="/var/log/rclone_cryoss_c3.log"
LOG_HEALTH="/var/log/cryoss-health.log"
LOG_TREND="/var/lib/cryoss/disk-trend.log"
ALERT_DIR="/var/lib/cryoss/alerts"
COOLDOWN=3600   # 1h entre deux alertes identiques

# --- Seuils --- [F1] SMART_TEMP defini ici
DISK_WARN=75; DISK_CRIT=85
SMART_TEMP=55
# Seuils replication — adaptes au weekend (pas de fichiers modifies sam/dim)
# Lun-ven : 26h (detecte un backup manque d'une nuit)
# Sam-dim : 74h (vendredi 02h → lundi 04h = ~50h normales + marge)
DOW=$(date +%u)  # 1=lundi ... 7=dimanche
if (( DOW >= 6 )); then
    REPL_HOURS=74; SFTP_HOURS=73
else
    REPL_HOURS=26; SFTP_HOURS=25
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_HEALTH"; }
tshort() { date '+%d/%m/%Y %H:%M'; }

# ── Envoi email HTML ──────────────────────────────────────────────────────────
send_html_email() {
    local subject="$1" html_body="$2"
    local full_html; full_html=$(wrap_email "$subject" "$html_body")
    for DEST in "$EMAIL_TO_1" "$EMAIL_TO_2"; do
        [[ -z "$DEST" ]] && continue
        {
            echo "To: $DEST"
            echo "Subject: $subject"
            echo "MIME-Version: 1.0"
            echo "Content-Type: text/html; charset=UTF-8"
            echo ""
            echo "$full_html"
        } | msmtp "$DEST" 2>/dev/null || log "WARN: email non envoye a $DEST"
    done
}

# ── Template email Analyss (light theme) ─────────────────────────────────────
wrap_email() {
    local title="$1" body="$2"
    cat << TMPL
<!DOCTYPE html>
<html lang="fr">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:0;background:#f8f9fa;font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#f8f9fa;">
<tr><td align="center" style="padding:28px 12px;">
<table width="620" cellpadding="0" cellspacing="0" style="max-width:620px;width:100%;background:#ffffff;border-radius:8px;border:1px solid #e2e8f0;overflow:hidden;">

  <!-- Header -->
  <tr><td style="background:#ffffff;padding:24px 36px;border-bottom:2px solid #2563eb;">
    <table width="100%" cellpadding="0" cellspacing="0"><tr>
      <td>
        <span style="font-size:20px;font-weight:800;color:#1e293b;letter-spacing:1px;">CRYOSS</span>
        <p style="margin:4px 0 0;color:#64748b;font-size:11px;letter-spacing:2px;text-transform:uppercase;">Monitoring</p>
      </td>
      <td align="right" valign="middle">
        <span style="background:#eff6ff;border:1px solid #2563eb;color:#2563eb;padding:5px 13px;border-radius:16px;font-size:12px;font-weight:700;letter-spacing:1px;">$CLIENT_NAME</span>
      </td>
    </tr></table>
  </td></tr>

  <!-- Titre -->
  <tr><td style="padding:24px 36px 6px;">
    <h1 style="margin:0;color:#1e293b;font-size:18px;font-weight:700;">$title</h1>
    <p style="margin:5px 0 0;color:#64748b;font-size:12px;">$(tshort) &nbsp;&bull;&nbsp; $HOSTNAME_RPI1</p>
  </td></tr>

  <!-- Corps -->
  <tr><td style="padding:14px 36px 28px;">$body</td></tr>

  <!-- Footer -->
  <tr><td style="background:#f8f9fa;padding:16px 36px;border-top:1px solid #e2e8f0;">
    <table width="100%" cellpadding="0" cellspacing="0"><tr>
      <td style="color:#94a3b8;font-size:11px;">Cryoss &copy; <a href="https://analyss.fr" style="color:#2563eb;text-decoration:none;">Analyss</a> &mdash; Rapport automatique</td>
      <td align="right"><a href="https://analyss.fr" style="color:#2563eb;font-size:11px;text-decoration:none;">analyss.fr</a></td>
    </tr></table>
  </td></tr>

</table>
</td></tr></table>
</body></html>
TMPL
}

# ── Composants HTML (light theme) ─────────────────────────────────────────────
badge() {
    local lbl="$1" t="$2"
    case "$t" in
        ok)   echo "<span style='background:#ecfdf5;color:#059669;padding:2px 9px;border-radius:3px;font-size:11px;font-weight:700;border:1px solid #a7f3d0;'>$lbl</span>" ;;
        warn) echo "<span style='background:#fffbeb;color:#d97706;padding:2px 9px;border-radius:3px;font-size:11px;font-weight:700;border:1px solid #fde68a;'>$lbl</span>" ;;
        crit) echo "<span style='background:#fef2f2;color:#dc2626;padding:2px 9px;border-radius:3px;font-size:11px;font-weight:700;border:1px solid #fecaca;'>$lbl</span>" ;;
        info) echo "<span style='background:#eef2ff;color:#6366f1;padding:2px 9px;border-radius:3px;font-size:11px;font-weight:700;border:1px solid #c7d2fe;'>$lbl</span>" ;;
    esac
}
section_open() {
    echo "<table width='100%' cellpadding='0' cellspacing='0' style='margin-bottom:18px;'><tr><td style='padding-bottom:7px;border-bottom:1px solid #e2e8f0;'><span style='color:#2563eb;font-size:11px;font-weight:700;letter-spacing:1.5px;text-transform:uppercase;'>$1</span></td></tr><tr><td style='padding-top:10px;'><table width='100%' cellpadding='0' cellspacing='0'>"
}
section_close() { echo "</table></td></tr></table>"; }
mrow() {
    echo "<tr><td style='padding:5px 0;color:#64748b;font-size:13px;width:48%;'>$1</td><td style='padding:5px 0;color:#1e293b;font-size:13px;font-weight:600;'>$2 $3</td></tr>"
}
alert_banner() {
    local msg="$1" type="${2:-crit}"
    if [[ "$type" == "ok" ]]; then
        echo "<div style='background:#f0fdf4;border-left:4px solid #059669;padding:11px 14px;border-radius:0 6px 6px 0;margin-bottom:18px;'><span style='color:#059669;font-weight:700;font-size:14px;'>&#10003; $msg</span></div>"
    else
        echo "<div style='background:#fef2f2;border-left:4px solid #dc2626;padding:11px 14px;border-radius:0 6px 6px 0;margin-bottom:18px;'><span style='color:#dc2626;font-weight:700;font-size:14px;'>&#9888; $msg</span></div>"
    fi
}
code_block() {
    echo "<pre style='font-family:monospace;font-size:11px;color:#1e293b;background:#f1f5f9;padding:10px;border-radius:5px;overflow-x:auto;margin:6px 0;white-space:pre-wrap;word-break:break-all;border:1px solid #e2e8f0;'>$1</pre>"
}

# ── Collecte ──────────────────────────────────────────────────────────────────
disk_usage()    { df -h "$1" 2>/dev/null | awk 'NR==2{print $3"/"$4" ("$5")"}' || echo "N/A"; }
disk_pct()      { df "$1" 2>/dev/null | awk 'NR==2{gsub("%","",$5);print $5}' || echo "0"; }
raid_state()    { mdadm --detail "/dev/$1" 2>/dev/null | awk '/State :/{$1=$2="";print $0}' | xargs || echo "inconnu"; }
raid_details()  { mdadm --detail "/dev/$1" 2>/dev/null | grep -E "State|Active|Failed|Spare|Rebuild" | sed 's/^ *//' || echo ""; }
smart_attr()    { smartctl -A "/dev/$1" 2>/dev/null | awk -v a="$2" '$2==a{print $10}' || echo "0"; }
smart_temp()    { smartctl -A "/dev/$1" 2>/dev/null | awk '$2~/Temperature/{print $10;exit}' || echo "N/A"; }
smart_health()  { smartctl -H "/dev/$1" 2>/dev/null | awk '/overall/{print $NF}' || echo "N/A"; }
smart_hours()   { smartctl -A "/dev/$1" 2>/dev/null | awk '$2=="Power_On_Hours"{print $10}' || echo "N/A"; }
svc_state()     { systemctl is-active "$1" 2>/dev/null || echo "inactive"; }
f2b_bans_today(){ journalctl -u fail2ban --since "$(date '+%Y-%m-%d')" 2>/dev/null | grep -c " Ban " || echo "0"; }
f2b_bans_week() { journalctl -u fail2ban --since "$(date -d '7 days ago' '+%Y-%m-%d')" 2>/dev/null | grep -c " Ban " || echo "0"; }
f2b_banned()    { fail2ban-client status sshd 2>/dev/null | awk '/Banned IP/{$1=$2=$3="";print $0}' | xargs || echo "aucune"; }
sys_temp()      { cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf "%.1f",$1/1000}' || echo "N/A"; }
sys_load()      { uptime | awk -F'load average:' '{print $2}' | xargs || echo "N/A"; }
sys_ram()       { free -h | awk '/^Mem/{print $3"/"$2}' || echo "N/A"; }
sys_uptime_str(){ uptime -p 2>/dev/null || echo "N/A"; }
# Age du dernier rclone : -1 si pas de donnee (au lieu de 493k heures calcules depuis epoch 0)
rclone_age_h()  {
    local ts
    ts=$(grep "Elapsed time" "$LOG_RCLONE" 2>/dev/null | tail -1 | awk '{print $1,$2}' | xargs -I{} date -d "{}" +%s 2>/dev/null || true)
    ts=$(echo "$ts" | tr -cd '0-9')
    if [[ -z "$ts" || "$ts" == "0" ]]; then
        echo "-1"   # sentinelle "pas de donnee"
        return
    fi
    echo $(( ($(date +%s) - ts) / 3600 ))
}
rclone_last_files() { grep "Copied\|Transferred" "$LOG_RCLONE" 2>/dev/null | tail -1 | grep -oP '\d+ files' || echo "0 fichiers"; }

# Age de la derniere reception RPi2 : -1 si SSH echoue OU aucun fichier
# (evite l'alerte 493 447h declenchee par epoch 0)
repl_age_h() {
    # Tenter plusieurs hostnames : alias SSH puis IP interco fallback
    local rpi2_host="cryoss-rpi2"
    ssh -o BatchMode=yes -o ConnectTimeout=3 "$rpi2_host" true 2>/dev/null || rpi2_host="10.42.0.2"

    # Tester accessibilite avant de calculer
    local accessible
    accessible=$(ssh -o BatchMode=yes -o ConnectTimeout=3 "$rpi2_host" "echo ok" 2>/dev/null)
    if [[ "$accessible" != "ok" ]]; then
        echo "-1"   # RPi2 injoignable
        return
    fi

    local ts
    ts=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$rpi2_host" \
        "find '$RPI2_DIR' -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1" \
        2>/dev/null | cut -d. -f1 || true)
    ts=$(echo "$ts" | tr -cd '0-9')
    if [[ -z "$ts" || "$ts" == "0" ]]; then
        echo "-1"   # aucun fichier reçu
        return
    fi
    echo $(( ($(date +%s) - ts) / 3600 ))
}
repl_count() {
    local rpi2_host="cryoss-rpi2"
    ssh -o BatchMode=yes -o ConnectTimeout=3 "$rpi2_host" true 2>/dev/null || rpi2_host="10.42.0.2"
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$rpi2_host" \
        "find '$RPI2_DIR' -type f | wc -l" 2>/dev/null || echo "N/A"
}
rpi2_raid() {
    local rpi2_host="cryoss-rpi2"
    ssh -o BatchMode=yes -o ConnectTimeout=3 "$rpi2_host" true 2>/dev/null || rpi2_host="10.42.0.2"
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$rpi2_host" \
        "mdadm --detail /dev/md0 2>/dev/null | awk '/State :/{print \$3}'" 2>/dev/null || echo "inaccessible"
}

# ── Cooldown alertes ──────────────────────────────────────────────────────────
cooldown_ok() {
    local id="${1//[^a-zA-Z0-9_-]/_}"; local f="$ALERT_DIR/${id}.ts"
    mkdir -p "$ALERT_DIR"
    if [[ -f "$f" ]]; then
        local age=$(( $(date +%s) - $(cat "$f") ))
        (( age < COOLDOWN )) && return 1
    fi
    date +%s > "$f"; return 0
}

# =============================================================================
#  RAPPORT QUOTIDIEN
# =============================================================================
run_daily() {
    log "--- Rapport quotidien ---"
    local body="" has_warn=0

    # Stockage
    local sp ep sp_pct ep_pct sb eb
    sp=$(disk_usage /etc/sauvegarde); sp_pct=$(disk_pct /etc/sauvegarde)
    ep=$(disk_usage /etc/encrypted);  ep_pct=$(disk_pct /etc/encrypted)
    if   (( sp_pct >= DISK_CRIT )); then sb=$(badge "CRITIQUE" crit); has_warn=1
    elif (( sp_pct >= DISK_WARN )); then sb=$(badge "ATTENTION" warn); has_warn=1
    else sb=$(badge "OK" ok); fi
    if   (( ep_pct >= DISK_CRIT )); then eb=$(badge "CRITIQUE" crit); has_warn=1
    elif (( ep_pct >= DISK_WARN )); then eb=$(badge "ATTENTION" warn); has_warn=1
    else eb=$(badge "OK" ok); fi
    # Tendance
    mkdir -p "$(dirname "$LOG_TREND")"
    echo "$(date '+%Y-%m-%d') sauvegarde=${sp_pct}% encrypted=${ep_pct}%" >> "$LOG_TREND"
    body+=$(section_open "STOCKAGE")
    body+=$(mrow "/etc/sauvegarde (RAID md0)" "$sp" "$sb")
    body+=$(mrow "/etc/encrypted  (RAID md1)" "$ep" "$eb")
    body+=$(section_close)

    # RAID
    body+=$(section_open "ETAT RAID")
    for MD in md0 md1; do
        local st rb
        st=$(raid_state "$MD")
        if   [[ "$st" =~ clean|active ]]; then rb=$(badge "OK" ok)
        elif [[ "$st" =~ degraded|failed ]]; then rb=$(badge "DÉGRADÉ" crit); has_warn=1
        elif [[ "$st" =~ recovering|resyncing ]]; then rb=$(badge "REBUILD" warn); has_warn=1
        else rb=$(badge "$st" warn); has_warn=1; fi
        body+=$(mrow "/dev/$MD" "$st" "$rb")
    done
    body+=$(section_close)

    # Services
    body+=$(section_open "SERVICES")
    for SVC in smbd fail2ban ssh; do
        local st sb
        st=$(svc_state "$SVC")
        [[ "$st" == "active" ]] && sb=$(badge "actif" ok) || { sb=$(badge "$st" crit); has_warn=1; }
        body+=$(mrow "$SVC" "" "$sb")
    done
    body+=$(section_close)

    # Sécurité
    local bans; bans=$(f2b_bans_today)
    local bb
    if   (( bans > 20 )); then bb=$(badge "${bans} bans" warn); has_warn=1
    elif (( bans > 0  )); then bb=$(badge "${bans} bans" info)
    else bb=$(badge "aucun" ok); fi
    body+=$(section_open "SECURITE")
    body+=$(mrow "Bans fail2ban (24h)" "" "$bb")
    body+=$(section_close)

    # Réplication & sync
    # rh/rclone_h == -1 => pas de donnee (RPi2 injoignable / jamais execute)
    local rh rh_b rh_text rclone_h rclone_b rclone_text
    rh=$(repl_age_h)
    local REPL_WARN=$(( REPL_HOURS / 2 ))
    if   (( rh == -1 )); then rh_b=$(badge "N/A" info); rh_text="indisponible"
    elif (( rh >= REPL_HOURS )); then rh_b=$(badge "RETARD ${rh}h" crit); rh_text="il y a ${rh}h"; has_warn=1
    elif (( rh >= REPL_WARN ));   then rh_b=$(badge "${rh}h" warn); rh_text="il y a ${rh}h"; has_warn=1
    else rh_b=$(badge "${rh}h OK" ok); rh_text="il y a ${rh}h"; fi
    if [[ "$ENABLE_SFTP" == "yes" ]]; then
        rclone_h=$(rclone_age_h)
        if   (( rclone_h == -1 )); then rclone_b=$(badge "N/A" info); rclone_text="indisponible"
        elif (( rclone_h >= SFTP_HOURS )); then rclone_b=$(badge "RETARD ${rclone_h}h" crit); rclone_text="il y a ${rclone_h}h"; has_warn=1
        else rclone_b=$(badge "${rclone_h}h OK" ok); rclone_text="il y a ${rclone_h}h"; fi
    else
        rclone_b=$(badge "DESACTIVE" info)
        rclone_text="désactivé"
    fi
    body+=$(section_open "REPLICATION & SYNC")
    body+=$(mrow "RPi2 — dernier fichier" "$rh_text" "$rh_b")
    if [[ "$ENABLE_SFTP" == "yes" ]]; then
        body+=$(mrow "SFTP rclone — dernière sync" "$rclone_text" "$rclone_b")
    else
        body+=$(mrow "SFTP rclone" "désactivé" "$rclone_b")
    fi
    body+=$(section_close)

    # Système
    body+=$(section_open "SYSTEME")
    body+=$(mrow "Température CPU" "$(sys_temp)°C" "")
    body+=$(mrow "Charge CPU (load avg)" "$(sys_load)" "")
    body+=$(mrow "RAM utilisée" "$(sys_ram)" "")
    body+=$(mrow "Uptime" "$(sys_uptime_str)" "")
    body+=$(section_close)

    # Bannière globale
    local banner
    if (( has_warn )); then
        banner=$(alert_banner "Des anomalies ont été détectées" crit)
    else
        banner=$(alert_banner "Tous les systèmes sont opérationnels" ok)
    fi

    local subj="[Cryoss $CLIENT_NAME] Rapport quotidien — $(date '+%d/%m/%Y')"
    send_html_email "$subj" "${banner}${body}"
    log "Rapport quotidien envoyé (anomalies: $has_warn)"
}

# =============================================================================
#  RAPPORT HEBDOMADAIRE
# =============================================================================
run_weekly() {
    log "--- Rapport hebdomadaire ---"
    local body=""

    # Résumé
    body+=$(section_open "SEMAINE")
    body+=$(mrow "Période" "$(date -d '7 days ago' '+%d/%m') → $(date '+%d/%m/%Y')" "")
    body+=$(mrow "Hôte" "$HOSTNAME_RPI1" "$(badge "RPi1" info)")
    body+=$(section_close)

    # SMART par disque
    local smart_html=""
    for DISK in $PHYSICAL_DISKS; do
        [[ -b "/dev/$DISK" ]] || continue
        local h t r p u hrs ds
        h=$(smart_health "$DISK")
        t=$(smart_temp "$DISK")
        r=$(smart_attr "$DISK" "Reallocated_Sector_Ct")
        p=$(smart_attr "$DISK" "Current_Pending_Sector")
        u=$(smart_attr "$DISK" "Offline_Uncorrectable")
        hrs=$(smart_hours "$DISK")
        local disk_ok=ok
        [[ "$h" != "PASSED" ]] && disk_ok=crit
        { [[ "$t" != "N/A" ]] && (( t >= SMART_TEMP )); } && disk_ok=crit
        { [[ "${r:-0}" != "0" ]]; } && disk_ok=crit
        { [[ "${u:-0}" != "0" ]]; } && disk_ok=crit
        { [[ "${p:-0}" != "0" ]] && [[ "$disk_ok" != "crit" ]]; } && disk_ok=warn
        smart_html+="<div style='margin:14px 0 4px;'><span style='color:#d8e8f4;font-weight:700;'>/dev/$DISK</span> &nbsp;$(badge "$h" "$disk_ok")</div>"
        smart_html+="<table width='100%' cellpadding='0' cellspacing='0'>"
        smart_html+=$(mrow "Température" "${t}°C" "")
        smart_html+=$(mrow "Secteurs réalloués" "$r" "$( [[ "${r:-0}" != "0" ]] && badge "ATTENTION" crit || badge "OK" ok )")
        smart_html+=$(mrow "Secteurs en attente" "$p" "$( [[ "${p:-0}" != "0" ]] && badge "ATTENTION" warn || badge "OK" ok )")
        smart_html+=$(mrow "Erreurs non corrigées" "$u" "$( [[ "${u:-0}" != "0" ]] && badge "CRITIQUE" crit || badge "OK" ok )")
        smart_html+=$(mrow "Heures sous tension" "${hrs}h" "")
        smart_html+="</table>"
    done
    body+=$(section_open "SANTE DISQUES SMART"); body+="$smart_html"; body+=$(section_close)

    # RAID détail
    local raid_html=""
    for MD in md0 md1; do
        [[ -b "/dev/$MD" ]] || continue
        local det; det=$(raid_details "$MD")
        raid_html+="<div style='margin-bottom:12px;'>"
        raid_html+="<span style='color:#d8e8f4;font-weight:700;'>/dev/$MD</span> &nbsp;$(badge "$(raid_state "$MD")" ok)"
        raid_html+=$(code_block "$det")
        raid_html+="</div>"
    done
    body+=$(section_open "ETAT RAID DETAILLE"); body+="$raid_html"; body+=$(section_close)

    # Archives
    local cbc_sz cbc_n src_sz src_n
    cbc_sz=$(du -sh /etc/encrypted 2>/dev/null | awk '{print $1}' || echo "N/A")
    cbc_n=$(find /etc/encrypted -type f 2>/dev/null | wc -l || echo "0")
    src_sz=$(du -sh /etc/sauvegarde 2>/dev/null | awk '{print $1}' || echo "N/A")
    src_n=$(find /etc/sauvegarde -maxdepth 1 -type f 2>/dev/null | wc -l || echo "0")
    body+=$(section_open "ARCHIVES")
    body+=$(mrow "/etc/encrypted (chiffres rclone crypt)" "$cbc_sz — $cbc_n fichiers" "")
    body+=$(mrow "/etc/sauvegarde (source)" "$src_sz — $src_n fichiers" "")
    body+=$(section_close)

    # rclone semaine
    local rc_ok rc_err
    rc_ok=$(grep -c "Copied\|Transferred" "$LOG_RCLONE" 2>/dev/null || echo "0")
    rc_err=$(grep -c "ERROR\|FAILED" "$LOG_RCLONE" 2>/dev/null || echo "0")
    if [[ "$ENABLE_SFTP" == "yes" ]]; then
    body+=$(section_open "SYNC SFTP RCLONE (SFTP: $SFTP_HOST)")
    body+=$(mrow "Transferts (semaine)" "$rc_ok" "")
    body+=$(mrow "Erreurs" "$rc_err" "$( (( ${rc_err:-0} > 0 )) && badge "ERREURS" warn || badge "OK" ok )")
    body+=$(section_close)
    fi  # fin ENABLE_SFTP

    # RPi2
    local rpi2_s rpi2_cnt rpi2_age rpi2_age_text
    rpi2_s=$(rpi2_raid 2>/dev/null || echo "inaccessible")
    rpi2_cnt=$(repl_count 2>/dev/null || echo "N/A")
    rpi2_age=$(repl_age_h 2>/dev/null || echo "-1")
    [[ "$rpi2_age" == "-1" ]] && rpi2_age_text="indisponible" || rpi2_age_text="il y a ${rpi2_age}h"
    body+=$(section_open "REPLICATION RPi2")
    body+=$(mrow "RAID RPi2 (md0)" "$rpi2_s" "$( [[ "$rpi2_s" == clean* || "$rpi2_s" == active* ]] && badge "OK" ok || badge "$rpi2_s" crit )")
    body+=$(mrow "Fichiers chiffrés reçus" "$rpi2_cnt" "")
    body+=$(mrow "Dernière réplication" "$rpi2_age_text" "")
    body+=$(section_close)

    # Fail2ban semaine
    local bans_w banned
    bans_w=$(f2b_bans_week)
    banned=$(f2b_banned)
    body+=$(section_open "SECURITE — FAIL2BAN (7 jours)")
    body+=$(mrow "Total bans" "$bans_w" "")
    body+=$(mrow "IPs bannies actuellement" "$banned" "")
    body+=$(section_close)

    # Tendance
    local trend_html
    if [[ -f "$LOG_TREND" ]]; then
        trend_html=$(code_block "$(tail -7 "$LOG_TREND" | column -t)")
    else
        trend_html="<span style='color:#3a5570;font-size:12px;'>Données insuffisantes (&lt;7j)</span>"
    fi
    body+=$(section_open "TENDANCE ESPACE DISQUE (7 derniers jours)")
    body+="$trend_html"
    body+=$(section_close)

    # Système
    body+=$(section_open "SYSTEME")
    body+=$(mrow "Température CPU" "$(sys_temp)°C" "")
    body+=$(mrow "Charge (load avg)" "$(sys_load)" "")
    body+=$(mrow "RAM" "$(sys_ram)" "")
    body+=$(mrow "Uptime" "$(sys_uptime_str)" "")
    body+=$(section_close)

    local subj="[Cryoss $CLIENT_NAME] Rapport hebdomadaire — sem. $(date -d '7 days ago' '+%d/%m')"
    send_html_email "$subj" "$body"
    log "Rapport hebdomadaire envoyé"
}

# =============================================================================
#  WATCHDOG — ALERTES IMMEDIATES
# =============================================================================
run_alert() {
    log "--- Watchdog ---"
    local fired=0

    fire() {
        local id="$1" subj="$2" html="$3"
        if cooldown_ok "$id"; then
            local alert_html
            alert_html="<div style='background:#0e0305;border-left:4px solid #d93644;padding:14px 16px;border-radius:0 7px 7px 0;margin-bottom:18px;'>
              <p style='margin:0 0 3px;color:#d93644;font-weight:700;font-size:15px;'>&#9888;&nbsp; ALERTE CRYOSS</p>
              <p style='margin:0;color:#8aaccc;font-size:12px;'>Détectée le $(tshort) &bull; $HOSTNAME_RPI1</p>
            </div>$html"
            send_html_email "$subj" "$alert_html"
            log "ALERTE : $id"
            (( fired++ )) || true
        fi
    }

    # RAID dégradé
    for MD in md0 md1; do
        local st; st=$(raid_state "$MD")
        if [[ "$st" =~ degraded|failed ]]; then
            local det; det=$(raid_details "$MD")
            local h; h=$(section_open "RAID /dev/$MD — ÉTAT : $st")
            h+=$(code_block "$det")
            h+="<p style='color:#5a8099;font-size:12px;margin-top:8px;'>Remplacez le disque défaillant. Vérifiez <code style='color:#7ec8e3;'>/proc/mdstat</code></p>"
            h+=$(section_close)
            fire "raid_${MD}_degraded" "[Cryoss $CLIENT_NAME] &#9888; RAID /dev/$MD DÉGRADÉ" "$h"
        fi
    done

    # SMART critique
    for DISK in $PHYSICAL_DISKS; do
        [[ -b "/dev/$DISK" ]] || continue
        local issues="" t h r p u
        t=$(smart_temp "$DISK"); h=$(smart_health "$DISK")
        r=$(smart_attr "$DISK" "Reallocated_Sector_Ct")
        p=$(smart_attr "$DISK" "Current_Pending_Sector")
        u=$(smart_attr "$DISK" "Offline_Uncorrectable")
        [[ "$h" != "PASSED" && "$h" != "N/A" ]] && \
            issues+="<li style='color:#d93644;'>SMART health : <strong>$h</strong></li>"
        { [[ "$t" != "N/A" ]] && (( t >= SMART_TEMP )); } && \
            issues+="<li style='color:#e8a000;'>Température : <strong>${t}°C</strong> (seuil ${SMART_TEMP}°C)</li>"
        { [[ "${r:-0}" != "0" ]]; } && \
            issues+="<li style='color:#d93644;'>Secteurs réalloués : <strong>$r</strong></li>"
        { [[ "${u:-0}" != "0" ]]; } && \
            issues+="<li style='color:#d93644;'>Erreurs non corrigées : <strong>$u</strong></li>"
        { [[ "${p:-0}" != "0" ]]; } && \
            issues+="<li style='color:#e8a000;'>Secteurs en attente : <strong>$p</strong></li>"
        if [[ -n "$issues" ]]; then
            local h_html; h_html=$(section_open "DISQUE /dev/$DISK — ANOMALIE SMART")
            h_html+="<ul style='margin:0;padding-left:18px;line-height:1.9;'>$issues</ul>"
            h_html+=$(section_close)
            fire "smart_${DISK}" "[Cryoss $CLIENT_NAME] &#9888; SMART /dev/$DISK anormal" "$h_html"
        fi
    done

    # Espace disque
    for MNT in /etc/sauvegarde /etc/encrypted; do
        local pct; pct=$(disk_pct "$MNT")
        local used; used=$(disk_usage "$MNT")
        if (( pct >= DISK_CRIT )); then
            local h; h=$(section_open "ESPACE DISQUE CRITIQUE — $MNT")
            h+=$(mrow "Utilisation" "$used" "$(badge "${pct}%" crit)")
            h+="<p style='color:#5a8099;font-size:12px;margin-top:8px;'>Seuil critique : ${DISK_CRIT}%. Libérez de l'espace.</p>"
            h+=$(section_close)
            fire "disk_crit_${MNT//\//_}" "[Cryoss $CLIENT_NAME] &#9888; Disque $MNT à ${pct}%" "$h"
        elif (( pct >= DISK_WARN )); then
            local h; h=$(section_open "ESPACE DISQUE — ATTENTION — $MNT")
            h+=$(mrow "Utilisation" "$used" "$(badge "${pct}%" warn)")
            h+=$(section_close)
            fire "disk_warn_${MNT//\//_}" "[Cryoss $CLIENT_NAME] Disque $MNT à ${pct}% — attention" "$h"
        fi
    done

    # Services down
    for SVC in smbd fail2ban ssh; do
        local st; st=$(svc_state "$SVC")
        if [[ "$st" != "active" ]]; then
            local h; h=$(section_open "SERVICE ARRÊTÉ — $SVC")
            h+=$(mrow "État" "$st" "$(badge "INACTIF" crit)")
            h+="<p style='color:#5a8099;font-size:12px;margin-top:8px;'>Redémarrage : <code style='color:#7ec8e3;'>systemctl restart $SVC</code></p>"
            h+=$(section_close)
            fire "svc_${SVC}_down" "[Cryoss $CLIENT_NAME] &#9888; Service $SVC arrêté" "$h"
        fi
    done

    # Réplication RPi2 silencieuse
    # rh == -1  => RPi2 injoignable OU aucun fichier reçu — PAS une alerte retard
    # rh >= REPL_HOURS => vraie alerte retard
    local rh; rh=$(repl_age_h)
    if (( rh == -1 )); then
        log "Replication RPi2 : pas de donnee (RPi2 injoignable ou dossier vide)"
    elif (( rh >= REPL_HOURS )); then
        local h; h=$(section_open "RÉPLICATION RPi2 — SILENCE DÉTECTÉ")
        h+=$(mrow "Dernier fichier reçu" "il y a ${rh}h" "$(badge "RETARD" crit)")
        h+="<p style='color:#5a8099;font-size:12px;margin-top:8px;'>Seuil : ${REPL_HOURS}h. Vérifiez la connexion SSH RPi1→RPi2 et les logs cryoss-backup.</p>"
        h+=$(section_close)
        fire "repl_rpi2_late" "[Cryoss $CLIENT_NAME] &#9888; Réplication RPi2 silencieuse (${rh}h)" "$h"
    fi

    # Sync SFTP silencieuse (uniquement si SFTP activé)
    if [[ "$ENABLE_SFTP" == "yes" ]]; then
        local sh; sh=$(rclone_age_h)
        if (( sh == -1 )); then
            log "Sync SFTP : pas de donnee (jamais execute ou log absent)"
        elif (( sh >= SFTP_HOURS )); then
            local h; h=$(section_open "SYNC SFTP — SILENCE DÉTECTÉ")
            h+=$(mrow "Dernière sync rclone" "il y a ${sh}h" "$(badge "RETARD" crit)")
            h+="<p style='color:#5a8099;font-size:12px;margin-top:8px;'>Seuil : ${SFTP_HOURS}h. Vérifiez la connectivité SFTP : <code style='color:#7ec8e3;'>rclone lsd cryoss-sftp:</code></p>"
            h+=$(section_close)
            fire "sftp_sync_late" "[Cryoss $CLIENT_NAME] &#9888; Sync SFTP silencieuse (${sh}h)" "$h"
        fi
    fi  # fin ENABLE_SFTP watchdog

    log "Watchdog terminé — alertes déclenchées : $fired"
}

# =============================================================================
MODE="${1:-alert}"
mkdir -p "$ALERT_DIR" "$(dirname "$LOG_TREND")"
case "$MODE" in
    daily)   run_daily  ;;
    weekly)  run_weekly ;;
    alert)   run_alert  ;;
    *)
        echo "Usage: $0 [daily|weekly|alert]"
        echo "  daily   : rapport léger quotidien (07h00)"
        echo "  weekly  : rapport complet hebdo (lundi 08h00)"
        echo "  alert   : watchdog anomalies (toutes les 15min)"
        exit 1 ;;
esac
HEALTH_SCRIPT

# Injecter les variables dans le script
PHYS_DISKS="${DISK1##/dev/} ${DISK2##/dev/} ${DISK3##/dev/} ${DISK4##/dev/}"
sed -i \
    -e "s|__CLIENT_NAME__|${CLIENT_NAME}|g" \
    -e "s|__EMAIL_TO_1__|${EMAIL_TO}|g" \
    -e "s|__EMAIL_TO_2__|${EMAIL_TO_2:-}|g" \
    -e "s|__PHYSICAL_DISKS__|${PHYS_DISKS}|g" \
    -e "s|__RPI2_DIR__|${RPI2_DIR}|g" \
    -e "s|__SFTP_HOST__|${SFTP_HOST:-N/A}|g" \
    -e "s|__ENABLE_SFTP__|${ENABLE_SFTP}|g" \
    /usr/local/bin/cryoss-health.sh

chmod 700 /usr/local/bin/cryoss-health.sh
chown root:root /usr/local/bin/cryoss-health.sh
ok "cryoss-health.sh installe — design HTML Analyss, 2 destinataires"

# Systemd — rapport quotidien 07h00
cat > /etc/systemd/system/cryoss-health-daily.service <<SVC_EOF
[Unit]
Description=CRYOSS - Rapport sante quotidien [$CLIENT_NAME]
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/cryoss-health.sh daily
StandardOutput=append:/var/log/cryoss-health.log
StandardError=append:/var/log/cryoss-health.log
User=root
SVC_EOF
cat > /etc/systemd/system/cryoss-health-daily.timer <<TMR_EOF
[Unit]
Description=CRYOSS - Rapport quotidien 07h00 [$CLIENT_NAME]
[Timer]
OnCalendar=*-*-* 07:00:00
Persistent=true
Unit=cryoss-health-daily.service
[Install]
WantedBy=timers.target
TMR_EOF

# Systemd — rapport hebdo lundi 08h00
cat > /etc/systemd/system/cryoss-health-weekly.service <<SVC_EOF
[Unit]
Description=CRYOSS - Rapport sante hebdomadaire [$CLIENT_NAME]
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/cryoss-health.sh weekly
StandardOutput=append:/var/log/cryoss-health.log
StandardError=append:/var/log/cryoss-health.log
User=root
SVC_EOF
cat > /etc/systemd/system/cryoss-health-weekly.timer <<TMR_EOF
[Unit]
Description=CRYOSS - Rapport hebdo lundi 08h00 [$CLIENT_NAME]
[Timer]
OnCalendar=Mon *-*-* 08:00:00
Persistent=true
Unit=cryoss-health-weekly.service
[Install]
WantedBy=timers.target
TMR_EOF

# Systemd — watchdog toutes les 15min
cat > /etc/systemd/system/cryoss-watchdog.service <<SVC_EOF
[Unit]
Description=CRYOSS - Watchdog alertes [$CLIENT_NAME]
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/cryoss-health.sh alert
StandardOutput=append:/var/log/cryoss-health.log
StandardError=append:/var/log/cryoss-health.log
User=root
SVC_EOF
cat > /etc/systemd/system/cryoss-watchdog.timer <<TMR_EOF
[Unit]
Description=CRYOSS - Watchdog /15min [$CLIENT_NAME]
[Timer]
OnCalendar=*-*-* *:00,15,30,45:00
Persistent=true
Unit=cryoss-watchdog.service
[Install]
WantedBy=timers.target
TMR_EOF

systemctl daemon-reload
systemctl enable cryoss-health-daily.timer cryoss-health-weekly.timer cryoss-watchdog.timer
systemctl start  cryoss-health-daily.timer cryoss-health-weekly.timer cryoss-watchdog.timer
ok "Timers : quotidien 07h | hebdo lundi 08h | watchdog toutes les 15min"

# Logrotate
cat >> /etc/logrotate.d/cryoss << LR_EOF

/var/log/cryoss-health.log {
    weekly
    rotate 12
    compress
    missingok
    notifempty
    create 640 root root
}
LR_EOF
ok "Logrotate health configure"

info "Test rapport initial..."
/usr/local/bin/cryoss-health.sh daily \
    && ok "Rapport test envoye a $EMAIL_TO${EMAIL_TO_2:+ et $EMAIL_TO_2}" \
    || warn "Erreur rapport test — verifiez msmtp"
    cryoss_done "14-monitoring"
fi

# =============================================================================
if cryoss_step "15-master-key" "15. Master key Console Analyss (Fernet)"; then
    # Master key Fernet utilisée par cryoss-command-runner pour déchiffrer les
    # params sensibles (`enc:v1:<token>`) reçus de la Console Analyss.
    # Référence : ADR 0001 §4 (Analyss).
    info "La Console Analyss envoie certains params (mots de passe Samba ajoutés"
    info "via le panel users) chiffrés en Fernet. Le runner local doit pouvoir"
    info "les déchiffrer."
    info ""
    info "Si vous n'utilisez PAS la Console Analyss bidirectionnelle, vous pouvez"
    info "skipper cette étape — toutes les autres commandes (clear-text params)"
    info "fonctionneront sans master key."
    echo
    read -rp "Configurer la master key Fernet maintenant ? [O/n] : " _mk
    if [[ "${_mk,,}" == "n" ]]; then
        info "Étape skippée. Pour la configurer plus tard :"
        info "  sudo bash $0 --only-step 15-master-key"
    else
        # Vérifier python3-cryptography (dépendance du helper)
        if ! python3 -c 'import cryptography.fernet' 2>/dev/null; then
            info "Installation python3-cryptography (requis pour Fernet)..."
            cryoss_apt_install python3-cryptography
        fi

        # Saisie de la clé (l'opérateur la copie depuis la Console Analyss)
        echo
        info "La master key est une clé Fernet base64 url-safe (44 caractères)."
        info "Elle est générée par la Console Analyss ; copiez-la depuis l'UI."
        echo
        while true; do
            read -rsp "  Master key Fernet : " MASTER_KEY; echo
            if [[ -z "$MASTER_KEY" ]]; then
                warn "Vide — réessayez ou Ctrl+C pour skipper."
                continue
            fi
            # Validation : encrypt+decrypt d'un test message via le helper Python
            if MK="$MASTER_KEY" python3 -c '
import os, sys
from cryptography.fernet import Fernet, InvalidToken
try:
    f = Fernet(os.environ["MK"].encode())
    token = f.encrypt(b"cryoss-master-key-self-test")
    plain = f.decrypt(token)
    sys.exit(0 if plain == b"cryoss-master-key-self-test" else 1)
except (ValueError, InvalidToken):
    sys.exit(2)
' 2>/dev/null; then
                ok "Master key valide (test encrypt+decrypt OK)"
                break
            else
                warn "Master key invalide. Format attendu : Fernet base64 url-safe (44 chars)."
            fi
        done

        # Pose en 0600 root:root. mkdir prealable pour que --only-step 15-master-key
        # marche standalone (sans depender des steps amont qui creent /etc/cryoss).
        mkdir -p /etc/cryoss
        chmod 700 /etc/cryoss
        chown root:root /etc/cryoss
        umask 077
        printf '%s\n' "$MASTER_KEY" > /etc/cryoss/master_key
        chmod 600 /etc/cryoss/master_key
        chown root:root /etc/cryoss/master_key
        unset MASTER_KEY
        ok "Master key déposée : /etc/cryoss/master_key (0600 root:root)"
        info "Le runner peut maintenant déchiffrer les params 'enc:v1:' de la Console."
    fi
    cryoss_done "15-master-key"
fi

# =============================================================================
#  RESUME — récap final (robuste sur reprise : recalcule ce qui manque)
# =============================================================================

# UUID_MD0/MD1 peuvent être absents si l'étape 4 a été skippée (resume) — recalcul
UUID_MD0="${UUID_MD0:-$(blkid -s UUID -o value /dev/md0 2>/dev/null || echo 'N/A')}"
UUID_MD1="${UUID_MD1:-$(blkid -s UUID -o value /dev/md1 2>/dev/null || echo 'N/A')}"

echo
echo -e "${BOLD}${GREEN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          CRYOSS RPi1 — Installation terminée !              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "${BOLD}${CRY}── Client ──${NC}"
echo "  $CLIENT_NAME"
echo -e "${BOLD}${CRY}── Réseau ──${NC}"
echo "  ${NET_IP}/${NET_CIDR}  GW:$NET_GW  ($NET_IFACE)"
echo -e "${BOLD}${CRY}── RAID ──${NC}"
echo "  md0 ($DISK1+$DISK2) -> /etc/sauvegarde  UUID:$UUID_MD0"
echo "  md1 ($DISK3+$DISK4) -> /etc/encrypted   UUID:$UUID_MD1"
echo -e "${BOLD}${CRY}── Chemins de sauvegarde ──${NC}"
echo "  [1] rclone crypt (XSalsa20, KEY_C1) -> /etc/encrypted        (RAID, quotidien 02h)"
echo "  [2] rclone crypt (XSalsa20-Poly1305, KEY_C2) -> RPi2 via SFTP interco"
if [[ "$ENABLE_SFTP" == "yes" ]]; then
    echo "  [3] rclone crypt -> $SFTP_USER@$SFTP_HOST  (incremental 02/08/14/20h)"
else
    echo "  [3] SFTP désactivé"
fi
echo -e "${BOLD}${CRY}── Monitoring ──${NC}"
echo "  Rapport quotidien  : 07h00  -> $EMAIL_TO${EMAIL_TO_2:+ + $EMAIL_TO_2}"
echo "  Rapport hebdo      : lundi 08h00 (SMART complet, tendances)"
echo "  Watchdog alertes   : toutes les 15min (cooldown 1h/alerte)"
echo "  Alertes immédiates : RAID dégradé, SMART critique, espace >85%,"
echo "                       service down, réplication silencieuse"
echo -e "${BOLD}${CRY}── Utilisateurs (système) ──${NC}"
echo "  ds-user : ${DS_PASS:-(inchangé)}  (Samba R/W, nologin)"
echo "  habyss  : ${HABYSS_PASS:-(inchangé)}  (sudo+SSH+Samba)"
# Wizard : afficher les partages/utilisateurs personnalisés si présents
if [[ -f /etc/cryoss/shares.conf ]]; then
    cryoss_wizard_load_config 2>/dev/null || true
    if (( ${#WIZ_USERS[@]} > 0 )) || (( ${#WIZ_SHARES[@]} > 0 )); then
        echo -e "${BOLD}${CRY}── Samba personnalisé (wizard) ──${NC}"
        if (( ${#WIZ_USERS[@]} > 0 )); then
            echo "  Utilisateurs Samba purs (nologin, password Unix verrouillé) :"
            for _u in "${WIZ_USERS[@]}"; do echo "    - $_u"; done
        fi
        if (( ${#WIZ_SHARES[@]} > 0 )); then
            echo "  Partages personnalisés :"
            for _s in "${WIZ_SHARES[@]}"; do
                echo "    - [$_s] -> ${WIZ_SHARE_PATH[$_s]}"
            done
        fi
        echo "  Config persistée : /etc/cryoss/shares.conf"
        echo "  → Pour modifier : sudo bash $0 --from-step 11b-samba-wizard"
    fi
fi
echo -e "${BOLD}${CRY}── Clés ──${NC}"
echo "  Cles rclone : /etc/cryoss/keys-backup.conf"
echo "  rclone    : /root/.config/rclone/rclone.conf"
echo -e "${BOLD}${CRY}── État d'installation ──${NC}"
echo "  Étapes validées   : $(wc -l < "$CRYOSS_STATE_FILE" 2>/dev/null || echo 0)/${#CRYOSS_STEPS[@]}"
echo "  Fichier d'état    : $CRYOSS_STATE_FILE"
echo "  Variables (env)   : $CRYOSS_ENV_FILE"
echo "  Log brut          : $CRYOSS_INSTALL_LOG"
echo -e "${BOLD}${CRY}── Logs runtime ──${NC}"
echo "  /var/log/cryoss-backup.log"
echo "  /var/log/rclone_cryoss.log"
echo "  /var/log/cryoss-health.log"
echo ""
echo -e "${YELLOW}Tests utiles :${NC}"
echo "  sudo /usr/local/bin/cryoss-health.sh daily     # Rapport quotidien"
echo "  sudo /usr/local/bin/cryoss-health.sh weekly    # Rapport hebdo"
echo "  sudo /usr/local/bin/cryoss-health.sh alert     # Watchdog"
echo "  sudo systemctl start cryoss-backup.service"
echo "  tail -f /var/log/cryoss-health.log"
echo ""
echo -e "${BOLD}${CRY}Reprise / modifications ultérieures :${NC}"
echo "  sudo bash $0 --list-steps                     # statut des étapes"
echo "  sudo bash $0 --from-step 11b-samba-wizard     # rejouer le wizard Samba"
echo "  sudo bash $0 --resume                         # reprendre après interruption"
echo
echo -e "${RED}${BOLD}Redémarrage recommandé.${NC}"
echo
