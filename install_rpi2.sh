#!/bin/bash
# =============================================================================
#  CRYOSS - Script d'installation RPi2 (Secondaire / Réplication)
#  - Reçoit les sauvegardes AES-256-CBC/KEY2 de RPi1 via SSH dédié
#  - RAID 1 unique (2 disques) -> /etc/encrypted
#  - RPi2 n'est connecté au LAN QUE pendant l'installation
#    En production : réseau interco uniquement (10.42.0.0/30)
#  - Monitoring email via RPi1 comme relais SMTP
#  - Accès admin : SSH depuis RPi1 (10.42.0.1) uniquement
#  Usage : sudo bash install_rpi2.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "${GREEN}[v]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }
step() { echo -e "\n${BOLD}${BLUE}--- $1 ---${NC}"; }

[[ $EUID -ne 0 ]] && err "Executer en root : sudo bash $0"

# =============================================================================
#  COLLECTE
# =============================================================================
echo -e "${BOLD}"
echo "============================================================"
echo "  CRYOSS RPi2 - Installation (Secondaire)"
echo "  Reception chiffree AES-256-CBC/KEY2 depuis RPi1 via SSH"
echo "============================================================"
echo -e "${NC}"

step "Identification"
read -rp "  Nom du client : " CLIENT_NAME

step "Réseau RPi2 — interface LAN temporaire (installation uniquement)"
warn "RPi2 sera HORS LAN en production."
warn "Cette interface n'est utilisée que pour installer les paquets."
warn "Après installation, débranchez le câble LAN — RPi2 tourne en réseau interco uniquement."
echo ""
echo "  Interfaces :"; ip -o link show | awk -F': ' '{print "   "$2}' | grep -v lo; echo
read -rp "  Interface LAN temporaire (ex: eth0) : " NET_IFACE
# IP LAN temporaire : on utilise le DHCP existant si disponible, sinon fixe
DHCP_IP=$(ip -4 addr show "$NET_IFACE" 2>/dev/null | grep -oP '(?<=inet )[\d.]+' | head -1 || true)
if [[ -n "$DHCP_IP" ]]; then
    info "IP DHCP détectée sur $NET_IFACE : $DHCP_IP — utilisée pour l'installation"
    NET_IP="$DHCP_IP"
    NET_CIDR=$(ip -4 addr show "$NET_IFACE" 2>/dev/null | grep -oP '(?<=inet )[\d.]+/\d+' | grep -oP '\d+$' | head -1 || echo "24")
    NET_GW=$(ip route show dev "$NET_IFACE" 2>/dev/null | grep default | awk '{print $3}' | head -1 || echo "")
    NET_DNS1="1.1.1.1"; NET_DNS2="8.8.8.8"
else
    warn "Aucune IP DHCP détectée — configuration manuelle"
    read -rp "  IP fixe temporaire (ex: 192.168.1.51) : " NET_IP
    read -rp "  CIDR               (ex: 24)           : " NET_CIDR
    read -rp "  Passerelle         (ex: 192.168.1.1)  : " NET_GW
    NET_DNS1="1.1.1.1"; NET_DNS2="8.8.8.8"
fi

step "Réseau inter-RPi — interface câble direct vers RPi1"
echo "  Le câble Ethernet direct RPi1(eth1-USB) ↔ RPi2 utilise un réseau dédié :"
echo "    RPi1 : 10.42.0.1/30   RPi2 : 10.42.0.2/30  (identiques dans install_rpi1.sh)"
echo ""
ip -o link show | awk -F': ' '{print "    " $2}' | grep -v lo
echo
read -rp "  Interface câble direct vers RPi1 (ex: eth0 ou eth1) : " INTERCO_IFACE

# IPs inter-RPi fixes — identiques dans install_rpi1.sh
INTERCO_IP_RPI1="10.42.0.1"
INTERCO_IP_RPI2="10.42.0.2"
INTERCO_CIDR="30"
INTERCO_CON="cryoss-interco"
RPI1_IP="${INTERCO_IP_RPI1}"

read -rp "  Répertoire de réception ici (ex: /etc/encrypted/rpi1) : " RPI2_DIR

step "RAID 1 (2 disques)"
echo "  Disques :"; lsblk -d -o NAME,SIZE,MODEL 2>/dev/null | grep -v "^NAME\|mmcblk\|nvme" || true; echo
read -rp "  Disque 1 (ex: sda) : " DISK1
read -rp "  Disque 2 (ex: sdb) : " DISK2
DISK1="/dev/${DISK1##/dev/}"; DISK2="/dev/${DISK2##/dev/}"

step "Utilisateurs"
HABYSS_PASS=$(openssl rand -base64 16)
REPL_PASS=$(openssl rand -base64 16)
warn "Mots de passe generés :"
echo -e "  ${BOLD}ds-repl${NC}  : ${BOLD}${REPL_PASS}${NC}  (reception SFTP-only depuis RPi1 (rclone crypt))"
echo -e "  ${BOLD}habyss${NC}   : ${BOLD}${HABYSS_PASS}${NC}  (admin local, SSH via RPi1)"
read -rp "  Notez-les puis Entree..."

