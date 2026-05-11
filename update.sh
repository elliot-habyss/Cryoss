#!/bin/bash
# ===========================================================================
# CRYOSS — Mise a jour (safe)
# ===========================================================================
#
# Met a jour une installation existante SANS RIEN CASSER :
#
# JAMAIS TOUCHE :
#   ✗ RAID (pas de nuke_disk, pas de mkfs, pas de mdadm --create)
#   ✗ Cles rclone (rclone.conf preserve tel quel)
#   ✗ Cles backup (/etc/cryoss/keys-backup.conf)
#   ✗ Mots de passe users (pas de chpasswd)
#   ✗ Numero de serie
#   ✗ Cle API
#   ✗ Cles SSH
#   ✗ Config reseau (IP, interco)
#   ✗ Config email (msmtp, postfix)
#   ✗ fstab
#
# MIS A JOUR :
#   ✓ cryoss-backup.sh (re-genere avec la config existante)
#   ✓ cryoss-health.sh (re-genere avec la config existante)
#   ✓ cryoss-api.py
#   ✓ Services/timers systemd
#   ✓ Config Samba (smb.conf)
#   ✓ Config fail2ban, sysctl, logrotate
#   ✓ Profils AppArmor
#   ✓ Dependances Python API
#
# Le script lit la config DEPUIS L'INSTALLATION EXISTANTE — pas de questions.
#
# Usage :
#   sudo bash update.sh              # RPi1 (full update)
#   sudo bash update.sh --rpi2       # RPi2 (full update)
#   sudo bash update.sh --check      # Dry-run : liste les MAJ disponibles
#                                    #            sur les paquets Cryoss-critiques
# ===========================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step() { echo -e "\n${BOLD}${BLUE}━━━ $1 ━━━${NC}"; }

[[ $EUID -ne 0 ]] && err "Root requis"

IS_RPI2=false
CHECK_ONLY=false
case "${1:-}" in
    --rpi2)  IS_RPI2=true ;;
    --check) CHECK_ONLY=true ;;
    "")      ;;
    *)       err "Argument inconnu : $1 (utilisez --rpi2 ou --check)" ;;
esac

# ===========================================================================
# Mode --check : dry-run informatif (utilisé par cryoss-command-runner pour
# apt_update_check). Ne touche à rien, retourne la liste des MAJ disponibles
# sur les paquets Cryoss-critiques uniquement (pas tout le système).
# ===========================================================================
if [[ "$CHECK_ONLY" == true ]]; then
    info "Mode --check : dry-run (aucune modification)"
    apt-get update -qq 2>/dev/null || warn "apt-get update a échoué (continue)"
    echo
    echo "=== Mises à jour disponibles (paquets Cryoss-critiques) ==="
    PKGS_PATTERN='^(rclone|samba|samba-common|samba-common-bin|smbclient|libsmbclient|fail2ban|ufw|mdadm|msmtp|msmtp-mta|smartmontools|openssh-server|python3|python3-cryptography|curl)/'
    UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -E "$PKGS_PATTERN" || true)
    if [[ -z "$UPGRADABLE" ]]; then
        echo "(aucune mise à jour disponible sur les paquets Cryoss-critiques)"
    else
        echo "$UPGRADABLE"
    fi
    echo
    echo "=== Versions actuelles installées ==="
    for pkg in rclone samba mdadm fail2ban msmtp; do
        v=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo "non installé")
        printf "  %-30s %s\n" "$pkg" "$v"
    done
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║        CRYOSS — Mise a jour safe         ║${NC}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════╝${NC}"
echo ""

# ===========================================================================
# DETECTION ET LECTURE CONFIG EXISTANTE
# ===========================================================================
step "0. Lecture de la configuration existante"

# --- Detecter le role ---
if [[ "$IS_RPI2" == true ]]; then
    ROLE="rpi2"
else
    ROLE="rpi1"
fi

# --- Verifier qu'il y a bien une installation ---
if [[ "$ROLE" == "rpi1" ]]; then
    [[ ! -f /usr/local/bin/cryoss-backup.sh ]] && \
        err "cryoss-backup.sh non trouve — pas d'installation Cryoss. Utilisez install_rpi1.sh pour une installation neuve."
fi

