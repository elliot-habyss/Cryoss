#!/bin/bash
# =============================================================================
# CRYOSS - Suite de tests unifiée
# =============================================================================
# Remplace test_installation.sh + test_command_flow.sh (mergés ici).
#
# Usage :
#   sudo bash tests/cryoss-test.sh                  # all (auto-detect rôle)
#   sudo bash tests/cryoss-test.sh install          # post-install validation
#   sudo bash tests/cryoss-test.sh runner           # command flow runtime (RPi1 only)
#   sudo bash tests/cryoss-test.sh all              # = défaut
#   sudo bash tests/cryoss-test.sh install --rpi2   # force RPi2
#   sudo bash tests/cryoss-test.sh --help
#
# Codes retour :
#   0 = tous les tests passent
#   1 = au moins un test CRITIQUE échoue
#   2 = warnings (fonctionnel mais à surveiller)
# =============================================================================

set -uo pipefail
# PAS set -e : on continue même si un test individuel échoue.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

PASS=0; FAIL=0; WARN=0; SKIP=0

pass()    { echo -e "  ${GREEN}[PASS]${NC} $1"; (( PASS++ )); }
fail()    { echo -e "  ${RED}[FAIL]${NC} $1"; (( FAIL++ )); }
warning() { echo -e "  ${YELLOW}[WARN]${NC} $1"; (( WARN++ )); }
skip()    { echo -e "  ${BLUE}[SKIP]${NC} $1"; (( SKIP++ )); }
info()    { echo -e "  ${BLUE}[INFO]${NC} $1"; }
section() { echo -e "\n${BOLD}${BLUE}━━━ $1 ━━━${NC}"; }

usage() {
    sed -n '2,18p' "$0" | sed 's/^# \?//'
    exit 0
}

# =============================================================================
# Détection rôle (RPi1 si cryoss-backup.sh existe, sinon RPi2 si ds-repl/10.42.0.2)
# =============================================================================
detect_role() {
    if [[ -f /usr/local/bin/cryoss-backup.sh ]]; then
        echo "rpi1"
    elif [[ -d /var/lib/ds-repl ]] || ip addr 2>/dev/null | grep -q "10\.42\.0\.2"; then
        echo "rpi2"
    else
        echo "unknown"
    fi
}

# =============================================================================
# CLI
# =============================================================================
MODE="all"
FORCE_ROLE=""
for arg in "$@"; do
    case "$arg" in
        install|runner|all) MODE="$arg" ;;
        --rpi2) FORCE_ROLE="rpi2" ;;
        --rpi1) FORCE_ROLE="rpi1" ;;
        --help|-h) usage ;;
        *) echo "Argument inconnu : $arg" >&2; exit 1 ;;
    esac
done

[[ $EUID -ne 0 ]] && { echo "Root requis : sudo bash $0" >&2; exit 1; }

ROLE="${FORCE_ROLE:-$(detect_role)}"
if [[ "$ROLE" == "unknown" ]]; then
    echo "Impossible de détecter le rôle (RPi1/RPi2). Force avec --rpi1 ou --rpi2." >&2
    exit 1