echo -e "\n${BOLD}=== Récapitulatif RPi2 ===${NC}"
echo "  Client        : $CLIENT_NAME"
echo "  LAN temporaire: ${NET_IP}/${NET_CIDR} sur $NET_IFACE (installation seulement)"
echo "  Inter-RPi     : ${INTERCO_IP_RPI2}/${INTERCO_CIDR} sur $INTERCO_IFACE (production)"
echo "  RAID          : md0($DISK1+$DISK2) -> /etc/encrypted"
echo "  Réplication   : RPi1 --rclone SFTP crypt--> ds-repl@${INTERCO_IP_RPI2} -> $RPI2_DIR"
echo "  Admin SSH     : depuis RPi1 (10.42.0.1) uniquement"
echo "  Monitoring    : email via RPi1 comme relais SMTP"
warn "En production : le câble LAN sera débranché — uniquement lien interco actif"
echo
read -rp "Confirmer ? [o/N] : " CONFIRM
[[ "${CONFIRM,,}" != "o" ]] && err "Annule."

# =============================================================================
#  INSTALLATION
# =============================================================================

step "1. Paquets"
# TOUS les paquets ici — avant UFW, tant que le LAN est accessible
apt-get update -qq
apt-get install -y openssl mdadm ufw fail2ban \
    smartmontools msmtp msmtp-mta attr 2>/dev/null
ok "Paquets installés"

# =============================================================================
step "2. Interface LAN temporaire (apt uniquement)"
# Vérifier que l'interface LAN est active pour les téléchargements
if ! ip addr show "$NET_IFACE" 2>/dev/null | grep -q "inet "; then
    if ! systemctl is-active --quiet NetworkManager 2>/dev/null; then
        apt-get install -y network-manager &>/dev/null
        systemctl enable NetworkManager; systemctl start NetworkManager; sleep 3
    fi
    NM_LAN_TEMP="cryoss-lan-temp"
    nmcli connection delete "$NM_LAN_TEMP" 2>/dev/null || true
    if [[ -n "${NET_GW:-}" ]]; then
        nmcli connection add type ethernet ifname "$NET_IFACE" con-name "$NM_LAN_TEMP" \
            ipv4.method manual \
            ipv4.addresses "${NET_IP}/${NET_CIDR}" \
            ipv4.gateway "$NET_GW" \
            ipv4.dns "${NET_DNS1:-1.1.1.1} ${NET_DNS2:-8.8.8.8}" \
            ipv6.method disabled \
            connection.autoconnect no
        nmcli connection up "$NM_LAN_TEMP"
    fi
    ok "Interface LAN temporaire activée"
else
    ok "Interface LAN déjà active (DHCP)"
fi

# Interface interco — réseau de production permanent
nmcli connection delete "$INTERCO_CON" 2>/dev/null || true
nmcli connection add type ethernet ifname "$INTERCO_IFACE" con-name "$INTERCO_CON" \
    ipv4.method manual \
    ipv4.addresses "${INTERCO_IP_RPI2}/${INTERCO_CIDR}" \
    ipv4.gateway "" \
    ipv4.dns "" \
    ipv6.method disabled \
    connection.autoconnect yes
nmcli connection up "$INTERCO_CON" 2>/dev/null || true
ok "IP inter-RPi : ${INTERCO_IP_RPI2}/${INTERCO_CIDR} sur $INTERCO_IFACE (réseau de production)"
info "RPi1 utilisera ${INTERCO_IP_RPI1} sur eth1 USB"
step "3. RAID 1 (md0 - 2 disques)"

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

[ -b /dev/md0 ] && { umount -f /dev/md0 2>/dev/null || true; mdadm --stop /dev/md0 2>/dev/null || true; }
nuke_disk "$DISK1"; nuke_disk "$DISK2"
sleep 2; partprobe "$DISK1" "$DISK2" 2>/dev/null || true; sleep 2

info "Creation /dev/md0 ($DISK1 + $DISK2)..."
mdadm --create /dev/md0 --level=1 --raid-devices=2 --bitmap=internal --run --force \
    "$DISK1" "$DISK2" <<< "yes"
ok "/dev/md0 cree"

sleep 10; cat /proc/mdstat
mkfs.ext4 -F -q /dev/md0
ok "md0 formate ext4"

# =============================================================================
step "4. Repertoires et montage"

mkdir -p /etc/encrypted
mount /dev/md0 /etc/encrypted && ok "md0 -> /etc/encrypted" || warn "deja monte"

# Creer le sous-repertoire de reception si different de /etc/encrypted
[[ "$RPI2_DIR" != "/etc/encrypted" ]] && mkdir -p "$RPI2_DIR"

mdadm --detail --scan >> /etc/mdadm/mdadm.conf
update-initramfs -u -k all &>/dev/null
ok "Config mdadm persistee"