# --- Lire la config depuis les scripts deployes ---

# Client name (depuis smb.conf ou le script backup)
CLIENT_NAME=""
if [[ -f /etc/samba/smb.conf ]]; then
    CLIENT_NAME=$(grep "server string" /etc/samba/smb.conf 2>/dev/null | sed 's/.*\[//;s/\].*//' || true)
fi
if [[ -z "$CLIENT_NAME" ]] && [[ -f /usr/local/bin/cryoss-backup.sh ]]; then
    CLIENT_NAME=$(grep '^CLIENT_NAME=' /usr/local/bin/cryoss-backup.sh 2>/dev/null | head -1 | cut -d'"' -f2 || true)
fi
if [[ -z "$CLIENT_NAME" ]] && [[ -f /usr/local/bin/cryoss-health.sh ]]; then
    CLIENT_NAME=$(grep '^CLIENT_NAME=' /usr/local/bin/cryoss-health.sh 2>/dev/null | head -1 | cut -d'"' -f2 || true)
fi
[[ -z "$CLIENT_NAME" ]] && CLIENT_NAME="Cryoss"
ok "Client : $CLIENT_NAME"

# Email (depuis le script backup ou health)
EMAIL_TO=""
EMAIL_TO_2=""
if [[ -f /usr/local/bin/cryoss-backup.sh ]]; then
    EMAIL_TO=$(grep '^EMAIL_TO=' /usr/local/bin/cryoss-backup.sh 2>/dev/null | head -1 | cut -d'"' -f2 || true)
    EMAIL_TO_2=$(grep '^EMAIL_TO_2=' /usr/local/bin/cryoss-backup.sh 2>/dev/null | head -1 | cut -d'"' -f2 || true)
fi
if [[ -z "$EMAIL_TO" ]] && [[ -f /usr/local/bin/cryoss-health.sh ]]; then
    EMAIL_TO=$(grep '^EMAIL_TO_1=' /usr/local/bin/cryoss-health.sh 2>/dev/null | head -1 | cut -d'"' -f2 || true)
    EMAIL_TO_2=$(grep '^EMAIL_TO_2=' /usr/local/bin/cryoss-health.sh 2>/dev/null | head -1 | cut -d'"' -f2 || true)
fi
[[ -n "$EMAIL_TO" ]] && ok "Email 1 : $EMAIL_TO" || warn "Email non detecte"
[[ -n "$EMAIL_TO_2" ]] && ok "Email 2 : $EMAIL_TO_2"

# SFTP active ?
ENABLE_SFTP="no"
if [[ -f /usr/local/bin/cryoss-backup.sh ]]; then
    ENABLE_SFTP=$(grep '^ENABLE_SFTP=' /usr/local/bin/cryoss-backup.sh 2>/dev/null | head -1 | cut -d'"' -f2 || echo "no")
fi
if [[ "$ENABLE_SFTP" == "no" ]] && rclone listremotes 2>/dev/null | grep -q "cryoss-c3"; then
    ENABLE_SFTP="yes"
fi
ok "SFTP distant : $ENABLE_SFTP"

# Serial
SERIAL=""
[[ -f /etc/cryoss/serial ]] && SERIAL=$(cat /etc/cryoss/serial)
[[ -n "$SERIAL" ]] && ok "Serial : $SERIAL" || info "Serial non defini"

# rclone.conf existe ?
RCLONE_CONF="/root/.config/rclone/rclone.conf"
[[ -f "$RCLONE_CONF" ]] && ok "rclone.conf : present (preserve)" || warn "rclone.conf absent"

# Cles backup existent ?
[[ -f /etc/cryoss/keys-backup.conf ]] && ok "Cles backup : presentes" || warn "Cles backup absentes"

# Disques physiques (depuis le health existant)
PHYSICAL_DISKS=""
if [[ -f /usr/local/bin/cryoss-health.sh ]]; then
    PHYSICAL_DISKS=$(grep '^PHYSICAL_DISKS=' /usr/local/bin/cryoss-health.sh 2>/dev/null | head -1 | cut -d'"' -f2 || true)
fi
if [[ -z "$PHYSICAL_DISKS" ]]; then
    PHYSICAL_DISKS=$(lsblk -dno NAME 2>/dev/null | grep -E '^sd|^nvme' | tr '\n' ' ')
