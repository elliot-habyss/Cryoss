#!/bin/bash
# =============================================================================
#  CRYOSS - Patch bug "493447h" (watchdog + rapport health)
#
#  Bug d'origine : repl_age_h() et rclone_age_h() retournaient
#  (date +%s - 0) / 3600 = ~493 000 heures quand :
#    - SSH vers RPi2 echoue (hostname cryoss-rpi2 non resolu)
#    - OU le dossier RPi2 est vide (jamais de replication)
#    - OU le log rclone est absent/vide
#
#  Fix : retour de "-1" comme sentinelle "pas de donnee", filtre dans le
#  watchdog pour ne PAS declencher d'alerte dans ce cas.
#
#  Cible : /usr/local/bin/cryoss-health.sh (RPi1 uniquement)
#
#  Usage : sudo bash /tmp/patch_watchdog.sh
# =============================================================================
set -euo pipefail

TARGET="/usr/local/bin/cryoss-health.sh"
BAK="$TARGET.bak-$(date +%s)"

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

# -----------------------------------------------------------------------------
# FIX 1 : rclone_age_h() - retourner -1 au lieu de 0
# -----------------------------------------------------------------------------
old_rclone = '''rclone_age_h()  {
    local ts; ts=$(grep "Elapsed time" "$LOG_RCLONE" 2>/dev/null | tail -1 | awk '{print $1,$2}' | xargs -I{} date -d "{}" +%s 2>/dev/null || true)
    ts=$(echo "$ts" | tr -cd '0-9')
    [[ -z "$ts" ]] && ts=0
    echo $(( ($(date +%s) - ts) / 3600 ))
}'''

new_rclone = '''rclone_age_h()  {
    local ts
    ts=$(grep "Elapsed time" "$LOG_RCLONE" 2>/dev/null | tail -1 | awk '{print $1,$2}' | xargs -I{} date -d "{}" +%s 2>/dev/null || true)
    ts=$(echo "$ts" | tr -cd '0-9')
    if [[ -z "$ts" || "$ts" == "0" ]]; then
        echo "-1"
        return
    fi
    echo $(( ($(date +%s) - ts) / 3600 ))
}'''

if old_rclone in content:
    content = content.replace(old_rclone, new_rclone)
    print("  Fix 1 applique : rclone_age_h() retourne -1 si pas de donnee")
elif 'echo "-1"' in content and 'rclone_age_h' in content:
    print("  Fix 1 deja applique (rclone_age_h)")

# -----------------------------------------------------------------------------
# FIX 2 : repl_age_h() - retourner -1 + utiliser 10.42.0.2 si hostname echoue
# -----------------------------------------------------------------------------
old_repl = '''repl_age_h() {
    local ts; ts=$(ssh -o BatchMode=yes -o ConnectTimeout=5 cryoss-rpi2 \\
        "find '$RPI2_DIR' -type f -printf '%T@\\n' 2>/dev/null | sort -n | tail -1" \\
        2>/dev/null | cut -d. -f1 || true)
    ts=$(echo "$ts" | tr -cd '0-9')
    [[ -z "$ts" ]] && ts=0
    echo $(( ($(date +%s) - ts) / 3600 ))
}'''

new_repl = '''repl_age_h() {
    local rpi2_host="cryoss-rpi2"
    ssh -o BatchMode=yes -o ConnectTimeout=3 "$rpi2_host" true 2>/dev/null || rpi2_host="10.42.0.2"
    local accessible
    accessible=$(ssh -o BatchMode=yes -o ConnectTimeout=3 "$rpi2_host" "echo ok" 2>/dev/null)
    if [[ "$accessible" != "ok" ]]; then
        echo "-1"
        return
    fi
    local ts
    ts=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$rpi2_host" \\
        "find '$RPI2_DIR' -type f -printf '%T@\\n' 2>/dev/null | sort -n | tail -1" \\
        2>/dev/null | cut -d. -f1 || true)
    ts=$(echo "$ts" | tr -cd '0-9')
    if [[ -z "$ts" || "$ts" == "0" ]]; then
        echo "-1"
        return
    fi
    echo $(( ($(date +%s) - ts) / 3600 ))
}'''

if old_repl in content:
    content = content.replace(old_repl, new_repl)
    print("  Fix 2 applique : repl_age_h() retourne -1 + fallback 10.42.0.2")