UUID_MD0=$(blkid -s UUID -o value /dev/md0)
sed -i '/\/etc\/encrypted/d' /etc/fstab
echo "UUID=$UUID_MD0   /etc/encrypted   ext4   defaults,nodev,nosuid   0   2" >> /etc/fstab
ok "fstab mis a jour"

# =============================================================================
step "5. Utilisateurs et permissions"

# Pas de ds-user ni samba-share : Samba non installé (RPi2 hors LAN)

# ds-repl : reception SFTP depuis RPi1 (rclone crypt)
# Utilise /usr/sbin/nologin comme shell — l'acces est SFTP-only via
# Match User dans sshd_config (ForceCommand internal-sftp).
# Plus besoin de command= ni de cryoss-repl-check.sh.
REPL_HOME="/var/lib/ds-repl"
if id ds-repl &>/dev/null; then
    warn "ds-repl existe — mise a jour"
    usermod -s /usr/sbin/nologin -d "$REPL_HOME" ds-repl
else
    useradd -r -s /usr/sbin/nologin -d "$REPL_HOME" -M ds-repl
fi
echo "ds-repl:${REPL_PASS}" | chpasswd
mkdir -p "${REPL_HOME}/.ssh"
chmod 700 "$REPL_HOME" "${REPL_HOME}/.ssh"
touch "${REPL_HOME}/.ssh/authorized_keys"
chmod 600 "${REPL_HOME}/.ssh/authorized_keys"
chown -R ds-repl:ds-repl "$REPL_HOME"
ok "ds-repl cree (SFTP-only, nologin, home $REPL_HOME)"

# ds-user supprimé — pas de Samba sur RPi2 (hors LAN en production)

# habyss : admin local (accès SSH via RPi1 uniquement en production)
if id habyss &>/dev/null; then
    usermod -aG sudo habyss
else
    useradd -m -s /bin/bash -G sudo habyss
fi
echo "habyss:${HABYSS_PASS}" | chpasswd
ok "habyss configuré (admin local, SSH via RPi1 uniquement)"

# Permissions
# Note : /etc/encrypted doit être en 751 (et non 750) pour que ds-repl
# puisse traverser vers /etc/encrypted/rpi1 (dont il est owner)
chown root:root /etc/encrypted
chmod 751 /etc/encrypted
chown ds-repl:ds-repl "$RPI2_DIR"
chmod 750 "$RPI2_DIR"
ok "Permissions OK (encrypted:751, rpi1:750 ds-repl)"

# =============================================================================
step "6. Acces SFTP-only pour ds-repl (rclone depuis RPi1)"

# ds-repl est confine en SFTP-only via Match User dans sshd_config.
# rclone sftp depuis RPi1 utilise le subsystem SFTP (pas de shell).
# Plus besoin de cryoss-repl-check.sh — la securite est assuree par :
#   1. ForceCommand internal-sftp (aucune commande shell possible)
#   2. ChrootDirectory $REPL_HOME (confine dans son home)
#   3. Cle SSH-only (pas de mot de passe)
#   4. AllowTcpForwarding no, X11 no, etc.

warn "Collez la cle publique RPi1 (/root/.ssh/cryoss_rpi2.pub)"
warn "ou laissez vide pour l'ajouter manuellement plus tard :"
read -rp "  Cle publique RPi1 (ssh-ed25519 ...) : " RPI1_PUBKEY

if [[ -n "$RPI1_PUBKEY" ]]; then
    echo "$RPI1_PUBKEY" >> "${REPL_HOME}/.ssh/authorized_keys"
    chown ds-repl:ds-repl "${REPL_HOME}/.ssh/authorized_keys"
    ok "Cle RPi1 ajoutee pour ds-repl (SFTP-only)"
else
    warn "A faire manuellement : echo 'ssh-ed25519 AAAA...' >> ${REPL_HOME}/.ssh/authorized_keys"
fi

# Le chroot SFTP requiert que $REPL_HOME soit propriete de root
# et que le sous-dossier data/ soit proprietaire ds-repl
chown root:root "$REPL_HOME"
chmod 755 "$REPL_HOME"
# Creer un sous-dossier pour les donnees (ds-repl peut ecrire ici)
mkdir -p "${REPL_HOME}/data"
# [Q2] Bind mount OBLIGATOIRE — les symlinks ne fonctionnent PAS dans un ChrootDirectory
if mountpoint -q "${REPL_HOME}/data" 2>/dev/null; then
    info "Bind mount deja actif"
elif [[ -d "$RPI2_DIR" ]]; then
    mount --bind "$RPI2_DIR" "${REPL_HOME}/data" \
        || err "Bind mount echoue — ChrootDirectory SFTP ne fonctionnera pas sans"
fi
chown ds-repl:ds-repl "$RPI2_DIR"
chmod 750 "$RPI2_DIR"

# Ajouter le bind mount dans fstab pour persistance
if ! grep -q "ds-repl/data" /etc/fstab 2>/dev/null; then
    echo "$RPI2_DIR  ${REPL_HOME}/data  none  bind  0  0" >> /etc/fstab
fi

ok "SFTP chroot configure pour ds-repl"

# =============================================================================
step "7. Samba"

