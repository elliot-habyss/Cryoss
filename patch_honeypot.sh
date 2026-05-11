#!/bin/bash
# =============================================================================
#  CRYOSS - Patch honeypot
#
#  Corrige 3 problemes :
#  1) inotifywait suivait le fichier sentinel par son inode.
#     Quand un editeur (vim, sed -i, etc.) remplace le fichier, l'inode change
#     et le watch est perdu -> aucun event detecte jusqu'au timeout (60s).
#     Fix : surveiller le REPERTOIRE parent avec filtre sur le nom.
#
#  2) Aucune action automatique en cas de detection. Maintenant :
#     - Stop immediat de smbd (empeche l'ecriture par le ransomware en cours)
#     - Flag persistent /var/lib/cryoss/compromised (consomme par le heartbeat)
#     - Declenchement immediat d'un heartbeat (au lieu d'attendre 5 min)
#
#  3) Cooldown email de 5 min conserve (anti-flood), mais le flag compromised
#     est pousse vers Analyss immediatement (pas de cooldown).
#
#  Usage : sudo bash /tmp/patch_honeypot.sh
# =============================================================================
set -euo pipefail

TARGET="/usr/local/bin/cryoss-honeypot.sh"
BAK="$TARGET.bak-$(date +%s)"

if [[ ! -f "$TARGET" ]]; then
    echo "ERREUR : $TARGET introuvable"
    exit 1
fi

cp "$TARGET" "$BAK"
echo "Backup : $BAK"

# Extraire les variables du fichier actuel (EMAIL_TO, CLIENT_NAME, etc.)
SCRIPT_VARS=$(grep -E '^(EMAIL_TO|EMAIL_TO_2|CLIENT_NAME|SENTINEL|COOLDOWN)' "$TARGET" | head -10 || true)

# Reecrire le script avec la nouvelle logique
cat > "$TARGET" << 'HONEY_EOF'
#!/bin/bash
# =============================================================================
#  CRYOSS - Honeypot inotify (v2)
#  Surveillance du fichier sentinel dans /etc/sauvegarde — alerte + action.
# =============================================================================
set -uo pipefail

SENTINEL="/etc/sauvegarde/__CRYOSS_SENTINEL__"
SENTINEL_DIR="/etc/sauvegarde"
SENTINEL_NAME="__CRYOSS_SENTINEL__"
LOG="/var/log/cryoss-honeypot.log"
EMAIL_TO="__EMAIL_TO__"
EMAIL_TO_2="__EMAIL_TO_2__"
CLIENT_NAME="__CLIENT_NAME__"
COOLDOWN_FILE="/var/lib/cryoss/honeypot-alert.ts"
COMPROMISED_FLAG="/var/lib/cryoss/compromised"
COOLDOWN=300   # 5min entre deux emails (anti-flood)
AUTO_STOP_SAMBA=1   # 1 = stop smbd automatiquement sur detection

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

