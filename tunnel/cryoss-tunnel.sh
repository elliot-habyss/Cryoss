#!/bin/bash
# ===========================================================================
# Cryoss v2 — SSH Reverse Tunnel Setup
# ===========================================================================
# Installe et configure un tunnel SSH inverse persistant via autossh.
#
# Architecture :
#   RPi1 ──autossh──> VPS/Serveur Analyss
#                       ├── port SSH (unique par serial)
#                       └── port API (SSH + 10000)
#
# L'admin se connecte au VPS, puis accède au RPi via le port tunnel :
#   ssh -p <TUNNEL_PORT> habyss@VPS_IP
#   ou forward l'API :
#   ssh -L 8420:localhost:8420 -p <TUNNEL_PORT> habyss@VPS_IP
#
# Le port est dérivé du numéro de série (unique par installation).
# ===========================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && err "Ce script doit être exécuté en root"

# --- Charger le serial ---
SERIAL_SCRIPT="/usr/local/bin/cryoss-serial.sh"
[[ ! -x "$SERIAL_SCRIPT" ]] && err "cryoss-serial.sh non trouvé — installer d'abord"

SERIAL=$("$SERIAL_SCRIPT" get)
TUNNEL_SSH_PORT=$("$SERIAL_SCRIPT" port)
TUNNEL_API_PORT=$("$SERIAL_SCRIPT" api-port)

echo -e "\n${BOLD}${BLUE}━━━ Cryoss Tunnel Setup ━━━${NC}"
echo -e "  Serial     : ${BOLD}$SERIAL${NC}"
echo -e "  SSH port   : ${BOLD}$TUNNEL_SSH_PORT${NC}"
echo -e "  API port   : ${BOLD}$TUNNEL_API_PORT${NC}\n"

# --- Paramètres ---
read -rp "  IP/hostname du serveur VPS Analyss : " VPS_HOST
[[ -z "$VPS_HOST" ]] && err "IP VPS obligatoire"

read -rp "  Utilisateur SSH sur le VPS [cryoss-tunnel] : " VPS_USER
VPS_USER="${VPS_USER:-cryoss-tunnel}"

read -rp "  Port SSH du VPS [22] : " VPS_PORT
VPS_PORT="${VPS_PORT:-22}"

# --- Installer autossh ---
if ! command -v autossh &>/dev/null; then
    info "Installation de autossh..."
    apt-get update -qq && apt-get install -y -qq autossh
fi

# --- Générer la clé SSH tunnel ---
TUNNEL_KEY="/root/.ssh/cryoss_tunnel"
if [[ ! -f "$TUNNEL_KEY" ]]; then
    info "Génération de la clé SSH tunnel..."
    ssh-keygen -t ed25519 -f "$TUNNEL_KEY" -N "" -C "cryoss-tunnel-${SERIAL}"
    chmod 600 "$TUNNEL_KEY"
    ok "Clé tunnel générée"
fi

TUNNEL_PUBKEY=$(cat "${TUNNEL_KEY}.pub")
echo ""
warn "IMPORTANT : Ajoutez cette clé sur le VPS ($VPS_HOST) :"
echo -e "${BOLD}${TUNNEL_PUBKEY}${NC}"
echo ""
info "Sur le VPS :"
echo "  sudo useradd -r -s /bin/bash -m $VPS_USER 2>/dev/null || true"
echo "  sudo mkdir -p /home/$VPS_USER/.ssh"
echo "  echo '$TUNNEL_PUBKEY' | sudo tee -a /home/$VPS_USER/.ssh/authorized_keys"
echo "  sudo chmod 600 /home/$VPS_USER/.ssh/authorized_keys"
echo "  sudo chown -R $VPS_USER:$VPS_USER /home/$VPS_USER/.ssh"
echo ""
echo "  # Et dans /etc/ssh/sshd_config du VPS :"
echo "  GatewayPorts clientspecified"
echo "  sudo systemctl restart ssh"
echo ""

read -rp "  Clé ajoutée sur le VPS ? [o/N] : " CONFIRM
[[ "${CONFIRM,,}" != "o" && "${CONFIRM,,}" != "y" ]] && err "Abandon — ajoutez la clé d'abord"

# --- Tester la connexion ---
info "Test de connexion vers $VPS_HOST..."
if ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    -i "$TUNNEL_KEY" -p "$VPS_PORT" "${VPS_USER}@${VPS_HOST}" "echo ok" 2>/dev/null | grep -q ok; then
    ok "Connexion SSH vers VPS OK"
else
    err "Connexion échouée — vérifiez la clé et le VPS"
fi

# --- Créer le service systemd ---
cat > /etc/systemd/system/cryoss-tunnel.service <<TUNNEL_EOF
[Unit]
Description=Cryoss SSH Reverse Tunnel [$SERIAL]
After=network-online.target ssh.service
Wants=network-online.target

[Service]
Type=simple
Environment="AUTOSSH_GATETIME=0"
ExecStart=/usr/bin/autossh -M 0 -N \\
    -R ${TUNNEL_SSH_PORT}:localhost:22 \\
    -R ${TUNNEL_API_PORT}:localhost:8420 \\
    -i ${TUNNEL_KEY} \\
    -p ${VPS_PORT} \\
    -o "ServerAliveInterval=30" \\
    -o "ServerAliveCountMax=3" \\
    -o "ExitOnForwardFailure=yes" \\
    -o "StrictHostKeyChecking=yes" \\
    -o "BatchMode=yes" \\
    ${VPS_USER}@${VPS_HOST}
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
TUNNEL_EOF

systemctl daemon-reload
systemctl enable cryoss-tunnel
systemctl start cryoss-tunnel

# Attendre un peu puis vérifier
sleep 3
if systemctl is-active cryoss-tunnel &>/dev/null; then
    ok "Tunnel actif"
else
    warn "Le tunnel ne semble pas actif — vérifiez : journalctl -u cryoss-tunnel -n 20"
fi

# --- Résumé ---
echo ""
echo -e "${BOLD}${GREEN}━━━ Tunnel Configuré ━━━${NC}"
echo -e "  Serial          : ${BOLD}$SERIAL${NC}"
echo -e "  VPS             : ${BOLD}$VPS_HOST${NC}"
echo -e "  SSH via tunnel  : ${BOLD}ssh -p $TUNNEL_SSH_PORT habyss@$VPS_HOST${NC}"
echo -e "  API via tunnel  : ${BOLD}ssh -L 8420:localhost:8420 -p $TUNNEL_SSH_PORT habyss@$VPS_HOST${NC}"
echo -e "  ou direct API   : ${BOLD}curl http://localhost:$TUNNEL_API_PORT/healthz${NC} (depuis le VPS)"
echo ""
echo -e "  Commandes utiles :"
echo -e "    systemctl status cryoss-tunnel"
echo -e "    journalctl -u cryoss-tunnel -f"
echo -e "    systemctl restart cryoss-tunnel"
