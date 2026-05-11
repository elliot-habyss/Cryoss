#!/bin/bash
# =============================================================================
#  CRYOSS - Patch emails HTML
#
#  Deploie la librairie /usr/local/lib/cryoss-email.sh (templates HTML partages)
#  puis patche cryoss-backup.sh pour utiliser l'email HTML au lieu du texte brut.
#
#  Lancer sur RPi1 ET RPi2 (la lib est utile aux deux).
#  Sur RPi1 : patche cryoss-backup.sh (email OK/ECHEC).
#  Sur RPi2 : patche cryoss-health.sh (rapport quotidien/hebdo).
#
#  Usage : sudo bash /tmp/patch_email_html.sh
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Etape 1 : Installer la librairie email partagee
# -----------------------------------------------------------------------------
echo "[1/3] Installation de /usr/local/lib/cryoss-email.sh"
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
echo "  OK : /usr/local/lib/cryoss-email.sh installe"

# -----------------------------------------------------------------------------
# Etape 2 : Detecter le role (rpi1 ou rpi2) et patcher le script approprie
# -----------------------------------------------------------------------------
ROLE="unknown"
if [[ -f /usr/local/bin/cryoss-backup.sh ]]; then
    ROLE="rpi1"
elif [[ -f /usr/local/bin/cryoss-health.sh ]] && ip addr show 2>/dev/null | grep -q "10.42.0.2"; then
    ROLE="rpi2"
fi
echo "[2/3] Role detecte : $ROLE"

# -----------------------------------------------------------------------------
# Etape 3 : Patch cryoss-backup.sh (RPi1) ou cryoss-health.sh (RPi2)
# -----------------------------------------------------------------------------
if [[ "$ROLE" == "rpi1" ]]; then
    TARGET="/usr/local/bin/cryoss-backup.sh"
    BAK="$TARGET.bak-$(date +%s)"
    cp "$TARGET" "$BAK"
    echo "[3/3] Patch $TARGET (backup: $BAK)"

    python3 - "$TARGET" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Ajouter le source de la lib juste apres le set -uo pipefail (si pas deja fait)
if '/usr/local/lib/cryoss-email.sh' not in content:
    marker = 'LOG="/var/log/cryoss-backup.log"'
    insert = '''LOG="/var/log/cryoss-backup.log"
HOSTNAME_VAL="$(hostname 2>/dev/null || echo cryoss1)"

# Sourcer la librairie email HTML
if [[ -f /usr/local/lib/cryoss-email.sh ]]; then
    # shellcheck source=/usr/local/lib/cryoss-email.sh
    source /usr/local/lib/cryoss-email.sh
fi'''
    content = content.replace(marker, insert, 1)
    print("  source lib ajoute")

# Remplacer toute la fonction send_email() par la version HTML
old_pattern = re.compile(
    r'# ── Email.*?─+\nsend_email\(\) \{.*?^\}',
    re.DOTALL | re.MULTILINE
)