# =============================================================================
step "8. Désactivation Samba (RPi2 air-gapped)"

# Samba n'est pas utilisé sur RPi2 : pas de LAN client accessible
# Si smbd est présent (dépendance OS), on le désactive complètement
systemctl disable --now smbd nmbd winbind 2>/dev/null || true
systemctl mask smbd nmbd 2>/dev/null || true
ok "Samba désactivé et masqué (RPi2 n'est pas accessible depuis le LAN)"
info "Les archives chiffrees (rclone crypt) sont accessibles depuis RPi1 via : ssh cryoss-rpi2 'ls /etc/encrypted/'"

# =============================================================================
step "8. Durcissement systeme"

# SSH — habyss pour admin, ds-repl confine en SFTP-only
cat > /etc/ssh/sshd_config.d/99-cryoss.conf <<SSH_EOF
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers habyss ds-repl
Banner /etc/ssh/banner

# ds-repl : confine en SFTP-only (chroot dans son home)
# rclone sftp utilise le subsystem SFTP — pas besoin de shell.
# Securite : aucune commande shell, aucun forwarding, chroot strict.
Match User ds-repl
    ForceCommand internal-sftp
    ChrootDirectory /var/lib/ds-repl
    AllowTcpForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTTY no
SSH_EOF
echo "[ Cryoss RPi2 | $CLIENT_NAME — accès SSH via RPi1(10.42.0.1) uniquement ]" > /etc/ssh/banner
systemctl restart ssh
ok "SSH durci (AllowUsers: habyss + ds-repl)"

# UFW — RPi2 hors LAN en production : une seule règle SSH depuis RPi1
ufw --force reset
ufw default deny incoming; ufw default allow outgoing
# Seule règle permanente : SSH depuis RPi1 via lien interco dédié
ufw allow from "$INTERCO_IP_RPI1" to any port 22 comment "Cryoss SSH RPi1 interco"
# [A4] Regle LAN temporaire avec suppression automatique apres 2h
# Un timer systemd supprime la regle — l'operateur n'a pas besoin de se rappeler
LAN_SUBNET="${NET_IP%.*}.0/24"
ufw allow from "$LAN_SUBNET" to any port 22 comment "TEMP-install SSH LAN"
ufw --force enable
ok "UFW : SSH RPi1 interco + SSH LAN temporaire ($LAN_SUBNET)"

# Timer systemd one-shot : supprime la regle LAN apres 2h
cat > /etc/systemd/system/cryoss-ufw-cleanup.service <<UFW_SVC
[Unit]
Description=Cryoss — Suppression automatique regle UFW LAN temporaire
[Service]
Type=oneshot
ExecStart=/usr/sbin/ufw delete allow from ${LAN_SUBNET} to any port 22
UFW_SVC

cat > /etc/systemd/system/cryoss-ufw-cleanup.timer <<UFW_TMR
[Unit]
Description=Cryoss — Suppression regle UFW LAN dans 2h
[Timer]
OnActiveSec=2h
Unit=cryoss-ufw-cleanup.service
[Install]
WantedBy=timers.target
UFW_TMR

systemctl daemon-reload
systemctl enable --now cryoss-ufw-cleanup.timer
ok "Regle UFW LAN sera auto-supprimee dans 2h (cryoss-ufw-cleanup.timer)"

# Fail2Ban
cat > /etc/fail2ban/jail.d/99-cryoss.conf <<F2B_EOF
[sshd]
enabled=true
port=ssh
maxretry=5
bantime=3600
findtime=600
F2B_EOF
systemctl enable fail2ban; systemctl restart fail2ban
ok "Fail2Ban configure"

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

cat > /etc/logrotate.d/cryoss-rpi2 <<LR_EOF
# Pas de log Samba (désactivé sur RPi2)
LR_EOF
ok "Logrotate configure"

# =============================================================================
step "9. Monitoring et sante (cryoss-health)"

# smartmontools + msmtp déjà installés en step 1

# RPi2 hors LAN : les emails transitent par RPi1 comme relais SMTP local
# RPi1 expose un relais msmtp sur 10.42.0.1:25 (configuré dans install_rpi1.sh)
info "RPi2 est hors LAN — les emails de monitoring transitent via RPi1 (10.42.0.1)"
info "RPi1 agit comme relais SMTP local sur le lien interco."
read -rp "  Email destinataire pour les alertes RPi2 : " R2_EMAIL_TO
R2_SMTP_HOST="${INTERCO_IP_RPI1}"
R2_SMTP_PORT="25"

cat > /etc/msmtprc <<MSMTP_EOF
defaults
auth           off
tls            off
logfile        /var/log/msmtp.log

account        relais-rpi1
host           ${INTERCO_IP_RPI1}
port           25
from           cryoss-rpi2@localhost

account default : relais-rpi1
MSMTP_EOF
chmod 600 /etc/msmtprc; chown root:root /etc/msmtprc
ok "msmtp configuré — relais via RPi1 (${INTERCO_IP_RPI1}:25)"
warn "RPi1 doit avoir le relais SMTP activé (install_rpi1.sh configure postfix/msmtp-relay)"

