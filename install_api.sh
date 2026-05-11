#!/bin/bash
# ===========================================================================
# Cryoss v2 — Installation API + Serial + Heartbeat
# ===========================================================================
# À exécuter APRÈS install_rpi1.sh ou install_rpi2.sh
#
# Ce script installe :
#   1. Le numéro de série unique (si pas déjà généré)
#   2. L'API REST de contrôle distant (FastAPI)
#   3. Le service systemd pour l'API
#   4. Le heartbeat phone-home vers Analyss (HTTPS push)
#
# Usage :
#   sudo bash install_api.sh
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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Détection du rôle ---
if [[ -f /usr/local/bin/cryoss-backup.sh ]]; then
    ROLE="rpi1"
    API_HOST="127.0.0.1"
    API_PORT=8420
elif ip addr show 2>/dev/null | grep -q "10.42.0.2"; then
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
# STEP 6 : Heartbeat phone-home vers Analyss (RPi1 uniquement)
# ===========================================================================
# RPi2 est air-gapped — il n'envoie PAS de heartbeat directement.
# RPi1 collecte les donnees de RPi2 via SSH interco et les inclut dans son heartbeat.
if [[ "$ROLE" == "rpi1" ]]; then
    step "6. Heartbeat Analyss"

    cp "$SCRIPT_DIR/heartbeat/cryoss-heartbeat.sh" /usr/local/bin/cryoss-heartbeat.sh
    chmod 755 /usr/local/bin/cryoss-heartbeat.sh
    ok "Script heartbeat installe"

    # Command runner (executeur des commandes bidirectionnelles depuis Analyss)
    if [[ -f "$SCRIPT_DIR/heartbeat/cryoss-command-runner.sh" ]]; then
        cp "$SCRIPT_DIR/heartbeat/cryoss-command-runner.sh" /usr/local/bin/cryoss-command-runner.sh
        chmod 700 /usr/local/bin/cryoss-command-runner.sh
        chown root:root /usr/local/bin/cryoss-command-runner.sh
        touch /var/log/cryoss-command.log
        chmod 640 /var/log/cryoss-command.log
        ok "Command runner installe (commandes Analyss->Cryoss)"
    fi

    # Helper Fernet (cryoss-decrypt-secret) — pour les params chiffrés par la Console
    if [[ -f "$SCRIPT_DIR/heartbeat/cryoss-decrypt-secret" ]]; then
        cp "$SCRIPT_DIR/heartbeat/cryoss-decrypt-secret" /usr/local/bin/cryoss-decrypt-secret
        chmod 700 /usr/local/bin/cryoss-decrypt-secret
        chown root:root /usr/local/bin/cryoss-decrypt-secret
        # Dépendance Python — installée seulement si manquante
        if ! python3 -c 'import cryptography.fernet' 2>/dev/null; then
            info "Installation python3-cryptography (requis pour Fernet)..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y python3-cryptography &>/dev/null \
                && ok "python3-cryptography installe" \
                || warn "python3-cryptography non installable — la decryption Fernet ne marchera pas"
        fi
        ok "Helper Fernet installe (cryoss-decrypt-secret)"
    fi

    # Master key Fernet — requise pour decrypter les params 'enc:v1:*' envoyes
    # par la Console (passwords Samba via samba_user_add etc.). Logique
    # dupliquee de install_rpi1.sh step 15 (source de verite) pour permettre
    # a un operateur qui n'a lance que install_rpi1.sh sans step 15 de la
    # configurer ici. Sans master key, les commandes a params sensibles
    # ack_error mais le reste (diagnostics, samba sans password) marche.
    if [[ ! -f /etc/cryoss/master_key ]]; then
        echo
        info "Master key Fernet (/etc/cryoss/master_key) absente."
        info "Elle est requise pour decrypter les params 'enc:v1:*' (passwords"
        info "Samba etc.) envoyes par la Console Analyss."
        echo
        read -rp "  Configurer la master key maintenant ? [O/n] : " _cfg_mk
        if [[ "${_cfg_mk,,}" == "n" ]]; then
            warn "Master key skippee. Pour la configurer plus tard :"
            warn "  sudo bash install_rpi1.sh --only-step 15-master-key"
            warn "Les commandes Samba avec password ne marcheront pas tant qu'elle"
            warn "ne sera pas deposee (les diagnostics et le reste fonctionnent)."
        else
            if ! python3 -c 'import cryptography.fernet' 2>/dev/null; then
                info "Installation python3-cryptography..."
                DEBIAN_FRONTEND=noninteractive apt-get install -y python3-cryptography &>/dev/null \
                    || err "python3-cryptography requis pour valider la master key"
            fi
            info "Format attendu : Fernet base64 url-safe (44 caracteres)."
            info "Genere par la Console Analyss, copier depuis l'UI."
            echo
            while true; do
                read -rsp "  Master key Fernet : " MASTER_KEY; echo
                if [[ -z "$MASTER_KEY" ]]; then
                    warn "Vide — reessayez ou Ctrl+C pour skipper."
                    continue
                fi
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
                    warn "Master key invalide. Format : Fernet base64 url-safe (44 chars)."
                fi
            done
            mkdir -p /etc/cryoss
            chmod 700 /etc/cryoss
            chown root:root /etc/cryoss
            umask 077
            printf '%s\n' "$MASTER_KEY" > /etc/cryoss/master_key
            chmod 600 /etc/cryoss/master_key
            chown root:root /etc/cryoss/master_key
            unset MASTER_KEY
            ok "Master key deposee : /etc/cryoss/master_key (0600 root:root)"
        fi
    else
        ok "Master key presente : /etc/cryoss/master_key"
    fi

    # Template de surcharge des roots filesystem du runner (whitelist 4 cles).
    # Depose en .example pour signaler aux operateurs l'existence du fichier
    # et la liste exacte des cles acceptees — pas de copie automatique en
    # config.env (defaults runner OK pour 99% des installs).
    if [[ ! -f /etc/cryoss/config.env.example ]]; then
        mkdir -p /etc/cryoss
        chmod 700 /etc/cryoss
        chown root:root /etc/cryoss
        cat > /etc/cryoss/config.env.example <<'CONFIG_ENV_EOF'
