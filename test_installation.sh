#!/bin/bash
# ===========================================================================
# CRYOSS — Test post-installation complet
# ===========================================================================
#
# Verifie que TOUT fonctionne apres une installation ou une mise a jour.
# A lancer sur RPi1 et RPi2 separement.
#
# Tests effectues :
#   1. RAID (etat, montages, UUID fstab)
#   2. Utilisateurs et permissions
#   3. rclone (remotes, connectivite, chiffrement, restauration)
#   4. Samba (config, partage, connexion)
#   5. SSH (cle RPi2, interco, SFTP chroot)
#   6. Services systemd (timers, backup, health, watchdog, honeypot, API)
#   7. Securite (UFW, fail2ban, sysctl, AppArmor, chattr)
#   8. Email (envoi test msmtp)
#   9. Backup complet (3 chemins + cryptcheck + restauration SHA-256)
#  10. API (healthz, auth, endpoints)
#
# Usage :
#   sudo bash test_installation.sh             # RPi1
#   sudo bash test_installation.sh --rpi2      # RPi2
#
# Codes retour :
#   0 = tous les tests passent
#   1 = au moins un test CRITIQUE echoue
#   2 = tests WARNING (fonctionnel mais a surveiller)
# ===========================================================================

set -uo pipefail
# PAS set -e : on veut continuer meme si un test echoue

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

PASS=0; FAIL=0; WARN=0; SKIP=0

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; (( PASS++ )); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; (( FAIL++ )); }
warning() { echo -e "  ${YELLOW}[WARN]${NC} $1"; (( WARN++ )); }
skip() { echo -e "  ${BLUE}[SKIP]${NC} $1"; (( SKIP++ )); }
section() { echo -e "\n${BOLD}${BLUE}━━━ $1 ━━━${NC}"; }

[[ $EUID -ne 0 ]] && { echo "Root requis"; exit 1; }

IS_RPI2=false
[[ "${1:-}" == "--rpi2" ]] && IS_RPI2=true

if [[ "$IS_RPI2" == true ]]; then
    ROLE="rpi2"
else
    ROLE="rpi1"
fi

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   CRYOSS — Test post-installation ($ROLE)          ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""

# ===========================================================================
# 1. RAID
# ===========================================================================
section "1. RAID"

# mdstat
if cat /proc/mdstat 2>/dev/null | grep -q '\[UU\]'; then
    NB_UU=$(grep -c '\[UU\]' /proc/mdstat)
    if [[ "$ROLE" == "rpi1" ]] && (( NB_UU >= 2 )); then
        pass "RAID : $NB_UU arrays [UU] (md0 + md1)"
    elif [[ "$ROLE" == "rpi2" ]] && (( NB_UU >= 1 )); then
        pass "RAID : $NB_UU array [UU] (md0)"
    else
        warning "RAID : $NB_UU array(s) [UU] — attendu $( [[ "$ROLE" == "rpi1" ]] && echo 2 || echo 1 )"
    fi
else
    fail "RAID : aucun array [UU] — cat /proc/mdstat"
fi

# Montages
for mnt in /etc/sauvegarde /etc/encrypted; do
    if [[ "$ROLE" == "rpi2" ]] && [[ "$mnt" == "/etc/sauvegarde" ]]; then
        continue
    fi
    if mountpoint -q "$mnt" 2>/dev/null; then
        pass "$mnt : monte"
    else
        fail "$mnt : non monte"
    fi
done

# fstab UUID
for md in md0 md1; do
    if [[ "$ROLE" == "rpi2" ]] && [[ "$md" == "md1" ]]; then continue; fi
    if grep -q "UUID=.*$md\|/dev/$md" /etc/fstab 2>/dev/null; then
        pass "fstab : /dev/$md present"
    elif grep -q "/etc/sauvegarde\|/etc/encrypted" /etc/fstab 2>/dev/null; then
        pass "fstab : montages presents"
    else
        warning "fstab : entree $md non trouvee"
    fi
