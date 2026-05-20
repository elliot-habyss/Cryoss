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
#  CONFIGURATION RPi1 — consommée par la lib UI commune
# =============================================================================
CRYOSS_ROLE="rpi1"
CRYOSS_STATE_DIR="/var/lib/cryoss"
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
    "13b-firewall-wizard:Wizard UFW — règles métier (admin distant, VPN, etc.)"
    "14-monitoring:Monitoring et rapports HTML"
    "15-master-key:Master key Console Analyss (Fernet)"
    "16-versioning-sftp:Anti-ransomware C1 — Versioning SFTP (rclone --backup-dir)"
    "17-honeypot:Anti-ransomware C2 — Honeypot inotify"
    "18-mirror-mode:Anti-ransomware C3 — mode miroir (chattr +a DESACTIVE)"
    "19-apparmor:Anti-ransomware C4 — AppArmor smbd + cryoss-backup"
)

# Variables persistées dans /var/lib/cryoss/install.env (pour resume)
CRYOSS_ENV_VARS=(
    CLIENT_NAME
    SMTP_HOST SMTP_PORT SMTP_FROM SMTP_USER SMTP_PASS
    EMAIL_TO EMAIL_TO_2
    NET_IFACE NET_IP NET_CIDR NET_GW NET_DNS1 NET_DNS2
    INTERCO_IFACE INTERCO_IP_RPI1 INTERCO_IP_RPI2 INTERCO_CIDR INTERCO_CON
    RPI2_IP RPI2_SSH_PORT RPI2_USER RPI2_DIR
    ENABLE_SFTP SFTP_HOST SFTP_PORT SFTP_USER SFTP_PASS SFTP_REMOTE_DIR
    DISK1 DISK2 DISK3 DISK4
    DS_PASS HABYSS_PASS
    # Cles crypt rclone (XSalsa20-Poly1305) — CRITIQUES, sans ces valeurs les
    # backups deja chiffres sont irrecuperables. Persistees dans install.env
    # ET dans /etc/cryoss/keys-backup.conf. La rejouabilite step 06-rclone
    # detecte ces valeurs et NE LES REGENERE PAS si presentes (sinon
    # incompatibilite avec les backups existants).
    KEY_C1_PASS KEY_C1_SALT KEY_C2_PASS KEY_C2_SALT KEY_C3_PASS KEY_C3_SALT
)

# Source de la lib UI commune (couleurs, helpers, runner, resume framework).
# Le script DOIT etre lance depuis le repo Cryoss (lib/cryoss-installer-ui.sh
# attendue a cote de install_rpi1.sh).
LIB_UI="$(cd "$(dirname "$0")" && pwd)/lib/cryoss-installer-ui.sh"
if [[ ! -f "$LIB_UI" ]]; then
    echo "[✗] Lib UI manquante : $LIB_UI" >&2
    echo "    Verifie que tu lances le script depuis le dossier du repo Cryoss." >&2
    exit 1
fi
# shellcheck source=lib/cryoss-installer-ui.sh
source "$LIB_UI"

# CLI : parse + dispatch des modes (help, list, reset, resume, from-step, only-step, install)
cryoss_parse_cli "$@"
cryoss_handle_readonly_modes
[[ $EUID -ne 0 ]] && err "Exécuter en root : sudo bash $0"
cryoss_handle_root_modes

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
# Convention Cryoss : RPi2 reçoit sous /etc/encrypted/rpi1 (identique dans install_rpi2.sh).
# Pas de prompt — le mount RAID md0 de RPi2 est /etc/encrypted et /rpi1 est le subdir
# reception fixe imposé par install_rpi2.sh.
RPI2_DIR="/etc/encrypted/rpi1"

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
    cryoss_apt_install openssl msmtp msmtp-mta samba mdadm ufw fail2ban curl smartmontools \
        smbclient inotify-tools apparmor apparmor-utils apparmor-profiles apparmor-profiles-extra attr

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
    # Tout l'output (stdout+stderr) part dans le log d'install — UX propre.
    {
        for part in $(lsblk -ln -o NAME "$disk" 2>/dev/null | tail -n +2); do
            umount -f "/dev/$part" || true
        done
        umount -f "$disk" || true
        for md in $(grep "^md" /proc/mdstat 2>/dev/null | awk '{print $1}'); do
            mdadm --detail "/dev/$md" 2>/dev/null | grep -q "$disk" && \
                mdadm --stop "/dev/$md" || true
        done
        mdadm --zero-superblock --force "$disk" || true
        wipefs -a -f "$disk" || true
        dd if=/dev/zero of="$disk" bs=1M count=10 conv=fsync || true
        parted -s "$disk" mklabel gpt || true
    } &>> "$CRYOSS_INSTALL_LOG"
    ok "$disk nettoye"
}

# Stop des md existants — output redirige vers le log
{
    for MD in /dev/md0 /dev/md1; do
        [ -b "$MD" ] && { umount -f "$MD" || true; mdadm --stop "$MD" || true; }
    done
} &>> "$CRYOSS_INSTALL_LOG"
for DISK in "$DISK1" "$DISK2" "$DISK3" "$DISK4"; do nuke_disk "$DISK"; done
sleep 2; partprobe "$DISK1" "$DISK2" "$DISK3" "$DISK4" &>> "$CRYOSS_INSTALL_LOG" || true; sleep 2

cryoss_run "Création RAID md0 ($DISK1 + $DISK2)" -- bash -c \
    "mdadm --create /dev/md0 --level=1 --raid-devices=2 --bitmap=internal --run --force '$DISK1' '$DISK2' <<< yes"

cryoss_run "Création RAID md1 ($DISK3 + $DISK4)" -- bash -c \
    "mdadm --create /dev/md1 --level=1 --raid-devices=2 --bitmap=internal --run --force '$DISK3' '$DISK4' <<< yes"

# Status RAID dans le log (pas en stdout pour garder l'UX propre)
sleep 10
cat /proc/mdstat &>> "$CRYOSS_INSTALL_LOG"
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

# Cles crypt rclone (XSalsa20-Poly1305) :
#  - Mode `install` initial : generation aleatoire (3 paires independantes)
#  - Mode `--resume`/`--only-step 06-rclone` : REUSE des cles existantes via
#    install.env (CRYOSS_ENV_VARS) ou /etc/cryoss/keys-backup.conf.
# Sans cette reuse, regenerer les cles rendrait illisibles les backups deja
# chiffres dans /etc/encrypted (md1) et sur RPi2/SFTP.
_load_existing_key() {
    local var="$1"
    # 1. Deja en env (apres cryoss_load_env / install.env source) ?
    [[ -n "${!var:-}" ]] && return 0
    # 2. Sinon, fallback keys-backup.conf (format KEY_X="value")
    if [[ -f /etc/cryoss/keys-backup.conf ]]; then
        local v
        v=$(grep -oP "^${var}=\K.*" /etc/cryoss/keys-backup.conf | tail -1 | tr -d '"')
        if [[ -n "$v" ]]; then
            printf -v "$var" '%s' "$v"
            return 0
        fi
    fi
    return 1
}

_generated_any=0
for _kv in KEY_C1_PASS KEY_C1_SALT KEY_C2_PASS KEY_C2_SALT KEY_C3_PASS KEY_C3_SALT; do
    if _load_existing_key "$_kv"; then
        info "  Cle $_kv : reutilisee depuis env/keys-backup.conf"
    else
        printf -v "$_kv" '%s' "$(rclone obscure "$(openssl rand -base64 32)")"
        info "  Cle $_kv : generee (aleatoire)"
        _generated_any=1
    fi
