#!/bin/bash
# ===========================================================================
# Cryoss v2 — Installation API + Serial + Tunnel
# ===========================================================================
# À exécuter APRÈS install_rpi1.sh ou install_rpi2.sh
#
# Ce script installe :
#   1. Le numéro de série unique (si pas déjà généré)
#   2. L'API REST de contrôle distant (FastAPI)
#   3. Le service systemd pour l'API
#   4. (Optionnel) Le tunnel SSH inverse
#
# Usage :
#   sudo bash install_api.sh
#   sudo bash install_api.sh --with-tunnel
# ===========================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step() { echo -e "\n${BOLD}${BLUE}━━━ $1 ━━━${NC}"; }

[[ $EUID -ne 0 ]] && err "Ce script doit être exécuté en root"

WITH_TUNNEL=false
[[ "${1:-}" == "--with-tunnel" ]] && WITH_TUNNEL=true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Détection du rôle ---
if [[ -f /usr/local/bin/cryoss-backup.sh ]]; then
    ROLE="rpi1"
    API_HOST="127.0.0.1"
    API_PORT=8420
elif [[ -f /usr/local/bin/cryoss-repl-check.sh ]]; then
    ROLE="rpi2"
    API_HOST="10.42.0.2"
    API_PORT=8421
else
    err "Ni RPi1 ni RPi2 détecté — lancez install_rpi1.sh ou install_rpi2.sh d'abord"
fi

echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Cryoss v2 — Installation API ($ROLE)${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# ===========================================================================
# STEP 1 : Numéro de série
# ===========================================================================
step "1. Numéro de série"

mkdir -p /etc/cryoss
cp "$SCRIPT_DIR/serial/cryoss-serial.sh" /usr/local/bin/cryoss-serial.sh
chmod 755 /usr/local/bin/cryoss-serial.sh

# Demander le SN a l'installateur (sauf si deja defini)
if [[ -f /etc/cryoss/serial ]]; then
    SERIAL=$(cat /etc/cryoss/serial)
    info "Serial existant : $SERIAL"
    read -rp "  Garder ce serial ? [O/n] : " KEEP
    if [[ "${KEEP,,}" == "n" ]]; then
        read -rp "  Nouveau numero de serie (ex: DS-4A7F2C1E) : " SERIAL
        [[ -z "$SERIAL" ]] && err "Numero de serie obligatoire"
    fi
else
    echo ""
    info "Chaque installation Cryoss a un numero de serie unique."
    info "Format recommande : DS-XXXXXXXX (ex: DS-4A7F2C1E)"
    echo ""
    read -rp "  Numero de serie : " SERIAL
    [[ -z "$SERIAL" ]] && err "Numero de serie obligatoire"
fi

# Sauvegarder le serial
echo "$SERIAL" > /etc/cryoss/serial
chmod 644 /etc/cryoss/serial
ok "Serial : $SERIAL"

TUNNEL_SSH_PORT=$(/usr/local/bin/cryoss-serial.sh port)
TUNNEL_API_PORT=$(/usr/local/bin/cryoss-serial.sh api-port)
info "Ports tunnel dérivés : SSH=$TUNNEL_SSH_PORT, API=$TUNNEL_API_PORT"

# Ajouter le serial à la bannière SSH existante
if [[ -f /etc/ssh/banner ]]; then
    if ! grep -q "$SERIAL" /etc/ssh/banner 2>/dev/null; then
        sed -i "s/\]/ | $SERIAL]/" /etc/ssh/banner
    fi
fi

# ===========================================================================
# STEP 2 : Dépendances Python
# ===========================================================================
step "2. Dépendances Python"

# Vérifier Python 3.11+
PYTHON=""
for p in python3.12 python3.11 python3; do
    if command -v "$p" &>/dev/null; then
        PY_VER=$("$p" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
        PY_MAJOR=$(echo "$PY_VER" | cut -d. -f1)
        PY_MINOR=$(echo "$PY_VER" | cut -d. -f2)
        if (( PY_MAJOR >= 3 && PY_MINOR >= 11 )); then
            PYTHON="$p"
            break
        fi
    fi
done

if [[ -z "$PYTHON" ]]; then
    info "Python 3.11+ non trouvé — installation..."
    apt-get update -qq
    apt-get install -y -qq python3 python3-pip python3-venv
    PYTHON="python3"
fi

ok "Python : $($PYTHON --version)"

# Créer un venv dédié pour l'API
VENV_DIR="/opt/cryoss-api"
if [[ ! -d "$VENV_DIR" ]]; then
    info "Création du venv..."
    $PYTHON -m venv "$VENV_DIR"
fi

# Installer les dépendances dans le venv
"$VENV_DIR/bin/pip" install --quiet --upgrade pip
"$VENV_DIR/bin/pip" install --quiet fastapi "uvicorn[standard]" pydantic

ok "Dépendances installées dans $VENV_DIR"

# ===========================================================================
# STEP 3 : Installation de l'API
# ===========================================================================
step "3. Installation API"

cp "$SCRIPT_DIR/api/cryoss-api.py" /usr/local/bin/cryoss-api.py
chmod 644 /usr/local/bin/cryoss-api.py
ok "API copiée"

# ===========================================================================
# STEP 4 : Clé API
# ===========================================================================
step "4. Clé API"

API_KEY_FILE="/etc/cryoss/api-key"
if [[ -f "$API_KEY_FILE" ]]; then
    info "Clé API existante conservée"
else
    API_KEY=$(openssl rand -base64 48)
    echo "$API_KEY" > "$API_KEY_FILE"
    chmod 600 "$API_KEY_FILE"
    ok "Clé API générée"
    echo ""
    warn "CONSERVEZ CETTE CLÉ (elle ne sera plus affichée) :"
    echo -e "  ${BOLD}$API_KEY${NC}"
    echo ""
fi

# ===========================================================================
# STEP 5 : Service systemd API
# ===========================================================================
step "5. Utilisateur et service systemd"

# [A1] L'API ne tourne PAS en root — utilisateur dedie avec sudo restreint
if ! id cryoss-api &>/dev/null; then
    useradd -r -s /usr/sbin/nologin -d /nonexistent -M cryoss-api
    ok "Utilisateur cryoss-api cree"
fi

# Donner acces en lecture a la cle API et au serial
chown root:cryoss-api /etc/cryoss/api-key 2>/dev/null || true
chmod 640 /etc/cryoss/api-key 2>/dev/null || true
chown root:cryoss-api /etc/cryoss/serial 2>/dev/null || true
chmod 644 /etc/cryoss/serial 2>/dev/null || true

# sudoers : cryoss-api peut executer uniquement les commandes de monitoring
cat > /etc/sudoers.d/cryoss-api <<'SUDO_EOF'
# Cryoss API — commandes autorisees sans mot de passe
cryoss-api ALL=(root) NOPASSWD: /usr/bin/systemctl show *
cryoss-api ALL=(root) NOPASSWD: /usr/bin/systemctl is-active *
cryoss-api ALL=(root) NOPASSWD: /usr/bin/systemctl start cryoss-backup.service
cryoss-api ALL=(root) NOPASSWD: /usr/bin/systemctl start cryoss-sftp-sync.service
cryoss-api ALL=(root) NOPASSWD: /usr/bin/systemctl list-units *
cryoss-api ALL=(root) NOPASSWD: /usr/bin/systemctl list-timers *
cryoss-api ALL=(root) NOPASSWD: /usr/bin/journalctl *
cryoss-api ALL=(root) NOPASSWD: /usr/bin/mdadm --detail *
cryoss-api ALL=(root) NOPASSWD: /usr/bin/smartctl *
cryoss-api ALL=(root) NOPASSWD: /usr/bin/fail2ban-client *
cryoss-api ALL=(root) NOPASSWD: /usr/sbin/ufw status *
cryoss-api ALL=(root) NOPASSWD: /usr/bin/rclone *
cryoss-api ALL=(root) NOPASSWD: /usr/local/bin/cryoss-health.sh *
cryoss-api ALL=(root) NOPASSWD: /usr/bin/ssh -o BatchMode=yes *
cryoss-api ALL=(root) NOPASSWD: /usr/bin/df *
cryoss-api ALL=(root) NOPASSWD: /usr/bin/cat /proc/*
cryoss-api ALL=(root) NOPASSWD: /usr/bin/aa-status
SUDO_EOF
chmod 440 /etc/sudoers.d/cryoss-api
ok "sudoers API configure (commandes restreintes)"

# Donner acces en lecture aux logs
for logf in /var/log/cryoss-backup.log /var/log/cryoss-health.log /var/log/cryoss-honeypot.log \
            /var/log/rclone_cryoss_c1.log /var/log/rclone_cryoss_c2.log /var/log/rclone_cryoss_c3.log \
            /var/log/msmtp.log; do
    touch "$logf" 2>/dev/null
    chown root:cryoss-api "$logf" 2>/dev/null
    chmod 640 "$logf" 2>/dev/null
done

cat > /etc/systemd/system/cryoss-api.service <<API_SVC_EOF
[Unit]
Description=Cryoss Remote API [$SERIAL] ($ROLE)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${VENV_DIR}/bin/uvicorn cryoss-api:app \\
    --host ${API_HOST} \\
    --port ${API_PORT} \\
    --app-dir /usr/local/bin \\
    --log-level warning \\
    --timeout-keep-alive 30 \\
    --limit-concurrency 20
Restart=on-failure
RestartSec=10
User=cryoss-api
Group=cryoss-api
StandardOutput=append:/var/log/cryoss-api.log
StandardError=append:/var/log/cryoss-api.log
NoNewPrivileges=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=/var/log/cryoss-api.log

[Install]
WantedBy=multi-user.target
API_SVC_EOF

# Logrotate pour les logs API
cat > /etc/logrotate.d/cryoss-api <<LOGROTATE_EOF
/var/log/cryoss-api.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    create 640 root root
}
LOGROTATE_EOF

systemctl daemon-reload
systemctl enable cryoss-api
systemctl start cryoss-api

sleep 2
if systemctl is-active cryoss-api &>/dev/null; then
    ok "API active sur ${API_HOST}:${API_PORT}"
else
    warn "L'API ne semble pas démarrée — vérifiez : journalctl -u cryoss-api -n 20"
fi

# UFW : autoriser le port API sur l'interco (RPi2 seulement)
if [[ "$ROLE" == "rpi2" ]]; then
    ufw allow from 10.42.0.1 to 10.42.0.2 port "$API_PORT" proto tcp \
        comment "Cryoss API RPi2 (depuis RPi1)" 2>/dev/null || true
    ok "UFW : port $API_PORT ouvert pour RPi1"
fi

# ===========================================================================
# STEP 6 : Tunnel SSH inverse (optionnel)
# ===========================================================================
if [[ "$WITH_TUNNEL" == true && "$ROLE" == "rpi1" ]]; then
    step "6. Tunnel SSH inverse"
    bash "$SCRIPT_DIR/tunnel/cryoss-tunnel.sh"
else
    if [[ "$ROLE" == "rpi1" ]]; then
        info "Tunnel non installé — relancez avec : sudo bash install_api.sh --with-tunnel"
    else
        info "Tunnel non applicable sur RPi2 (air-gapped)"
    fi
fi

# ===========================================================================
# RÉSUMÉ
# ===========================================================================
echo ""
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Cryoss v2 API — Installation terminée${NC}"
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Serial         : ${BOLD}$SERIAL${NC}"
echo -e "  Rôle           : ${BOLD}$ROLE${NC}"
echo -e "  API            : ${BOLD}http://${API_HOST}:${API_PORT}${NC}"
echo -e "  Swagger        : ${BOLD}http://${API_HOST}:${API_PORT}/docs${NC}"
echo -e "  Health check   : ${BOLD}http://${API_HOST}:${API_PORT}/healthz${NC}"
echo -e "  Clé API        : ${BOLD}$API_KEY_FILE${NC}"
echo ""

if [[ "$ROLE" == "rpi1" ]]; then
    echo -e "  ${BOLD}Accès depuis l'extérieur :${NC}"
    echo -e "    1. SSH tunnel :  ssh -L 8420:localhost:8420 habyss@<IP_PUBLIQUE_CLIENT>"
    echo -e "    2. Puis :        curl -H 'Authorization: Bearer <KEY>' http://localhost:8420/api/v1/status"
    echo -e "    3. Swagger :     open http://localhost:8420/docs"
    echo ""
    if [[ "$WITH_TUNNEL" == true ]]; then
        echo -e "  ${BOLD}Accès via tunnel inverse (depuis le VPS) :${NC}"
        echo -e "    ssh -p $TUNNEL_SSH_PORT habyss@VPS_IP"
        echo -e "    curl http://localhost:$TUNNEL_API_PORT/healthz"
    else
        echo -e "  ${BOLD}Tunnel inverse :${NC} non installé"
        echo -e "    Installer : sudo bash install_api.sh --with-tunnel"
    fi
fi

echo ""
echo -e "  ${BOLD}Test rapide :${NC}"
echo -e "    curl http://${API_HOST}:${API_PORT}/healthz"
echo -e "    curl -H 'Authorization: Bearer \$(cat $API_KEY_FILE)' http://${API_HOST}:${API_PORT}/api/v1/status"
echo ""