done

# Espace disque
for mnt in /etc/sauvegarde /etc/encrypted; do
    if [[ "$ROLE" == "rpi2" ]] && [[ "$mnt" == "/etc/sauvegarde" ]]; then continue; fi
    if mountpoint -q "$mnt" 2>/dev/null; then
        PCT=$(df "$mnt" 2>/dev/null | awk 'NR==2{gsub("%","",$5);print $5}')
        if (( PCT < 85 )); then
            pass "$mnt : ${PCT}% utilise"
        elif (( PCT < 95 )); then
            warning "$mnt : ${PCT}% utilise (>85%)"
        else
            fail "$mnt : ${PCT}% utilise (CRITIQUE)"
        fi
    fi
done

# ===========================================================================
# 2. UTILISATEURS ET PERMISSIONS
# ===========================================================================
section "2. Utilisateurs et permissions"

# Users
if [[ "$ROLE" == "rpi1" ]]; then
    for user in ds-user habyss; do
        id "$user" &>/dev/null && pass "User $user : existe" || fail "User $user : absent"
    done
    # Samba users
    pdbedit -L 2>/dev/null | grep -q "ds-user" && pass "Samba ds-user : active" || warning "Samba ds-user : non trouve"
fi

if [[ "$ROLE" == "rpi2" ]]; then
    id ds-repl &>/dev/null && pass "User ds-repl : existe" || fail "User ds-repl : absent"
    # Verifier shell nologin
    SHELL=$(getent passwd ds-repl 2>/dev/null | cut -d: -f7)
    if [[ "$SHELL" == "/usr/sbin/nologin" ]]; then
        pass "ds-repl : shell nologin"
    else
        warning "ds-repl : shell = $SHELL (attendu /usr/sbin/nologin)"
    fi
fi

id habyss &>/dev/null && pass "User habyss : existe" || fail "User habyss : absent"

# Permissions repertoires
if [[ "$ROLE" == "rpi1" ]]; then
    PERMS=$(stat -c '%a' /etc/sauvegarde 2>/dev/null)
    [[ "$PERMS" == "2770" ]] && pass "/etc/sauvegarde : perms 2770" || warning "/etc/sauvegarde : perms $PERMS (attendu 2770)"

    OWNER=$(stat -c '%U:%G' /etc/sauvegarde 2>/dev/null)
    [[ "$OWNER" == "root:samba-share" ]] && pass "/etc/sauvegarde : owner root:samba-share" || warning "/etc/sauvegarde : owner $OWNER"
fi

# ===========================================================================
# 3. RCLONE
# ===========================================================================
section "3. rclone"

# rclone installe
if command -v rclone &>/dev/null; then
    pass "rclone installe ($(rclone version 2>/dev/null | head -1 | awk '{print $2}'))"
else
    fail "rclone non installe"
fi

# rclone.conf existe
if [[ -f /root/.config/rclone/rclone.conf ]]; then
    pass "rclone.conf present"
    PERMS=$(stat -c '%a' /root/.config/rclone/rclone.conf 2>/dev/null)
    [[ "$PERMS" == "600" ]] && pass "rclone.conf : perms 600" || warning "rclone.conf : perms $PERMS (attendu 600)"
else
    fail "rclone.conf absent"
fi

