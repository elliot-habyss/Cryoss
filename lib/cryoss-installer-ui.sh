# =============================================================================
#  cryoss-installer-ui.sh — Librairie UI + resume framework partagée
#
#  Sourcée par install_rpi1.sh et install_rpi2.sh pour unifier :
#    - Bannière ASCII Cryoss
#    - Spinner / barre de progression / cryoss_run (output -> log, UX propre)
#    - Resume framework (cryoss_step, cryoss_done, --resume, --from-step, etc.)
#    - Sauvegarde/chargement /var/lib/cryoss/install.env
#
#  Le caller DOIT définir AVANT de sourcer ce fichier :
#    CRYOSS_ROLE        : "rpi1" ou "rpi2"
#    CRYOSS_STEPS[]     : array de "ID:Titre"
#    CRYOSS_ENV_VARS[]  : array des noms de variables à persister
#
#  Optionnellement :
#    CRYOSS_STATE_DIR     (défaut /var/lib/cryoss)
#    CRYOSS_INSTALL_LOG   (défaut /var/log/cryoss-install.log)
#    CRYOSS_BANNER_TAGLINE (défaut "Triple chiffrement rclone (XSalsa20-Poly1305 ×3)")
#
#  La lib NE doit PAS être exécutée directement — source uniquement.
# =============================================================================

# Contrôles d'entrée stricts — la lib échoue tôt si le caller a mal préparé.
[[ -n "${CRYOSS_ROLE:-}" ]] || { echo "lib UI: CRYOSS_ROLE non défini (rpi1|rpi2)" >&2; exit 1; }
[[ "${CRYOSS_ROLE}" =~ ^rpi[12]$ ]] || { echo "lib UI: CRYOSS_ROLE invalide ($CRYOSS_ROLE)" >&2; exit 1; }
declare -p CRYOSS_STEPS &>/dev/null || { echo "lib UI: CRYOSS_STEPS[] non défini" >&2; exit 1; }
declare -p CRYOSS_ENV_VARS &>/dev/null || { echo "lib UI: CRYOSS_ENV_VARS[] non défini" >&2; exit 1; }

# Paths par défaut
: "${CRYOSS_STATE_DIR:=/var/lib/cryoss}"
: "${CRYOSS_INSTALL_LOG:=/var/log/cryoss-install.log}"
CRYOSS_STATE_FILE="${CRYOSS_STATE_DIR}/install.state"
CRYOSS_ENV_FILE="${CRYOSS_STATE_DIR}/install.env"
: "${CRYOSS_BANNER_TAGLINE:=Triple chiffrement rclone (XSalsa20-Poly1305 ×3)}"

# =============================================================================
#  COULEURS — palette Cryoss
# =============================================================================
RED='\033[0;31m';     GREEN='\033[0;32m';   YELLOW='\033[1;33m'
BLUE='\033[0;34m';    CYAN='\033[0;36m';    MAGENTA='\033[0;35m'
BOLD='\033[1m';       DIM='\033[2m';        NC='\033[0m'
CRY='\033[38;5;39m';  CRY_DARK='\033[38;5;33m';  CRY_LIGHT='\033[38;5;117m'

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
#  GLYPHES UI (UTF-8)
# =============================================================================
CRYOSS_BAR_FILL='█'
CRYOSS_BAR_EMPTY='░'
CRYOSS_SPINNER=('⣾' '⣽' '⣻' '⢿' '⡿' '⣟' '⣯' '⣷')

# =============================================================================
#  BANNIÈRE ASCII
# =============================================================================
cryoss_banner() {
    local subtitle
    case "$CRYOSS_ROLE" in
        rpi1) subtitle="Installation RPi1 — Primaire" ;;
        rpi2) subtitle="Installation RPi2 — Secondaire (réplication)" ;;
    esac
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
    echo -e "${DIM}        ${CRYOSS_BANNER_TAGLINE}${NC}"
    echo -e "${DIM}              ${subtitle}${NC}"
    echo
}

# =============================================================================
#  BARRE DE PROGRESSION — cryoss_bar PERCENT [LABEL]
# =============================================================================
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