new_func = r'''# -- Email HTML (utilise /usr/local/lib/cryoss-email.sh, fallback plain) ------
send_email() {
    local status="$1"
    local total_err=$(( ERR_C1 + ERR_C2 + ERR_C3 ))
    local subject

    # Badges d'etat par chemin
    local c1_badge c2_badge c3_badge c3_label
    if declare -F badge &>/dev/null; then
        (( ERR_C1 == 0 )) && c1_badge=$(badge "OK" ok) || c1_badge=$(badge "ERREUR" crit)
        (( ERR_C2 == 0 )) && c2_badge=$(badge "OK" ok) || c2_badge=$(badge "ERREUR" crit)
        if [[ "$ENABLE_SFTP" != "yes" ]]; then
            c3_badge=$(badge "DESACTIVE" info); c3_label="C3 (SFTP distant)"
        elif (( ERR_C3 == 0 )); then
            c3_badge=$(badge "OK" ok); c3_label="C3 (SFTP distant + versioning)"
        else
            c3_badge=$(badge "ERREUR" crit); c3_label="C3 (SFTP distant)"
        fi
    fi

    local src_count src_size restore_status manifest_path
    src_count=$(find "$SRC_DIR" -maxdepth 1 -type f ! -name "__CRYOSS_SENTINEL__" 2>/dev/null | wc -l)
    src_size=$(du -sh "$SRC_DIR" 2>/dev/null | awk '{print $1}')
    restore_status="${RESTORE_OK:-non teste}"
    manifest_path="${MANIFEST:-N/A}"

    if [[ "$status" == "success" ]]; then
        subject="[Cryoss $CLIENT_NAME] Sauvegarde OK - $BACKUP_DATE"
    else
        subject="[Cryoss $CLIENT_NAME] ECHEC sauvegarde ($total_err err) - $BACKUP_DATE"
    fi

    if declare -F send_email_wrapped &>/dev/null; then
        local body=""
        local accent="ok"
        [[ "$status" != "success" ]] && accent="crit"

        if [[ "$status" == "success" ]]; then
            body+=$(alert_banner "Sauvegarde triple chiffrement reussie - $BACKUP_DATE" "ok")
        else
            body+=$(alert_banner "Echec sauvegarde - $total_err erreur(s) detectee(s)" "crit")
        fi

        body+=$(section_open "CHEMINS DE SAUVEGARDE")
        body+=$(mrow "C1 (RAID local)" "XSalsa20-Poly1305" "$c1_badge")
        body+=$(mrow "C2 (RPi2 interco)" "XSalsa20-Poly1305" "$c2_badge")
        body+=$(mrow "$c3_label" "XSalsa20-Poly1305" "$c3_badge")
        body+=$(section_close)

        body+=$(section_open "DONNEES SAUVEGARDEES")
        body+=$(mrow "Fichiers source" "$src_count fichier(s)" "")
        body+=$(mrow "Taille source" "${src_size:-N/A}" "")
        local restore_badge=""
        [[ "$restore_status" == "ok" ]] && restore_badge=$(badge "OK" ok) || restore_badge=$(badge "$restore_status" warn)
        body+=$(mrow "Test restauration" "$restore_status" "$restore_badge")
        body+=$(section_close)

        body+=$(section_open "SECURITE")
        body+=$(mrow "Chiffrement" "XSalsa20-Poly1305 (AEAD)" "")
        body+=$(mrow "Noms fichiers" "AES-256-EME (obfusques)" "")
        body+=$(mrow "Cles independantes" "3 cles distinctes par chemin" "$(badge "ISOLE" info)")
        body+=$(section_close)

        if [[ "$status" != "success" ]]; then
            body+=$(section_open "LOGS A CONSULTER")
            body+=$(code_block "Principal : $LOG
C1 rclone : /var/log/rclone_cryoss_c1.log
C2 rclone : /var/log/rclone_cryoss_c2.log
C3 rclone : /var/log/rclone_cryoss_c3.log
Manifeste : $manifest_path")
            body+=$(section_close)
        fi

        send_email_wrapped "$subject" "${subject#*] }" "$body" "$accent" \
            && return 0 || log "WARN: envoi HTML echoue - fallback plain"
    fi

    # Fallback plain text
    local plain_body="Sauvegarde $BACKUP_DATE - status: $status
C1: $( (( ERR_C1 )) && echo ERREUR || echo OK )
C2: $( (( ERR_C2 )) && echo ERREUR || echo OK )
C3: $( [[ "$ENABLE_SFTP" != "yes" ]] && echo DESACTIVE || { (( ERR_C3 )) && echo ERREUR || echo OK; } )
Logs: $LOG"
    for DEST in "$EMAIL_TO" "$EMAIL_TO_2"; do
        [[ -z "$DEST" ]] && continue
        { echo "To: $DEST"; echo "Subject: $subject"; echo ""; echo "$plain_body"; } \
            | msmtp "$DEST" 2>/dev/null || log "WARN: email vers $DEST echoue"
    done
}'''

new_content, n = old_pattern.subn(new_func, content, count=1)
if n == 1:
    content = new_content
    print("  send_email() remplace par version HTML")
else:
    print("  ATTENTION : send_email() non trouve (deja patche ?)")

with open(path, 'w') as f:
    f.write(content)
PYEOF

    # Verification syntaxe
    if bash -n "$TARGET"; then
        echo "  OK : syntaxe valide apres patch"
    else
        echo "  ERREUR : syntaxe invalide, restauration du backup"
        cp "$BAK" "$TARGET"
        exit 1
    fi

    echo ""
    echo "Patch applique. Pour tester :"
    echo "  sudo /usr/local/bin/cryoss-backup.sh"
    echo ""
    echo "Le prochain backup OK/ECHEC arrivera en HTML."

elif [[ "$ROLE" == "rpi2" ]]; then
    TARGET="/usr/local/bin/cryoss-health.sh"
    BAK="$TARGET.bak-$(date +%s)"
    cp "$TARGET" "$BAK"
    echo "[3/3] Patch $TARGET (backup: $BAK)"

    python3 - "$TARGET" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Ajouter le source de la lib juste apres les declarations initiales
if '/usr/local/lib/cryoss-email.sh' not in content:
    marker = 'ANOMALIES=()\nREPORT=""\n'
    insert = '''ANOMALIES=()
REPORT=""
HOSTNAME_VAL="$HOSTNAME_SHORT"
EMAIL_TO_2=""

# Sourcer la lib email HTML
if [[ -f /usr/local/lib/cryoss-email.sh ]]; then
    # shellcheck source=/usr/local/lib/cryoss-email.sh
    source /usr/local/lib/cryoss-email.sh
fi
'''
    content = content.replace(marker, insert, 1)
    print("  source lib ajoute")

