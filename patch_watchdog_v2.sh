#!/bin/bash
# =============================================================================
#  CRYOSS - Patch v2 : utiliser habyss@RPi2 au lieu de ds-repl (chroot SFTP)
#
#  Le patch v1 gardait l'alias cryoss-rpi2 qui pointe vers ds-repl@10.42.0.2
#  avec ForceCommand internal-sftp (chroot pour rclone). Resultat :
#  toute commande shell renvoie "This service allows sftp connections only."
#  -> le parse (( "..." )) plante.
#
#  Fix : utiliser explicitement ssh habyss@10.42.0.2 avec la cle SSH partagee.
#  (la meme cle cryoss_rpi2 est autorisee pour ds-repl ET habyss grace a
#   ssh-copy-id lance a l'install).
#
#  Corrige AUSSI le bug "0\n0" dans f2b_bans_today/week : grep -c retourne
#  rc=1 quand 0 match ce qui declenche `|| echo "0"` en plus du "0" deja emis.
#
#  Usage : sudo bash /tmp/patch_watchdog_v2.sh
# =============================================================================
set -euo pipefail

TARGET="/usr/local/bin/cryoss-health.sh"
BAK="$TARGET.bak-v2-$(date +%s)"

if [[ ! -f "$TARGET" ]]; then
    echo "ERREUR : $TARGET introuvable"
    exit 1
fi

# -----------------------------------------------------------------------------
# Verifier que habyss@RPi2 est accessible avec la cle cryoss_rpi2
# -----------------------------------------------------------------------------
echo "Test cle SSH habyss@10.42.0.2..."
if ! ssh -i /root/.ssh/cryoss_rpi2 -o BatchMode=yes -o ConnectTimeout=3 \
     -o StrictHostKeyChecking=no habyss@10.42.0.2 "echo ok" 2>/dev/null | grep -q ok; then
    echo ""
    echo "  La cle SSH n'est pas autorisee pour habyss@RPi2."
    echo "  Copie de la cle (necessite le mot de passe habyss de RPi2) :"
    ssh-copy-id -i /root/.ssh/cryoss_rpi2.pub -o StrictHostKeyChecking=no \
        habyss@10.42.0.2 || {
        echo "  ECHEC : copie manuelle :"
        echo "    sudo ssh-copy-id -i /root/.ssh/cryoss_rpi2.pub habyss@10.42.0.2"
        exit 1
    }
    echo "  OK : cle copiee"
else
    echo "  OK : acces habyss@RPi2 deja fonctionnel"
fi

cp "$TARGET" "$BAK"
echo "Backup : $BAK"

python3 - "$TARGET" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# -----------------------------------------------------------------------------
# FIX : remplacer toutes les refs a cryoss-rpi2 par habyss@10.42.0.2 + cle
# -----------------------------------------------------------------------------

# Construire la commande SSH standard
SSH_BASE = 'ssh -i /root/.ssh/cryoss_rpi2 -o BatchMode=yes -o StrictHostKeyChecking=no'

# Remplacement de repl_age_h (robuste avec plusieurs variantes possibles)
old_patterns = [
    # Variante v1 du patch (avec fallback hostname)
    (re.compile(
        r'repl_age_h\(\) \{\n'
        r'    local rpi2_host="cryoss-rpi2"\n'
        r'    ssh -o BatchMode=yes -o ConnectTimeout=3 "\$rpi2_host" true 2>/dev/null \|\| rpi2_host="10\.42\.0\.2"\n'
        r'    local accessible\n'
        r'    accessible=\$\(ssh -o BatchMode=yes -o ConnectTimeout=3 "\$rpi2_host" "echo ok" 2>/dev/null\)\n'
        r'    if \[\[ "\$accessible" != "ok" \]\]; then\n'
        r'        echo "-1"\n'
        r'        return\n'
        r'    fi\n'
        r'    local ts\n'
        r'    ts=\$\(ssh -o BatchMode=yes -o ConnectTimeout=5 "\$rpi2_host" \\\n'
        r'        "find \'\$RPI2_DIR\' -type f -printf \'%T@\\\\n\' 2>/dev/null \| sort -n \| tail -1" \\\n'
        r'        2>/dev/null \| cut -d\. -f1 \|\| true\)\n'
        r'    ts=\$\(echo "\$ts" \| tr -cd \'0-9\'\)\n'
        r'    if \[\[ -z "\$ts" \|\| "\$ts" == "0" \]\]; then\n'
        r'        echo "-1"\n'
        r'        return\n'
        r'    fi\n'
        r'    echo \$\(\( \(\$\(date \+%s\) - ts\) / 3600 \)\)\n'
        r'\}'
    ), 'repl_age_h'),
    # Variante originale
    (re.compile(
        r'repl_age_h\(\) \{\n'
        r'    local ts; ts=\$\(ssh -o BatchMode=yes -o ConnectTimeout=5 cryoss-rpi2 \\\n'
        r'        "find \'\$RPI2_DIR\' -type f -printf \'%T@\\\\n\' 2>/dev/null \| sort -n \| tail -1" \\\n'
        r'        2>/dev/null \| cut -d\. -f1 \|\| true\)\n'
        r'    ts=\$\(echo "\$ts" \| tr -cd \'0-9\'\)\n'
        r'    \[\[ -z "\$ts" \]\] && ts=0\n'
        r'    echo \$\(\( \(\$\(date \+%s\) - ts\) / 3600 \)\)\n'
        r'\}'
    ), 'repl_age_h'),
]