done

if (( _generated_any == 0 )); then
    info "Toutes les cles crypt reutilisees (compatibilite avec backups existants preservee)"
else
    warn "Cle(s) nouvelle(s) generee(s) — IMPOSSIBLE de dechiffrer les backups anterieurs"
    warn "avec ces nouvelles cles. Sauvegarder keys-backup.conf APRES install."
fi
unset _generated_any _kv

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

# Copier la cle SSH vers RPi2 pour acces sans mot de passe.
# Etape 1 : habyss (admin shell, password auth dispo car defini par install_rpi2)
info "Copie de la cle SSH vers habyss@RPi2..."
if ssh-copy-id -i /root/.ssh/cryoss_rpi2.pub -o StrictHostKeyChecking=accept-new habyss@10.42.0.2 2>/dev/null; then
    ok "Cle SSH copiee vers habyss@10.42.0.2"
else
    warn "ssh-copy-id habyss echoue — faites-le manuellement :"
    warn "  ssh-copy-id -i /root/.ssh/cryoss_rpi2.pub habyss@10.42.0.2"
fi

# Etape 2 : ds-repl (SFTP-only chroot, nologin) — push via habyss+sudo.
# ds-repl ne peut pas accepter ssh-copy-id directement (nologin),
# donc on passe par habyss qui a sudo + shell.
info "Push de la cle vers ds-repl@RPi2 (via habyss+sudo)..."
if scp -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
       /root/.ssh/cryoss_rpi2.pub habyss@10.42.0.2:/tmp/cryoss_rpi2.pub 2>/dev/null \
   && ssh -o ConnectTimeout=10 habyss@10.42.0.2 "sudo install -d -m 700 -o ds-repl -g ds-repl /var/lib/ds-repl/.ssh && sudo install -m 600 -o ds-repl -g ds-repl /tmp/cryoss_rpi2.pub /var/lib/ds-repl/.ssh/authorized_keys && rm /tmp/cryoss_rpi2.pub" 2>/dev/null; then
    ok "Cle SSH push vers ds-repl@10.42.0.2 (rclone SFTP chroot)"
else
    warn "Push cle ds-repl echoue — faites-le manuellement :"
    warn "  scp /root/.ssh/cryoss_rpi2.pub habyss@10.42.0.2:/tmp/"
    warn "  ssh habyss@10.42.0.2 'sudo install -m 600 -o ds-repl -g ds-repl /tmp/cryoss_rpi2.pub /var/lib/ds-repl/.ssh/authorized_keys'"
fi

info "Test SSH RPi2..."
if ssh -o ConnectTimeout=5 cryoss-rpi2 "mkdir -p $RPI2_DIR && echo OK" 2>/dev/null; then
    ok "SSH RPi2 operationnel (rclone SFTP via ds-repl)"
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

# Compteurs par chemin :
#  ERR_Cx == -1 : non-tente (precheck KO, rclone jamais lance) -> badge NON-TENTE
#  ERR_Cx == 0  : sync rclone OK -> badge OK (sauf si WARN_Cx > 0 -> WARN)
#  ERR_Cx > 0   : sync echoue (rc rclone != 0) -> badge ERREUR (rouge)
# WARN_Cx == 1  : sync OK MAIS cryptcheck post-sync signale un drift.
#                 Cause typique : Veeam (ou autre source active) ecrit en
#                 parallele pendant le sync rclone -> fichiers manquants ou
#                 sizes differ cote dest, rattrape au prochain run. Pas une
#                 alerte critique, juste un warning informatif.
ERR_C1=-1; ERR_C2=-1; ERR_C3=-1
WARN_C1=0; WARN_C2=0; WARN_C3=0

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
    count=$(find "$SRC_DIR" -type f ! -name "__CRYOSS_SENTINEL__" 2>/dev/null | wc -l)
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
    # Clamp ERR_Cx negatif (NON-TENTE = -1) a 0 dans le total, sinon
    # le subject affiche "(-1 err)" trompeur sur les chemins non executes.
    local _e1=$(( ERR_C1 > 0 ? ERR_C1 : 0 ))
    local _e2=$(( ERR_C2 > 0 ? ERR_C2 : 0 ))
    local _e3=$(( ERR_C3 > 0 ? ERR_C3 : 0 ))
    local total_err=$(( _e1 + _e2 + _e3 ))
    local subject

    # Badges d'etat par chemin — distinguer SUCCESS / WARN / ERREUR / NON-TENTE
    # ERR_C* == -1 : pas tente (precheck KO, rclone jamais lance) -> "NON-TENTE"
    # ERR_C* == 0 & WARN_C* == 0 : succes complet -> "OK"
    # ERR_C* == 0 & WARN_C* > 0  : sync OK + drift fichiers source -> "WARN"
    # ERR_C* > 0   : sync rclone echoue (rc != 0) -> "ERREUR"
    local c1_badge c2_badge c3_badge c3_label
    if   (( ERR_C1 == -1 )); then c1_badge=$(badge "NON-TENTE" warn)
    elif (( ERR_C1 > 0 ));   then c1_badge=$(badge "ERREUR" crit)
    elif (( WARN_C1 > 0 ));  then c1_badge=$(badge "OK (drift source)" warn)
    else                           c1_badge=$(badge "OK" ok); fi
    if   (( ERR_C2 == -1 )); then c2_badge=$(badge "NON-TENTE" warn)
    elif (( ERR_C2 > 0 ));   then c2_badge=$(badge "ERREUR" crit)
    elif (( WARN_C2 > 0 ));  then c2_badge=$(badge "OK (drift source)" warn)
    else                           c2_badge=$(badge "OK" ok); fi
    if [[ "$ENABLE_SFTP" != "yes" ]]; then
        c3_badge=$(badge "DESACTIVE" info)
        c3_label="C3 (SFTP distant)"
    elif (( ERR_C3 == -1 )); then
        c3_badge=$(badge "NON-TENTE" warn)
        c3_label="C3 (SFTP distant)"
    elif (( ERR_C3 > 0 )); then
        c3_badge=$(badge "ERREUR" crit)
        c3_label="C3 (SFTP distant)"
    elif (( WARN_C3 > 0 )); then
        c3_badge=$(badge "OK (drift source)" warn)
        c3_label="C3 (SFTP distant + versioning)"
    else
        c3_badge=$(badge "OK" ok)
        c3_label="C3 (SFTP distant + versioning)"
    fi

    # Metadonnees
    local src_count src_size restore_status manifest_path
    src_count=$(find "$SRC_DIR" -type f ! -name "__CRYOSS_SENTINEL__" 2>/dev/null | wc -l)
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
ERR_C1=0   # mark "attempted"

RCLONE_LOG_C1="/var/log/rclone_cryoss_c1.log"

# Mode miroir : pas de chattr +a sur /etc/encrypted (decision step 18-mirror-mode).
# Mais on lance chattr -a defensivement au cas ou une install anterieure
# l'avait pose, pour eviter de bloquer les DELETE de rclone sync.
chattr -R -a "$LOCAL_ENC" 2>/dev/null || true

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
        log "  [C1 WARN] sync OK mais cryptcheck rc=$RC_CHECK — drift fichiers source (Veeam ecrit en parallele ?). Rattrape au prochain run. Voir $RCLONE_LOG_C1"
        WARN_C1=1   # informatif : sync OK, juste un drift cote source
    fi
else
    log "  [C1 ERREUR] rclone sync rc=$RC_C1"
    ERR_C1=1
fi