# -----------------------------------------------------------------------------
# Alerte email HTML (avec cooldown)
# -----------------------------------------------------------------------------
send_alert_html() {
    local event="$1" smb_ctx="$2" action_taken="$3"
    local ts; ts=$(date '+%d/%m/%Y a %H:%M:%S')

    # Cooldown pour eviter le spam email
    if [[ -f "$COOLDOWN_FILE" ]]; then
        local age=$(( $(date +%s) - $(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0) ))
        if (( age < COOLDOWN )); then
            log "Cooldown actif ($age s < $COOLDOWN s) - email supprime"
            return 0
        fi
    fi
    date +%s > "$COOLDOWN_FILE"

    for DEST in "$EMAIL_TO" "$EMAIL_TO_2"; do
        [[ -z "$DEST" ]] && continue
        {
            echo "To: $DEST"
            echo "Subject: [Cryoss $CLIENT_NAME] HONEYPOT DECLENCHE - Activite ransomware"
            echo "MIME-Version: 1.0"
            echo "Content-Type: text/html; charset=UTF-8"
            echo ""
            cat << HTML_EOF
<!DOCTYPE html><html><head><meta charset="UTF-8"></head>
<body style="margin:0;padding:0;background:#f8f9fa;font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#f8f9fa;">
<tr><td align="center" style="padding:28px 12px;">
<table width="620" cellpadding="0" cellspacing="0" style="max-width:620px;background:#ffffff;border-radius:8px;border:1px solid #e2e8f0;overflow:hidden;">
  <tr><td style="background:#ffffff;padding:24px 36px;border-bottom:2px solid #dc2626;">
    <table width="100%"><tr>
      <td>
        <span style="font-size:20px;font-weight:800;color:#1e293b;letter-spacing:1px;">CRYOSS</span>
        <p style="margin:4px 0 0;color:#dc2626;font-size:11px;letter-spacing:2px;text-transform:uppercase;">Alerte Securite</p>
      </td>
      <td align="right">
        <span style="background:#fef2f2;border:1px solid #dc2626;color:#dc2626;padding:5px 13px;border-radius:16px;font-size:12px;font-weight:700;">${CLIENT_NAME}</span>
      </td>
    </tr></table>
  </td></tr>
  <tr><td style="padding:24px 36px 8px;">
    <h1 style="margin:0;color:#dc2626;font-size:20px;font-weight:700;">&#9888; HONEYPOT DECLENCHE</h1>
    <p style="margin:6px 0 0;color:#64748b;font-size:12px;">${ts} &bull; $(hostname -s)</p>
  </td></tr>
  <tr><td style="padding:8px 36px 24px;">
    <div style="background:#fef2f2;border-left:4px solid #dc2626;padding:14px 16px;border-radius:0 6px 6px 0;margin-bottom:20px;">
      <p style="margin:0;color:#dc2626;font-weight:700;font-size:14px;">Le fichier leurre a ete accede ou modifie</p>
      <p style="margin:4px 0 0;color:#64748b;font-size:12px;">Activite de type ransomware detectee sur le partage SMB</p>
    </div>
    ${action_taken:+<div style="background:#fffbeb;border-left:4px solid #d97706;padding:14px 16px;border-radius:0 6px 6px 0;margin-bottom:20px;"><p style="margin:0;color:#d97706;font-weight:700;font-size:14px;">Action automatique : ${action_taken}</p></div>}
    <table width="100%" cellpadding="6" cellspacing="0" style="background:#f8f9fa;border-radius:6px;margin-bottom:16px;border:1px solid #e2e8f0;">
      <tr><td style="color:#64748b;font-size:12px;width:40%;">Evenement inotify</td>
          <td style="color:#1e293b;font-size:12px;font-weight:600;">${event}</td></tr>
      <tr><td style="color:#64748b;font-size:12px;">Fichier leurre</td>
          <td style="color:#1e293b;font-size:12px;">${SENTINEL}</td></tr>
    </table>
    <p style="color:#dc2626;font-size:11px;font-weight:700;letter-spacing:1.5px;text-transform:uppercase;border-bottom:1px solid #e2e8f0;padding-bottom:6px;margin:0 0 10px;">Connexions SMB actives</p>
    <pre style="font-size:11px;color:#1e293b;background:#f1f5f9;padding:10px;border-radius:5px;margin:0 0 16px;white-space:pre-wrap;border:1px solid #e2e8f0;">${smb_ctx}</pre>
    <p style="color:#059669;font-size:11px;font-weight:700;letter-spacing:1.5px;text-transform:uppercase;border-bottom:1px solid #e2e8f0;padding-bottom:6px;margin:0 0 10px;">Procedure d'intervention</p>
    <p style="color:#1e293b;font-size:13px;margin:0 0 6px;">1. Identifier et isoler le poste client (couper le reseau)</p>
    <p style="color:#1e293b;font-size:13px;margin:0 0 6px;">2. Lister les versions SFTP disponibles : <code>rclone lsd cryoss-versions:</code></p>
    <p style="color:#1e293b;font-size:13px;margin:0 0 6px;">3. Restaurer la derniere version saine : <code>rclone sync cryoss-versions:YYYY-MM-DD /etc/sauvegarde --checksum</code></p>
    <p style="color:#1e293b;font-size:13px;margin:0;">4. Redemarrer Samba : <code>systemctl start smbd</code></p>
  </td></tr>
  <tr><td style="background:#f8f9fa;padding:14px 36px;border-top:1px solid #e2e8f0;">
    <table width="100%"><tr>
      <td style="color:#94a3b8;font-size:11px;">Cryoss &copy; Analyss &mdash; Alerte automatique</td>
      <td align="right"><a href="https://analyss.fr" style="color:#2563eb;font-size:11px;text-decoration:none;">analyss.fr</a></td>
    </tr></table>
  </td></tr>
</table></td></tr></table>
</body></html>
HTML_EOF
        } | msmtp "$DEST" 2>/dev/null || log "WARN: email vers $DEST echoue"
    done
    log "Email alerte envoye"
}