fi

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   CRYOSS - Suite de tests ($MODE / $ROLE)          ${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"

# =============================================================================
# === FONCTIONS DE TESTS POST-INSTALLATION ===================================
# (héritées de test_installation.sh)
# =============================================================================

test_install_raid() {
    section "1. RAID"

    if cat /proc/mdstat 2>/dev/null | grep -q '\[UU\]'; then
        NB_UU=$(grep -c '\[UU\]' /proc/mdstat)
        if [[ "$ROLE" == "rpi1" ]] && (( NB_UU >= 2 )); then
            pass "RAID : $NB_UU arrays [UU] (md0 + md1)"
        elif [[ "$ROLE" == "rpi2" ]] && (( NB_UU >= 1 )); then
            pass "RAID : $NB_UU array [UU] (md0)"
        else
            warning "RAID : $NB_UU array(s) [UU] - attendu $( [[ "$ROLE" == "rpi1" ]] && echo 2 || echo 1 )"
        fi
    else
        fail "RAID : aucun array [UU] - cat /proc/mdstat"
    fi

    for mnt in /etc/sauvegarde /etc/encrypted; do
        if [[ "$ROLE" == "rpi2" ]] && [[ "$mnt" == "/etc/sauvegarde" ]]; then continue; fi
        if mountpoint -q "$mnt" 2>/dev/null; then
            pass "$mnt : monte"
        else
            fail "$mnt : non monte"
        fi
    done

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
}

test_install_users() {
    section "2. Utilisateurs et permissions"

    if [[ "$ROLE" == "rpi1" ]]; then
        for user in ds-user habyss; do
            id "$user" &>/dev/null && pass "User $user : existe" || fail "User $user : absent"
        done
        pdbedit -L 2>/dev/null | grep -q "ds-user" && pass "Samba ds-user : active" || warning "Samba ds-user : non trouve"
    fi

    if [[ "$ROLE" == "rpi2" ]]; then
        id ds-repl &>/dev/null && pass "User ds-repl : existe" || fail "User ds-repl : absent"
        SHELL_DS=$(getent passwd ds-repl 2>/dev/null | cut -d: -f7)
        [[ "$SHELL_DS" == "/usr/sbin/nologin" ]] && pass "ds-repl : shell nologin" \
            || warning "ds-repl : shell = $SHELL_DS (attendu /usr/sbin/nologin)"
    fi

    id habyss &>/dev/null && pass "User habyss : existe" || fail "User habyss : absent"

    if [[ "$ROLE" == "rpi1" ]]; then
        PERMS=$(stat -c '%a' /etc/sauvegarde 2>/dev/null)
        [[ "$PERMS" == "2770" ]] && pass "/etc/sauvegarde : perms 2770" \
            || warning "/etc/sauvegarde : perms $PERMS (attendu 2770)"

        OWNER=$(stat -c '%U:%G' /etc/sauvegarde 2>/dev/null)
        [[ "$OWNER" == "root:samba-share" ]] && pass "/etc/sauvegarde : owner root:samba-share" \
            || warning "/etc/sauvegarde : owner $OWNER"
    fi
}

test_install_rclone() {
    section "3. rclone"

    if command -v rclone &>/dev/null; then
        pass "rclone installe ($(rclone version 2>/dev/null | head -1 | awk '{print $2}'))"
    else
        fail "rclone non installe"
    fi

    if [[ -f /root/.config/rclone/rclone.conf ]]; then
        pass "rclone.conf present"
        PERMS=$(stat -c '%a' /root/.config/rclone/rclone.conf 2>/dev/null)
        [[ "$PERMS" == "600" ]] && pass "rclone.conf : perms 600" || warning "rclone.conf : perms $PERMS (attendu 600)"
    else
        fail "rclone.conf absent"
    fi

    if [[ "$ROLE" == "rpi1" ]]; then
        REMOTES=$(rclone listremotes 2>/dev/null)
        for remote in cryoss-c1-crypt cryoss-c2-crypt; do
            echo "$REMOTES" | grep -q "$remote" && pass "Remote $remote : present" \
                || fail "Remote $remote : absent"
        done
        echo "$REMOTES" | grep -q "cryoss-c3-crypt" && pass "Remote cryoss-c3-crypt : present" \
            || skip "Remote cryoss-c3-crypt : absent (SFTP desactive ?)"

        if rclone lsd cryoss-c1-crypt: &>/dev/null; then
            pass "C1 (local) : rclone lsd OK"
        else
            if rclone ls cryoss-c1-crypt: 2>/dev/null; then
                pass "C1 (local) : accessible (vide = normal si premier backup)"
            else
                fail "C1 (local) : rclone echoue"
            fi
        fi

        if rclone lsd cryoss-c2-crypt: --contimeout 10s --timeout 10s &>/dev/null; then
            pass "C2 (RPi2) : rclone SFTP OK"
        else
            if ping -c 1 -W 3 10.42.0.2 &>/dev/null; then
                warning "C2 (RPi2) : RPi2 joignable mais rclone echoue - verifier cle SSH et SFTP chroot"
            else
                warning "C2 (RPi2) : RPi2 injoignable (cable interco ?)"
            fi
        fi

        if echo "$REMOTES" | grep -q "cryoss-c3-crypt"; then
            if rclone lsd cryoss-c3-sftp: --contimeout 10s --timeout 10s &>/dev/null; then
                pass "C3 (SFTP distant) : connexion OK"
            else
                warning "C3 (SFTP distant) : connexion echouee"
            fi
        fi
    fi

    if [[ -f /etc/cryoss/keys-backup.conf ]]; then
        PERMS=$(stat -c '%a' /etc/cryoss/keys-backup.conf 2>/dev/null)
        [[ "$PERMS" == "600" ]] && pass "Cles backup : presentes (600)" \
            || warning "Cles backup : perms $PERMS (attendu 600)"
    else
        [[ "$ROLE" == "rpi1" ]] && fail "Cles backup absentes (/etc/cryoss/keys-backup.conf)" \
            || skip "Cles backup : non applicable sur RPi2"
    fi
}

test_install_samba() {
    [[ "$ROLE" != "rpi1" ]] && return 0
    section "4. Samba"

    systemctl is-active smbd &>/dev/null && pass "smbd : actif" || fail "smbd : inactif"

    if testparm -s &>/dev/null; then
        pass "smb.conf : syntaxe OK"
    else
        fail "smb.conf : erreur syntaxe - testparm -s"
    fi

    grep -q "vfs objects.*fruit" /etc/samba/smb.conf 2>/dev/null && \
        pass "Samba : vfs_fruit active" || warning "Samba : vfs_fruit absent (Word/Pinpoint KO)"

    grep -q "smb encrypt.*desired\|smb encrypt.*required" /etc/samba/smb.conf 2>/dev/null && \
        pass "Samba : chiffrement SMB actif" || warning "Samba : chiffrement SMB non configure"

    if grep -A5 "encrypted_backup" /etc/samba/smb.conf 2>/dev/null | grep -q "read only = yes"; then
        pass "Samba : encrypted_backup lecture seule"
    else
        warning "Samba : encrypted_backup pourrait etre writable"
    fi
}

test_install_ssh() {
    section "5. SSH et interco"

    systemctl is-active ssh &>/dev/null && pass "SSH : actif" || fail "SSH : inactif"

    SSHD_CONF=$(ls /etc/ssh/sshd_config.d/99-cryoss.conf 2>/dev/null || echo "")
    if [[ -f "$SSHD_CONF" ]]; then
        pass "99-cryoss.conf : present"
        grep -q "PermitRootLogin no" "$SSHD_CONF" && pass "SSH : root login interdit" \
            || warning "SSH : root login non interdit"
        grep -q "AllowUsers" "$SSHD_CONF" && pass "SSH : AllowUsers configure" \
            || warning "SSH : AllowUsers absent"
    else
        fail "99-cryoss.conf : absent"
    fi

    if [[ "$ROLE" == "rpi1" ]]; then
        KEY_PATH=""
        [[ -f /root/.ssh/cryoss_rpi2 ]] && KEY_PATH="/root/.ssh/cryoss_rpi2"
        [[ -f /root/.ssh/deepsave_rpi2 ]] && KEY_PATH="/root/.ssh/deepsave_rpi2"

        if [[ -n "$KEY_PATH" ]]; then
            pass "Cle SSH RPi2 : $KEY_PATH"
        else
            fail "Cle SSH RPi2 : absente"
        fi

        if ping -c 1 -W 3 10.42.0.2 &>/dev/null; then
            pass "Interco : 10.42.0.2 joignable"
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
        if grep -q "Match User ds-repl" "$SSHD_CONF" 2>/dev/null; then
            pass "SFTP chroot : Match User ds-repl present"
            grep -q "ForceCommand internal-sftp" "$SSHD_CONF" && pass "SFTP : ForceCommand internal-sftp" \
                || fail "SFTP : ForceCommand absent"
            grep -q "ChrootDirectory" "$SSHD_CONF" && pass "SFTP : ChrootDirectory configure" \
                || fail "SFTP : ChrootDirectory absent"
        else
            fail "SFTP chroot : Match User ds-repl absent"
        fi

        if mountpoint -q /var/lib/ds-repl/data 2>/dev/null; then
            pass "Bind mount ds-repl/data : actif"
        else
            fail "Bind mount ds-repl/data : inactif"
        fi

        grep -q "ds-repl/data" /etc/fstab 2>/dev/null && pass "fstab : bind mount ds-repl" \
            || warning "fstab : bind mount absent"

        if ping -c 1 -W 3 10.42.0.1 &>/dev/null; then
            pass "Interco : 10.42.0.1 joignable"
        else
            warning "Interco : 10.42.0.1 injoignable"
        fi
    fi
}

test_install_services() {
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

    if [[ "$ROLE" == "rpi1" ]]; then
        if systemctl is-enabled cryoss-sftp-sync.timer &>/dev/null; then
            pass "Timer cryoss-sftp-sync : active"
        else
            skip "Timer cryoss-sftp-sync : non active (SFTP desactive ?)"
        fi
    fi

    if [[ "$ROLE" == "rpi1" ]] && systemctl is-enabled cryoss-honeypot.service &>/dev/null; then
        systemctl is-active cryoss-honeypot.service &>/dev/null && \
            pass "Honeypot : actif" || warning "Honeypot : enable mais inactif"
    fi

    if systemctl is-enabled cryoss-api.service &>/dev/null; then
        systemctl is-active cryoss-api.service &>/dev/null && \
            pass "API : active" || warning "API : enable mais inactive"
    else
        skip "API : non installee"
    fi

    if systemctl is-enabled cryoss-heartbeat.timer &>/dev/null; then
        systemctl is-active cryoss-heartbeat.timer &>/dev/null && \
            pass "Heartbeat : timer actif" || warning "Heartbeat : timer enable mais inactif"
        [[ -f /etc/cryoss/analyss.conf ]] && \
            pass "Heartbeat : config Analyss presente" || warning "Heartbeat : config Analyss manquante"
    fi
}

test_install_security() {
    section "7. Securite"

    if ufw status 2>/dev/null | grep -q "Status: active"; then
        pass "UFW : actif"
        ufw status 2>/dev/null | grep -q "deny (incoming)" && pass "UFW : deny incoming" \
            || warning "UFW : incoming non deny"
    else
        fail "UFW : inactif"
    fi

    systemctl is-active fail2ban &>/dev/null && pass "Fail2ban : actif" || fail "Fail2ban : inactif"
    if fail2ban-client status sshd &>/dev/null; then
        pass "Fail2ban jail sshd : active"
    else
        warning "Fail2ban jail sshd : non active"
    fi

    [[ -f /etc/sysctl.d/99-cryoss.conf ]] && pass "Sysctl hardening : present" \
        || warning "Sysctl 99-cryoss.conf : absent"

    if [[ "$ROLE" == "rpi1" ]] && command -v aa-status &>/dev/null; then
        if aa-status 2>/dev/null | grep -q "enforce"; then
            ENFORCE_COUNT=$(aa-status 2>/dev/null | grep "enforce" | head -1 | awk '{print $1}')
            pass "AppArmor : $ENFORCE_COUNT profil(s) en enforce"
        else
            warning "AppArmor : aucun profil en enforce"
        fi
    fi

    if [[ "$ROLE" == "rpi1" ]]; then
        ATTRS=$(lsattr -d /etc/encrypted 2>/dev/null | awk '{print $1}')
        if [[ "$ATTRS" == *"a"* ]]; then
            pass "chattr +a : /etc/encrypted en append-only"
        else
            skip "chattr +a : non actif (hardening pas encore lance ?)"
        fi

        if [[ -f /etc/sauvegarde/__CRYOSS_SENTINEL__ ]]; then
            pass "Sentinel honeypot : present"
        else
            skip "Sentinel honeypot : absent (hardening ?)"
        fi
    fi
}

test_install_email() {
    section "8. Email (msmtp)"

    if [[ -f /etc/msmtprc ]]; then
        pass "msmtprc : present"
        PERMS=$(stat -c '%a' /etc/msmtprc 2>/dev/null)
        [[ "$PERMS" == "600" ]] && pass "msmtprc : perms 600" || warning "msmtprc : perms $PERMS"
    else
        fail "msmtprc : absent"
    fi

    info "Test email manuel : echo 'Test Cryoss' | msmtp -v VOTRE_EMAIL"

    if [[ "$ROLE" == "rpi1" ]] && systemctl is-active postfix &>/dev/null; then
        pass "Postfix : actif (relay pour RPi2)"
    fi
}

test_install_backup() {
    [[ "$ROLE" != "rpi1" ]] && return 0
    section "9. Test backup complet (fichier test)"

    TEST_FILE="/etc/sauvegarde/_cryoss_test_$(date +%s).txt"
    TEST_CONTENT="CRYOSS_TEST_$(date -Iseconds)_$(openssl rand -hex 8)"
    RESTORE_DIR=""

    echo "$TEST_CONTENT" > "$TEST_FILE"
    pass "Fichier test cree : $TEST_FILE"

    chattr -R -a /etc/encrypted 2>/dev/null || true
    info "Test C1 (sync local)..."
    rclone sync /etc/sauvegarde cryoss-c1-crypt: \
        --exclude "__CRYOSS_SENTINEL__" --checksum 2>/dev/null
    RC=$?
    chattr -R +a /etc/encrypted 2>/dev/null || true
    if (( RC == 0 )); then
        pass "C1 sync : OK (rc=0)"

        rclone cryptcheck /etc/sauvegarde cryoss-c1-crypt: \
            --exclude "__CRYOSS_SENTINEL__" --one-way 2>/dev/null
        RC_CHK=$?
        (( RC_CHK == 0 )) && pass "C1 cryptcheck : integrite OK" \
            || warning "C1 cryptcheck : echoue (rc=$RC_CHK)"

        RESTORE_DIR=$(mktemp -d /tmp/cryoss-test-restore.XXXXXX)
        rclone copy "cryoss-c1-crypt:$(basename "$TEST_FILE")" "$RESTORE_DIR/" 2>/dev/null
        if [[ -f "$RESTORE_DIR/$(basename "$TEST_FILE")" ]]; then
            HASH_SRC=$(sha256sum "$TEST_FILE" | awk '{print $1}')
            HASH_DST=$(sha256sum "$RESTORE_DIR/$(basename "$TEST_FILE")" | awk '{print $1}')
            if [[ "$HASH_SRC" == "$HASH_DST" ]]; then
                pass "C1 restauration : SHA-256 identique - backup restaurable"
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

    info "Test C2 (sync RPi2)..."
    rclone sync /etc/sauvegarde cryoss-c2-crypt: \
        --exclude "__CRYOSS_SENTINEL__" --checksum \
        --contimeout 10s --timeout 20s 2>/dev/null
    RC=$?
    if (( RC == 0 )); then
        pass "C2 sync RPi2 : OK"
        SRC_COUNT=$(rclone ls /etc/sauvegarde --exclude "__CRYOSS_SENTINEL__" 2>/dev/null | wc -l)
        DST_COUNT=$(rclone ls cryoss-c2-crypt: --exclude "__CRYOSS_SENTINEL__" \
            --contimeout 15s --timeout 30s 2>/dev/null | wc -l)
        if (( SRC_COUNT > 0 && SRC_COUNT == DST_COUNT )); then
            pass "C2 verification : nombre de fichiers correspond ($SRC_COUNT/$DST_COUNT)"
        else
            warning "C2 verification : fichiers src=$SRC_COUNT dst=$DST_COUNT"
        fi
    else
        warning "C2 sync RPi2 : echoue (rc=$RC) - RPi2 joignable ?"
    fi

    if rclone listremotes 2>/dev/null | grep -q "cryoss-c3-crypt"; then
        info "Test C3 (sync SFTP distant)..."
        rclone sync /etc/sauvegarde cryoss-c3-crypt: \
            --exclude "__CRYOSS_SENTINEL__" --checksum \
            --contimeout 15s --timeout 30s 2>/dev/null
        RC=$?
        (( RC == 0 )) && pass "C3 sync SFTP : OK" || warning "C3 sync SFTP : echoue (rc=$RC)"
    else
        skip "C3 : SFTP non configure"
    fi

    rm -f "$TEST_FILE"
    rclone sync /etc/sauvegarde cryoss-c1-crypt: --exclude "__CRYOSS_SENTINEL__" --checksum 2>/dev/null
    rclone sync /etc/sauvegarde cryoss-c2-crypt: --exclude "__CRYOSS_SENTINEL__" --checksum \
        --contimeout 10s --timeout 20s 2>/dev/null
    rclone sync /etc/sauvegarde cryoss-c3-crypt: --exclude "__CRYOSS_SENTINEL__" --checksum \
        --contimeout 15s --timeout 30s 2>/dev/null
    pass "Fichier test nettoye (supprime des 3 destinations)"
}

test_install_api() {
    section "10. API"

    if systemctl is-active cryoss-api &>/dev/null; then
        API_HOST="127.0.0.1"; API_PORT=8420
        [[ "$ROLE" == "rpi2" ]] && API_HOST="10.42.0.2" && API_PORT=8421

        HTTP=$(curl -s -o /dev/null -w "%{http_code}" "http://${API_HOST}:${API_PORT}/healthz" 2>/dev/null || echo "000")
        [[ "$HTTP" == "200" ]] && pass "API healthz : HTTP 200" || fail "API healthz : HTTP $HTTP"

        HTTP=$(curl -s -o /dev/null -w "%{http_code}" "http://${API_HOST}:${API_PORT}/api/v1/status" 2>/dev/null || echo "000")
        [[ "$HTTP" != "200" && "$HTTP" != "000" ]] && pass "API auth : protegee (HTTP $HTTP sans token)" \
            || fail "API auth : HTTP $HTTP (attendu rejet sans token)"

        if [[ -f /etc/cryoss/api-key ]]; then
            KEY=$(cat /etc/cryoss/api-key)
            HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
                -H "Authorization: Bearer $KEY" \
                "http://${API_HOST}:${API_PORT}/api/v1/status" 2>/dev/null || echo "000")
            [[ "$HTTP" == "200" ]] && pass "API /status avec cle : HTTP 200" \
                || fail "API /status avec cle : HTTP $HTTP"
        else
            skip "API : pas de cle API pour tester"
        fi

        HTTP=$(curl -s -o /dev/null -w "%{http_code}" "http://${API_HOST}:${API_PORT}/docs" 2>/dev/null || echo "000")
        [[ "$HTTP" == "200" ]] && pass "API Swagger /docs : accessible" \
            || warning "API Swagger : HTTP $HTTP"
    else
        skip "API : non active"
    fi
}

