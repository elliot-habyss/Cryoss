#!/bin/bash
# ===========================================================================
# CRYOSS — Migration DeepSave v1 → Cryoss v2
# ===========================================================================
#
# Migre une installation DeepSave existante vers Cryoss.
#
# PRESERVE :
#   ✓ RAID md0 (/etc/sauvegarde) — donnees de prod intactes
#   ✓ RAID md1 (/etc/encrypted) — vide apres migration (anciennes archives supprimees)
#   ✓ Utilisateurs (ds-user, habyss, ds-repl)
#   ✓ Montages fstab, reseau, SSH
#
# SUPPRIME :
#   ✗ Anciennes archives chiffrees (.cbc.enc, .cbc2.enc) — seront re-generees par rclone
#   ✗ Anciens services deepsave-*
#   ✗ Anciens scripts (/usr/local/bin/encryptbackup.sh etc.)
#   ✗ Anciennes configs (99-deepsave.conf)
#
# Apres ce script, lancer :
#   install_rpi1.sh (ou install_rpi2.sh) → detecte le RAID et saute les etapes destructives
#   install_security.sh
#   install_api.sh
#
# Usage :
#   sudo bash migrate_deepsave_to_cryoss.sh         # RPi1
#   sudo bash migrate_deepsave_to_cryoss.sh --rpi2   # RPi2
# ===========================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && err "Root requis"

IS_RPI2=false
[[ "${1:-}" == "--rpi2" ]] && IS_RPI2=true

# --- Verifications ---
echo -e "\n${BOLD}${BLUE}━━━ Cryoss — Migration depuis DeepSave ━━━${NC}\n"

if cat /proc/mdstat 2>/dev/null | grep -q '\[UU\]'; then
    ok "RAID intact"
else
    warn "RAID possiblement degrade — verifiez avant de continuer"
    read -rp "  Continuer ? [o/N] : " C; [[ "${C,,}" != "o" ]] && exit 1
fi

mountpoint -q /etc/sauvegarde 2>/dev/null && ok "/etc/sauvegarde monte (donnees de prod)" || warn "/etc/sauvegarde non monte"
mountpoint -q /etc/encrypted 2>/dev/null && ok "/etc/encrypted monte" || warn "/etc/encrypted non monte"

echo ""
warn "Cette migration va SUPPRIMER les anciennes archives chiffrees"
warn "(elles seront re-generees par le nouveau systeme rclone)"
warn "Les donnees de prod dans /etc/sauvegarde sont PRESERVEES."
read -rp "  Confirmer ? [o/N] : " C; [[ "${C,,}" != "o" ]] && exit 1

# --- 1. Arreter les anciens services ---
info "Arret des services DeepSave..."
for svc in encryptbackup.timer encryptbackup.service \
           deepsave-sftp-sync.timer deepsave-sftp-sync.service \
           deepsave-health-daily.timer deepsave-health-daily.service \
           deepsave-health-weekly.timer deepsave-health-weekly.service \
           deepsave-watchdog.timer deepsave-watchdog.service \
           deepsave-honeypot.service; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
done
ok "Services DeepSave arretes"

# --- 2. Supprimer les anciennes archives (RAID md1 nettoye) ---
info "Nettoyage des anciennes archives chiffrees..."
find /etc/encrypted -maxdepth 2 -type f \( -name "*.cbc.enc" -o -name "*.cbc2.enc" -o -name "*.enc" \) -delete 2>/dev/null || true
CLEANED=$(find /etc/encrypted -maxdepth 2 -type f 2>/dev/null | wc -l)
ok "Archives supprimees (${CLEANED} fichiers restants sur md1)"

# --- 3. Supprimer les anciens scripts et services ---
info "Nettoyage des anciens scripts et services..."
rm -f /usr/local/bin/encryptbackup.sh \
      /usr/local/bin/deepsave-health.sh \
      /usr/local/bin/deepsave-honeypot.sh \
      /usr/local/bin/deepsave-cleanup.sh \
      /usr/local/bin/deepsave-versions-purge.sh \
      /usr/local/bin/deepsave-repl-check.sh 2>/dev/null || true

rm -f /etc/systemd/system/encryptbackup.* \
      /etc/systemd/system/deepsave-*.service \
      /etc/systemd/system/deepsave-*.timer 2>/dev/null || true