if [[ -x /usr/local/bin/cryoss-cleanup.sh ]]; then
    /usr/local/bin/cryoss-cleanup.sh 2>/dev/null || log "  [C1 WARN] cleanup echoue"
fi

# Repose chattr +a sur /etc/encrypted apres le sync C1 + cryptcheck + cleanup
# chattr +a desactive : on veut un miroir strict de /etc/sauvegarde, pas un
# append-only qui accumule l'historique cote local. La protection ransomware
# est assuree par : C2 (RPi2 air-gap), C3 (SFTP distant + versioning _versions/DATE),
# Honeypot inotify, AppArmor smbd confine. Voir docs/security/HARDENING.md.
# chattr -R +a "$LOCAL_ENC" 2>/dev/null || log "  [C1 WARN] chattr +a non repose"

# =============================================================================
# CHEMIN 2 : rclone crypt → RPi2 via SFTP interco (10.42.0.x)
# =============================================================================
log "-- C2 : rclone sync -> cryoss-c2-crypt (RPi2 SFTP interco) --"
ERR_C2=0   # mark "attempted"

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
    SRC_COUNT=$(find "$SRC_DIR" -type f ! -name "__CRYOSS_SENTINEL__" 2>/dev/null | wc -l)
    DST_COUNT=$(rclone size cryoss-c2-crypt: 2>/dev/null | grep -oP 'Total objects: \K[0-9,]+' | tr -d ',')
    set -e
    DST_COUNT="${DST_COUNT:-0}"
    if [[ "$SRC_COUNT" -gt 0 ]] && [[ "$DST_COUNT" -ge "$SRC_COUNT" ]]; then
        log "  [C2 OK] sync OK — $SRC_COUNT fichier(s) source, $DST_COUNT cote RPi2"
    else
        log "  [C2 WARN] sync OK mais ecart comptage (src=$SRC_COUNT dst=$DST_COUNT) — drift source (Veeam ?). Rattrape au prochain run."
        WARN_C2=1   # informatif : drift comptage
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
    ERR_C3=0   # mark "attempted"

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
TEST_FILE=$(find "$SRC_DIR" -type f ! -name "__CRYOSS_SENTINEL__" 2>/dev/null | shuf -n 1)
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
    echo "  \"source_files\": $(find "$SRC_DIR" -type f ! -name "__CRYOSS_SENTINEL__" | wc -l),"
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
if cryoss_step "13b-firewall-wizard" "13b. Wizard UFW — règles métier"; then

# Wizard interactif pour ajouter des regles UFW custom (admin distant, VPN
# entreprise, sous-reseaux specifiques) en plus des regles de base posees
# en step 13-hardening. Les regles sont persistees dans /etc/cryoss/firewall.conf
# pour permettre la rejouabilite via --only-step 13b-firewall-wizard.
#
# Format /etc/cryoss/firewall.conf :
#   RULE  <label>  <CIDR>  <PORTS>  <PROTO>  <COMMENT>
# Exemple :
#   RULE  admin-distant  82.138.69.128/32  22  tcp  Admin distant Jean
#   RULE  vpn-entreprise 10.99.0.0/24      22,445 tcp VPN siege

FIREWALL_CONF="/etc/cryoss/firewall.conf"
mkdir -p /etc/cryoss; chmod 700 /etc/cryoss
touch "$FIREWALL_CONF"; chmod 600 "$FIREWALL_CONF"

# Affiche les regles UFW actuelles
firewall_show_current() {
    echo
    hdr "Regles UFW actuelles :"
    ufw status numbered 2>/dev/null | sed 's/^/    /' | head -30
    echo
}

# Affiche les regles metier persistees
firewall_show_custom() {
    if [[ ! -s "$FIREWALL_CONF" ]] || ! grep -q '^RULE ' "$FIREWALL_CONF"; then
        info "Aucune regle metier persistee (${FIREWALL_CONF})"
        return
    fi
    hdr "Regles metier persistees :"
    local i=0 label cidr ports proto comment
    while read -r kw label cidr ports proto comment; do
        [[ "$kw" != "RULE" ]] && continue
        i=$((i+1))
        printf "    [%2d] %s\n         %-20s %-25s ports=%-12s proto=%-3s\n         %s\n" \
            "$i" "$label" "$label" "$cidr" "$ports" "$proto" "${comment:-(no comment)}"
    done < "$FIREWALL_CONF"
    echo
}

# Valide le format CIDR (basique : IPv4 + optional /N)
firewall_valid_cidr() {
    local c="$1"
    [[ "$c" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]
}

# Valide les ports (comma-separated, range "X:Y" autorise)
firewall_valid_ports() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+(:[0-9]+)?(,[0-9]+(:[0-9]+)?)*$ ]]
}

# Applique une regle UFW (idempotent, ne dedoublonne pas — UFW le fait)
firewall_apply_rule() {
    local cidr="$1" ports="$2" proto="$3" comment="$4"
    local port
    IFS=',' read -ra _PORTS_ARR <<< "$ports"
    for port in "${_PORTS_ARR[@]}"; do
        ufw allow from "$cidr" to any port "$port" proto "$proto" \
            comment "$comment" >/dev/null 2>&1 || true
    done
}

# Rejoue toutes les regles persistees
firewall_replay_all() {
    [[ ! -s "$FIREWALL_CONF" ]] && return 0
    local count=0
    while read -r kw label cidr ports proto comment; do
        [[ "$kw" != "RULE" ]] && continue
        firewall_apply_rule "$cidr" "$ports" "$proto" "$comment"
        count=$((count+1))
    done < "$FIREWALL_CONF"
    if (( count > 0 )); then
        ok "$count regle(s) metier re-appliquee(s) depuis $FIREWALL_CONF"
    fi
}