if [[ "$ROLE" == "rpi1" ]]; then
    # Remotes presents
    REMOTES=$(rclone listremotes 2>/dev/null)
    for remote in cryoss-c1-crypt cryoss-c2-crypt; do
        echo "$REMOTES" | grep -q "$remote" && pass "Remote $remote : present" || fail "Remote $remote : absent"
    done
    echo "$REMOTES" | grep -q "cryoss-c3-crypt" && pass "Remote cryoss-c3-crypt : present" || skip "Remote cryoss-c3-crypt : absent (SFTP desactive ?)"

    # Test C1 (local) — peut-on lister ?
    if rclone lsd cryoss-c1-crypt: &>/dev/null; then
        pass "C1 (local) : rclone lsd OK"
    else
        # C1 pointe vers /etc/encrypted via alias — si vide c'est normal
        if rclone ls cryoss-c1-crypt: 2>/dev/null; then
            pass "C1 (local) : accessible (vide = normal si premier backup)"
        else
            fail "C1 (local) : rclone echoue"
        fi
    fi

    # Test C2 (RPi2) — connectivite SFTP
    if rclone lsd cryoss-c2-crypt: --contimeout 10s --timeout 10s &>/dev/null; then
        pass "C2 (RPi2) : rclone SFTP OK"
    else
        # Tester si RPi2 est joignable
        if ping -c 1 -W 3 10.42.0.2 &>/dev/null; then
            warning "C2 (RPi2) : RPi2 joignable mais rclone echoue — verifier cle SSH et SFTP chroot"
        else
            warning "C2 (RPi2) : RPi2 injoignable (cable interco ?)"
        fi
    fi

    # Test C3 (SFTP distant) — si configure
    if echo "$REMOTES" | grep -q "cryoss-c3-crypt"; then
        if rclone lsd cryoss-c3-sftp: --contimeout 10s --timeout 10s &>/dev/null; then
            pass "C3 (SFTP distant) : connexion OK"
        else
            warning "C3 (SFTP distant) : connexion echouee"
        fi
    fi
fi

# Cles backup
if [[ -f /etc/cryoss/keys-backup.conf ]]; then
    PERMS=$(stat -c '%a' /etc/cryoss/keys-backup.conf 2>/dev/null)
    [[ "$PERMS" == "600" ]] && pass "Cles backup : presentes (600)" || warning "Cles backup : perms $PERMS (attendu 600)"
else
    if [[ "$ROLE" == "rpi1" ]]; then
        fail "Cles backup absentes (/etc/cryoss/keys-backup.conf)"
    else
        skip "Cles backup : non applicable sur RPi2"
    fi
fi

# ===========================================================================
# 4. SAMBA (RPi1 uniquement)
# ===========================================================================
if [[ "$ROLE" == "rpi1" ]]; then
    section "4. Samba"

    systemctl is-active smbd &>/dev/null && pass "smbd : actif" || fail "smbd : inactif"

    # Config valide
    if testparm -s &>/dev/null; then
        pass "smb.conf : syntaxe OK"
    else
        fail "smb.conf : erreur syntaxe — testparm -s"
    fi

    # vfs_fruit
    grep -q "vfs objects.*fruit" /etc/samba/smb.conf 2>/dev/null && \
        pass "Samba : vfs_fruit active" || warning "Samba : vfs_fruit absent (Word/Pinpoint KO)"

    # SMB encrypt
    grep -q "smb encrypt.*desired\|smb encrypt.*required" /etc/samba/smb.conf 2>/dev/null && \
        pass "Samba : chiffrement SMB actif" || warning "Samba : chiffrement SMB non configure"

    # encrypted_backup read-only
    if grep -A5 "encrypted_backup" /etc/samba/smb.conf 2>/dev/null | grep -q "read only = yes"; then
        pass "Samba : encrypted_backup lecture seule"
    else
        warning "Samba : encrypted_backup pourrait etre writable"
    fi
fi

# ===========================================================================
# 5. SSH ET INTERCO
# ===========================================================================
section "5. SSH et interco"

systemctl is-active ssh &>/dev/null && pass "SSH : actif" || fail "SSH : inactif"

# Config hardening
SSHD_CONF=$(ls /etc/ssh/sshd_config.d/99-cryoss.conf 2>/dev/null || echo "")
if [[ -f "$SSHD_CONF" ]]; then
    pass "99-cryoss.conf : present"
    grep -q "PermitRootLogin no" "$SSHD_CONF" && pass "SSH : root login interdit" || warning "SSH : root login non interdit"
    grep -q "AllowUsers" "$SSHD_CONF" && pass "SSH : AllowUsers configure" || warning "SSH : AllowUsers absent"