test_install_serial() {
    section "11. Serial et cles"

    [[ -f /etc/cryoss/serial ]] && pass "Serial : $(cat /etc/cryoss/serial)" || skip "Serial : non defini"
    [[ -f /etc/cryoss/api-key ]] && pass "Cle API : presente" || skip "Cle API : non definie"

    if [[ "$ROLE" == "rpi1" ]]; then
        [[ -f /root/.ssh/cryoss_rpi2 ]] && pass "Cle SSH RPi2 : /root/.ssh/cryoss_rpi2" || \
        [[ -f /root/.ssh/deepsave_rpi2 ]] && pass "Cle SSH RPi2 : /root/.ssh/deepsave_rpi2 (legacy)" || \
        fail "Cle SSH RPi2 : absente"
    fi
}

run_install_tests() {
    test_install_raid
    test_install_users
    test_install_rclone
    test_install_samba
    test_install_ssh
    test_install_services
    test_install_security
    test_install_email
    test_install_backup
    test_install_api
    test_install_serial
}

# =============================================================================
# === FONCTIONS DE TESTS COMMAND-FLOW (runner) ================================
# (héritées de test_command_flow.sh)
# =============================================================================

test_runner_install() {
    section "RUNNER - 1. Installation"

    if [[ -x /usr/local/bin/cryoss-command-runner.sh ]]; then
        pass "cryoss-command-runner.sh installe et executable"
    else
        fail "cryoss-command-runner.sh manquant ou pas executable"
    fi

    PERMS=$(stat -c '%a' /usr/local/bin/cryoss-command-runner.sh 2>/dev/null || echo "??")
    if [[ "$PERMS" == "700" ]]; then
        pass "Permissions runner : 700 (root-only)"
    else
        fail "Permissions runner : $PERMS (attendu : 700)"
    fi

    if [[ -f /var/log/cryoss-command.log ]]; then
        pass "Log file cryoss-command.log existe"
    else
        warning "Log cryoss-command.log n'existe pas encore (sera cree au 1er run)"
    fi

    if [[ -f /etc/cryoss/analyss.conf ]]; then
        pass "Config analyss.conf trouvee"
        # shellcheck source=/etc/cryoss/analyss.conf
        source /etc/cryoss/analyss.conf
        [[ -n "${ANALYSS_URL:-}" ]] && pass "ANALYSS_URL = $ANALYSS_URL" || fail "ANALYSS_URL vide"
        [[ -n "${ANALYSS_API_KEY:-}" ]] && pass "ANALYSS_API_KEY configuree (${#ANALYSS_API_KEY} chars)" \
            || fail "ANALYSS_API_KEY vide"
    else
        fail "Config analyss.conf manquante"
    fi
}

