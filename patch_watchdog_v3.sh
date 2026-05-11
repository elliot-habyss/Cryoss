#!/bin/bash
# =============================================================================
#  CRYOSS - Patch watchdog v3 : fixes SCRIPT seulement (pas de SSH requis)
#
#  Corrige :
#  1) f2b_bans_today/week retourne "0\n0" -> erreur (( : 0\n0 ))
#     Fix : awk au lieu de grep -c | echo "0"
#  2) repl_age_h / repl_count / rpi2_raid utilisent l'alias cryoss-rpi2
#     qui pointe vers ds-repl@RPi2 (SFTP chroot) -> "This service allows
#     sftp connections only" dans l'arithm.
#     Fix : utiliser ssh -i /root/.ssh/cryoss_rpi2 habyss@10.42.0.2
#
#  Ne necessite PAS SSH RPi2 actif pour s'appliquer. Le script fonctionnera
#  avec rh=-1 (pas d'alerte) tant que SSH RPi2 est down, et reprendra
#  automatiquement quand SSH sera back.
#
#  Usage : sudo bash /tmp/patch_watchdog_v3.sh
# =============================================================================
set -euo pipefail

TARGET="/usr/local/bin/cryoss-health.sh"
BAK="$TARGET.bak-v3-$(date +%s)"

if [[ ! -f "$TARGET" ]]; then
    echo "ERREUR : $TARGET introuvable"
    exit 1
fi

cp "$TARGET" "$BAK"
echo "Backup : $BAK"

python3 - "$TARGET" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

changes = 0

# -----------------------------------------------------------------------------
# Fix 1 : f2b_bans_today - utiliser awk au lieu de grep -c || echo "0"
# -----------------------------------------------------------------------------
old_today = re.search(r'f2b_bans_today\(\)[^{]*\{[^}]*\}', content)
if old_today:
    new_today = '''f2b_bans_today() {
    journalctl -u fail2ban --since "$(date '+%Y-%m-%d')" 2>/dev/null | awk '/ Ban /{c++} END{print c+0}'
}'''
    content = content.replace(old_today.group(0), new_today)
    print("  Fix 1a : f2b_bans_today (awk)")
    changes += 1

# -----------------------------------------------------------------------------
# Fix 2 : f2b_bans_week - idem
# -----------------------------------------------------------------------------
old_week = re.search(r'f2b_bans_week\(\)[^{]*\{[^}]*\}', content)
if old_week:
    new_week = '''f2b_bans_week() {
    journalctl -u fail2ban --since "$(date -d '7 days ago' '+%Y-%m-%d')" 2>/dev/null | awk '/ Ban /{c++} END{print c+0}'
}'''
    content = content.replace(old_week.group(0), new_week)
    print("  Fix 1b : f2b_bans_week (awk)")
    changes += 1

# -----------------------------------------------------------------------------
# Fix 3 : repl_age_h - utiliser habyss@10.42.0.2 (shell) au lieu de cryoss-rpi2 (chroot SFTP)
# Match flexible : plusieurs variantes possibles
# -----------------------------------------------------------------------------
# Cherche la fonction complete repl_age_h
m = re.search(r'repl_age_h\(\)\s*\{(?:[^{}]|\{[^{}]*\})*\}', content, re.DOTALL)
if m:
    new_repl_age = '''repl_age_h() {
    local SSH_CMD="ssh -i /root/.ssh/cryoss_rpi2 -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=3 habyss@10.42.0.2"
    local accessible
    accessible=$($SSH_CMD "echo ok" 2>/dev/null)
    if [[ "$accessible" != "ok" ]]; then
        echo "-1"
        return
    fi
    local ts
    ts=$($SSH_CMD "find '$RPI2_DIR' -type f -printf '%T@\\n' 2>/dev/null | sort -n | tail -1" 2>/dev/null | cut -d. -f1 || true)
    ts=$(echo "$ts" | tr -cd '0-9')
    if [[ -z "$ts" || "$ts" == "0" ]]; then
        echo "-1"
        return
    fi
    echo $(( ($(date +%s) - ts) / 3600 ))
}'''
    content = content.replace(m.group(0), new_repl_age)
    print("  Fix 2a : repl_age_h (habyss@10.42.0.2)")
    changes += 1

# -----------------------------------------------------------------------------
# Fix 4 : repl_count
# -----------------------------------------------------------------------------
m = re.search(r'repl_count\(\)\s*\{(?:[^{}]|\{[^{}]*\})*\}', content, re.DOTALL)
if m:
    new_repl_count = '''repl_count() {
    local SSH_CMD="ssh -i /root/.ssh/cryoss_rpi2 -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 habyss@10.42.0.2"
    $SSH_CMD "find '$RPI2_DIR' -type f | wc -l" 2>/dev/null || echo "N/A"
}'''
    content = content.replace(m.group(0), new_repl_count)
    print("  Fix 2b : repl_count (habyss@10.42.0.2)")
    changes += 1

# -----------------------------------------------------------------------------
# Fix 5 : rpi2_raid
# -----------------------------------------------------------------------------
m = re.search(r'rpi2_raid\(\)\s*\{(?:[^{}]|\{[^{}]*\})*\}', content, re.DOTALL)
if m:
    new_rpi2_raid = r'''rpi2_raid() {
    local SSH_CMD="ssh -i /root/.ssh/cryoss_rpi2 -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 habyss@10.42.0.2"
    $SSH_CMD "mdadm --detail /dev/md0 2>/dev/null | awk '/State :/{print \$3}'" 2>/dev/null || echo "inaccessible"
}'''
    content = content.replace(m.group(0), new_rpi2_raid)
    print("  Fix 2c : rpi2_raid (habyss@10.42.0.2)")
    changes += 1

with open(path, 'w') as f:
    f.write(content)

print(f"\n{changes} changement(s) applique(s).")
PYEOF

# Verifier syntaxe
if bash -n "$TARGET"; then
    echo "OK : syntaxe valide"
else
    echo "ERREUR : syntaxe invalide - restauration"
    cp "$BAK" "$TARGET"
    exit 1
fi

# Purge cooldowns pour permettre re-declenchement propre
rm -f /var/lib/cryoss/alerts/repl_rpi2_late.ts 2>/dev/null || true
rm -f /var/lib/cryoss/alerts/sftp_sync_late.ts 2>/dev/null || true

echo ""
echo "Patch applique."
echo ""
echo "Test maintenant :"
echo "  sudo /usr/local/bin/cryoss-health.sh alert"
echo ""
echo "Quand SSH RPi2 reviendra, ajoute la cle habyss :"
echo "  sudo ssh-copy-id -i /root/.ssh/cryoss_rpi2.pub habyss@10.42.0.2"