elif 'rpi2_host="cryoss-rpi2"' in content:
    print("  Fix 2 deja applique (repl_age_h)")

# -----------------------------------------------------------------------------
# FIX 3 : watchdog run_alert - ne pas declencher d'alerte si rh == -1
# -----------------------------------------------------------------------------
old_watchdog_repl = '''    # Réplication RPi2 silencieuse
    local rh; rh=$(repl_age_h)
    if (( rh >= REPL_HOURS )); then
        local h; h=$(section_open "RÉPLICATION RPi2 — SILENCE DÉTECTÉ")
        h+=$(mrow "Dernier fichier reçu" "il y a ${rh}h" "$(badge "RETARD" crit)")'''

new_watchdog_repl = '''    # Réplication RPi2 silencieuse (rh == -1 = pas de donnee, pas d'alerte)
    local rh; rh=$(repl_age_h)
    if (( rh == -1 )); then
        log "Replication RPi2 : pas de donnee (RPi2 injoignable ou dossier vide)"
    elif (( rh >= REPL_HOURS )); then
        local h; h=$(section_open "RÉPLICATION RPi2 — SILENCE DÉTECTÉ")
        h+=$(mrow "Dernier fichier reçu" "il y a ${rh}h" "$(badge "RETARD" crit)")'''

if old_watchdog_repl in content:
    content = content.replace(old_watchdog_repl, new_watchdog_repl)
    print("  Fix 3 applique : watchdog ignore rh == -1")
elif 'rh == -1' in content:
    print("  Fix 3 deja applique (watchdog)")

# -----------------------------------------------------------------------------
# FIX 4 : watchdog rclone_age_h aussi
# -----------------------------------------------------------------------------
old_watchdog_sftp = '''    local sh; sh=$(rclone_age_h)
    if (( sh >= SFTP_HOURS )); then'''

new_watchdog_sftp = '''    local sh; sh=$(rclone_age_h)
    if (( sh == -1 )); then
        log "Sync SFTP : pas de donnee (jamais execute ou log absent)"
    elif (( sh >= SFTP_HOURS )); then'''

if old_watchdog_sftp in content and 'sh == -1' not in content:
    content = content.replace(old_watchdog_sftp, new_watchdog_sftp)
    print("  Fix 4 applique : watchdog ignore sh == -1")

# -----------------------------------------------------------------------------
# FIX 5 : rapport daily - afficher "indisponible" au lieu de "-1h"
# -----------------------------------------------------------------------------
# rh == -1 dans le daily report : remplacer le bloc d'affichage
old_daily = '''    rh=$(repl_age_h)
    local REPL_WARN=$(( REPL_HOURS / 2 ))
    if   (( rh >= REPL_HOURS )); then rh_b=$(badge "RETARD ${rh}h" crit); has_warn=1
    elif (( rh >= REPL_WARN ));   then rh_b=$(badge "${rh}h" warn); has_warn=1
    else rh_b=$(badge "${rh}h OK" ok); fi'''

new_daily = '''    rh=$(repl_age_h)
    local REPL_WARN=$(( REPL_HOURS / 2 ))
    if   (( rh == -1 )); then rh_b=$(badge "N/A" info)
    elif (( rh >= REPL_HOURS )); then rh_b=$(badge "RETARD ${rh}h" crit); has_warn=1
    elif (( rh >= REPL_WARN ));   then rh_b=$(badge "${rh}h" warn); has_warn=1
    else rh_b=$(badge "${rh}h OK" ok); fi'''

if old_daily in content:
    content = content.replace(old_daily, new_daily)
    print("  Fix 5 applique : daily report affiche N/A si rh == -1")

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

echo ""
echo "Purge des fichiers de cooldown d'alertes (pour que l'alerte existante"
echo "puisse se relancer proprement apres le fix, au lieu d'attendre 6h)"
rm -f /var/lib/cryoss/alerts/repl_rpi2_late.ts 2>/dev/null || true
rm -f /var/lib/cryoss/alerts/sftp_sync_late.ts 2>/dev/null || true
echo "OK : cooldowns purges"

echo ""
echo "Pour tester immediatement (declencher un run du watchdog) :"
echo "  sudo /usr/local/bin/cryoss-health.sh alert"
echo ""
echo "Si RPi2 est accessible et contient des fichiers, AUCUNE alerte"
echo "de replication ne doit partir."
echo "Si RPi2 est vide ou injoignable, l'alerte bidon 493447h disparait."