new_repl = '''repl_age_h() {
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

for pattern, _ in old_patterns:
    new_content, n = pattern.subn(new_repl, content, count=1)
    if n == 1:
        content = new_content
        print("  Fix repl_age_h : habyss@10.42.0.2 avec cle cryoss_rpi2")
        break

# Remplacer repl_count
content = re.sub(
    r'repl_count\(\) \{\n(?:    local rpi2_host="cryoss-rpi2"\n    ssh -o BatchMode=yes -o ConnectTimeout=3 "\$rpi2_host" true 2>/dev/null \|\| rpi2_host="10\.42\.0\.2"\n    )?ssh -o BatchMode=yes -o ConnectTimeout=5 (cryoss-rpi2|"\$rpi2_host") \\\n        "find \'\$RPI2_DIR\' -type f \| wc -l" 2>/dev/null \|\| echo "N/A"\n\}',
    '''repl_count() {
    ssh -i /root/.ssh/cryoss_rpi2 -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 \\
        habyss@10.42.0.2 "find '$RPI2_DIR' -type f | wc -l" 2>/dev/null || echo "N/A"
}''',
    content, count=1
)
if 'ssh -i /root/.ssh/cryoss_rpi2' in content and 'repl_count' in content:
    print("  Fix repl_count : habyss@10.42.0.2")

# Remplacer rpi2_raid
content = re.sub(
    r'rpi2_raid\(\) \{\n(?:    local rpi2_host="cryoss-rpi2"\n    ssh -o BatchMode=yes -o ConnectTimeout=3 "\$rpi2_host" true 2>/dev/null \|\| rpi2_host="10\.42\.0\.2"\n    )?ssh -o BatchMode=yes -o ConnectTimeout=5 (cryoss-rpi2|"\$rpi2_host") \\\n        "mdadm --detail /dev/md0 2>/dev/null \| awk \'/State :/\{print \\\$3\}\'" 2>/dev/null \|\| echo "inaccessible"\n\}',
    '''rpi2_raid() {
    ssh -i /root/.ssh/cryoss_rpi2 -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 \\
        habyss@10.42.0.2 "mdadm --detail /dev/md0 2>/dev/null | awk '/State :/{print \\$3}'" 2>/dev/null || echo "inaccessible"
}''',
    content, count=1
)
print("  Fix rpi2_raid : habyss@10.42.0.2")

# -----------------------------------------------------------------------------
# FIX : f2b_bans_today / _week retourne "0\n0" quand grep -c ne matche pas
# -----------------------------------------------------------------------------
content = re.sub(
    r'f2b_bans_today\(\)\{[^}]*\}',
    '''f2b_bans_today() {
    journalctl -u fail2ban --since "$(date '+%Y-%m-%d')" 2>/dev/null | awk '/ Ban /{c++} END{print c+0}'
}''',
    content, count=1
)
content = re.sub(
    r'f2b_bans_week\(\)\s*\{[^}]*\}',
    '''f2b_bans_week() {
    journalctl -u fail2ban --since "$(date -d '7 days ago' '+%Y-%m-%d')" 2>/dev/null | awk '/ Ban /{c++} END{print c+0}'
}''',
    content, count=1
)
print("  Fix f2b_bans_today/week : awk compte en un seul passage")

with open(path, 'w') as f:
    f.write(content)

print("\nPatch termine.")
PYEOF

# Verifier syntaxe
if bash -n "$TARGET"; then
    echo ""
    echo "OK : syntaxe valide apres patch"
else
    echo ""
    echo "ERREUR : syntaxe invalide — restauration"
    cp "$BAK" "$TARGET"
    exit 1
fi

# Purge cooldown pour que le prochain test repartise proprement
rm -f /var/lib/cryoss/alerts/repl_rpi2_late.ts 2>/dev/null || true
rm -f /var/lib/cryoss/alerts/sftp_sync_late.ts 2>/dev/null || true
echo "Cooldowns purges"

# Test direct des fonctions patchees
echo ""
echo "Test des fonctions apres patch :"
bash -c '
source /usr/local/bin/cryoss-health.sh 2>/dev/null || true
' || true

# Test manuel ssh
echo ""
echo "Test SSH habyss@RPi2 :"
if ssh -i /root/.ssh/cryoss_rpi2 -o BatchMode=yes -o StrictHostKeyChecking=no \
     -o ConnectTimeout=3 habyss@10.42.0.2 "echo SHELL_OK" 2>/dev/null | grep -q SHELL_OK; then
    echo "  OK : shell accessible sur RPi2"
else
    echo "  WARN : acces shell echoue (la cle est peut-etre mal configuree)"
fi

echo ""
echo "Verification : lance maintenant le watchdog a la main"
echo "  sudo /usr/local/bin/cryoss-health.sh alert"
echo "Puis regarde les logs"
echo "  sudo tail -20 /var/log/cryoss-health.log"