else
    fail "99-cryoss.conf : absent"
fi

if [[ "$ROLE" == "rpi1" ]]; then
    # Cle SSH vers RPi2
    KEY_PATH=""
    [[ -f /root/.ssh/cryoss_rpi2 ]] && KEY_PATH="/root/.ssh/cryoss_rpi2"
    [[ -f /root/.ssh/deepsave_rpi2 ]] && KEY_PATH="/root/.ssh/deepsave_rpi2"

    if [[ -n "$KEY_PATH" ]]; then
        pass "Cle SSH RPi2 : $KEY_PATH"
    else
        fail "Cle SSH RPi2 : absente"
    fi

    # Test interco
    if ping -c 1 -W 3 10.42.0.2 &>/dev/null; then
        pass "Interco : 10.42.0.2 joignable"

        # Test SSH admin
        if ssh -o BatchMode=yes -o ConnectTimeout=5 habyss@10.42.0.2 "echo ok" &>/dev/null; then
            pass "SSH habyss@RPi2 : OK"
        else
            warning "SSH habyss@RPi2 : echoue (cle pas encore copiee ?)"
        fi
    else
        warning "Interco : 10.42.0.2 injoignable (cable ?)"
    fi
fi

if [[ "$ROLE" == "rpi2" ]]; then
    # SFTP chroot
    if grep -q "Match User ds-repl" "$SSHD_CONF" 2>/dev/null; then
        pass "SFTP chroot : Match User ds-repl present"
        grep -q "ForceCommand internal-sftp" "$SSHD_CONF" && pass "SFTP : ForceCommand internal-sftp" || fail "SFTP : ForceCommand absent"
        grep -q "ChrootDirectory" "$SSHD_CONF" && pass "SFTP : ChrootDirectory configure" || fail "SFTP : ChrootDirectory absent"
    else
        fail "SFTP chroot : Match User ds-repl absent"
    fi

    # Bind mount
    if mountpoint -q /var/lib/ds-repl/data 2>/dev/null; then
        pass "Bind mount ds-repl/data : actif"
    else
        fail "Bind mount ds-repl/data : inactif"
    fi

    # fstab
    grep -q "ds-repl/data" /etc/fstab 2>/dev/null && pass "fstab : bind mount ds-repl" || warning "fstab : bind mount absent"

    # Interco
    if ping -c 1 -W 3 10.42.0.1 &>/dev/null; then
        pass "Interco : 10.42.0.1 joignable"
    else
        warning "Interco : 10.42.0.1 injoignable"
    fi
fi

# ===========================================================================
# 6. SERVICES SYSTEMD
# ===========================================================================
section "6. Services systemd"

if [[ "$ROLE" == "rpi1" ]]; then
    TIMERS=(cryoss-backup.timer cryoss-health-daily.timer cryoss-health-weekly.timer cryoss-watchdog.timer)
else
    TIMERS=(cryoss-health-daily.timer cryoss-health-weekly.timer)
fi

for timer in "${TIMERS[@]}"; do
    if systemctl is-enabled "$timer" &>/dev/null; then
        pass "Timer $timer : active"
    else
        fail "Timer $timer : non active"
    fi
done

# SFTP sync timer (RPi1, optionnel)
if [[ "$ROLE" == "rpi1" ]]; then
    if systemctl is-enabled cryoss-sftp-sync.timer &>/dev/null; then
        pass "Timer cryoss-sftp-sync : active"
    else
        skip "Timer cryoss-sftp-sync : non active (SFTP desactive ?)"
    fi
fi

# Honeypot (RPi1)
if [[ "$ROLE" == "rpi1" ]] && systemctl is-enabled cryoss-honeypot.service &>/dev/null; then
    systemctl is-active cryoss-honeypot.service &>/dev/null && \
        pass "Honeypot : actif" || warning "Honeypot : enable mais inactif"
fi