# =============================================================================
# Cryoss runner config — overrides pour cryoss-command-runner.sh
# =============================================================================
# Lu par le runner au dispatch. Pour activer un override, copier ce fichier
# vers /etc/cryoss/config.env (sans le .example) et decommenter les lignes.
#
# Parser strict : seules les 4 cles ci-dessous sont acceptees. Autres lignes
# = ignorees + log WARN. Format KEY=VALUE (pas de quoting requis).
#
# /etc/cryoss/config.env doit etre en 0600 root:root.
# =============================================================================

# Cible des Samba shares (RAID md0, depot clair).
# Defaut : /etc/sauvegarde
#CRYOSS_SHARE_ROOT=/etc/sauvegarde

# Cible locale c1 (RAID md1). c2/c3 sont sur SFTP et n'ont pas de path FS local.
# Defaut : /etc/encrypted
#CRYOSS_ARCHIVE_ROOT=/etc/encrypted

# Dossier de destination pour decrypt_path. Cleanup auto via timer apres TTL.
# Defaut : /var/lib/cryoss/decrypted
#CRYOSS_DECRYPT_DIR=/var/lib/cryoss/decrypted

# TTL (heures) avant cleanup automatique du contenu decrypte.
# Defaut : 1
#CRYOSS_DECRYPT_TTL_HOURS=1
CONFIG_ENV_EOF
        chmod 644 /etc/cryoss/config.env.example
        chown root:root /etc/cryoss/config.env.example
        ok "Template depose : /etc/cryoss/config.env.example"
    fi

    # update.sh (utilise par apt_update_check / apt_upgrade via le runner).
    # Sans ce cp, les deux commandes ack_error en permanence ("update.sh introuvable").
    if [[ -f "$SCRIPT_DIR/update.sh" ]]; then
        cp "$SCRIPT_DIR/update.sh" /usr/local/bin/update.sh
        chmod 700 /usr/local/bin/update.sh
        chown root:root /usr/local/bin/update.sh
        ok "update.sh installe (/usr/local/bin/update.sh)"
    else
        warn "update.sh introuvable dans $SCRIPT_DIR — apt_update_check / apt_upgrade ne fonctionneront pas"
    fi

    # Cleanup automatique des dechiffres a la demande (decrypt_path) apres T+1h
    mkdir -p /var/lib/cryoss/decrypted
    chmod 700 /var/lib/cryoss/decrypted
    chown root:root /var/lib/cryoss/decrypted

    cat > /etc/systemd/system/cryoss-decrypted-cleanup.service <<'CLEANUP_SVC_EOF'