# -----------------------------------------------------------------------------
# Action automatique : stop Samba + flag compromis + heartbeat immediat
# -----------------------------------------------------------------------------
trigger_incident() {
    local event="$1"
    local action_taken=""

    # 1. Flag persistent (lu par cryoss-heartbeat.sh)
    mkdir -p "$(dirname "$COMPROMISED_FLAG")"
    {
        echo "timestamp=$(date -Iseconds)"
        echo "event=$event"
        echo "sentinel=$SENTINEL"
    } > "$COMPROMISED_FLAG"
    log "Flag compromis cree : $COMPROMISED_FLAG"

    # 2. Stop Samba pour empecher l'ecriture (si activee)
    if [[ "$AUTO_STOP_SAMBA" == "1" ]] && systemctl is-active --quiet smbd 2>/dev/null; then
        systemctl stop smbd 2>/dev/null && {
            log "Samba arrete (empeche nouvelles ecritures)"
            action_taken="Samba arrete"
        } || log "WARN: arret Samba echoue"
    fi

    # 3. Forcer un heartbeat immediat vers Analyss
    if [[ -x /usr/local/bin/cryoss-heartbeat.sh ]]; then
        /usr/local/bin/cryoss-heartbeat.sh 2>/dev/null &
        log "Heartbeat d'escalade declenche (background)"
    fi

    echo "$action_taken"
}

# -----------------------------------------------------------------------------
# Recreer le sentinel s'il a ete supprime
# -----------------------------------------------------------------------------
recreate_sentinel() {
    [[ -f "$SENTINEL" ]] && return 0
    cat > "$SENTINEL" << 'SF'
[BackupConfig]
Version=3.2
Profile=Enterprise
LastSync=2024-01-15T02:00:00Z
RetentionDays=30
CompressionLevel=6
EncryptionMode=AES256
SF
    chmod 644 "$SENTINEL"
    chown root:samba-share "$SENTINEL" 2>/dev/null || true
    log "Sentinel recree"
}

# -----------------------------------------------------------------------------
# Main loop - surveillance du REPERTOIRE (robuste aux changements d'inode)
# -----------------------------------------------------------------------------
log "=== Honeypot demarre (v2) — surveillance repertoire: $SENTINEL_DIR ==="
log "Fichier cible: $SENTINEL_NAME"