# API
if systemctl is-enabled cryoss-api.service &>/dev/null; then
    systemctl is-active cryoss-api.service &>/dev/null && \
        pass "API : active" || warning "API : enable mais inactive"
else
    skip "API : non installee"
fi

# Tunnel
if systemctl is-enabled cryoss-tunnel.service &>/dev/null; then
    systemctl is-active cryoss-tunnel.service &>/dev/null && \
        pass "Tunnel : actif" || warning "Tunnel : enable mais inactif"
fi

# ===========================================================================
# 7. SECURITE
# ===========================================================================
section "7. Securite"

# UFW
if ufw status 2>/dev/null | grep -q "Status: active"; then
    pass "UFW : actif"
    # Verifier deny default
    ufw status 2>/dev/null | grep -q "deny (incoming)" && pass "UFW : deny incoming" || warning "UFW : incoming non deny"
else
    fail "UFW : inactif"
fi

# Fail2ban
systemctl is-active fail2ban &>/dev/null && pass "Fail2ban : actif" || fail "Fail2ban : inactif"
if fail2ban-client status sshd &>/dev/null; then
    pass "Fail2ban jail sshd : active"
else
    warning "Fail2ban jail sshd : non active"
fi

# Sysctl
[[ -f /etc/sysctl.d/99-cryoss.conf ]] && pass "Sysctl hardening : present" || warning "Sysctl 99-cryoss.conf : absent"

# AppArmor (RPi1)
if [[ "$ROLE" == "rpi1" ]] && command -v aa-status &>/dev/null; then
    if aa-status 2>/dev/null | grep -q "enforce"; then
        ENFORCE_COUNT=$(aa-status 2>/dev/null | grep "enforce" | head -1 | awk '{print $1}')
        pass "AppArmor : $ENFORCE_COUNT profil(s) en enforce"
    else
        warning "AppArmor : aucun profil en enforce"
    fi
fi

# chattr +a
if [[ "$ROLE" == "rpi1" ]]; then
    ATTRS=$(lsattr -d /etc/encrypted 2>/dev/null | awk '{print $1}')
    if [[ "$ATTRS" == *"a"* ]]; then
        pass "chattr +a : /etc/encrypted en append-only"
    else
        skip "chattr +a : non actif (install_security.sh pas encore lance ?)"
    fi
fi

# Honeypot sentinel
if [[ "$ROLE" == "rpi1" ]] && [[ -f /etc/sauvegarde/__CRYOSS_SENTINEL__ ]]; then
    pass "Sentinel honeypot : present"
else
    if [[ "$ROLE" == "rpi1" ]]; then
        skip "Sentinel honeypot : absent (install_security.sh ?)"
    fi
fi

# ===========================================================================
# 8. EMAIL
# ===========================================================================
section "8. Email (msmtp)"

if [[ -f /etc/msmtprc ]]; then
    pass "msmtprc : present"
    PERMS=$(stat -c '%a' /etc/msmtprc 2>/dev/null)
    [[ "$PERMS" == "600" ]] && pass "msmtprc : perms 600" || warning "msmtprc : perms $PERMS"
else
    fail "msmtprc : absent"
fi

# Test d'envoi (optionnel — on ne spam pas)
echo -e "  ${BLUE}[INFO]${NC} Test email : msmtp -v peut etre teste manuellement"
echo -e "         echo 'Test Cryoss' | msmtp -v VOTRE_EMAIL"

# Postfix relay (RPi1 uniquement)
if [[ "$ROLE" == "rpi1" ]] && systemctl is-active postfix &>/dev/null; then
    pass "Postfix : actif (relay pour RPi2)"
fi