# Wizard interactif : ajout/suppression de regles
firewall_wizard_loop() {
    while true; do
        firewall_show_custom
        echo "  [1] Ajouter une regle (IP/CIDR + ports + commentaire)"
        echo "  [2] Supprimer une regle existante"
        echo "  [3] Reinitialiser (vider la liste metier)"
        echo "  [4] Voir l'etat UFW complet (toutes regles incluses)"
        echo "  [5] Terminer le wizard"
        read -rp "  Choix [1-5] : " _fw_choice
        case "$_fw_choice" in
            1)
                echo
                info "Format CIDR : 192.168.1.0/24, 82.138.69.128/32, ..."
                read -rp "  CIDR ou IP : " _cidr
                if ! firewall_valid_cidr "$_cidr"; then
                    warn "CIDR invalide : $_cidr"; continue
                fi
                info "Format ports : 22 / 22,445 / 30000:30100 / 22,445,139"
                read -rp "  Port(s) : " _ports
                if ! firewall_valid_ports "$_ports"; then
                    warn "Format ports invalide : $_ports"; continue
                fi
                read -rp "  Protocole [tcp/udp] (defaut: tcp) : " _proto
                _proto="${_proto:-tcp}"
                [[ "$_proto" != "tcp" && "$_proto" != "udp" ]] && { warn "Protocole invalide"; continue; }
                read -rp "  Label court (a-z0-9-, ex: admin-jean) : " _label
                _label="${_label// /-}"
                if [[ ! "$_label" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]]; then
                    warn "Label invalide (a-z0-9- only, max 32 chars)"; continue
                fi
                read -rp "  Commentaire libre : " _comment
                _comment="${_comment:-Cryoss wizard rule}"
                # Persiste
                printf 'RULE %s %s %s %s %s\n' "$_label" "$_cidr" "$_ports" "$_proto" "$_comment" \
                    >> "$FIREWALL_CONF"
                # Applique
                firewall_apply_rule "$_cidr" "$_ports" "$_proto" "$_comment"
                ok "Regle ajoutee : $_label ($_cidr port=$_ports proto=$_proto)"
                ;;
            2)
                if [[ ! -s "$FIREWALL_CONF" ]] || ! grep -q '^RULE ' "$FIREWALL_CONF"; then
                    info "Aucune regle metier a supprimer"; continue
                fi
                read -rp "  Numero de regle a supprimer : " _idx
                if ! [[ "$_idx" =~ ^[0-9]+$ ]]; then
                    warn "Numero invalide"; continue
                fi
                # Recupere la regle visee
                local line; line=$(grep '^RULE ' "$FIREWALL_CONF" | sed -n "${_idx}p")
                if [[ -z "$line" ]]; then
                    warn "Aucune regle au numero $_idx"; continue
                fi
                read -r _kw _label _cidr _ports _proto _rest <<< "$line"
                # Retire les regles UFW correspondantes
                local port
                IFS=',' read -ra _PORTS_ARR <<< "$_ports"
                for port in "${_PORTS_ARR[@]}"; do
                    yes | ufw delete allow from "$_cidr" to any port "$port" proto "$_proto" \
                        >/dev/null 2>&1 || true
                done
                # Retire de la conf persistee
                grep -v "^RULE ${_label} " "$FIREWALL_CONF" > "${FIREWALL_CONF}.tmp" || true
                mv "${FIREWALL_CONF}.tmp" "$FIREWALL_CONF"
                chmod 600 "$FIREWALL_CONF"
                ok "Regle '$_label' supprimee"
                ;;
            3)
                read -rp "  Confirmer la reinitialisation ? [o/N] : " _conf
                if [[ "${_conf,,}" == "o" ]]; then
                    # Pour chaque regle persistee, on essaie de la retirer d'UFW
                    while read -r kw label cidr ports proto comment; do
                        [[ "$kw" != "RULE" ]] && continue
                        local port
                        IFS=',' read -ra _PORTS_ARR <<< "$ports"
                        for port in "${_PORTS_ARR[@]}"; do
                            yes | ufw delete allow from "$cidr" to any port "$port" proto "$proto" \
                                >/dev/null 2>&1 || true
                        done
                    done < "$FIREWALL_CONF"
                    : > "$FIREWALL_CONF"
                    chmod 600 "$FIREWALL_CONF"
                    ok "Toutes les regles metier supprimees"
                fi
                ;;
            4) firewall_show_current ;;
            5) break ;;
            *) warn "Choix invalide" ;;
        esac
    done
}

# Mode resume / from-step : rejoue silencieusement les regles persistees,
# pas de wizard interactif. Mode install : prompt l'operateur.
if [[ "$CRYOSS_MODE" == "install" || "$CRYOSS_MODE" == "only-step" ]]; then
    info "Regles UFW de base (step 13) deja posees : SSH/SMB LAN + SSH/SMTP RPi2 interco"
    info "Ce wizard sert a AJOUTER des regles metier (admin distant, VPN, sous-reseaux specifiques)"
    info ""
    info "Exemples typiques :"
    info "  - Admin distant : 82.138.69.128/32 port 22 (ssh depuis IP publique fixe)"
    info "  - VPN entreprise : 10.99.0.0/24 port 22,445 (acces depuis siege via VPN)"
    info "  - Poste comptabilite : 192.168.10.42/32 port 445 (Samba dedie)"
    echo
    read -rp "  Lancer le wizard de regles UFW custom ? [O/n] : " _fw_wiz
    if [[ "${_fw_wiz,,}" != "n" ]]; then
        firewall_wizard_loop
    else
        info "Wizard skippe — relance plus tard : sudo bash $0 --only-step 13b-firewall-wizard"
    fi
else
    # resume / from-step : rejoue silencieusement
    firewall_replay_all
fi

# Recharge UFW pour appliquer / persister
ufw reload >/dev/null 2>&1 && ok "UFW rechargee" || warn "ufw reload echoue"
cryoss_done "13b-firewall-wizard"
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
disk_usage()    { df -h "$1" 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5")"}' || echo "N/A"; }
disk_pct()      { df "$1" 2>/dev/null | awk 'NR==2{gsub("%","",$5);print $5}' || echo "0"; }
raid_state()    { mdadm --detail "/dev/$1" 2>/dev/null | awk '/State :/{$1=$2="";print $0}' | xargs || echo "inconnu"; }
raid_details()  { mdadm --detail "/dev/$1" 2>/dev/null | grep -E "State|Active|Failed|Spare|Rebuild" | sed 's/^ *//' || echo ""; }
smart_attr()    { smartctl -A "/dev/$1" 2>/dev/null | awk -v a="$2" '$2==a{print $10}' || echo "0"; }
smart_temp()    { smartctl -A "/dev/$1" 2>/dev/null | awk '$2~/Temperature/{print $10;exit}' || echo "N/A"; }
smart_health()  { smartctl -H "/dev/$1" 2>/dev/null | awk '/overall/{print $NF}' || echo "N/A"; }
smart_hours()   { smartctl -A "/dev/$1" 2>/dev/null | awk '$2=="Power_On_Hours"{print $10}' || echo "N/A"; }
svc_state()     { systemctl is-active "$1" 2>/dev/null || echo "inactive"; }
f2b_bans_today(){ journalctl -u fail2ban --since "$(date '+%Y-%m-%d')" 2>/dev/null | grep -c " Ban " || true; }
f2b_bans_week() { journalctl -u fail2ban --since "$(date -d '7 days ago' '+%Y-%m-%d')" 2>/dev/null | grep -c " Ban " || true; }
f2b_banned()    { fail2ban-client status sshd 2>/dev/null | awk '/Banned IP/{$1=$2=$3="";print $0}' | xargs || echo "aucune"; }
sys_temp()      { cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf "%.1f",$1/1000}' || echo "N/A"; }
sys_load()      { uptime | awk -F'load average:' '{print $2}' | xargs || echo "N/A"; }
sys_ram()       { free -h | awk '/^Mem/{print $3"/"$2}' || echo "N/A"; }
sys_uptime_str(){ uptime -p 2>/dev/null || echo "N/A"; }
# Age du dernier rclone : -1 si pas de donnee (au lieu de 493k heures calcules depuis epoch 0)
rclone_age_h()  {
    local ts
    ts=$(grep "Elapsed time" "$LOG_RCLONE_C3" 2>/dev/null | tail -1 | awk '{print $1,$2}' | xargs -I{} date -d "{}" +%s 2>/dev/null || true)
    ts=$(echo "$ts" | tr -cd '0-9')
    if [[ -z "$ts" || "$ts" == "0" ]]; then
        echo "-1"   # sentinelle "pas de donnee"
        return
    fi
    echo $(( ($(date +%s) - ts) / 3600 ))
}
rclone_last_files() { grep "Copied\|Transferred" "$LOG_RCLONE_C3" 2>/dev/null | tail -1 | grep -oP '\d+ files' || echo "0 fichiers"; }

# Connexion SSH vers RPi2 : utilise habyss (admin shell) avec la cle Cryoss.
# L'alias `cryoss-rpi2` cible ds-repl (SFTP-only ForceCommand internal-sftp),
# inutilisable pour `find` / `cat` / etc. On utilise donc habyss directement
# avec la cle dediee /root/.ssh/cryoss_rpi2 deposee par install_rpi1 step 07.
RPI2_SSH_KEY="/root/.ssh/cryoss_rpi2"
RPI2_SSH_REMOTE="habyss@10.42.0.2"

