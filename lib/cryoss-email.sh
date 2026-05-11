#!/usr/bin/env bash
# =============================================================================
#  CRYOSS - Librairie templates email HTML
#
#  Source ce fichier pour acceder aux fonctions :
#   - send_html_email "subject" "html_body"
#   - wrap_email "title" "body" "type"        (type: ok|warn|crit|info)
#   - badge "label" "type"                    (type: ok|warn|crit|info)
#   - section_open "TITRE"  / section_close
#   - mrow "label" "value" "badge_optional"
#   - alert_banner "message" "type"
#   - code_block "text"
#
#  Variables requises avant source :
#   - CLIENT_NAME   : nom du client (ex: "CRYOSS DEV")
#   - EMAIL_TO      : destinataire principal
#   - EMAIL_TO_2    : destinataire secondaire (peut etre vide)
#   - HOSTNAME_VAL  : nom de la machine (ex: cryoss1, cryoss2)
#   - LOG           : chemin log pour WARN (optionnel)
#
#  Installation : /usr/local/lib/cryoss-email.sh
# =============================================================================

# Valeurs par defaut si variables non definies dans le script appelant
: "${CLIENT_NAME:=CRYOSS}"
: "${EMAIL_TO:=}"
: "${EMAIL_TO_2:=}"
: "${HOSTNAME_VAL:=$(hostname 2>/dev/null || echo unknown)}"
: "${LOG:=/var/log/cryoss-email.log}"

# -----------------------------------------------------------------------------
# Helpers formatage date
# -----------------------------------------------------------------------------
_tshort() { date '+%d/%m/%Y %H:%M'; }

# -----------------------------------------------------------------------------
# Log (silencieux si pas configure)
# -----------------------------------------------------------------------------
_elog() {
    [[ -n "${LOG:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [email] $1" >> "$LOG" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Badges colores
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Sections
# -----------------------------------------------------------------------------
section_open() {
    echo "<table width='100%' cellpadding='0' cellspacing='0' style='margin-bottom:18px;'><tr><td style='padding-bottom:7px;border-bottom:1px solid #e2e8f0;'><span style='color:#2563eb;font-size:11px;font-weight:700;letter-spacing:1.5px;text-transform:uppercase;'>$1</span></td></tr><tr><td style='padding-top:10px;'><table width='100%' cellpadding='0' cellspacing='0'>"
}
section_close() { echo "</table></td></tr></table>"; }

# -----------------------------------------------------------------------------
# Ligne metrique dans une section
# -----------------------------------------------------------------------------
mrow() {
    echo "<tr><td style='padding:5px 0;color:#64748b;font-size:13px;width:48%;'>$1</td><td style='padding:5px 0;color:#1e293b;font-size:13px;font-weight:600;'>$2 $3</td></tr>"
}

# -----------------------------------------------------------------------------
# Banniere d'alerte (haut de page)
# type : ok | warn | crit | info
# -----------------------------------------------------------------------------
alert_banner() {
    local msg="$1" type="${2:-crit}"
    case "$type" in
        ok)
            echo "<div style='background:#f0fdf4;border-left:4px solid #059669;padding:11px 14px;border-radius:0 6px 6px 0;margin-bottom:18px;'><span style='color:#059669;font-weight:700;font-size:14px;'>&#10003; $msg</span></div>"
            ;;
        warn)
            echo "<div style='background:#fffbeb;border-left:4px solid #d97706;padding:11px 14px;border-radius:0 6px 6px 0;margin-bottom:18px;'><span style='color:#d97706;font-weight:700;font-size:14px;'>&#9888; $msg</span></div>"
            ;;
        info)
            echo "<div style='background:#eff6ff;border-left:4px solid #2563eb;padding:11px 14px;border-radius:0 6px 6px 0;margin-bottom:18px;'><span style='color:#2563eb;font-weight:700;font-size:14px;'>&#8505; $msg</span></div>"
            ;;
        crit|*)
            echo "<div style='background:#fef2f2;border-left:4px solid #dc2626;padding:11px 14px;border-radius:0 6px 6px 0;margin-bottom:18px;'><span style='color:#dc2626;font-weight:700;font-size:14px;'>&#9888; $msg</span></div>"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Bloc code preformate
# -----------------------------------------------------------------------------
code_block() {
    echo "<pre style='font-family:monospace;font-size:11px;color:#1e293b;background:#f1f5f9;padding:10px;border-radius:5px;overflow-x:auto;margin:6px 0;white-space:pre-wrap;word-break:break-all;border:1px solid #e2e8f0;'>$1</pre>"
}

# -----------------------------------------------------------------------------
# Wrapper HTML complet
# Usage : wrap_email "title" "body_html" [accent_type]
# accent_type : ok | warn | crit | info (default: info — barre bleue)
# -----------------------------------------------------------------------------
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

  <!-- Header -->
  <tr><td style="background:#ffffff;padding:24px 36px;border-bottom:2px solid ${accent_color};">
    <table width="100%" cellpadding="0" cellspacing="0"><tr>
      <td>
        <span style="font-size:20px;font-weight:800;color:#1e293b;letter-spacing:1px;">CRYOSS</span>
        <p style="margin:4px 0 0;color:#64748b;font-size:11px;letter-spacing:2px;text-transform:uppercase;">Monitoring</p>
      </td>
      <td align="right" valign="middle">
        <span style="background:#eff6ff;border:1px solid ${accent_color};color:${accent_color};padding:5px 13px;border-radius:16px;font-size:12px;font-weight:700;letter-spacing:1px;">${CLIENT_NAME}</span>
      </td>
    </tr></table>
  </td></tr>

  <!-- Titre -->
  <tr><td style="padding:24px 36px 6px;">
    <h1 style="margin:0;color:#1e293b;font-size:18px;font-weight:700;">${title}</h1>
    <p style="margin:5px 0 0;color:#64748b;font-size:12px;">$(_tshort) &nbsp;&bull;&nbsp; ${HOSTNAME_VAL}</p>
  </td></tr>

  <!-- Corps -->
  <tr><td style="padding:14px 36px 28px;">${body}</td></tr>

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

# -----------------------------------------------------------------------------
# Envoi email HTML via msmtp
# Usage : send_html_email "subject" "html_body_wrapped"
# Note : html_body_wrapped doit deja etre passe par wrap_email
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Raccourci : envoi email avec wrap automatique
# Usage : send_email_wrapped "subject" "title" "body_html" [accent]
# -----------------------------------------------------------------------------
send_email_wrapped() {
    local subject="$1" title="$2" body="$3" accent="${4:-info}"
    local full_html
    full_html=$(wrap_email "$title" "$body" "$accent")
    send_html_email "$subject" "$full_html"
}