test_runner_whitelist() {
    section "RUNNER - 2. Whitelist des commandes"

    info "Test commande autorisee : ping"
    TEST_ID="test-ping-$(date +%s)"
    /usr/local/bin/cryoss-command-runner.sh "$TEST_ID" ping 2>&1 | head -5 > /tmp/cmd-test-ping.out
    LAST=$(tail -5 /var/log/cryoss-command.log 2>/dev/null)
    if echo "$LAST" | grep -q "$TEST_ID"; then
        pass "Commande 'ping' traitee (voir logs)"
    else
        fail "Commande 'ping' non trace dans les logs"
    fi

    info "Test commande INCONNUE : evil_command (doit etre refusee)"
    TEST_ID2="test-evil-$(date +%s)"
    /usr/local/bin/cryoss-command-runner.sh "$TEST_ID2" evil_command 2>&1 > /tmp/cmd-test-evil.out
    sleep 1
    LAST=$(tail -10 /var/log/cryoss-command.log 2>/dev/null)
    if echo "$LAST" | grep -q "$TEST_ID2"; then
        if echo "$LAST" | grep -q "inconnue\|refusee"; then
            pass "Commande inconnue correctement refusee"
        else
            warning "Commande inconnue traitee mais pas forcement refusee - verifier logs"
        fi
    fi
}