while true; do
    recreate_sentinel

    # Surveiller le repertoire avec filtre sur le nom du fichier
    # -> robuste aux editeurs qui creent un nouveau fichier (vim, sed -i, etc.)
    EVENT_INFO=$(inotifywait -q \
        -e modify,delete,close_write,attrib,moved_to,moved_from,create \
        --format '%e %f' --timeout 60 \
        "$SENTINEL_DIR" 2>/dev/null || echo "TIMEOUT")

    [[ "$EVENT_INFO" == "TIMEOUT" ]] && continue
    [[ -z "$EVENT_INFO" ]] && continue

    # Parser : "EVENTS filename" -> on filtre par nom
    EVENT_TYPE=$(echo "$EVENT_INFO" | awk '{print $1}')
    EVENT_FILE=$(echo "$EVENT_INFO" | awk '{print $2}')

    # Ignorer les events sur les autres fichiers (fichiers client normaux)
    [[ "$EVENT_FILE" != "$SENTINEL_NAME" ]] && continue

    log "ALERTE : evenement '$EVENT_TYPE' sur $EVENT_FILE"

    # Contexte SMB
    SMB_CTX=$(smbstatus --brief 2>/dev/null \
        | grep -v "^[[:space:]]*$\|^Samba\|^PID\|^---" \
        | head -20 \
        || echo "smbstatus non disponible")

    # Action automatique + notification
    ACTION=$(trigger_incident "$EVENT_TYPE")
    send_alert_html "$EVENT_TYPE" "$SMB_CTX" "$ACTION"

    sleep 5
done
HONEY_EOF

# Re-injecter les vraies valeurs (EMAIL_TO, CLIENT_NAME) depuis les backups
# en lisant le fichier backup original
if echo "$SCRIPT_VARS" | grep -q 'EMAIL_TO='; then
    OLD_EMAIL=$(echo "$SCRIPT_VARS" | grep -m1 '^EMAIL_TO=' | sed 's/EMAIL_TO="//;s/"$//')
    OLD_EMAIL2=$(echo "$SCRIPT_VARS" | grep -m1 '^EMAIL_TO_2=' | sed 's/EMAIL_TO_2="//;s/"$//' || echo "")
    OLD_CLIENT=$(echo "$SCRIPT_VARS" | grep -m1 '^CLIENT_NAME=' | sed 's/CLIENT_NAME="//;s/"$//')

    sed -i \
        -e "s|__EMAIL_TO__|${OLD_EMAIL}|g" \
        -e "s|__EMAIL_TO_2__|${OLD_EMAIL2}|g" \
        -e "s|__CLIENT_NAME__|${OLD_CLIENT}|g" \
        "$TARGET"
    echo "Variables restaurees : EMAIL_TO=$OLD_EMAIL, CLIENT=$OLD_CLIENT"
else
    echo "WARN : impossible de recuperer EMAIL_TO/CLIENT_NAME du fichier original"
    echo "       Edite manuellement $TARGET avant de demarrer le service"
fi

chmod 700 "$TARGET"
chown root:root "$TARGET"

# Verifier syntaxe
if bash -n "$TARGET"; then
    echo "OK : syntaxe valide"
else
    echo "ERREUR : syntaxe invalide - restauration"
    cp "$BAK" "$TARGET"
    exit 1
fi

# Purge du cooldown pour test immediat
rm -f /var/lib/cryoss/honeypot-alert.ts
rm -f /var/lib/cryoss/compromised

# Redemarrer le service
systemctl restart cryoss-honeypot.service
sleep 2

if systemctl is-active --quiet cryoss-honeypot.service; then
    echo "OK : service cryoss-honeypot redemarre"
else
    echo "ERREUR : service ne demarre pas"
    systemctl status cryoss-honeypot.service --no-pager
    exit 1
fi

echo ""
echo "Test : modifie le sentinel et regarde les logs"
echo "  echo 'test-$(date +%s)' | sudo tee -a /etc/sauvegarde/__CRYOSS_SENTINEL__"
echo "  sudo tail -20 /var/log/cryoss-honeypot.log"
echo ""
echo "ATTENTION : si le test se declenche, Samba sera arrete automatiquement."
echo "Pour le redemarrer : sudo systemctl start smbd"
echo ""
echo "Pour desactiver l'arret auto de Samba : editer AUTO_STOP_SAMBA=0 dans"
echo "  $TARGET puis 'sudo systemctl restart cryoss-honeypot.service'"