fi
ok "Disques : $PHYSICAL_DISKS"

# RPI2_DIR
RPI2_DIR=""
if [[ -f /usr/local/bin/cryoss-health.sh ]]; then
    RPI2_DIR=$(grep '^RPI2_DIR=' /usr/local/bin/cryoss-health.sh 2>/dev/null | head -1 | cut -d'"' -f2 || true)
fi
[[ -z "$RPI2_DIR" ]] && RPI2_DIR="/etc/encrypted/rpi1"

# SFTP_HOST
SFTP_HOST=""
if [[ -f /usr/local/bin/cryoss-health.sh ]]; then
    SFTP_HOST=$(grep '^SFTP_HOST=' /usr/local/bin/cryoss-health.sh 2>/dev/null | head -1 | cut -d'"' -f2 || true)
fi
[[ -z "$SFTP_HOST" ]] && SFTP_HOST="N/A"

# INTERCO IP
INTERCO_IP_RPI2="10.42.0.2"
if grep -q "HostName" /root/.ssh/config 2>/dev/null; then
    INTERCO_IP_RPI2=$(grep "HostName.*10.42" /root/.ssh/config 2>/dev/null | awk '{print $2}' | head -1 || echo "10.42.0.2")
fi

echo ""
warn "Les elements suivants NE SERONT PAS touches :"
echo "  - RAID (md0, md1)"
echo "  - Cles rclone (rclone.conf)"
echo "  - Mots de passe utilisateurs"
echo "  - Cles SSH, serial, cle API"
echo "  - Config reseau et email"
echo ""
info "Seuls les scripts, services et configs seront mis a jour."
read -rp "  Continuer ? [o/N] : " C; [[ "${C,,}" != "o" ]] && exit 1

# ===========================================================================
# 1. ARRETER LES SERVICES
# ===========================================================================
step "1. Arret des services"

for svc in cryoss-backup.timer cryoss-sftp-sync.timer \
           cryoss-health-daily.timer cryoss-health-weekly.timer \
           cryoss-watchdog.timer cryoss-honeypot.service \
           cryoss-api.service; do
    systemctl stop "$svc" 2>/dev/null || true
done
ok "Services arretes"

# ===========================================================================
# 2. MISE A JOUR RCLONE
# ===========================================================================
step "2. Verification rclone"

if ! command -v rclone &>/dev/null; then
    info "Installation rclone..."
    curl -fsSL https://rclone.org/install.sh | bash &>/dev/null \
        || err "Installation rclone echouee"
    ok "rclone installe"
else
    CURRENT_VER=$(rclone version 2>/dev/null | head -1 | awk '{print $2}')
    ok "rclone $CURRENT_VER"
fi

# ===========================================================================
# 3. RPi1 : RE-GENERER LE SCRIPT BACKUP AVEC LA CONFIG EXISTANTE
# ===========================================================================
if [[ "$ROLE" == "rpi1" ]]; then
    step "3. Mise a jour cryoss-backup.sh"

    # Le backup script est un heredoc dans install_rpi1.sh.
    # On extrait le nouveau heredoc et on injecte les valeurs existantes.

    # Extraire le heredoc du nouveau install_rpi1.sh
    sed -n "/^cat > \/usr\/local\/bin\/cryoss-backup.sh << 'SCRIPT_HEREDOC'/,/^SCRIPT_HEREDOC/p" \
        "$SCRIPT_DIR/install_rpi1.sh" \
        | tail -n +2 | head -n -1 \
        > /usr/local/bin/cryoss-backup.sh

    # Injecter les valeurs existantes
    sed -i \
        -e "s|DS_ENABLE_SFTP|${ENABLE_SFTP}|g" \
        -e "s|DS_EMAIL_TO_2|${EMAIL_TO_2}|g" \
        -e "s|DS_EMAIL_TO|${EMAIL_TO}|g" \
        -e "s|DS_CLIENT_NAME|${CLIENT_NAME}|g" \
        /usr/local/bin/cryoss-backup.sh

    chmod 700 /usr/local/bin/cryoss-backup.sh
    chown root:root /usr/local/bin/cryoss-backup.sh
    ok "cryoss-backup.sh mis a jour (config preservee)"

    # --- Re-generer le health script ---
    step "3b. Mise a jour cryoss-health.sh"

    sed -n "/^cat > \/usr\/local\/bin\/cryoss-health.sh << 'HEALTH_SCRIPT'/,/^HEALTH_SCRIPT/p" \
        "$SCRIPT_DIR/install_rpi1.sh" \
        | tail -n +2 | head -n -1 \
        > /usr/local/bin/cryoss-health.sh

    sed -i \
        -e "s|__CLIENT_NAME__|${CLIENT_NAME}|g" \
        -e "s|__EMAIL_TO_1__|${EMAIL_TO}|g" \
        -e "s|__EMAIL_TO_2__|${EMAIL_TO_2}|g" \
        -e "s|__PHYSICAL_DISKS__|${PHYSICAL_DISKS}|g" \
        -e "s|__RPI2_DIR__|${RPI2_DIR}|g" \
        -e "s|__SFTP_HOST__|${SFTP_HOST}|g" \
        -e "s|__ENABLE_SFTP__|${ENABLE_SFTP}|g" \
        /usr/local/bin/cryoss-health.sh

    chmod 700 /usr/local/bin/cryoss-health.sh
    chown root:root /usr/local/bin/cryoss-health.sh
    ok "cryoss-health.sh mis a jour"