test_runner_validations() {
    section "RUNNER - 3. Validations strictes fail2ban"

    info "Test fail2ban_ban avec IP interco (DOIT etre refuse)"
    TEST_ID3="test-ban-interco-$(date +%s)"
    /usr/local/bin/cryoss-command-runner.sh "$TEST_ID3" fail2ban_ban \
        '{"jail":"sshd","ip":"10.42.0.2"}' 2>&1 > /tmp/cmd-test-banintercon.out
    sleep 1
    LAST=$(tail -5 /var/log/cryoss-command.log 2>/dev/null)
    if echo "$LAST" | grep -q "Refus de bannir\|interco"; then
        pass "Ban de l'IP interco 10.42.0.2 bien refuse"
    else
        warning "Message de refus pas detecte - verifier : grep interco /var/log/cryoss-command.log"
    fi

    info "Test fail2ban_ban avec jail invalide (DOIT etre refuse)"
    TEST_ID4="test-ban-evil-$(date +%s)"
    /usr/local/bin/cryoss-command-runner.sh "$TEST_ID4" fail2ban_ban \
        '{"jail":"rm-rf-root","ip":"1.2.3.4"}' 2>&1 > /tmp/cmd-test-banevil.out
    sleep 1
    LAST=$(tail -5 /var/log/cryoss-command.log 2>/dev/null)
    if echo "$LAST" | grep -q "Jail non autorisee"; then
        pass "Jail non whitelistee bien refusee"
    else
        warning "Message de refus jail non detecte"
    fi
}