# =============================================================================
#  RUNNER — cryoss_run "Label" -- cmd args...
#  Exécute la commande, redirige stdout/stderr vers le log, anime un spinner.
#  Affiche ✓ ou ✗ + temps écoulé. Sur échec, montre les 20 dernières lignes.
# =============================================================================
cryoss_run() {
    local label="$1"
    shift
    [[ "${1:-}" == "--" ]] && shift
    local start_ts elapsed rc=0 spin_pid frame=0
    mkdir -p "$(dirname "$CRYOSS_INSTALL_LOG")" 2>/dev/null || true
    : > /tmp/.cryoss_run.$$.log

    start_ts=$(date +%s)
    ( "$@" >>/tmp/.cryoss_run.$$.log 2>&1 ) &
    local cmd_pid=$!

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

# cryoss_apt_install pkg1 pkg2 ... — apt-get install avec spinner
cryoss_apt_install() {
    local pkgs=("$@")
    local total=${#pkgs[@]}
    local label="apt-get install (${total} paquet(s))"
    DEBIAN_FRONTEND=noninteractive cryoss_run "$label" -- \
        apt-get install -y -o Dpkg::Use-Pty=0 "${pkgs[@]}"
}

# cryoss_download URL DEST [LABEL] — télécharge avec spinner
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

cryoss_mark_done() {
    cryoss_state_init
    grep -qxF "$1" "$CRYOSS_STATE_FILE" 2>/dev/null || echo "$1" >> "$CRYOSS_STATE_FILE"
}

cryoss_is_done() {
    [[ -f "$CRYOSS_STATE_FILE" ]] && grep -qxF "$1" "$CRYOSS_STATE_FILE"
}

# cryoss_step ID TITLE — renvoie 0 = exécuter, 1 = skip (déjà fait)
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

# cryoss_save_env : sauvegarde les CRYOSS_ENV_VARS dans install.env (600 root)
cryoss_save_env() {
    cryoss_state_init
    umask 077
    {
        echo "# Cryoss — variables d'installation (généré $(date '+%Y-%m-%d %H:%M:%S'))"
        echo "# CONFIDENTIEL : peut contenir mots de passe SMTP/SFTP en clair, mode 600 root."
        echo "# Sourcé automatiquement par install_${CRYOSS_ROLE}.sh --resume"
        local var
        for var in "${CRYOSS_ENV_VARS[@]}"; do
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

cryoss_list_steps() {
    cryoss_banner
    hdr "Liste des étapes Cryoss ${CRYOSS_ROLE^^}"
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

# cryoss_reset_from ID : purge l'état à partir de l'étape ID (incluse).
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
    cat <<HELP
Usage : sudo bash install_${CRYOSS_ROLE}.sh [OPTION]

  (sans option)         Installation standard : collecte interactive puis exécution
                        de toutes les étapes. Si un état partiel existe, propose
                        de reprendre.
  --resume              Reprend après le dernier checkpoint OK (utilise l'env sauvegardé).
  --from-step ID        Repart à partir d'une étape précise. Toutes les étapes
                        suivantes sont rejouées. Utilise l'env sauvegardé.
  --only-step ID        Rejoue UNIQUEMENT l'étape donnée. Utilise l'env.
  --list-steps          Affiche la liste des étapes avec leur statut.
  --reset               Efface l'état et l'env sauvegardé (réinstall complète).
  --help, -h            Affiche cette aide.

Fichiers d'état :
  ${CRYOSS_STATE_FILE}   Étapes complétées (1 ID/ligne, 600 root).
  ${CRYOSS_ENV_FILE}     Variables collectées (600 root, sensible).
  ${CRYOSS_INSTALL_LOG}     Log brut de toutes les commandes encapsulées.
HELP
}

# =============================================================================
#  CLI MODE — caller doit avoir parsé $CRYOSS_MODE / $CRYOSS_FROM_STEP / etc.
#  Cette fonction gère les modes "help" / "list" qui ne demandent pas root.
#  Retourne 0 si le mode est terminé (exit attendu côté caller).
# =============================================================================
cryoss_handle_readonly_modes() {
    case "${CRYOSS_MODE:-install}" in
        help) cryoss_show_help; exit 0 ;;
        list) cryoss_list_steps; exit 0 ;;
    esac
}

# Mode dispatcher pour les actions root (resume / from-step / only-step / reset).
# Le caller appelle cette fonction APRÈS le root check.
cryoss_handle_root_modes() {
    case "${CRYOSS_MODE:-install}" in
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
            if [[ -z "${CRYOSS_FROM_STEP:-}" ]]; then
                err "--from-step requiert un ID d'étape. Voir --list-steps."
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
            if [[ -z "${CRYOSS_ONLY_STEP:-}" ]]; then
                err "--only-step requiert un ID d'étape. Voir --list-steps."
            fi
            if ! printf '%s\n' "${CRYOSS_STEPS[@]}" | grep -q "^${CRYOSS_ONLY_STEP}:"; then
                err "ID inconnu : ${CRYOSS_ONLY_STEP}. Voir --list-steps."
            fi
            cryoss_load_env
            if [[ -f "$CRYOSS_STATE_FILE" ]]; then
                grep -vxF "$CRYOSS_ONLY_STEP" "$CRYOSS_STATE_FILE" > "${CRYOSS_STATE_FILE}.tmp" || true
                mv "${CRYOSS_STATE_FILE}.tmp" "$CRYOSS_STATE_FILE"
                chmod 600 "$CRYOSS_STATE_FILE"
            fi
            info "Mode --only-step : seule l'étape ${CRYOSS_ONLY_STEP} sera rejouée."
            ;;
        install)
            cryoss_banner
            if [[ -f "$CRYOSS_STATE_FILE" ]] && [[ -s "$CRYOSS_STATE_FILE" ]]; then
                warn "Une installation partielle a été détectée :"
                echo
                local done_count
                done_count=$(wc -l < "$CRYOSS_STATE_FILE" 2>/dev/null || echo 0)
                echo -e "  ${CRY}Étapes déjà validées : ${BOLD}${done_count}${NC} / ${#CRYOSS_STEPS[@]}"
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
                    5|*) err "Annulé." ;;
                esac
            fi
            ;;
    esac
}

# Parsing CLI commun — le caller appelle après avoir défini CRYOSS_STEPS.
# Set CRYOSS_MODE, CRYOSS_FROM_STEP, CRYOSS_ONLY_STEP en variables globales.
cryoss_parse_cli() {
    CRYOSS_MODE="install"
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
}