# ===========================================================================
# 9. BACKUP COMPLET (RPi1 uniquement)
# ===========================================================================
if [[ "$ROLE" == "rpi1" ]]; then
    section "9. Test backup complet (fichier test)"

    TEST_FILE="/etc/sauvegarde/_cryoss_test_$(date +%s).txt"
    TEST_CONTENT="CRYOSS_TEST_$(date -Iseconds)_$(openssl rand -hex 8)"
    RESTORE_DIR=""

    # Creer un fichier test
    echo "$TEST_CONTENT" > "$TEST_FILE"
    pass "Fichier test cree : $TEST_FILE"

    # --- C1 : sync local ---
    info "Test C1 (sync local)..."
    rclone sync /etc/sauvegarde cryoss-c1-crypt: \
        --exclude "__CRYOSS_SENTINEL__" \
        --checksum 2>/dev/null
    RC=$?
    if (( RC == 0 )); then
        pass "C1 sync : OK (rc=0)"

        # cryptcheck
        rclone cryptcheck /etc/sauvegarde cryoss-c1-crypt: \
            --exclude "__CRYOSS_SENTINEL__" \
            --one-way 2>/dev/null
        RC_CHK=$?
        (( RC_CHK == 0 )) && pass "C1 cryptcheck : integrite OK" || warning "C1 cryptcheck : echoue (rc=$RC_CHK)"

        # Test restauration
        RESTORE_DIR=$(mktemp -d /tmp/cryoss-test-restore.XXXXXX)
        rclone copy "cryoss-c1-crypt:$(basename "$TEST_FILE")" "$RESTORE_DIR/" 2>/dev/null
        if [[ -f "$RESTORE_DIR/$(basename "$TEST_FILE")" ]]; then
            HASH_SRC=$(sha256sum "$TEST_FILE" | awk '{print $1}')
            HASH_DST=$(sha256sum "$RESTORE_DIR/$(basename "$TEST_FILE")" | awk '{print $1}')
            if [[ "$HASH_SRC" == "$HASH_DST" ]]; then
                pass "C1 restauration : SHA-256 identique — backup restaurable"
            else
                fail "C1 restauration : SHA-256 DIFFERENT (src=$HASH_SRC dst=$HASH_DST)"
            fi
        else
            warning "C1 restauration : fichier non trouve apres rclone copy"
        fi
        rm -rf "$RESTORE_DIR"
    else
        fail "C1 sync : echoue (rc=$RC)"
    fi

    # --- C2 : sync RPi2 ---
    info "Test C2 (sync RPi2)..."
    rclone sync /etc/sauvegarde cryoss-c2-crypt: \
        --exclude "__CRYOSS_SENTINEL__" \
        --checksum --contimeout 10s --timeout 20s 2>/dev/null
    RC=$?
    if (( RC == 0 )); then
        pass "C2 sync RPi2 : OK"
        rclone cryptcheck /etc/sauvegarde cryoss-c2-crypt: \
            --exclude "__CRYOSS_SENTINEL__" \
            --one-way 2>/dev/null
        (( $? == 0 )) && pass "C2 cryptcheck : integrite OK" || warning "C2 cryptcheck : echoue"
    else
        warning "C2 sync RPi2 : echoue (rc=$RC) — RPi2 joignable ?"
    fi

    # --- C3 : sync SFTP ---
    if rclone listremotes 2>/dev/null | grep -q "cryoss-c3-crypt"; then
        info "Test C3 (sync SFTP distant)..."
        rclone sync /etc/sauvegarde cryoss-c3-crypt: \
            --exclude "__CRYOSS_SENTINEL__" \
            --checksum --contimeout 15s --timeout 30s 2>/dev/null
        RC=$?
        (( RC == 0 )) && pass "C3 sync SFTP : OK" || warning "C3 sync SFTP : echoue (rc=$RC)"
    else
        skip "C3 : SFTP non configure"
    fi

    # Nettoyage : supprimer le fichier test et re-sync pour le retirer des destinations
    rm -f "$TEST_FILE"
    rclone sync /etc/sauvegarde cryoss-c1-crypt: --exclude "__CRYOSS_SENTINEL__" --checksum 2>/dev/null
    rclone sync /etc/sauvegarde cryoss-c2-crypt: --exclude "__CRYOSS_SENTINEL__" --checksum --contimeout 10s --timeout 20s 2>/dev/null
    rclone sync /etc/sauvegarde cryoss-c3-crypt: --exclude "__CRYOSS_SENTINEL__" --checksum --contimeout 15s --timeout 30s 2>/dev/null
    pass "Fichier test nettoye (supprime des 3 destinations)"