test_runner_heartbeat() {
    section "RUNNER - 4. Heartbeat : dispatch pending_commands"

    if [[ -x /usr/local/bin/cryoss-heartbeat.sh ]]; then
        pass "cryoss-heartbeat.sh installe"
    else
        fail "cryoss-heartbeat.sh manquant"
    fi

    if grep -q "process_pending_commands" /usr/local/bin/cryoss-heartbeat.sh; then
        pass "heartbeat contient la fonction process_pending_commands"
    else
        fail "heartbeat ne contient PAS process_pending_commands"
    fi

    if grep -q "pending_commands" /usr/local/bin/cryoss-heartbeat.sh; then
        pass "heartbeat parse le champ pending_commands"
    else
        fail "heartbeat ne traite pas pending_commands"
    fi

    info "Simulation : reponse Analyss avec 1 commande 'ping'"
    FAKE_RESPONSE='{"status":"ok","pending_commands":[{"id":"fake-uuid-abc","type":"ping","params":{}}]}'
    export FAKE_RESPONSE
    python3 -c "
import os, json
data = json.loads(os.environ.get('FAKE_RESPONSE', '{}'))
cmds = data.get('pending_commands', [])
print(f'  {len(cmds)} commande(s) parsee(s):')
for c in cmds:
    print(f'    id={c[\"id\"]} type={c[\"type\"]} params={c[\"params\"]}')
"
    unset FAKE_RESPONSE
}