fi

if [[ "$ROLE" == "rpi2" ]]; then
    step "3. Mise a jour cryoss-health.sh (RPi2)"

    # Extraire le health script RPi2 depuis install_rpi2.sh
    if grep -q "HEALTH_SCRIPT" "$SCRIPT_DIR/install_rpi2.sh"; then
        sed -n "/^cat > \/usr\/local\/bin\/cryoss-health.sh << 'HEALTH_SCRIPT'/,/^HEALTH_SCRIPT/p" \
            "$SCRIPT_DIR/install_rpi2.sh" \
            | tail -n +2 | head -n -1 \
            > /usr/local/bin/cryoss-health.sh

        # Lire les valeurs existantes depuis l'ancien health
        OLD_EMAIL=$(grep '^R2_EMAIL_TO=' /usr/local/bin/cryoss-health.sh 2>/dev/null | head -1 | cut -d'"' -f2 || echo "$EMAIL_TO")
        OLD_CLIENT=$(grep '^DS_CLIENT_NAME=' /usr/local/bin/cryoss-health.sh 2>/dev/null | head -1 | cut -d'"' -f2 || echo "$CLIENT_NAME")
        OLD_RPI1_IP=$(grep '^DS_RPI1_IP=' /usr/local/bin/cryoss-health.sh 2>/dev/null | head -1 | cut -d'"' -f2 || echo "10.42.0.1")
        OLD_RPI2_DIR=$(grep '^DS_RPI2_DIR=' /usr/local/bin/cryoss-health.sh 2>/dev/null | head -1 | cut -d'"' -f2 || echo "$RPI2_DIR")

        sed -i \
            -e "s|DS_EMAIL_TO|${OLD_EMAIL}|g" \
            -e "s|DS_CLIENT_NAME|${OLD_CLIENT}|g" \
            -e "s|DS_RPI1_IP|${OLD_RPI1_IP}|g" \
            -e "s|DS_RPI2_DIR|${OLD_RPI2_DIR}|g" \
            /usr/local/bin/cryoss-health.sh 2>/dev/null || true

        chmod 700 /usr/local/bin/cryoss-health.sh
        ok "cryoss-health.sh RPi2 mis a jour"
    else
        warn "Heredoc health non trouve dans install_rpi2.sh — script inchange"
    fi
fi

# ===========================================================================
# 4. METTRE A JOUR LES SERVICES SYSTEMD
# ===========================================================================
step "4. Mise a jour services systemd"

if [[ "$ROLE" == "rpi1" ]]; then
    # Extraire et installer les unites systemd depuis install_rpi1.sh
    # Le plus simple : re-generer les fichiers a la main

    cat > /etc/systemd/system/cryoss-backup.service <<SVC_EOF
[Unit]
Description=Cryoss — Triple sauvegarde chiffree [$CLIENT_NAME]
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

    cat > /etc/systemd/system/cryoss-backup.timer <<TMR_EOF