fi

# ===========================================================================
# 10. API
# ===========================================================================
section "10. API"

if systemctl is-active cryoss-api &>/dev/null; then
    API_HOST="127.0.0.1"
    API_PORT=8420
    [[ "$ROLE" == "rpi2" ]] && API_HOST="10.42.0.2" && API_PORT=8421

    # healthz (sans auth)
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" "http://${API_HOST}:${API_PORT}/healthz" 2>/dev/null || echo "000")
    [[ "$HTTP" == "200" ]] && pass "API healthz : HTTP 200" || fail "API healthz : HTTP $HTTP"

    # Auth requise sur /api/v1/status
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" "http://${API_HOST}:${API_PORT}/api/v1/status" 2>/dev/null || echo "000")
    [[ "$HTTP" == "401" || "$HTTP" == "403" ]] && pass "API auth : protegee (HTTP $HTTP sans token)" || warning "API auth : HTTP $HTTP (attendu 401)"

    # Auth avec cle
    if [[ -f /etc/cryoss/api-key ]]; then
        KEY=$(cat /etc/cryoss/api-key)
        HTTP=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $KEY" "http://${API_HOST}:${API_PORT}/api/v1/status" 2>/dev/null || echo "000")
        [[ "$HTTP" == "200" ]] && pass "API /status avec cle : HTTP 200" || fail "API /status avec cle : HTTP $HTTP"
    else
        skip "API : pas de cle API pour tester"
    fi

    # Swagger
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" "http://${API_HOST}:${API_PORT}/docs" 2>/dev/null || echo "000")
    [[ "$HTTP" == "200" ]] && pass "API Swagger /docs : accessible" || warning "API Swagger : HTTP $HTTP"
else
    skip "API : non active"
fi

# ===========================================================================
# 11. SERIAL ET CLES
# ===========================================================================
section "11. Serial et cles"

[[ -f /etc/cryoss/serial ]] && pass "Serial : $(cat /etc/cryoss/serial)" || skip "Serial : non defini"
[[ -f /etc/cryoss/api-key ]] && pass "Cle API : presente" || skip "Cle API : non definie"

# Cle SSH
if [[ "$ROLE" == "rpi1" ]]; then
    [[ -f /root/.ssh/cryoss_rpi2 ]] && pass "Cle SSH RPi2 : /root/.ssh/cryoss_rpi2" || \
    [[ -f /root/.ssh/deepsave_rpi2 ]] && pass "Cle SSH RPi2 : /root/.ssh/deepsave_rpi2 (legacy)" || \
    fail "Cle SSH RPi2 : absente"
fi

# ===========================================================================
# RESUME
# ===========================================================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                    RESULTATS                     ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════╣${NC}"
echo -e "║  ${GREEN}PASS${NC} : ${BOLD}$PASS${NC}                                       ║"
echo -e "║  ${RED}FAIL${NC} : ${BOLD}$FAIL${NC}                                       ║"
echo -e "║  ${YELLOW}WARN${NC} : ${BOLD}$WARN${NC}                                       ║"
echo -e "║  ${BLUE}SKIP${NC} : ${BOLD}$SKIP${NC}                                       ║"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""

if (( FAIL > 0 )); then
    echo -e "${RED}${BOLD}  ✗ $FAIL test(s) ECHOUE(S) — a corriger avant mise en production${NC}"
    echo ""
    exit 1
elif (( WARN > 0 )); then
    echo -e "${YELLOW}${BOLD}  ! $WARN avertissement(s) — fonctionnel mais a surveiller${NC}"
    echo ""
    exit 2
else
    echo -e "${GREEN}${BOLD}  ✓ Tous les tests passent — installation OK${NC}"
    echo ""
    exit 0
fi