test_runner_e2e() {
    section "RUNNER - 5. Flow end-to-end (si Analyss joignable)"

    if [[ ! -f /etc/cryoss/analyss.conf ]]; then
        skip "Pas de config analyss — skip E2E"
        return
    fi
    # shellcheck source=/etc/cryoss/analyss.conf
    source /etc/cryoss/analyss.conf

    info "Test connexion a Analyss : ${ANALYSS_URL:-}"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 5 \
        "${ANALYSS_URL:-}/api/sync/cryoss/heartbeat" \
        -H "Authorization: Bearer ${ANALYSS_API_KEY:-}" \
        -H "Content-Type: application/json" \
        -d '{"serial":"test"}' 2>/dev/null || echo "000")

    case "$HTTP_CODE" in
        200|201|204|400|422) pass "Analyss joignable (HTTP $HTTP_CODE)" ;;
        401|403) warning "Analyss repond mais authentification refusee (HTTP $HTTP_CODE)" ;;
        404) warning "Endpoint /api/sync/cryoss/heartbeat inexistant cote Analyss (HTTP 404)" ;;
        000) fail "Analyss injoignable (${ANALYSS_URL:-})" ;;
        *) warning "Reponse Analyss inattendue (HTTP $HTTP_CODE)" ;;
    esac

    info "Test endpoint command-ack"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 5 \
        "${ANALYSS_URL:-}/api/sync/cryoss/command-ack" \
        -H "Authorization: Bearer ${ANALYSS_API_KEY:-}" \
        -H "Content-Type: application/json" \
        -d '{"command_id":"test","status":"ok"}' 2>/dev/null || echo "000")

    case "$HTTP_CODE" in
        200|201|204) pass "Endpoint command-ack accepte (HTTP $HTTP_CODE)" ;;
        400|422) warning "Endpoint command-ack existe mais refuse la structure test (HTTP $HTTP_CODE - normal si command_id inconnu)" ;;
        401|403) warning "Endpoint command-ack : auth refusee (HTTP $HTTP_CODE)" ;;
        404) warning "Endpoint /api/sync/cryoss/command-ack absent cote Analyss" ;;
        000) fail "Analyss injoignable" ;;
        *) warning "Reponse inattendue (HTTP $HTTP_CODE)" ;;
    esac
}