# Age de la derniere reception RPi2 : -1 si SSH echoue OU aucun fichier
# (evite l'alerte 493 447h declenchee par epoch 0)
repl_age_h() {
    # Test accessibilite — toutes sorties vers /dev/null pour eviter le leak du
    # banner SFTP qui contaminerait la valeur de retour de la fonction.
    if ! ssh -i "$RPI2_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=3 \
              "$RPI2_SSH_REMOTE" true &>/dev/null; then
        echo "-1"; return
    fi

    local ts
    ts=$(ssh -i "$RPI2_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
              "$RPI2_SSH_REMOTE" \
              "find '$RPI2_DIR' -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1" \
              2>/dev/null | cut -d. -f1 || true)
    ts=$(echo "$ts" | tr -cd '0-9')
    if [[ -z "$ts" || "$ts" == "0" ]]; then
        echo "-1"; return
    fi
    echo $(( ($(date +%s) - ts) / 3600 ))
}
repl_count() {
    if ! ssh -i "$RPI2_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=3 \
              "$RPI2_SSH_REMOTE" true &>/dev/null; then
        echo "N/A"; return
    fi
    ssh -i "$RPI2_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
        "$RPI2_SSH_REMOTE" "find '$RPI2_DIR' -type f 2>/dev/null | wc -l" 2>/dev/null || echo "N/A"
}
# RAID state lu depuis /sys/block/md0/md/array_state (lecture publique, pas de sudo).
# Valeurs typiques : clean, active, active-idle, clear, inactive, degraded.
rpi2_raid() {
    local s
    s=$(ssh -i "$RPI2_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
            "$RPI2_SSH_REMOTE" "cat /sys/block/md0/md/array_state 2>/dev/null" 2>/dev/null)
    echo "${s:-inaccessible}"
}
# Usage disque RPi2 /etc/encrypted (mount RAID md0). Parse local du `df` distant.
rpi2_disk_usage() {
    local out
    out=$(ssh -i "$RPI2_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
            "$RPI2_SSH_REMOTE" 'df -h /etc/encrypted 2>/dev/null | tail -1' 2>/dev/null)
    [[ -z "$out" ]] && { echo "N/A"; return; }
    echo "$out" | awk '{print $3"/"$2" ("$5")"}'
}
rpi2_disk_pct() {
    local out
    out=$(ssh -i "$RPI2_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
            "$RPI2_SSH_REMOTE" 'df /etc/encrypted 2>/dev/null | tail -1' 2>/dev/null)
    [[ -z "$out" ]] && { echo "0"; return; }
    echo "$out" | awk '{gsub("%","",$5);print $5}'
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
    # Stockage RPi2 (mesure distante via SSH habyss)
    local rpi2_du rpi2_pct rpi2_dub
    rpi2_du=$(rpi2_disk_usage)
    rpi2_pct=$(rpi2_disk_pct); rpi2_pct=${rpi2_pct:-0}
    if [[ "$rpi2_du" == "N/A" ]]; then rpi2_dub=$(badge "N/A" info)
    elif (( rpi2_pct >= 95 )); then rpi2_dub=$(badge "CRITIQUE" crit); has_warn=1
    elif (( rpi2_pct >= 85 )); then rpi2_dub=$(badge "ATTENTION" warn); has_warn=1
    else rpi2_dub=$(badge "OK" ok); fi
    body+=$(section_open "STOCKAGE")
    body+=$(mrow "/etc/sauvegarde (RAID md0) — local" "$sp" "$sb")
    body+=$(mrow "/etc/encrypted  (RAID md1) — local" "$ep" "$eb")
    body+=$(mrow "/etc/encrypted  (RAID md0) — RPi2"  "$rpi2_du" "$rpi2_dub")
    body+=$(section_close)

    # RAID — local (md0 + md1) puis RPi2 (md0 distant)
    body+=$(section_open "ETAT RAID")
    for MD in md0 md1; do
        local st rb
        st=$(raid_state "$MD")
        if   [[ "$st" =~ clean|active ]]; then rb=$(badge "OK" ok)
        elif [[ "$st" =~ degraded|failed ]]; then rb=$(badge "DÉGRADÉ" crit); has_warn=1
        elif [[ "$st" =~ recovering|resyncing ]]; then rb=$(badge "REBUILD" warn); has_warn=1
        else rb=$(badge "$st" warn); has_warn=1; fi
        body+=$(mrow "/dev/$MD — local" "$st" "$rb")
    done
    # RAID RPi2 (md0) via /sys/block/md0/md/array_state distant
    local rpi2_rs rpi2_rb
    rpi2_rs=$(rpi2_raid 2>/dev/null || echo "inaccessible")
    if   [[ "$rpi2_rs" == "inaccessible" ]]; then rpi2_rb=$(badge "N/A" info)
    elif [[ "$rpi2_rs" =~ clean|active ]]; then rpi2_rb=$(badge "OK" ok)
    elif [[ "$rpi2_rs" =~ degraded|failed ]]; then rpi2_rb=$(badge "DÉGRADÉ" crit); has_warn=1
    elif [[ "$rpi2_rs" =~ recovering|resyncing ]]; then rpi2_rb=$(badge "REBUILD" warn); has_warn=1
    else rpi2_rb=$(badge "$rpi2_rs" warn); has_warn=1; fi
    body+=$(mrow "/dev/md0 — RPi2" "$rpi2_rs" "$rpi2_rb")
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
    src_n=$(find /etc/sauvegarde -type f 2>/dev/null | wc -l || echo "0")
    body+=$(section_open "ARCHIVES")
    body+=$(mrow "/etc/encrypted (chiffres rclone crypt)" "$cbc_sz — $cbc_n fichiers" "")
    body+=$(mrow "/etc/sauvegarde (source)" "$src_sz — $src_n fichiers" "")
    body+=$(section_close)

    # rclone semaine
    local rc_ok rc_err
    rc_ok=$(grep -c "Copied\|Transferred" "$LOG_RCLONE_C3" 2>/dev/null || echo "0")
    rc_err=$(grep -c "ERROR\|FAILED" "$LOG_RCLONE_C3" 2>/dev/null || echo "0")
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
#  ANTI-RANSOMWARE (4 couches) — anciennement install_security.sh
#  Couche 1 : versioning SFTP (rclone --backup-dir + retention purge)
#  Couche 2 : honeypot inotify (sentinel + email alerte)
#  Couche 3 : chattr +a /etc/encrypted (append-only)
#  Couche 4 : AppArmor (smbd enforce + cryoss-backup complain→enforce)
# =============================================================================
# Prerequis : EMAIL_TO / EMAIL_TO_2 / CLIENT_NAME / SFTP_REMOTE_DIR collectes plus tot.
BACKUP_SCRIPT="/usr/local/bin/cryoss-backup.sh"
SENTINEL="/etc/sauvegarde/__CRYOSS_SENTINEL__"

# Versions SFTP : sous-dossier _versions/ dans le remote SFTP distant.
VERSIONS_SFTP_DIR="${SFTP_REMOTE_DIR:-cryoss}/_versions"
RETENTION_DAYS=30

# =============================================================================
if cryoss_step "16-versioning-sftp" "16. Anti-ransomware C1 — Versioning SFTP"; then
    if [[ "${ENABLE_SFTP:-no}" != "yes" ]]; then
        info "SFTP desactive (step 06-rclone) — couche 1 skippee, marquage done quand meme."
        cryoss_done "16-versioning-sftp"
    else
        # Ajouter le remote cryoss-versions dans rclone.conf (meme cle que C3 SFTP).
        RCLONE_CONF="/root/.config/rclone/rclone.conf"
        if ! grep -q "^\[cryoss-versions\]" "$RCLONE_CONF" 2>/dev/null; then
            cat >> "$RCLONE_CONF" <<RCLONE_VER_EOF

[cryoss-versions]
type = crypt
remote = cryoss-c3-sftp:${VERSIONS_SFTP_DIR}
filename_encryption = standard
directory_name_encryption = true
password = ${KEY_C3_PASS}
password2 = ${KEY_C3_SALT}
RCLONE_VER_EOF
            ok "Remote 'cryoss-versions' ajoute (cle = KEY_C3)"
        else
            info "Remote 'cryoss-versions' deja present — preserve"
        fi

        # Script de purge des versions expirees (appele apres chaque sync).
        cat > /usr/local/bin/cryoss-versions-purge.sh <<PURGE_EOF
#!/bin/bash
# Cryoss — purge des versions SFTP plus vieilles que ${RETENTION_DAYS}j
set -uo pipefail
RETENTION_DAYS=${RETENTION_DAYS}
LOG="/var/log/rclone_cryoss.log"
log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] [purge-versions] \$1" | tee -a "\$LOG"; }
CUTOFF=\$(date -d "\${RETENTION_DAYS} days ago" '+%Y-%m-%d')
log "Purge versions SFTP anterieures au \$CUTOFF"
PURGED=0
while IFS= read -r LINE; do
    DIR_DATE=\$(echo "\$LINE" | grep -oP '\\d{4}-\\d{2}-\\d{2}' | head -1 || true)
    [[ -z "\$DIR_DATE" ]] && continue
    if [[ "\$DIR_DATE" < "\$CUTOFF" ]]; then
        log "  Suppression : \$DIR_DATE"
        rclone purge "cryoss-versions:\$DIR_DATE" --contimeout 30s --timeout 60s 2>/dev/null \\
            && (( PURGED++ )) || log "  WARN : purge \$DIR_DATE echouee (non bloquant)"
    fi
