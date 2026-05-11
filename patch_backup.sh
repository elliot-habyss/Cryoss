#!/bin/bash
# =============================================================================
#  CRYOSS - Patch cryoss-backup.sh en place
#
#  Corrige 3 bugs :
#   1) $RCLONE_LOG undefined dans send_email (crash set -u avant envoi email)
#   2) chattr +a bloque rclone sync C1 (rc=1) — leve/repose autour du sync
#   3) cryptcheck C2 impossible cross-host — remplace par comptage de fichiers
#
#  Usage :   sudo bash /tmp/patch_backup.sh
# =============================================================================
set -euo pipefail

BACKUP="/usr/local/bin/cryoss-backup.sh"
BACKUP_BAK="/usr/local/bin/cryoss-backup.sh.bak-$(date +%s)"

if [[ ! -f "$BACKUP" ]]; then
    echo "ERREUR : $BACKUP introuvable"
    exit 1
fi

# Sauvegarde avant patch
cp "$BACKUP" "$BACKUP_BAK"
echo "Backup de l'original : $BACKUP_BAK"

# Fix 1 : $RCLONE_LOG undefined
sed -i 's|Logs rclone : \$RCLONE_LOG|Logs rclone : /var/log/rclone_cryoss_c1.log /var/log/rclone_cryoss_c2.log|' "$BACKUP"
echo "Fix 1 applique : \$RCLONE_LOG -> chemins explicites"

# Fix 2 : chattr -a avant sync C1 (insertion avant la ligne "set +e" du premier rclone sync)
# et chattr +a apres cleanup (insertion apres la ligne "cleanup echoue")
python3 - "$BACKUP" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Insertion chattr -a avant le 1er rclone sync C1
marker_before = 'RCLONE_LOG_C1="/var/log/rclone_cryoss_c1.log"\nset +e\nrclone sync "$SRC_DIR" cryoss-c1-crypt:'
new_before = '''RCLONE_LOG_C1="/var/log/rclone_cryoss_c1.log"

# [C3] Retrait temporaire chattr +a — rclone doit pouvoir supprimer/renommer
chattr -R -a "$LOCAL_ENC" 2>/dev/null || log "  [C1 WARN] chattr -a partiel"

set +e
rclone sync "$SRC_DIR" cryoss-c1-crypt:'''

if marker_before in content and '[C3] Retrait temporaire chattr +a' not in content:
    content = content.replace(marker_before, new_before)
    print("Fix 2a applique : chattr -a avant sync C1")

# Insertion chattr +a apres cleanup, avant C2
marker_after = '''if [[ -x /usr/local/bin/cryoss-cleanup.sh ]]; then
    /usr/local/bin/cryoss-cleanup.sh 2>/dev/null || log "  [C1 WARN] cleanup echoue"
fi'''
new_after = '''if [[ -x /usr/local/bin/cryoss-cleanup.sh ]]; then
    /usr/local/bin/cryoss-cleanup.sh 2>/dev/null || log "  [C1 WARN] cleanup echoue"
fi

# Repose chattr +a apres sync C1 + cleanup
chattr -R +a "$LOCAL_ENC" 2>/dev/null || log "  [C1 WARN] chattr +a non repose"'''

if marker_after in content and 'Repose chattr +a apres sync C1' not in content:
    content = content.replace(marker_after, new_after)
    print("Fix 2b applique : chattr +a apres cleanup")

# Fix 3 : remplacer cryptcheck C2 par comptage
marker_c2 = '''if (( RC_C2 == 0 )); then
    # [I1] Verification integrite post-sync
    set +e
    rclone cryptcheck "$SRC_DIR" cryoss-c2-crypt: \\
        --exclude "__CRYOSS_SENTINEL__" \\
        --one-way 2>>"$RCLONE_LOG_C2"
    RC_CHECK=$?
    set -e
    if (( RC_CHECK == 0 )); then
        log "  [C2 OK] sync + integrite verifiee (cryptcheck pass)"
    else
        log "  [C2 WARN] sync OK mais cryptcheck echoue (rc=$RC_CHECK)"
        ERR_C2=1
    fi
else'''

new_c2 = '''if (( RC_C2 == 0 )); then
    # [I1] Verification integrite : cryptcheck impossible cross-host
    # (source plain sur RPi1, dest crypt sur RPi2 SFTP).
    # On verifie plutot que le nombre de fichiers sur RPi2 >= source.
    set +e
    SRC_COUNT=$(find "$SRC_DIR" -maxdepth 1 -type f ! -name "__CRYOSS_SENTINEL__" 2>/dev/null | wc -l)
    DST_COUNT=$(rclone size cryoss-c2-crypt: 2>/dev/null | grep -oP 'Total objects: \\K[0-9,]+' | tr -d ',')
    set -e
    DST_COUNT="${DST_COUNT:-0}"
    if [[ "$SRC_COUNT" -gt 0 ]] && [[ "$DST_COUNT" -ge "$SRC_COUNT" ]]; then
        log "  [C2 OK] sync OK — $SRC_COUNT fichier(s) source, $DST_COUNT cote RPi2"
    else
        log "  [C2 WARN] sync OK mais ecart comptage (src=$SRC_COUNT dst=$DST_COUNT)"
        ERR_C2=1
    fi
else'''

if marker_c2 in content:
    content = content.replace(marker_c2, new_c2)
    print("Fix 3 applique : cryptcheck C2 -> comptage de fichiers")
else:
    print("Fix 3 non applique (marqueur deja modifie ou absent)")

with open(path, 'w') as f:
    f.write(content)
PYEOF

# Verifier syntaxe
if bash -n "$BACKUP"; then
    echo ""
    echo "OK : $BACKUP syntaxe valide apres patch"
else
    echo ""
    echo "ERREUR : syntaxe invalide — restauration du backup"
    cp "$BACKUP_BAK" "$BACKUP"
    exit 1
fi

echo ""
echo "Patch applique avec succes. Pour tester maintenant :"
echo "  sudo /usr/local/bin/cryoss-backup.sh"
echo ""
echo "(si probleme, restaurer avec : sudo cp $BACKUP_BAK $BACKUP)"