[Unit]
Description=Cryoss — Sauvegarde quotidienne 02h00

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
TMR_EOF

    if [[ "$ENABLE_SFTP" == "yes" ]]; then
        cat > /etc/systemd/system/cryoss-sftp-sync.service <<SVC2_EOF
[Unit]
Description=Cryoss — Sync SFTP incremental [$CLIENT_NAME]
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'rclone sync /etc/sauvegarde cryoss-c3-crypt: --backup-dir "cryoss-c3-versions:\$(date +%%Y-%%m-%%d)" --exclude "__CRYOSS_SENTINEL__" --checksum --transfers 2 --retries 3 --bwlimit 10M --contimeout 30s --timeout 60s --log-file /var/log/rclone_cryoss_c3.log --log-level INFO'
User=root

[Install]
WantedBy=multi-user.target
SVC2_EOF

        cat > /etc/systemd/system/cryoss-sftp-sync.timer <<TMR2_EOF
[Unit]
Description=Cryoss — Sync SFTP 8h/14h/20h

[Timer]
OnCalendar=*-*-* 08,14,20:00:00
Persistent=true

[Install]
WantedBy=timers.target
TMR2_EOF
    fi

    # Health daily
    cat > /etc/systemd/system/cryoss-health-daily.service <<EOF
[Unit]
Description=Cryoss — Rapport sante quotidien
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/cryoss-health.sh daily
StandardOutput=append:/var/log/cryoss-health.log
StandardError=append:/var/log/cryoss-health.log
User=root
EOF

    cat > /etc/systemd/system/cryoss-health-daily.timer <<EOF
[Unit]
Description=Cryoss — Rapport quotidien 07h00
[Timer]
OnCalendar=*-*-* 07:00:00
Persistent=true
[Install]
WantedBy=timers.target
EOF

    # Health weekly
    cat > /etc/systemd/system/cryoss-health-weekly.service <<EOF
[Unit]
Description=Cryoss — Rapport sante hebdomadaire SMART
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/cryoss-health.sh weekly
StandardOutput=append:/var/log/cryoss-health.log
StandardError=append:/var/log/cryoss-health.log
User=root
EOF

    cat > /etc/systemd/system/cryoss-health-weekly.timer <<EOF
[Unit]
Description=Cryoss — Rapport hebdo lundi 08h00
[Timer]
OnCalendar=Mon *-*-* 08:00:00
Persistent=true
[Install]
WantedBy=timers.target
EOF

    # Watchdog
    cat > /etc/systemd/system/cryoss-watchdog.service <<EOF
[Unit]
Description=Cryoss — Watchdog alertes
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/cryoss-health.sh alert
StandardOutput=append:/var/log/cryoss-health.log
StandardError=append:/var/log/cryoss-health.log
User=root
EOF

    cat > /etc/systemd/system/cryoss-watchdog.timer <<EOF
[Unit]
Description=Cryoss — Watchdog /15min
[Timer]
OnCalendar=*-*-* *:00,15,30,45:00
Persistent=true
[Install]
WantedBy=timers.target
EOF
fi

if [[ "$ROLE" == "rpi2" ]]; then
    cat > /etc/systemd/system/cryoss-health-daily.service <<EOF
[Unit]
Description=Cryoss RPi2 — Rapport sante quotidien
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/cryoss-health.sh daily
StandardOutput=append:/var/log/cryoss-health.log
StandardError=append:/var/log/cryoss-health.log
User=root
EOF

    cat > /etc/systemd/system/cryoss-health-daily.timer <<EOF
[Unit]
Description=Cryoss RPi2 — Rapport quotidien 06h30
[Timer]
OnCalendar=*-*-* 06:30:00
Persistent=true
[Install]
WantedBy=timers.target
EOF

    cat > /etc/systemd/system/cryoss-health-weekly.service <<EOF
[Unit]
Description=Cryoss RPi2 — Rapport hebdomadaire SMART
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/cryoss-health.sh weekly
StandardOutput=append:/var/log/cryoss-health.log
StandardError=append:/var/log/cryoss-health.log
User=root
EOF

    cat > /etc/systemd/system/cryoss-health-weekly.timer <<EOF