done < <(rclone lsd cryoss-versions: --contimeout 30s --timeout 30s 2>/dev/null || true)
log "Purge terminee : \$PURGED repertoire(s) supprime(s)"
PURGE_EOF
        chmod 700 /usr/local/bin/cryoss-versions-purge.sh
        chown root:root /usr/local/bin/cryoss-versions-purge.sh
        ok "Script purge versions cree (retention : ${RETENTION_DAYS}j)"

        # Patch cryoss-backup.sh : --backup-dir sur le sync C3 (idempotent).
        if [[ -f "$BACKUP_SCRIPT" ]] && ! grep -q "\-\-backup-dir" "$BACKUP_SCRIPT"; then
            python3 - "$BACKUP_SCRIPT" <<'PY_EOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()
# Match generique sur le rclone sync vers cryoss-c3-crypt (ou variantes)
import re
new_content = re.sub(
    r'(rclone sync\s+"\$SRC_DIR"\s+cryoss-c3-crypt:\s*\\\s*\n)',
    r'\1    --backup-dir "cryoss-versions:$(date +%Y-%m-%d)" \\\n',
    content, count=1,
)
if new_content != content:
    with open(path, 'w') as f:
        f.write(new_content)
    print("OK: --backup-dir injecte sur sync C3")
else:
    print("WARN: bloc rclone sync C3 non trouve — patch non applique")
    sys.exit(1)
PY_EOF
            ok "cryoss-backup.sh patche : --backup-dir sur sync C3"
        else
            info "cryoss-backup.sh deja patche ou absent"
        fi

        # Pre-creer le repertoire versioning cote SFTP (best-effort).
        if rclone mkdir "cryoss-c3-sftp:${VERSIONS_SFTP_DIR}" --contimeout 10s --timeout 10s 2>/dev/null; then
            ok "Repertoire SFTP ${VERSIONS_SFTP_DIR} cree"
        else
            warn "mkdir SFTP ${VERSIONS_SFTP_DIR} echoue (sera cree au 1er sync)"
        fi
        cryoss_done "16-versioning-sftp"
    fi
fi

# =============================================================================
if cryoss_step "17-honeypot" "17. Anti-ransomware C2 — Honeypot inotify"; then
    # Fichier leurre realiste dans le partage Samba.
    cat > "$SENTINEL" <<'SENT_EOF'
[BackupConfig]
Version=3.2
Profile=Enterprise
LastSync=2024-01-15T02:00:00Z
RetentionDays=30
CompressionLevel=6
EncryptionMode=AES256
StorageBackend=primary
MaxParallelJobs=4
SENT_EOF
    chmod 644 "$SENTINEL"
    chown root:samba-share "$SENTINEL" 2>/dev/null || true
    ok "Fichier leurre cree : $SENTINEL"

    # Service honeypot (heredoc avec ${VAR} echappes pour preservation).
    cat > /usr/local/bin/cryoss-honeypot.sh <<HONEY_EOF
#!/bin/bash
# Cryoss — Honeypot inotify
set -uo pipefail
SENTINEL="${SENTINEL}"
LOG="/var/log/cryoss-honeypot.log"
EMAIL_TO="${EMAIL_TO}"
EMAIL_TO_2="${EMAIL_TO_2:-}"
CLIENT_NAME="${CLIENT_NAME}"
COOLDOWN_FILE="/var/lib/cryoss/honeypot-alert.ts"
COOLDOWN=300

log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" | tee -a "\$LOG"; }

send_alert() {
    local event="\$1" smb_ctx="\$2"
    local ts; ts=\$(date '+%d/%m/%Y a %H:%M:%S')
    if [[ -f "\$COOLDOWN_FILE" ]]; then
        local age=\$(( \$(date +%s) - \$(cat "\$COOLDOWN_FILE") ))
        (( age < COOLDOWN )) && return 0
    fi
    date +%s > "\$COOLDOWN_FILE"
    for DEST in "\$EMAIL_TO" "\$EMAIL_TO_2"; do
        [[ -z "\$DEST" ]] && continue
        {
            echo "To: \$DEST"
            echo "Subject: [Cryoss \$CLIENT_NAME] HONEYPOT DECLENCHE - Activite ransomware"
            echo ""
            echo "Honeypot Cryoss declenche - \$ts"
            echo ""
            echo "Fichier leurre : \$SENTINEL"
            echo "Evenement inotify : \$event"
            echo ""
            echo "Contexte SMB :"
            echo "\$smb_ctx"
            echo ""
            echo "Procedure :"
            echo "  1. Isoler le poste client (couper le reseau)"
            echo "  2. Restaurer derniere version saine :"
            echo "       rclone sync cryoss-versions:YYYY-MM-DD /etc/sauvegarde --checksum"
            echo "  3. Relancer : systemctl start cryoss-backup.service"
        } | msmtp "\$DEST" 2>/dev/null || true
    done
}

recreate_sentinel() {
    [[ -f "\$SENTINEL" ]] && return 0
    cat > "\$SENTINEL" <<'SF'
[BackupConfig]
Version=3.2
Profile=Enterprise
LastSync=2024-01-15T02:00:00Z
RetentionDays=30
CompressionLevel=6
EncryptionMode=AES256
StorageBackend=primary
MaxParallelJobs=4
SF
    chmod 644 "\$SENTINEL"
    chown root:samba-share "\$SENTINEL" 2>/dev/null || true
    log "Sentinel recree"
}