cat > /usr/local/bin/cryoss-health.sh << 'HEALTH_EOF'
#!/bin/bash
# CRYOSS - Monitoring sante RPi2
set -euo pipefail

EMAIL_TO="DS_EMAIL_TO"
CLIENT_NAME="DS_CLIENT_NAME"
RPI1_IP="DS_RPI1_IP"
RPI2_DIR="DS_RPI2_DIR"
LOG="/var/log/cryoss-health.log"
MODE="${1:-daily}"
HOSTNAME_SHORT=$(hostname -s)
DATE_LABEL=$(date '+%d/%m/%Y %H:%M')
ANOMALIES=()
REPORT=""

log()       { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }
section()   { REPORT="${REPORT}\n$(printf '=%.0s' {1..50})\n  $1\n$(printf '=%.0s' {1..50})\n"; }
line()      { REPORT="${REPORT}$1\n"; }
alert()     { ANOMALIES+=("$1"); log "ANOMALIE: $1"; }
ok_line()   { line "  [OK]  $1"; }
warn_line() { line "  [!!]  $1"; alert "$1"; }
info_line() { line "  [--]  $1"; }

send_mail() {
    local subject="$1" body="$2"
    { echo "To: $EMAIL_TO"; echo "Subject: $subject"; echo ""; echo -e "$body"; } \
        | msmtp "$EMAIL_TO" 2>/dev/null || log "WARN: email non envoye"
}

check_raid() {
    section "ETAT RAID (mdadm)"
    if [ -b "/dev/md0" ]; then
        local detail state active failed
        detail=$(mdadm --detail /dev/md0 2>/dev/null || echo "ERREUR")
        state=$(echo "$detail" | grep "State :" | awk -F': ' '{print $2}' | xargs)
        active=$(echo "$detail" | grep "Active Devices" | awk -F': ' '{print $2}' | xargs)
        failed=$(echo "$detail" | grep "Failed Devices" | awk -F': ' '{print $2}' | xargs)
        if [[ "$state" == "clean" || "$state" == "active" ]]; then
            ok_line "/dev/md0 : etat=$state | actifs=$active | echecs=$failed"
        else
            warn_line "/dev/md0 ANOMALIE : etat=$state | actifs=$active | echecs=$failed"
        fi
        local resync; resync=$(grep -A2 "^md0" /proc/mdstat 2>/dev/null | grep "resync\|recovery" || true)
        [[ -n "$resync" ]] && info_line "  Reconstruction : $resync"
        if [[ "$MODE" == "weekly" ]]; then
            info_line "=== /proc/mdstat ==="; while IFS= read -r l; do info_line "  $l"; done < /proc/mdstat
            while IFS= read -r dl; do info_line "  $dl"; done < <(echo "$detail" | grep "/dev/sd" || true)
        fi
    else
        warn_line "/dev/md0 : introuvable"
    fi
}

check_smart() {
    section "SANTE DISQUES (SMART)"
    if ! command -v smartctl &>/dev/null; then warn_line "smartmontools non installe"; return; fi
    for DISK in /dev/sd[a-z]; do
        [ -b "$DISK" ] || continue
        local smart_out health reallocated pending uncorrectable temp
        smart_out=$(smartctl -H -A "$DISK" 2>/dev/null || true)
        health=$(echo "$smart_out" | grep "overall-health" | awk '{print $NF}' || echo "N/A")
        reallocated=$(echo "$smart_out" | grep "Reallocated_Sector" | awk '{print $10}' || echo "0")
        pending=$(echo "$smart_out" | grep "Current_Pending_Sector" | awk '{print $10}' || echo "0")
        uncorrectable=$(echo "$smart_out" | grep "Offline_Uncorrectable" | awk '{print $10}' || echo "0")
        temp=$(echo "$smart_out" | grep "Temperature_Celsius\|Airflow_Temperature" | head -1 | awk '{print $10}' || echo "N/A")
        [[ "$health" == "PASSED" ]] \
            && ok_line "$DISK : SMART=$health | Temp=${temp}C | Realloues=$reallocated | Pending=$pending" \
            || warn_line "$DISK : SMART=$health | Temp=${temp}C | Realloues=$reallocated | Pending=$pending"
        [[ "${reallocated:-0}" -gt 0 ]] 2>/dev/null && warn_line "$DISK : $reallocated secteurs realoues !"
        [[ "${pending:-0}" -gt 0 ]] 2>/dev/null && warn_line "$DISK : $pending secteurs en attente !"
        [[ "${uncorrectable:-0}" -gt 0 ]] 2>/dev/null && warn_line "$DISK : $uncorrectable secteurs non corrigibles !"
        if [[ "$MODE" == "weekly" ]]; then
            info_line "=== SMART $DISK ==="
            while IFS= read -r a; do info_line "  $a"; done < <(echo "$smart_out" | grep -E "^\s+[0-9]+" || true)
        fi
    done
}