# Remplacer send_mail() par une version qui tente HTML avec fallback plain
old_send = re.compile(
    r'send_mail\(\) \{\n\s+local subject="\$1" body="\$2"\n\s+\{ echo "To: \$EMAIL_TO".*?\}\n',
    re.DOTALL
)
new_send = '''send_mail() {
    local subject="$1" body="$2"
    # Tentative HTML si la lib est chargee
    if declare -F send_email_wrapped &>/dev/null; then
        local accent="ok"
        [[ ${#ANOMALIES[@]} -gt 0 ]] && accent="warn"
        local banner html_body anomalies_section=""
        if [[ ${#ANOMALIES[@]} -eq 0 ]]; then
            banner=$(alert_banner "Monitoring RPi2 - tout est sain" "ok")
        else
            banner=$(alert_banner "Monitoring RPi2 - ${#ANOMALIES[@]} anomalie(s)" "warn")
            anomalies_section+=$(section_open "ANOMALIES")
            for A in "${ANOMALIES[@]}"; do
                anomalies_section+=$(mrow "$A" "" "$(badge "A TRAITER" warn)")
            done
            anomalies_section+=$(section_close)
        fi
        local ctx_section
        ctx_section=$(section_open "CONTEXTE")
        ctx_section+=$(mrow "Hote" "$HOSTNAME_SHORT" "")
        ctx_section+=$(mrow "Mode" "$MODE" "")
        ctx_section+=$(mrow "Liaison RPi1" "$RPI1_IP" "")
        ctx_section+=$(mrow "Repertoire reception" "$RPI2_DIR" "")
        ctx_section+=$(section_close)
        local logs_section
        logs_section=$(section_open "RAPPORT COMPLET")
        logs_section+=$(code_block "$(echo -e "$body" | head -100)")
        logs_section+=$(section_close)
        html_body="${banner}${anomalies_section}${ctx_section}${logs_section}"
        local title
        case "$MODE" in
            daily)  title="RPi2 - Rapport quotidien" ;;
            weekly) title="RPi2 - Rapport hebdomadaire" ;;
            *)      title="RPi2 - Rapport $MODE" ;;
        esac
        send_email_wrapped "$subject" "$title" "$html_body" "$accent" && return 0
    fi
    # Fallback plain text
    { echo "To: $EMAIL_TO"; echo "Subject: $subject"; echo ""; echo -e "$body"; } \\
        | msmtp "$EMAIL_TO" 2>/dev/null || log "WARN: email non envoye"
}
'''
new_content, n = old_send.subn(new_send, content, count=1)
if n == 1:
    content = new_content
    print("  send_mail() remplace par version HTML")

# Remplacer send_alerts par version HTML
old_alerts = re.compile(
    r'send_alerts\(\) \{.*?\n\}',
    re.DOTALL
)
new_alerts = '''send_alerts() {
    [[ ${#ANOMALIES[@]} -eq 0 ]] && return
    local subject="[ALERTE RPi2 $CLIENT_NAME] ${#ANOMALIES[@]} anomalie(s) - $DATE_LABEL"
    if declare -F send_email_wrapped &>/dev/null; then
        local banner html_body
        banner=$(alert_banner "${#ANOMALIES[@]} anomalie(s) detectee(s) sur le RPi2" "crit")
        html_body="$banner"
        html_body+=$(section_open "ANOMALIES DETECTEES")
        for A in "${ANOMALIES[@]}"; do
            html_body+=$(mrow "$A" "" "$(badge "A TRAITER" warn)")
        done
        html_body+=$(section_close)
        html_body+=$(section_open "CONTEXTE")
        html_body+=$(mrow "Hote" "$HOSTNAME_SHORT" "")
        html_body+=$(mrow "Mode" "$MODE" "")
        html_body+=$(mrow "Liaison RPi1" "$RPI1_IP" "")
        html_body+=$(section_close)
        send_email_wrapped "$subject" "Alerte RPi2" "$html_body" "crit" \\
            && { log "Alerte envoyee (HTML)"; return 0; }
    fi
    local body="ALERTE CRYOSS RPi2 [$CLIENT_NAME] - $DATE_LABEL\\n\\n${#ANOMALIES[@]} anomalie(s) :\\n\\n"
    for A in "${ANOMALIES[@]}"; do body="${body}  >> $A\\n"; done
    { echo "To: $EMAIL_TO"; echo "Subject: $subject"; echo ""; echo -e "$body"; } \\
        | msmtp "$EMAIL_TO" 2>/dev/null || log "WARN: alerte non envoyee"
    log "Alerte envoyee (plain)"
}'''
new_content, n = old_alerts.subn(new_alerts, content, count=1)
if n == 1:
    content = new_content
    print("  send_alerts() remplace par version HTML")

with open(path, 'w') as f:
    f.write(content)
PYEOF

    if bash -n "$TARGET"; then
        echo "  OK : syntaxe valide apres patch"
    else
        echo "  ERREUR : syntaxe invalide, restauration du backup"
        cp "$BAK" "$TARGET"
        exit 1
    fi

    echo ""
    echo "Patch applique. Pour tester :"
    echo "  sudo /usr/local/bin/cryoss-health.sh daily"

else
    echo "[3/3] Role inconnu - seule la lib a ete installee"
    echo "  Les scripts a patcher n'ont pas ete trouves :"
    echo "  RPi1 : /usr/local/bin/cryoss-backup.sh"
    echo "  RPi2 : /usr/local/bin/cryoss-health.sh"
fi

echo ""
echo "==> Termine."