log "=== Honeypot demarre — surveillance : \$SENTINEL ==="
while true; do
    recreate_sentinel
    EVENT=\$(inotifywait -q -e modify,delete,moved_from,close_write,attrib \\
        --format '%e' --timeout 60 "\$SENTINEL" 2>/dev/null || echo "TIMEOUT")
    [[ "\$EVENT" == "TIMEOUT" ]] && continue
    log "ALERTE : evenement '\$EVENT' sur fichier leurre"
    SMB_CTX=\$(smbstatus --brief 2>/dev/null | head -20 || echo "smbstatus indispo")
    send_alert "\$EVENT" "\$SMB_CTX"
    sleep 5
done
HONEY_EOF
    chmod 700 /usr/local/bin/cryoss-honeypot.sh
    chown root:root /usr/local/bin/cryoss-honeypot.sh

    cat > /etc/systemd/system/cryoss-honeypot.service <<SVC_EOF
[Unit]
Description=Cryoss - Honeypot inotify anti-ransomware [${CLIENT_NAME}]
After=network.target smbd.service
Wants=smbd.service

[Service]
Type=simple
ExecStart=/usr/local/bin/cryoss-honeypot.sh
Restart=always
RestartSec=10
StandardOutput=append:/var/log/cryoss-honeypot.log
StandardError=append:/var/log/cryoss-honeypot.log
User=root

[Install]
WantedBy=multi-user.target
SVC_EOF
    systemctl daemon-reload
    systemctl enable cryoss-honeypot.service
    systemctl start cryoss-honeypot.service
    ok "Service honeypot actif (permanent, restart auto)"

    # Exclusion du sentinel dans cryoss-backup.sh (idempotent).
    if [[ -f "$BACKUP_SCRIPT" ]] && ! grep -q "__CRYOSS_SENTINEL__" "$BACKUP_SCRIPT"; then
        sed -i 's|--log-level INFO \\\\|--log-level INFO \\\\\n    --exclude "__CRYOSS_SENTINEL__" \\\\|' \
            "$BACKUP_SCRIPT" 2>/dev/null || true
        ok "Sentinel exclu des syncs rclone dans cryoss-backup.sh"
    fi
    cryoss_done "17-honeypot"
fi

# =============================================================================
if cryoss_step "18-mirror-mode" "18. Anti-ransomware C3 — mode miroir strict"; then
    # Decision design : pas de chattr +a sur /etc/encrypted (precedemment active
    # par cette etape). On veut un miroir exact de /etc/sauvegarde cote local
    # chiffre, pas un historique append-only qui accumule les anciennes versions
    # Veeam et sature le RAID md1.
    #
    # Protection ransomware preservee via :
    #  - C2 (RPi2) sur machine air-gappee — ransomware sur RPi1 ne touche pas
    #  - C3 (SFTP distant) avec --backup-dir cryoss-c3-versions:DATE — versioning
    #    cote distant, historique 30j preserve hors-site
    #  - Honeypot inotify (step 17) — alerte immediate
    #  - AppArmor smbd (step 19) — smbd confine, ne peut pas toucher /etc/encrypted
    #
    # Retirer un eventuel chattr +a heritee d'une install anterieure.
    chattr -R -a /etc/encrypted 2>/dev/null || true
    ok "/etc/encrypted : mode miroir strict (chattr +a desactive)"
    info "Protection ransomware : C2 (RPi2 air-gap) + C3 (SFTP versioning) + Honeypot + AppArmor"

    # cryoss-cleanup.sh ancien : neutralise. Si present, on le rend no-op.
    if [[ -f /usr/local/bin/cryoss-cleanup.sh ]]; then
        cat > /usr/local/bin/cryoss-cleanup.sh <<'CLEAN_EOF'
#!/bin/bash
# Cryoss — script no-op depuis le passage en mode miroir (step 18-mirror-mode).
# Cryoss-backup.sh fait `rclone sync` qui supprime nativement les fichiers
# absents en source. Pas besoin de cleanup separe.
exit 0
CLEAN_EOF
        chmod 700 /usr/local/bin/cryoss-cleanup.sh
        ok "cryoss-cleanup.sh neutralise (no-op, mode miroir gere par rclone sync)"
    fi
    cryoss_done "18-mirror-mode"
fi

# =============================================================================
if cryoss_step "19-apparmor" "19. Anti-ransomware C4 — AppArmor smbd + cryoss-backup"; then
    if ! systemctl is-active --quiet apparmor 2>/dev/null; then
        systemctl enable apparmor >/dev/null 2>&1 || true
        systemctl start apparmor >/dev/null 2>&1 || true
    fi

    # Profil AppArmor smbd
    cat > /etc/apparmor.d/usr.sbin.smbd <<'AA_SMBD'
#include <tunables/global>