check_disk_space() {
    section "ESPACE DISQUE"
    while IFS= read -r fs_line; do
        local use_pct; use_pct=$(echo "$fs_line" | awk '{print $5}' | tr -d '%')
        if [[ "$use_pct" -ge 90 ]]; then warn_line "$fs_line  <-- CRITIQUE"
        elif [[ "$use_pct" -ge 75 ]]; then warn_line "$fs_line  <-- ATTENTION"
        else ok_line "$fs_line"; fi
    done < <(df -h | grep -E "^/dev/(md|sd)" || true)
    info_line "Taille /etc/encrypted : $(du -sh /etc/encrypted 2>/dev/null | awk '{print $1}')"
}

check_system() {
    section "SYSTEME (CPU / RAM / TEMPERATURE)"
    local load1 load5 load15; read -r load1 load5 load15 _ < /proc/loadavg
    local cores; cores=$(nproc)
    info_line "Load : ${load1} / ${load5} / ${load15}  (${cores} coeurs)"
    [[ $(echo "$load1" | cut -d. -f1) -ge "$cores" ]] && warn_line "Charge CPU elevee : ${load1}"
    local mt ma mu mp
    mt=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    ma=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    mu=$(( mt - ma )); mp=$(( mu * 100 / mt ))
    info_line "RAM : $(( mu/1024 )) Mo / $(( mt/1024 )) Mo (${mp}%)"
    [[ "$mp" -ge 90 ]] && warn_line "RAM critique : ${mp}%"
    if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
        local tc; tc=$(( $(cat /sys/class/thermal/thermal_zone0/temp) / 1000 ))
        if [[ "$tc" -ge 80 ]]; then warn_line "Temperature : ${tc}C CRITIQUE"
        elif [[ "$tc" -ge 70 ]]; then warn_line "Temperature : ${tc}C ATTENTION"
        else ok_line "Temperature : ${tc}C"; fi
    fi
    info_line "Uptime : $(( $(cat /proc/uptime | awk '{print int($1)}') / 3600 ))h"
    if [[ "$MODE" == "weekly" ]]; then
        info_line "Top 5 processus CPU :"
        while IFS= read -r p; do info_line "  $p"; done \
            < <(ps aux --sort=-%cpu | head -6 | tail -5 | awk '{printf "%-20s %5s%% CPU  %5s%% MEM\n",$11,$3,$4}')
    fi
}

check_services() {
    section "SERVICES SYSTEMD"
    for SVC in ssh fail2ban ufw; do
        systemctl is-active --quiet "$SVC" 2>/dev/null \
            && ok_line "$SVC : actif" \
            || { systemctl is-enabled --quiet "$SVC" 2>/dev/null \
                && warn_line "$SVC : INACTIF alors qu'active" \
                || warn_line "$SVC : non active"; }
    done
}