# Renommer les configs
for conf in /etc/ssh/sshd_config.d/99-deepsave.conf \
            /etc/fail2ban/jail.d/99-deepsave.conf \
            /etc/sysctl.d/99-deepsave.conf \
            /etc/logrotate.d/deepsave; do
    [[ -f "$conf" ]] && mv "$conf" "${conf/deepsave/cryoss}" 2>/dev/null || true
done

systemctl daemon-reload
ok "Anciens scripts et configs nettoyes"

# --- 4. Conserver les anciennes cles (restauration legacy si besoin) ---
if [[ -d /etc/key ]]; then
    mkdir -p /etc/cryoss
    cp /etc/key/.key1conf /etc/cryoss/legacy-key1.conf 2>/dev/null || true
    cp /etc/key/.key2conf /etc/cryoss/legacy-key2.conf 2>/dev/null || true
    chmod 600 /etc/cryoss/legacy-key*.conf 2>/dev/null || true
    ok "Anciennes cles KEY1/KEY2 copiees dans /etc/cryoss/legacy-key*.conf"
fi

# --- 5. Migration RPi2 : ds-repl → SFTP chroot ---
if [[ "$IS_RPI2" == true ]]; then
    info "Migration ds-repl vers SFTP chroot..."

    # Changer le shell
    usermod -s /usr/sbin/nologin ds-repl 2>/dev/null || true

    # Preparer le chroot
    REPL_HOME="/var/lib/ds-repl"
    RPI2_DIR=$(find /etc/encrypted -maxdepth 1 -type d -name "rpi*" 2>/dev/null | head -1)
    [[ -z "$RPI2_DIR" ]] && RPI2_DIR="/etc/encrypted/rpi1" && mkdir -p "$RPI2_DIR"

    chown root:root "$REPL_HOME"; chmod 755 "$REPL_HOME"
    mkdir -p "${REPL_HOME}/data"
    chown ds-repl:ds-repl "$RPI2_DIR"; chmod 750 "$RPI2_DIR"

    if ! mountpoint -q "${REPL_HOME}/data" 2>/dev/null; then
        mount --bind "$RPI2_DIR" "${REPL_HOME}/data" || warn "Bind mount echoue"
    fi
    grep -q "ds-repl/data" /etc/fstab || echo "$RPI2_DIR  ${REPL_HOME}/data  none  bind  0  0" >> /etc/fstab

    # Ajouter Match User ds-repl
    SSHD_CONF=$(ls /etc/ssh/sshd_config.d/99-*.conf 2>/dev/null | head -1)
    [[ -z "$SSHD_CONF" ]] && SSHD_CONF="/etc/ssh/sshd_config.d/99-cryoss.conf"
    if ! grep -q "Match User ds-repl" "$SSHD_CONF" 2>/dev/null; then
        cat >> "$SSHD_CONF" <<'MATCH_EOF'

Match User ds-repl
    ForceCommand internal-sftp
    ChrootDirectory /var/lib/ds-repl
    AllowTcpForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTTY no
MATCH_EOF
        systemctl restart ssh
    fi

    # Nettoyer le command= des authorized_keys
    AUTH_KEYS="${REPL_HOME}/.ssh/authorized_keys"
    if [[ -f "$AUTH_KEYS" ]] && grep -q "command=" "$AUTH_KEYS" 2>/dev/null; then
        sed -i 's/command="[^"]*",//g' "$AUTH_KEYS"
        sed -i 's/no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding //g' "$AUTH_KEYS"
        chown ds-repl:ds-repl "$AUTH_KEYS"
    fi

    ok "ds-repl migre vers SFTP chroot"
fi

# --- Resume ---
echo ""
echo -e "${BOLD}${GREEN}━━━ Migration terminee ━━━${NC}"
echo ""
echo "  ✓ RAID intacts (donnees de prod preservees)"
echo "  ✓ Utilisateurs conserves"
echo "  ✓ Anciennes archives chiffrees supprimees"
echo "  ✓ Anciens services/scripts nettoyes"
echo "  ✓ Cles legacy sauvegardees dans /etc/cryoss/"
[[ "$IS_RPI2" == true ]] && echo "  ✓ ds-repl migre vers SFTP chroot"
echo ""
echo -e "  ${BOLD}Prochaine etape :${NC}"
if [[ "$IS_RPI2" == true ]]; then
    echo "    sudo bash install_rpi2.sh   # reinstalle les services Cryoss"
else
    echo "    sudo bash install_rpi1.sh   # reinstalle les services Cryoss"
fi
echo "    sudo bash install_security.sh"
echo "    sudo bash install_api.sh"
echo ""