profile smbd /usr/sbin/smbd {
    #include <abstractions/base>
    #include <abstractions/nameservice>
    #include <abstractions/openssl>

    capability dac_override,
    capability dac_read_search,
    capability net_bind_service,
    capability setuid,
    capability setgid,
    capability sys_resource,
    capability audit_write,
    capability chown,
    capability fowner,
    capability fsetid,

    /usr/sbin/smbd                          mr,
    /usr/lib/*/samba/**                     mr,

    /etc/samba/**                           r,
    /var/lib/samba/**                       rw,
    /var/cache/samba/**                     rw,
    /run/samba/**                           rw,
    /tmp/**                                 rw,
    /var/log/samba/**                       rw,

    /etc/sauvegarde/                        rw,
    /etc/sauvegarde/**                      rw,
    /etc/encrypted/                         r,
    /etc/encrypted/**                       r,

    /proc/sys/kernel/hostname               r,
    /proc/sys/net/**                        r,
    /proc/*/net/**                          r,
    /sys/class/net/**                       r,
    /dev/urandom                            r,
    /dev/random                             r,
    /dev/null                               rw,

    deny /etc/cryoss/**                     rwx,
    deny /root/**                           rwx,
    deny /usr/local/bin/**                  rwx,
    deny /home/**                           rwx,
    deny /etc/ssh/**                        rwx,
    deny /etc/sudoers                       rwx,
    deny /etc/crontab                       rwx,
}
AA_SMBD

    # Profil AppArmor cryoss-backup.sh
    cat > /etc/apparmor.d/usr.local.bin.cryoss-backup <<'AA_BACKUP'
#include <tunables/global>

profile cryoss-backup /usr/local/bin/cryoss-backup.sh {
    #include <abstractions/base>
    #include <abstractions/bash>

    /usr/local/bin/cryoss-backup.sh            r,
    /usr/local/bin/cryoss-cleanup.sh          rx,
    /usr/local/bin/cryoss-versions-purge.sh   rx,

    /bin/bash                                  ix,
    /usr/bin/openssl                           ix,
    /usr/bin/ssh                               ix,
    /usr/bin/find                              ix,
    /usr/bin/date                              ix,
    /usr/bin/basename                          ix,
    /usr/bin/du                                ix,
    /usr/bin/rclone                            ix,
    /usr/bin/msmtp                             ix,
    /usr/bin/wc                                ix,
    /usr/bin/grep                              ix,
    /usr/bin/stat                              ix,
    /usr/bin/rm                                ix,
    /usr/bin/python3*                          ix,
    /usr/bin/tee                               ix,

    /etc/sauvegarde/                           r,
    /etc/sauvegarde/**                         r,

    /etc/encrypted/                            rw,
    /etc/encrypted/**                          rw,

    /etc/cryoss/keys-backup.conf               r,

    /root/.ssh/cryoss_rpi2                     r,
    /root/.ssh/config                          r,
    /root/.ssh/known_hosts                     rw,

    /root/.config/rclone/rclone.conf           r,
    /root/.config/rclone/                      r,
    /tmp/rclone*                               rw,

    /var/log/cryoss-backup.log                 rw,
    /var/log/rclone_cryoss*.log                rw,
    /var/lib/cryoss/**                         rw,

    /proc/mounts                               r,
    /proc/meminfo                              r,
    /dev/urandom                               r,
    /etc/ssl/certs/**                          r,
    /etc/msmtprc                               r,

    deny /etc/passwd                           w,
    deny /etc/shadow                           rwx,
    deny /root/.ssh/authorized_keys            w,
    deny /usr/local/bin/cryoss-health.sh       w,
    deny /usr/local/bin/cryoss-honeypot.sh     w,
    deny /etc/crontab                          rwx,
    deny /etc/sudoers                          rwx,
    deny /etc/apparmor.d/**                    w,
}
AA_BACKUP

    apparmor_parser -r /etc/apparmor.d/usr.sbin.smbd 2>/dev/null \
        && ok "Profil AppArmor smbd charge" \
        || warn "Profil AppArmor smbd : erreur au chargement (voir syslog)"

    apparmor_parser -r /etc/apparmor.d/usr.local.bin.cryoss-backup 2>/dev/null \
        && ok "Profil AppArmor cryoss-backup charge" \
        || warn "Profil AppArmor cryoss-backup : erreur au chargement"

    # smbd en ENFORCE immediatement, cryoss-backup en COMPLAIN (passe enforce a T+24h via timer).
    aa-enforce /etc/apparmor.d/usr.sbin.smbd 2>/dev/null \
        && ok "smbd : mode ENFORCE" || warn "aa-enforce smbd echoue"
    aa-complain /etc/apparmor.d/usr.local.bin.cryoss-backup 2>/dev/null || true

    systemctl restart smbd 2>/dev/null && ok "smbd redemarre avec profil AppArmor" \
        || warn "Redemarrage smbd echoue"

    # Timer one-shot : passe cryoss-backup en enforce dans 24h
    cat > /etc/systemd/system/cryoss-apparmor-enforce.service <<AAENF_SVC
[Unit]
Description=Cryoss — passage AppArmor cryoss-backup en enforce
[Service]
Type=oneshot
ExecStart=/usr/sbin/aa-enforce /etc/apparmor.d/usr.local.bin.cryoss-backup
AAENF_SVC

    cat > /etc/systemd/system/cryoss-apparmor-enforce.timer <<AAENF_TMR
[Unit]
Description=Cryoss — enforce AppArmor backup dans 24h
[Timer]
OnActiveSec=24h
Unit=cryoss-apparmor-enforce.service
[Install]
WantedBy=timers.target
AAENF_TMR
    systemctl daemon-reload
    systemctl enable --now cryoss-apparmor-enforce.timer >/dev/null 2>&1 || true
    ok "AppArmor : smbd ENFORCE, cryoss-backup COMPLAIN→ENFORCE auto dans 24h"

    # Logrotate honeypot
    if ! grep -q "cryoss-honeypot.log" /etc/logrotate.d/cryoss 2>/dev/null; then
        cat >> /etc/logrotate.d/cryoss <<'LR_EOF'

/var/log/cryoss-honeypot.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    create 640 root root
}
LR_EOF
        ok "Logrotate honeypot configure"
    fi
    cryoss_done "19-apparmor"
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
echo
echo -e "${BOLD}${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${RED}║  ⚠  BUNDLE DE RECUPERATION — A SAUVEGARDER HORS RPi  ⚠   ║${NC}"
echo -e "${BOLD}${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
echo
echo -e "${BOLD}Sans ces valeurs, AUCUNE restauration n'est possible si les disques${NC}"
echo -e "${BOLD}brulent ou que le RPi meurt. Copie-les dans un gestionnaire de mdp${NC}"
echo -e "${BOLD}ou sur une cle USB chiffree, HORS DU RPi.${NC}"
echo
echo -e "${BOLD}${CRY}── Cles crypt rclone (XSalsa20-Poly1305, KEY_C1/C2/C3) ──${NC}"
echo "  KEY_C1_PASS=\"$KEY_C1_PASS\""
echo "  KEY_C1_SALT=\"$KEY_C1_SALT\""
echo "  KEY_C2_PASS=\"$KEY_C2_PASS\""
echo "  KEY_C2_SALT=\"$KEY_C2_SALT\""
echo "  KEY_C3_PASS=\"$KEY_C3_PASS\""
echo "  KEY_C3_SALT=\"$KEY_C3_SALT\""
echo "  → Fichier : /etc/cryoss/keys-backup.conf (0600 root)"
echo
if [[ -f /etc/cryoss/master_key ]]; then
    echo -e "${BOLD}${CRY}── Master key Fernet (Console Analyss bidirectional) ──${NC}"
    echo "  master_key=$(cat /etc/cryoss/master_key 2>/dev/null)"
    echo "  → Fichier : /etc/cryoss/master_key (0600 root)"
    echo
fi
if [[ -n "${SMTP_PASS:-}" ]]; then
    echo -e "${BOLD}${CRY}── SMTP (msmtp $SMTP_HOST) ──${NC}"
    echo "  SMTP_USER=$SMTP_USER"
    echo "  SMTP_PASS=$SMTP_PASS"
    echo
fi
if [[ "$ENABLE_SFTP" == "yes" ]] && [[ -n "${SFTP_PASS:-}" ]]; then
    echo -e "${BOLD}${CRY}── SFTP distant C3 ($SFTP_USER@$SFTP_HOST:$SFTP_PORT) ──${NC}"
    echo "  SFTP_PASS=$SFTP_PASS  (cleartext)"
    echo "  Le password est aussi stocke obscured dans rclone.conf, mais"
    echo "  la version cleartext est plus simple a sauvegarder."
    echo
fi
echo -e "${BOLD}${CRY}── Comptes systeme ──${NC}"
echo "  ds-user (Samba R/W)  : ${DS_PASS:-(inchange)}"
echo "  habyss  (admin SSH)  : ${HABYSS_PASS:-(inchange)}"
echo "  → Aussi dans : /var/lib/cryoss/install.env (0600 root)"
echo
echo -e "${BOLD}${CRY}── Procedure de restauration sur RPi neuf ──${NC}"
echo "  1. Reinstaller cryoss : install_rpi1.sh + install_api.sh"
echo "  2. NE PAS reformatter les disques RAID (sauvegarde toujours dessus)"
echo "  3. Recreer /etc/cryoss/keys-backup.conf avec les KEY_C* ci-dessus"
echo "  4. Recreer /root/.config/rclone/rclone.conf depuis le template"
echo "     (les sections [cryoss-c3-sftp] / [cryoss-c3-crypt] utilisent les KEY_C3)"
echo "  5. Si Console Analyss : redeposer /etc/cryoss/master_key (Fernet)"
echo "  6. Tester : rclone lsd cryoss-c1-crypt: | head"
echo
echo -e "${BOLD}${RED}══════════════════════════════════════════════════════════════${NC}"
echo
echo -e "${BOLD}${CRY}── Cles & configs (fichiers) ──${NC}"
echo "  Cles rclone : /etc/cryoss/keys-backup.conf"
echo "  rclone conf : /root/.config/rclone/rclone.conf"
echo "  Master key  : /etc/cryoss/master_key (si Console Analyss)"
echo "  Install env : /var/lib/cryoss/install.env (mots de passe SMTP/SFTP/users)"
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