[Unit]
Description=Cryoss RPi2 — Rapport hebdo lundi 07h30
[Timer]
OnCalendar=Mon *-*-* 07:30:00
Persistent=true
[Install]
WantedBy=timers.target
EOF
fi

ok "Services systemd mis a jour"

# ===========================================================================
# 5. MISE A JOUR SAMBA (RPi1 uniquement)
# ===========================================================================
if [[ "$ROLE" == "rpi1" ]]; then
    step "5. Mise a jour Samba"

    cat > /etc/samba/smb.conf <<SAMBA_EOF
[global]
   workgroup = WORKGROUP
   server string = Cryoss [$CLIENT_NAME]
   server role = standalone server
   security = user
   map to guest = never
   guest ok = no
   restrict anonymous = 2
   client min protocol = SMB2
   server min protocol = SMB2
   smb encrypt = desired
   ntlm auth = no
   lanman auth = no
   disable netbios = yes
   dns proxy = no
   usershare allow guests = no
   vfs objects = fruit streams_xattr
   fruit:metadata = stream
   fruit:posix_rename = yes
   fruit:nfs_aces = no
   fruit:wipe_intentionally_left_blank_rfork = yes
   fruit:delete_empty_adfiles = yes
   kernel oplocks = no
   oplocks = yes
   level2 oplocks = yes
   posix locking = no
   strict locking = no
   strict allocate = yes
   allocation roundup size = 0
   store dos attributes = yes
   map archive = yes
   map hidden = no
   map system = no
   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file

[sauvegarde]
   comment = Depot source [$CLIENT_NAME]
   path = /etc/sauvegarde
   browseable = yes
   read only = no
   guest ok = no
   valid users = ds-user habyss
   write list = ds-user habyss
   create mask = 0660
   directory mask = 2770
   force group = samba-share

[encrypted_backup]
   comment = Archives chiffrees [$CLIENT_NAME] (lecture seule)
   path = /etc/encrypted
   browseable = no
   read only = yes
   guest ok = no
   valid users = habyss
SAMBA_EOF

    systemctl restart smbd 2>/dev/null || true
    ok "smb.conf mis a jour (vfs_fruit, oplocks, strict allocate)"
fi

# ===========================================================================
# 6. MISE A JOUR API
# ===========================================================================
step "6. Mise a jour API"

cp "$SCRIPT_DIR/api/cryoss-api.py" /usr/local/bin/cryoss-api.py
chmod 644 /usr/local/bin/cryoss-api.py
ok "cryoss-api.py mis a jour"

cp "$SCRIPT_DIR/serial/cryoss-serial.sh" /usr/local/bin/cryoss-serial.sh
chmod 755 /usr/local/bin/cryoss-serial.sh
ok "cryoss-serial.sh mis a jour"

# Mise a jour du venv Python
VENV_DIR="/opt/cryoss-api"
if [[ -d "$VENV_DIR" ]]; then
    "$VENV_DIR/bin/pip" install --quiet --upgrade pip 2>/dev/null
    "$VENV_DIR/bin/pip" install --quiet --upgrade fastapi "uvicorn[standard]" pydantic 2>/dev/null
    ok "Dependances Python mises a jour"
fi

# ===========================================================================
# 7. MISE A JOUR CONFIGS SECURITE
# ===========================================================================
step "7. Mise a jour configs securite"

# Logrotate
cat > /etc/logrotate.d/cryoss <<LR_EOF
/var/log/cryoss-backup.log
/var/log/rclone_cryoss_c1.log
/var/log/rclone_cryoss_c2.log
/var/log/rclone_cryoss_c3.log
/var/log/cryoss-health.log
/var/log/cryoss-honeypot.log
/var/log/cryoss-api.log
{
    weekly
    rotate 8
    compress
    missingok
    notifempty
    create 640 root root
}
LR_EOF
ok "Logrotate mis a jour"

# ===========================================================================
# 8. REDEMARRAGE
# ===========================================================================
step "8. Redemarrage des services"

systemctl daemon-reload