run_runner_tests() {
    if [[ "$ROLE" != "rpi1" ]]; then
        info "Tests 'runner' applicables RPi1 uniquement - skip sur $ROLE"
        return 0
    fi
    test_runner_install
    test_runner_whitelist
    test_runner_validations
    test_runner_heartbeat
    test_runner_e2e
}

# =============================================================================
# DISPATCHER
# =============================================================================
case "$MODE" in
    install) run_install_tests ;;
    runner)  run_runner_tests ;;
    all)     run_install_tests; run_runner_tests ;;
esac

# =============================================================================
# RESUME
# =============================================================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                    RESULTATS                     ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════╣${NC}"
echo -e "║  ${GREEN}PASS${NC} : ${BOLD}$PASS${NC}                                       ${NC}"
echo -e "║  ${RED}FAIL${NC} : ${BOLD}$FAIL${NC}                                       ${NC}"
echo -e "║  ${YELLOW}WARN${NC} : ${BOLD}$WARN${NC}                                       ${NC}"
echo -e "║  ${BLUE}SKIP${NC} : ${BOLD}$SKIP${NC}                                       ${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""

if (( FAIL > 0 )); then
    echo -e "${RED}${BOLD}  ✗ $FAIL test(s) ECHOUE(S) - a corriger avant mise en production${NC}"
    echo ""
    exit 1
elif (( WARN > 0 )); then
    echo -e "${YELLOW}${BOLD}  ! $WARN avertissement(s) - fonctionnel mais a surveiller${NC}"
    echo ""
    exit 2
else
    echo -e "${GREEN}${BOLD}  ✓ Tous les tests passent${NC}"
    echo ""
    exit 0
fi