check_fail2ban() {
    section "SECURITE / FAIL2BAN"
    if command -v fail2ban-client &>/dev/null && systemctl is-active --quiet fail2ban; then
        local jails; jails=$(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://;s/,//g' | xargs)
        for JAIL in $jails; do
            local banned total
            banned=$(fail2ban-client status "$JAIL" 2>/dev/null | grep "Currently banned" | awk '{print $NF}')
            total=$(fail2ban-client status "$JAIL" 2>/dev/null | grep "Total banned" | awk '{print $NF}')
            if [[ "${banned:-0}" -gt 0 ]]; then
                warn_line "Jail $JAIL : $banned IP(s) bannies / $total total"
                local ips; ips=$(fail2ban-client status "$JAIL" 2>/dev/null | grep "Banned IP" | sed 's/.*Banned IP list://' | xargs)
                [[ -n "$ips" ]] && info_line "  IPs : $ips"
            else
                ok_line "Jail $JAIL : aucun ban actif (total: ${total:-0})"
            fi
        done
    else
        warn_line "Fail2Ban non disponible"
    fi
    local fails; fails=$(journalctl -u ssh --since "24 hours ago" 2>/dev/null | grep -c "Failed password\|Invalid user" || echo "0")
    [[ "$fails" -gt 10 ]] && warn_line "SSH : $fails tentatives (24h) -- suspect" || ok_line "SSH : $fails tentatives echouees (24h)"
    if [[ "$MODE" == "weekly" ]]; then
        info_line "Top IPs attaquantes (7j) :"
        while IFS= read -r il; do info_line "  $il"; done \
            < <(journalctl -u ssh --since "7 days ago" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort | uniq -c | sort -rn | head -10 || true)
    fi
}

check_reception() {
    section "RECEPTION DEPUIS RPi1 ($RPI1_IP)"
    local files_today; files_today=$(find "$RPI2_DIR" -name "*" -mtime -1 2>/dev/null | wc -l)
    info_line "Fichiers recus aujourd'hui : $files_today"
    local last_file; last_file=$(ls -t "$RPI2_DIR"/* 2>/dev/null | head -1 || echo "")
    if [[ -n "$last_file" ]]; then
        local last_ep; last_ep=$(stat -c '%Y' "$last_file" 2>/dev/null || echo "0")
        local h_since=$(( ($(date +%s) - last_ep) / 3600 ))
        info_line "Dernier fichier : $(basename "$last_file")"
        if [[ "$h_since" -gt 25 ]]; then warn_line "Derniere reception : il y a ${h_since}h -- RPi1 muet ?"
        else ok_line "Derniere reception : il y a ${h_since}h"; fi
    else
        warn_line "Aucun fichier chiffre dans $RPI2_DIR"
    fi
    info_line "Volume total : $(du -sh "$RPI2_DIR" 2>/dev/null | awk '{print $1}')"
    if [[ "$MODE" == "weekly" ]]; then
        local wk; wk=$(find "$RPI2_DIR" -name "*" -mtime -7 2>/dev/null | wc -l)
        info_line "Fichiers recus 7j : $wk"
    fi
}

build_report() {
    local lbl; [[ "$MODE" == "weekly" ]] && lbl="HEBDOMADAIRE COMPLET" || lbl="QUOTIDIEN"
    REPORT="CRYOSS [$CLIENT_NAME] - RPi2 - Rapport $lbl\nHote : $HOSTNAME_SHORT | $DATE_LABEL\n$(printf '=%.0s' {1..60})\n"
    check_raid; check_smart; check_disk_space; check_system
    check_services; check_fail2ban; check_reception
    REPORT="${REPORT}\n$(printf '=%.0s' {1..60})\n"
    if [[ ${#ANOMALIES[@]} -eq 0 ]]; then REPORT="${REPORT}  BILAN : TOUT EST SAIN\n"
    else
        REPORT="${REPORT}  BILAN : ${#ANOMALIES[@]} ANOMALIE(S)\n"
        for A in "${ANOMALIES[@]}"; do REPORT="${REPORT}  >> $A\n"; done
    fi
    REPORT="${REPORT}$(printf '=%.0s' {1..60})\n"
}

send_alerts() {
    [[ ${#ANOMALIES[@]} -eq 0 ]] && return
    local body="ALERTE CRYOSS RPi2 [$CLIENT_NAME] - $DATE_LABEL\n\n${#ANOMALIES[@]} anomalie(s) :\n\n"
    for A in "${ANOMALIES[@]}"; do body="${body}  >> $A\n"; done
    send_mail "[ALERTE RPi2 $CLIENT_NAME] ${#ANOMALIES[@]} anomalie(s) - $DATE_LABEL" "$body"
    log "Alerte envoyee"
}

log "=== Monitoring RPi2 [$MODE] ==="
build_report
case "$MODE" in
    daily)  SUBJ="[CRYOSS RPi2 $CLIENT_NAME] Rapport quotidien - $DATE_LABEL" ;;
    weekly) SUBJ="[CRYOSS RPi2 $CLIENT_NAME] Rapport hebdomadaire - $DATE_LABEL" ;;
    *)      SUBJ="[CRYOSS RPi2 $CLIENT_NAME] TEST - $DATE_LABEL" ;;
esac
send_mail "$SUBJ" "$REPORT"
log "Rapport $MODE envoye"
[[ "$MODE" != "alert-test" ]] && send_alerts
log "=== Fin monitoring (${#ANOMALIES[@]} anomalie(s)) ==="
HEALTH_EOF

sed -i \
    -e "s|DS_EMAIL_TO|${R2_EMAIL_TO}|g" \
    -e "s|DS_CLIENT_NAME|${CLIENT_NAME}|g" \
    -e "s|DS_RPI1_IP|${RPI1_IP}|g" \
    -e "s|DS_RPI2_DIR|${RPI2_DIR}|g" \
    /usr/local/bin/cryoss-health.sh

chmod 700 /usr/local/bin/cryoss-health.sh
chown root:root /usr/local/bin/cryoss-health.sh
ok "cryoss-health.sh installe et configure sur RPi2"

for TYPE in daily weekly; do
    [[ "$TYPE" == "daily" ]] && SCHED="*-*-* 06:30:00" || SCHED="Mon *-*-* 07:30:00"
    [[ "$TYPE" == "daily" ]] && LBL="quotidien 06h30" || LBL="hebdomadaire lundi 07h30"

    cat > /etc/systemd/system/cryoss-health-${TYPE}.service <<SVC_EOF
[Unit]
Description=CRYOSS - Rapport sante $LBL RPi2 [$CLIENT_NAME]
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/cryoss-health.sh $TYPE
StandardOutput=append:/var/log/cryoss-health.log
StandardError=append:/var/log/cryoss-health.log
User=root
[Install]
WantedBy=multi-user.target
SVC_EOF

    cat > /etc/systemd/system/cryoss-health-${TYPE}.timer <<TMR_EOF
[Unit]
Description=CRYOSS - Timer sante $LBL RPi2 [$CLIENT_NAME]
[Timer]
OnCalendar=$SCHED
Persistent=true
Unit=cryoss-health-${TYPE}.service
[Install]
WantedBy=timers.target
TMR_EOF
done

cat > /etc/logrotate.d/cryoss-rpi2-health <<LR_EOF
/var/log/cryoss-health.log {
    weekly
    rotate 12
    compress
    missingok
    notifempty
    create 640 root root
}
LR_EOF

systemctl daemon-reload
systemctl enable cryoss-health-daily.timer cryoss-health-weekly.timer
systemctl start  cryoss-health-daily.timer cryoss-health-weekly.timer
ok "Timers monitoring RPi2 : quotidien 06h30 | hebdomadaire lundi 07h30"

info "Test rapport sante RPi2..."
/usr/local/bin/cryoss-health.sh daily && ok "Rapport test envoye a ${R2_EMAIL_TO}" \
    || warn "Erreur rapport test — verifiez msmtp"

# =============================================================================
#  RESUME
# =============================================================================
echo -e "\n${BOLD}${GREEN}"
echo "============================================================"
echo "  CRYOSS RPi2 - Installation terminee !"
echo "============================================================"
echo -e "${NC}"
echo -e "${BOLD}--- Client ---${NC}"
echo "  $CLIENT_NAME"
echo -e "${BOLD}--- Reseau ---${NC}"
echo "  ${NET_IP}/${NET_CIDR}  GW:$NET_GW  ($NET_IFACE)"
echo -e "${BOLD}--- RAID ---${NC}"
echo "  md0 ($DISK1+$DISK2) -> /etc/encrypted   UUID:$UUID_MD0"
echo -e "${BOLD}--- Replication ---${NC}"
echo "  Réseau    : câble direct RPi1(eth1-USB/${INTERCO_IP_RPI1}) ↔ RPi2($INTERCO_IFACE/${INTERCO_IP_RPI2})"
echo "  Reception : RPi1 --rclone SFTP crypt--> ds-repl@${INTERCO_IP_RPI2} -> $RPI2_DIR"
echo "  Algo      : AES-256-CBC/KEY2 (chiffre avant transit SSH)"
echo -e "${BOLD}--- Utilisateurs ---${NC}"
echo "  ds-repl  : $REPL_PASS  (SFTP-only, nologin, chroot)"
echo "  habyss   : $HABYSS_PASS  (admin sudo, SSH via RPi1 uniquement)"

echo -e "${BOLD}--- Securite ---${NC}"
echo "  UFW : SSH RPi1 interco(${INTERCO_IP_RPI1}) — règle LAN temp à supprimer"
echo "  ds-repl : SFTP-only chroot (ForceCommand internal-sftp) dans $RPI2_DIR"
echo "  Fail2Ban, SMB2+ chiffre, sysctl durci"
echo -e "${BOLD}--- Monitoring ---${NC}"
echo "  Quotidien   : 06h30  (rapport leger + alertes immediates)"
echo "  Hebdomadaire: lundi 07h30  (rapport SMART complet)"
echo "  Script      : /usr/local/bin/cryoss-health.sh"
echo "  Log         : /var/log/cryoss-health.log"
echo ""

if [[ -z "${RPI1_PUBKEY:-}" ]]; then
    echo -e "${RED}${BOLD}ACTION REQUISE : ajouter la cle RPi1 dans :${NC}"
    echo "  ${REPL_HOME}/.ssh/authorized_keys"
    echo ""
fi

echo -e "${YELLOW}Tests :${NC}"
echo "  sudo /usr/local/bin/cryoss-health.sh daily       # Rapport test"
echo "  sudo /usr/local/bin/cryoss-health.sh weekly      # Rapport hebdo test"
echo "  sudo /usr/local/bin/cryoss-health.sh alert-test  # Test alerte seule"
echo "  ssh cryoss-rpi2 'cat > $RPI2_DIR/test.enc' < /dev/null  # Test replication"
echo "  tail -f /var/log/cryoss-health.log"
echo ""
warn "PasswordAuthentication est desactive (securite). Pour vous connecter :"
warn "  ssh-copy-id -i ~/.ssh/id_ed25519.pub habyss@${NET_IP}"
warn "  ou copiez votre cle publique dans /home/habyss/.ssh/authorized_keys"
echo -e "${YELLOW}${BOLD}=== ACTION REQUISE APRÈS DÉPLOIEMENT ===${NC}"
echo ""
echo "  1. Vérifier la connexion SSH depuis RPi1 :"
echo "     ssh cryoss-rpi2 'echo ok'"
echo ""
echo "  2. Supprimer la règle UFW LAN temporaire :"
echo "     ufw delete allow from ${LAN_SUBNET} to any port 22"
echo "     ufw status  # vérifier qu'il ne reste que SSH depuis 10.42.0.1"
echo ""
echo "  3. Désactiver la connexion NM LAN (cable LAN à débrancher) :"
echo "     nmcli connection modify cryoss-lan-temp connection.autoconnect no"
echo "     nmcli connection down cryoss-lan-temp 2>/dev/null || true"
echo ""
echo "  4. Débrancher le câble LAN de RPi2."
echo "     RPi2 sera uniquement accessible depuis RPi1 via le lien 10.42.0.0/30."
echo ""
echo -e "${RED}${BOLD}Redémarrage recommandé.${NC}"
echo