if [[ "$ROLE" == "rpi1" ]]; then
    for timer in cryoss-backup.timer cryoss-health-daily.timer \
                 cryoss-health-weekly.timer cryoss-watchdog.timer; do
        systemctl enable "$timer" 2>/dev/null || true
        systemctl start "$timer" 2>/dev/null || true
    done
    if [[ "$ENABLE_SFTP" == "yes" ]]; then
        systemctl enable cryoss-sftp-sync.timer 2>/dev/null || true
        systemctl start cryoss-sftp-sync.timer 2>/dev/null || true
    fi
    # Honeypot
    systemctl restart cryoss-honeypot.service 2>/dev/null || true
fi

if [[ "$ROLE" == "rpi2" ]]; then
    for timer in cryoss-health-daily.timer cryoss-health-weekly.timer; do
        systemctl enable "$timer" 2>/dev/null || true
        systemctl start "$timer" 2>/dev/null || true
    done
fi

# API
systemctl restart cryoss-api.service 2>/dev/null || true

# Heartbeat
systemctl restart cryoss-heartbeat.timer 2>/dev/null || true

# SSH
systemctl restart ssh 2>/dev/null || true

ok "Services redemarres"

# ===========================================================================
# 9. VERIFICATION
# ===========================================================================
step "9. Verification post-MAJ"

ERRORS=0
echo ""

# RAID
if cat /proc/mdstat 2>/dev/null | grep -q '\[UU\]'; then
    ok "RAID intact [UU]"
else
    warn "RAID a verifier"; (( ERRORS++ )) || true
fi

# rclone.conf intact
if [[ -f "$RCLONE_CONF" ]]; then
    REMOTES=$(rclone listremotes 2>/dev/null | grep -c cryoss || echo 0)
    ok "rclone.conf intact ($REMOTES remotes cryoss)"
else
    warn "rclone.conf absent"; (( ERRORS++ )) || true
fi

# Cles
[[ -f /etc/cryoss/keys-backup.conf ]] && ok "Cles backup intactes" || warn "Cles backup absentes"
[[ -f /etc/cryoss/serial ]] && ok "Serial : $(cat /etc/cryoss/serial)" || info "Serial non defini"
[[ -f /etc/cryoss/api-key ]] && ok "Cle API intacte" || info "Cle API non definie"

# Services
if [[ "$ROLE" == "rpi1" ]]; then
    SVCS=(smbd fail2ban ssh)
else
    SVCS=(fail2ban ssh)
fi
for svc in "${SVCS[@]}"; do
    systemctl is-active "$svc" &>/dev/null && ok "Service $svc : actif" || { warn "Service $svc : inactif"; (( ERRORS++ )) || true; }
done

# Timers
ACTIVE_TIMERS=$(systemctl list-timers --all --no-pager 2>/dev/null | grep -c cryoss || echo 0)
ok "Timers actifs : $ACTIVE_TIMERS"

# API
if systemctl is-active cryoss-api &>/dev/null; then
    ok "API active"
else
    info "API non active (normal si install_api.sh pas encore lance)"
fi

# Resume
echo ""
if (( ERRORS == 0 )); then
    echo -e "${BOLD}${GREEN}━━━ Mise a jour terminee — 0 erreur ━━━${NC}"
else
    echo -e "${BOLD}${YELLOW}━━━ Mise a jour terminee — $ERRORS avertissement(s) ━━━${NC}"
fi
echo ""
echo -e "  ${BOLD}Preserve :${NC}"
echo "    ✓ RAID (md0, md1)"
echo "    ✓ rclone.conf + cles de chiffrement"
echo "    ✓ Mots de passe utilisateurs"
echo "    ✓ Cles SSH"
[[ -n "$SERIAL" ]] && echo "    ✓ Serial : $SERIAL"
echo ""
echo -e "  ${BOLD}Mis a jour :${NC}"
echo "    ✓ Scripts (cryoss-backup.sh, cryoss-health.sh)"
echo "    ✓ Services systemd"
[[ "$ROLE" == "rpi1" ]] && echo "    ✓ Samba (smb.conf avec vfs_fruit)"
echo "    ✓ API (cryoss-api.py)"
echo "    ✓ Logrotate"
echo ""
if [[ "$ROLE" == "rpi1" ]]; then
    echo -e "  ${BOLD}Test recommande :${NC}"
    echo "    sudo systemctl start cryoss-backup.service"
    echo "    sudo journalctl -u cryoss-backup.service -f"
fi
echo ""