[Unit]
Description=Cryoss - Cleanup of on-demand decrypted files past TTL
ConditionPathIsDirectory=/var/lib/cryoss/decrypted

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
    set -e; \
    NOW=$(date +%s); \
    for d in /var/lib/cryoss/decrypted/*/; do \
        [[ -d "$d" ]] || continue; \
        EXP_FILE="${d}.expires_at"; \
        if [[ -f "$EXP_FILE" ]]; then \
            EXP=$(cat "$EXP_FILE" 2>/dev/null); \
            if [[ "$EXP" =~ ^[0-9]+$ ]] && (( EXP < NOW )); then \
                rm -rf "$d" && echo "cleaned: $d"; \
            fi; \
        else \
            AGE=$(( NOW - $(stat -c %Y "$d" 2>/dev/null || echo $NOW) )); \
            if (( AGE > 7200 )); then \
                rm -rf "$d" && echo "cleaned (no marker): $d"; \
            fi; \
        fi; \
    done'
StandardOutput=append:/var/log/cryoss-command.log
User=root
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/cryoss/decrypted /var/log
PrivateTmp=yes
CLEANUP_SVC_EOF

    cat > /etc/systemd/system/cryoss-decrypted-cleanup.timer <<'CLEANUP_TMR_EOF'
[Unit]
Description=Cryoss - Cleanup decrypted/ every 10 min

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
Unit=cryoss-decrypted-cleanup.service

[Install]
WantedBy=timers.target
CLEANUP_TMR_EOF

    systemctl daemon-reload
    systemctl enable --now cryoss-decrypted-cleanup.timer >/dev/null 2>&1 || true
    ok "Timer cleanup decrypted/ installe (TTL 1h, scan toutes les 10min)"

    # Config Analyss
    ANALYSS_CONF="/etc/cryoss/analyss.conf"
    if [[ -f "$ANALYSS_CONF" ]]; then
        info "Config Analyss existante conservee"
    else
        read -rp "  URL Analyss (ex: https://app.analyss.fr) : " ANALYSS_URL
        ANALYSS_URL="${ANALYSS_URL:-https://app.analyss.fr}"
        cat > "$ANALYSS_CONF" <<ANALYSS_EOF
# Cryoss heartbeat — connexion vers Analyss
ANALYSS_URL="${ANALYSS_URL}"
ANALYSS_API_KEY=""
ANALYSS_EOF
        chmod 600 "$ANALYSS_CONF"
        chown root:cryoss-api "$ANALYSS_CONF" 2>/dev/null || true
        ok "Config Analyss creee ($ANALYSS_CONF)"
        info "L'API key sera obtenue lors du premier enregistrement"
        info "Lancer : sudo cryoss-heartbeat.sh register"
    fi

    # Timer systemd heartbeat (toutes les 5 min)
    cat > /etc/systemd/system/cryoss-heartbeat.service <<HB_SVC_EOF
[Unit]
Description=Cryoss Heartbeat [$SERIAL] ($ROLE)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cryoss-heartbeat.sh
StandardOutput=append:/var/log/cryoss-heartbeat.log
StandardError=append:/var/log/cryoss-heartbeat.log
HB_SVC_EOF

    cat > /etc/systemd/system/cryoss-heartbeat.timer <<HB_TMR_EOF
[Unit]
Description=Cryoss Heartbeat Timer (5min)

[Timer]
OnBootSec=60
OnUnitActiveSec=300
AccuracySec=30

[Install]
WantedBy=timers.target
HB_TMR_EOF

    # Logrotate heartbeat
    cat >> /etc/logrotate.d/cryoss-api <<HB_LOG_EOF

/var/log/cryoss-heartbeat.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 640 root root
}
HB_LOG_EOF

    touch /var/log/cryoss-heartbeat.log
    chown root:cryoss-api /var/log/cryoss-heartbeat.log 2>/dev/null || true
    chmod 640 /var/log/cryoss-heartbeat.log 2>/dev/null || true

    systemctl daemon-reload
    systemctl enable cryoss-heartbeat.timer
    systemctl start cryoss-heartbeat.timer
    ok "Heartbeat timer actif (toutes les 5 min)"
else
    info "Heartbeat non installe sur RPi2 (air-gapped, donnees collectees par RPi1)"
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
echo -e "  Heartbeat      : ${BOLD}toutes les 5 min vers Analyss${NC}"
echo ""
echo -e "  ${BOLD}Enregistrement Analyss :${NC}"
echo -e "    sudo cryoss-heartbeat.sh register"
echo ""
echo -e "  ${BOLD}Test rapide :${NC}"
echo -e "    curl http://${API_HOST}:${API_PORT}/healthz"
echo -e "    curl -H 'Authorization: Bearer \$(cat $API_KEY_FILE)' http://${API_HOST}:${API_PORT}/api/v1/status"
echo -e "    sudo cryoss-heartbeat.sh    # envoyer un heartbeat maintenant"
echo ""
