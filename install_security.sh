#!/bin/bash
# =============================================================================
#  CRYOSS - Hardening anti-ransomware / anti-malware  (v2)
#  install_security.sh  —  à exécuter APRÈS install_rpi1.sh
#
#  Contraintes prises en compte :
#    - Carte SD 128 Go sur RPi → 0 octet de surcoût stockage local
#    - Données client jusqu'à 20 To → snapshots locaux impossibles
#    - Types de fichiers arbitraires (Veeam, BDD, bureautique, etc.)
#    - SFTP distant chez le client avec capacité disponible
#
#  Architecture de protection :
#
#  Couche 1 : rclone --backup-dir   — versioning côté SFTP client
#             Les fichiers écrasés/supprimés sont déplacés dans
#             _versions/YYYY-MM-DD/ AVANT d'être remplacés.
#             0 octet sur le RPi. Compatible tout type de fichier.
#             Rétention configurable + purge automatique.
#
#  Couche 2 : Honeypot inotify      — fichier leurre dans /etc/sauvegarde
#             Un ransomware qui parcourt le partage SMB touchera ce fichier.
#             Alerte email HTML immédiate avec contexte SMB + procédure
#             de restauration depuis les versions SFTP.
#
#  Couche 3 : chattr +a             — /etc/encrypted en append-only
#             Impossible de modifier ou supprimer une archive existante,
#             même root. Nettoyage 30j via script dédié uniquement.
#
#  Couche 4 : AppArmor              — confinement smbd + cryoss-backup.sh
#             smbd (enforce) : écriture limitée à /etc/sauvegarde.
#             cryoss-backup (complain→enforce) : lecture /etc/sauvegarde,
#             écriture /etc/encrypted uniquement. Clés SSH/AES inaccessibles.
#
#  Usage : sudo bash install_security.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step() { echo -e "\n${BOLD}${BLUE}━━━ $1 ━━━${NC}"; }

[[ $EUID -ne 0 ]] && err "Exécuter en root : sudo bash $0"

# Prérequis : install_rpi1.sh doit avoir été exécuté
[[ -f /usr/local/bin/cryoss-backup.sh ]]      || err "cryoss-backup.sh introuvable — exécutez install_rpi1.sh d'abord"
[[ -d /etc/sauvegarde ]]                       || err "/etc/sauvegarde introuvable — exécutez install_rpi1.sh d'abord"
# rclone.conf requis seulement si SFTP activé dans install_rpi1.sh
SFTP_CONFIGURED="no"
if [[ -f /root/.config/rclone/rclone.conf ]] &&    grep -q "\[cryoss-sftp\]" /root/.config/rclone/rclone.conf 2>/dev/null; then
    SFTP_CONFIGURED="yes"
fi

# Chemin du script de backup — utilisé dans plusieurs couches
BACKUP_SCRIPT="/usr/local/bin/cryoss-backup.sh"

# =============================================================================
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║     CRYOSS - Hardening anti-ransomware v2              ║"
echo "║     4 couches — 0 surcoût stockage sur RPi               ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Récupérer les infos depuis la config existante
CLIENT_NAME=$(grep "server string" /etc/samba/smb.conf 2>/dev/null \
    | grep -oP '\[.*?\]' | tr -d '[]' | head -1 || echo "CRYOSS")
SFTP_HOST=$(grep "^host = " /root/.config/rclone/rclone.conf 2>/dev/null \
    | head -1 | awk '{print $3}' || echo "sftp-inconnu")
SFTP_REMOTE_DIR=$(grep "^remote = " /root/.config/rclone/rclone.conf 2>/dev/null \
    | head -1 | sed 's|remote = cryoss-sftp:||' || echo "cryoss")
RCLONE_PASS=$(grep "^password = " /root/.config/rclone/rclone.conf 2>/dev/null \
    | head -1 | awk '{print $3}' || echo "")
RCLONE_SALT=$(grep "^password2 = " /root/.config/rclone/rclone.conf 2>/dev/null \
    | head -1 | awk '{print $3}' || echo "")

step "Collecte"
read -rp "  Email alerte 1                                      : " EMAIL_TO
read -rp "  Email alerte 2 (Entrée = ignorer)                   : " EMAIL_TO_2
EMAIL_TO_2="${EMAIL_TO_2:-}"

VERSIONS_SFTP_DIR="${SFTP_REMOTE_DIR}/_versions"
RETENTION_DAYS=30
if [[ "$SFTP_CONFIGURED" == "yes" ]]; then
    info "SFTP détecté : $SFTP_HOST — répertoire distant : $SFTP_REMOTE_DIR"
    read -rp "  Répertoire versioning SFTP [défaut: ${SFTP_REMOTE_DIR}/_versions] : " VER_DIR_INPUT
    VERSIONS_SFTP_DIR="${VER_DIR_INPUT:-${SFTP_REMOTE_DIR}/_versions}"
    echo ""
    warn "Le versioning SFTP stocke les fichiers modifiés/supprimés avant"
    warn "chaque sync rclone. Coût SFTP = uniquement les fichiers qui changent."
    read -rp "  Rétention des versions [défaut: 30 jours]           : " RETENTION_INPUT
    RETENTION_DAYS="${RETENTION_INPUT:-30}"
else
    warn "SFTP non activé dans install_rpi1.sh — couche 1 (versioning) sera ignorée."
    warn "Les couches 2 (honeypot), 3 (chattr) et 4 (AppArmor) seront installées."
fi

echo ""
echo -e "${BOLD}=== Récapitulatif ===${NC}"
echo "  Client             : $CLIENT_NAME"
echo "  Email(s) alerte    : $EMAIL_TO${EMAIL_TO_2:+ / $EMAIL_TO_2}"
if [[ "$SFTP_CONFIGURED" == "yes" ]]; then
    echo "  Versioning SFTP    : $SFTP_HOST:$VERSIONS_SFTP_DIR"
    echo "  Rétention          : $RETENTION_DAYS jours"
else
    echo "  Versioning SFTP    : DESACTIVE (SFTP non configuré)"
fi
echo ""
read -rp "Confirmer ? [o/N] : " CONFIRM
[[ "${CONFIRM,,}" != "o" ]] && err "Annulé."

mkdir -p /var/lib/cryoss

# =============================================================================
step "Paquets requis"

apt-get update -qq
apt-get install -y inotify-tools apparmor apparmor-utils \
    apparmor-profiles apparmor-profiles-extra attr 2>/dev/null
ok "inotify-tools, apparmor, attr installés"

if ! systemctl is-active --quiet apparmor 2>/dev/null; then
    systemctl enable apparmor
    systemctl start apparmor
fi
ok "AppArmor actif"

# =============================================================================
# ══════════════════════════════════════════════════════════════════════════════
#  COUCHE 1 — VERSIONING SFTP  (rclone --backup-dir)
# ══════════════════════════════════════════════════════════════════════════════
#
#  Sans --backup-dir (comportement actuel) :
#    rclone sync écrase les fichiers modifiés côté SFTP sans garder l'ancien.
#    Si un ransomware chiffre /etc/sauvegarde, le prochain sync propage
#    les fichiers chiffrés et détruit la dernière copie saine.
#
#  Avec --backup-dir :
#    Avant de remplacer un fichier, rclone le déplace dans
#    cryoss-versions:YYYY-MM-DD/. La version chiffrée (par le ransomware)
#    arrive en destination, mais l'ancienne version saine est préservée.
#
#  Structure SFTP après plusieurs jours :
#    cryoss-crypt:          ← version courante (chiffrée rclone)
#    cryoss-versions:
#      └─ 2025-06-14/        ← fichiers remplacés le 14
#      └─ 2025-06-15/        ← fichiers remplacés le 15
#      └─ 2025-06-16/        ← ...
#
#  Restauration en cas de ransomware :
#    rclone sync cryoss-versions:2025-06-14 /etc/sauvegarde --checksum
#
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$SFTP_CONFIGURED" != "yes" ]]; then
    info "Couche 1 (versioning SFTP) ignorée — SFTP non configuré"
else
step "Couche 1 : Versioning SFTP (rclone --backup-dir)"

# ── 1a. Ajouter le remote cryoss-versions dans rclone.conf ─────────────────
# Même chiffrement que cryoss-crypt, pointant vers le sous-répertoire versions
RCLONE_CONF="/root/.config/rclone/rclone.conf"

if ! grep -q "\[cryoss-versions\]" "$RCLONE_CONF"; then
    cat >> "$RCLONE_CONF" << RCLONE_EOF

[cryoss-versions]
type = crypt
remote = cryoss-sftp:${VERSIONS_SFTP_DIR}
filename_encryption = standard
directory_name_encryption = true
password = ${RCLONE_PASS}
password2 = ${RCLONE_SALT}
RCLONE_EOF
    ok "Remote 'cryoss-versions' ajouté dans rclone.conf"
else
    warn "Remote 'cryoss-versions' déjà présent dans rclone.conf"
fi

# ── 1b. Script de purge des versions expirées ─────────────────────────────────
cat > /usr/local/bin/cryoss-versions-purge.sh << PURGE_EOF
#!/bin/bash
# =============================================================================
#  CRYOSS - Purge des versions SFTP expirées
#  Supprime côté SFTP les répertoires datés (YYYY-MM-DD) plus vieux
#  que RETENTION_DAYS jours. Appelé automatiquement après chaque sync.
# =============================================================================
set -uo pipefail

RETENTION_DAYS=${RETENTION_DAYS}
LOG="/var/log/rclone_cryoss.log"
log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] [purge-versions] \$1" | tee -a "\$LOG"; }

CUTOFF=\$(date -d "\${RETENTION_DAYS} days ago" '+%Y-%m-%d' 2>/dev/null \
    || date -v-"\${RETENTION_DAYS}d" '+%Y-%m-%d')   # fallback macOS

log "Purge versions SFTP antérieures au \$CUTOFF (rétention \${RETENTION_DAYS}j)"
PURGED=0

while IFS= read -r LINE; do
    DIR_DATE=\$(echo "\$LINE" | grep -oP '\d{4}-\d{2}-\d{2}' | head -1 || true)
    [[ -z "\$DIR_DATE" ]] && continue
    if [[ "\$DIR_DATE" < "\$CUTOFF" ]]; then
        log "  Suppression : \$DIR_DATE"
        rclone purge "cryoss-versions:\$DIR_DATE" \
            --contimeout 30s --timeout 60s 2>/dev/null \
            && (( PURGED++ )) || log "  WARN : purge \$DIR_DATE échouée (non bloquant)"
    fi
done < <(rclone lsd cryoss-versions: --contimeout 30s --timeout 30s 2>/dev/null || true)

log "Purge terminée : \$PURGED répertoire(s) supprimé(s)"
PURGE_EOF

chmod 700 /usr/local/bin/cryoss-versions-purge.sh
chown root:root /usr/local/bin/cryoss-versions-purge.sh
ok "Script purge versions créé (rétention : ${RETENTION_DAYS}j)"

# ── 1c. Patcher cryoss-backup.sh : ajouter --backup-dir au rclone sync ────────
BACKUP_SCRIPT="/usr/local/bin/cryoss-backup.sh"

if ! grep -q "\-\-backup-dir" "$BACKUP_SCRIPT"; then
    python3 - "$BACKUP_SCRIPT" << 'PY_EOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Localiser et remplacer le bloc rclone sync
old = '''if rclone sync "$SRC_DIR" cryoss-crypt: \\
    --checksum \\
    --transfers 2 \\
    --retries 3 \\
    --low-level-retries 5 \\
    --contimeout 30s \\
    --timeout 60s \\
    --log-file "$RCLONE_LOG" \\
    --log-level INFO \\
    2>/dev/null
RC_RCLONE=$?'''

new = '''# Versioning : les fichiers remplacés sont déplacés dans _versions/DATE/
# avant d'être écrasés — 0 octet sur le RPi, restauration possible à tout moment
BACKUP_DATE=$(date +%Y-%m-%d)
if rclone sync "$SRC_DIR" cryoss-crypt: \\
    --backup-dir "cryoss-versions:${BACKUP_DATE}" \\
    --checksum \\
    --transfers 2 \\
    --retries 3 \\
    --low-level-retries 5 \\
    --contimeout 30s \\
    --timeout 60s \\
    --log-file "$RCLONE_LOG" \\
    --log-level INFO \\
    2>/dev/null
RC_RCLONE=$?'''

if old in content:
    content = content.replace(old, new, 1)
    # Ajouter la purge juste après le log SFTP OK
    old_ok = '    log "  [SFTP OK] $SYNCED fichier(s) transfere(s) ou a jour"'
    new_ok = old_ok + '\n    /usr/local/bin/cryoss-versions-purge.sh 2>/dev/null || true'
    content = content.replace(old_ok, new_ok, 1)
    with open(path, 'w') as f:
        f.write(content)
    print("OK: patch --backup-dir appliqué")
else:
    print("WARN: bloc rclone sync non trouvé exactement — patch non appliqué")
    print("      Ajoutez manuellement --backup-dir \"cryoss-versions:\$(date +%Y-%m-%d)\"")
    sys.exit(1)
PY_EOF
    ok "cryoss-backup.sh patché : rclone sync avec --backup-dir versionné"
else
    warn "cryoss-backup.sh : --backup-dir déjà présent"
fi

# ── 1d. Patcher aussi le service sftp-sync (syncs intermédiaires 6h) ──────────
SFTP_SVC="/etc/systemd/system/cryoss-sftp-sync.service"
if [[ -f "$SFTP_SVC" ]] && ! grep -q "backup-dir" "$SFTP_SVC"; then
    # Insérer --backup-dir dans la ligne ExecStart du service
    sed -i "s|rclone sync /etc/sauvegarde cryoss-crypt:|rclone sync /etc/sauvegarde cryoss-crypt: --backup-dir \"cryoss-versions:\$(date +%Y-%m-%d)\"|" \
        "$SFTP_SVC" 2>/dev/null || true
    systemctl daemon-reload
    ok "Service cryoss-sftp-sync patché avec --backup-dir"
fi

# ── 1e. Créer le répertoire de versioning côté SFTP ───────────────────────────
info "Création du répertoire de versioning côté SFTP..."
if rclone mkdir "cryoss-sftp:${VERSIONS_SFTP_DIR}" \
    --contimeout 10s --timeout 10s 2>/dev/null; then
    ok "Répertoire SFTP ${VERSIONS_SFTP_DIR} créé"
else
    warn "Impossible de créer ${VERSIONS_SFTP_DIR} côté SFTP — vérifiez la connectivité"
    warn "Commande manuelle : rclone mkdir cryoss-sftp:${VERSIONS_SFTP_DIR}"
fi

ok "Couche 1 : versioning SFTP actif — 0 octet sur RPi, rétention ${RETENTION_DAYS}j"

# =============================================================================
# ══════════════════════════════════════════════════════════════════════════════
#  COUCHE 2 — HONEYPOT INOTIFY
# ══════════════════════════════════════════════════════════════════════════════
#  Un fichier leurre discret vit dans /etc/sauvegarde.
#  Un service systemd permanent surveille via inotifywait tout événement
#  sur ce fichier (modify, delete, close_write, move).
#
#  Pourquoi ça marche contre les ransomwares :
#    Les ransomwares énumèrent tous les fichiers du partage et les chiffrent
#    séquentiellement. Le leurre sera touché très tôt dans cette enumération.
#    L'alerte est envoyée avant que la majorité des vrais fichiers soient
#    chiffrés, ce qui donne le temps d'isoler le poste client.
#
#  Le leurre est exclu des sauvegardes (pas de faux positifs dans les archives).
# ══════════════════════════════════════════════════════════════════════════════
fi  # fin couche 1 SFTP
step "Couche 2 : Honeypot inotify — détection accès temps réel"

SENTINEL="/etc/sauvegarde/__CRYOSS_SENTINEL__"

# Contenu réaliste (ressemble à un fichier de config applicatif)
cat > "$SENTINEL" << 'SENT_EOF'
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
chown root:samba-share "$SENTINEL"
ok "Fichier leurre créé : $SENTINEL"

# ── Script honeypot ───────────────────────────────────────────────────────────
cat > /usr/local/bin/cryoss-honeypot.sh << HONEY_EOF
#!/bin/bash
# =============================================================================
#  CRYOSS - Honeypot inotify
# =============================================================================
set -uo pipefail

SENTINEL="/etc/sauvegarde/__CRYOSS_SENTINEL__"
LOG="/var/log/cryoss-honeypot.log"
EMAIL_TO="${EMAIL_TO}"
EMAIL_TO_2="${EMAIL_TO_2}"
CLIENT_NAME="${CLIENT_NAME}"
COOLDOWN_FILE="/var/lib/cryoss/honeypot-alert.ts"
COOLDOWN=300   # 5min entre deux alertes (anti-flood si boucle ransomware)

log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" | tee -a "\$LOG"; }

send_alert_html() {
    local event="\$1" smb_ctx="\$2"
    local ts; ts=\$(date '+%d/%m/%Y à %H:%M:%S')

    # Cooldown
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
            echo "MIME-Version: 1.0"
            echo "Content-Type: text/html; charset=UTF-8"
            echo ""
            cat << 'HTML_OPEN'
<!DOCTYPE html><html><head><meta charset="UTF-8"></head>
<body style="margin:0;padding:0;background:#f8f9fa;font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#f8f9fa;">
<tr><td align="center" style="padding:28px 12px;">
<table width="620" cellpadding="0" cellspacing="0"
  style="max-width:620px;background:#ffffff;border-radius:8px;border:1px solid #e2e8f0;overflow:hidden;">
HTML_OPEN
            # Header rouge alerte
            cat << HTML_HEADER
  <tr><td style="background:#ffffff;padding:24px 36px;border-bottom:2px solid #dc2626;">
    <table width="100%" cellpadding="0" cellspacing="0"><tr>
      <td>
        <span style="font-size:20px;font-weight:800;color:#1e293b;letter-spacing:1px;">CRYOSS</span>
        <p style="margin:4px 0 0;color:#dc2626;font-size:11px;letter-spacing:2px;text-transform:uppercase;">
          Alerte S&eacute;curit&eacute;</p>
      </td>
      <td align="right">
        <span style="background:#fef2f2;border:1px solid #dc2626;color:#dc2626;
          padding:5px 13px;border-radius:16px;font-size:12px;font-weight:700;">\${CLIENT_NAME}</span>
      </td>
    </tr></table>
  </td></tr>
HTML_HEADER
            # Titre
            cat << HTML_TITLE
  <tr><td style="padding:24px 36px 8px;">
    <h1 style="margin:0;color:#dc2626;font-size:20px;font-weight:700;">
      &#9888;&nbsp; HONEYPOT D&Eacute;CLENCH&Eacute;</h1>
    <p style="margin:6px 0 0;color:#64748b;font-size:12px;">\${ts} &bull; \$(hostname -s)</p>
  </td></tr>
HTML_TITLE
            # Corps
            cat << HTML_BODY
  <tr><td style="padding:8px 36px 24px;">
    <div style="background:#fef2f2;border-left:4px solid #dc2626;
      padding:14px 16px;border-radius:0 6px 6px 0;margin-bottom:20px;">
      <p style="margin:0;color:#dc2626;font-weight:700;font-size:14px;">
        Le fichier leurre a &eacute;t&eacute; acc&eacute;d&eacute; ou modifi&eacute;</p>
      <p style="margin:4px 0 0;color:#64748b;font-size:12px;">
        Activit&eacute; de type ransomware d&eacute;tect&eacute;e sur le partage SMB</p>
    </div>
    <table width="100%" cellpadding="6" cellspacing="0"
      style="background:#f8f9fa;border-radius:6px;margin-bottom:16px;border:1px solid #e2e8f0;">
      <tr>
        <td style="color:#64748b;font-size:12px;width:40%;">&Eacute;v&eacute;nement inotify</td>
        <td style="color:#1e293b;font-size:12px;font-weight:600;">\${event}</td>
      </tr>
      <tr>
        <td style="color:#64748b;font-size:12px;">Fichier leurre</td>
        <td style="color:#1e293b;font-size:12px;">\${SENTINEL}</td>
      </tr>
    </table>
    <p style="color:#dc2626;font-size:11px;font-weight:700;letter-spacing:1.5px;
      text-transform:uppercase;border-bottom:1px solid #e2e8f0;padding-bottom:6px;margin:0 0 10px;">
      Connexions SMB actives</p>
    <pre style="font-size:11px;color:#1e293b;background:#f1f5f9;
      padding:10px;border-radius:5px;margin:0 0 16px;white-space:pre-wrap;border:1px solid #e2e8f0;">\${smb_ctx}</pre>
    <p style="color:#059669;font-size:11px;font-weight:700;letter-spacing:1.5px;
      text-transform:uppercase;border-bottom:1px solid #e2e8f0;padding-bottom:6px;margin:0 0 10px;">
      Proc&eacute;dure de r&eacute;ponse &agrave; incident</p>
    <p style="color:#1e293b;font-size:13px;margin:0 0 6px;">
      1. Identifier et isoler le poste client (couper le r&eacute;seau)</p>
    <p style="color:#1e293b;font-size:13px;margin:0 0 6px;">
      2. Lister les versions saines disponibles c&ocirc;t&eacute; SFTP :</p>
    <pre style="font-size:11px;color:#1e293b;background:#f1f5f9;
      padding:8px;border-radius:5px;margin:0 0 6px;border:1px solid #e2e8f0;">rclone lsd cryoss-versions:</pre>
    <p style="color:#1e293b;font-size:13px;margin:0 0 6px;">
      3. Restaurer la derni&egrave;re version saine :</p>
    <pre style="font-size:11px;color:#1e293b;background:#f1f5f9;
      padding:8px;border-radius:5px;margin:0 0 6px;border:1px solid #e2e8f0;">rclone sync cryoss-versions:YYYY-MM-DD /etc/sauvegarde --checksum</pre>
    <p style="color:#1e293b;font-size:13px;margin:0;">
      4. Relancer le backup : <code style="color:#2563eb;">systemctl start cryoss-backup.service</code></p>
  </td></tr>
HTML_BODY
            # Footer
            cat << 'HTML_FOOT'
  <tr><td style="background:#f8f9fa;padding:14px 36px;border-top:1px solid #e2e8f0;">
    <table width="100%" cellpadding="0" cellspacing="0"><tr>
      <td style="color:#94a3b8;font-size:11px;">Cryoss &copy; <a href="https://analyss.fr" style="color:#2563eb;text-decoration:none;">Analyss</a> &mdash; Alerte automatique</td>
      <td align="right">
        <a href="https://analyss.fr" style="color:#2563eb;font-size:11px;text-decoration:none;">
          analyss.fr</a></td>
    </tr></table>
  </td></tr>
</table></td></tr></table>
</body></html>
HTML_FOOT
        } | msmtp "\$DEST" 2>/dev/null || true
    done
}

recreate_sentinel() {
    [[ -f "\$SENTINEL" ]] && return 0
    cat > "\$SENTINEL" << 'SF'
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
    log "Sentinel recréé"
}

log "=== Honeypot démarré — surveillance : \$SENTINEL ==="

while true; do
    recreate_sentinel

    # Attente événement avec timeout 60s (pour récupérer proprement si fichier absent)
    EVENT=\$(inotifywait -q \
        -e modify,delete,moved_from,close_write,attrib \
        --format '%e' --timeout 60 \
        "\$SENTINEL" 2>/dev/null || echo "TIMEOUT")

    [[ "\$EVENT" == "TIMEOUT" ]] && continue

    log "ALERTE : événement '\$EVENT' sur fichier leurre"

    # Contexte SMB au moment de l'événement
    SMB_CTX=\$(smbstatus --brief 2>/dev/null \
        | grep -v "^\s*\$\|^Samba\|^PID\|^---" \
        | head -20 \
        || echo "smbstatus non disponible")

    send_alert_html "\$EVENT" "\$SMB_CTX"
    sleep 5
done
HONEY_EOF

chmod 700 /usr/local/bin/cryoss-honeypot.sh
chown root:root /usr/local/bin/cryoss-honeypot.sh

# Service systemd permanent
cat > /etc/systemd/system/cryoss-honeypot.service << SVC_EOF
[Unit]
Description=CRYOSS - Honeypot inotify anti-ransomware [${CLIENT_NAME}]
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
ok "Service honeypot actif (permanent, redémarrage automatique)"

# Exclure le sentinel du backup CBC/KEY1, CBC/KEY2 et du sync rclone
if ! grep -q "CRYOSS_SENTINEL" "$BACKUP_SCRIPT"; then
    python3 - "$BACKUP_SCRIPT" << 'PY_EOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()
old = 'FILES=("$SRC_DIR"/*)'
new = ('# Exclure le fichier honeypot des sauvegardes\n'
       'FILES=()\n'
       'for _f in "$SRC_DIR"/*; do\n'
       '    [[ "$(basename "$_f")" == "__CRYOSS_SENTINEL__" ]] && continue\n'
       '    FILES+=("$_f")\n'
       'done')
if old in content and '__CRYOSS_SENTINEL__' not in content:
    content = content.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(content)
    print("OK: exclusion honeypot patchée")
PY_EOF
fi

# Exclure aussi du sync rclone via --exclude
if ! grep -q "exclude.*SENTINEL" "$BACKUP_SCRIPT" 2>/dev/null; then
    sed -i 's|--log-level INFO \\|--log-level INFO \\\n    --exclude "__CRYOSS_SENTINEL__" \\|' \
        "$BACKUP_SCRIPT" 2>/dev/null || true
fi
ok "Sentinel exclu des 3 chemins de sauvegarde"
ok "Couche 2 : honeypot inotify actif — alerte HTML immédiate avec procédure restauration"

# =============================================================================
# ══════════════════════════════════════════════════════════════════════════════
#  COUCHE 3 — CHATTR +A  (/etc/encrypted en append-only)
# ══════════════════════════════════════════════════════════════════════════════
#  chattr +a = append-only : on peut créer de nouveaux fichiers dans le
#  répertoire, mais impossible de modifier ou supprimer les existants,
#  même en root, sans retirer +a explicitement.
#
#  Impact : un malware qui compromet root ne peut pas supprimer les archives
#  CBC ni modifier leur contenu pour les corrompre silencieusement.
#
#  Le nettoyage des fichiers > 30j est délégué à cryoss-cleanup.sh qui
#  retire +a, supprime, repose +a dans la même transaction.
# ══════════════════════════════════════════════════════════════════════════════
step "Couche 3 : chattr +a — /etc/encrypted en append-only"

chattr +a /etc/encrypted 2>/dev/null \
    && ok "/etc/encrypted : append-only activé (chattr +a)" \
    || warn "chattr +a échoué — filesystem ext4/xfs requis avec support attributs étendus"

cat > /usr/local/bin/cryoss-cleanup.sh << 'CLEAN_EOF'
#!/bin/bash
# =============================================================================
#  CRYOSS - Nettoyage CBC > 30j  (seul script autorisé à toucher chattr +a)
# =============================================================================
set -euo pipefail
LOG="/var/log/cryoss-backup.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [cleanup] $1" | tee -a "$LOG"; }

log "Nettoyage /etc/encrypted — retrait temporaire chattr +a"
chattr -a /etc/encrypted 2>/dev/null \
    || { log "ERREUR : chattr -a impossible"; exit 1; }

DELETED=$(find /etc/encrypted -name "*.cbc.enc" -mtime +30 -print -delete 2>/dev/null \
    | wc -l || echo 0)
log "  $DELETED fichier(s) supprimé(s)"

chattr +a /etc/encrypted 2>/dev/null \
    || log "WARN : chattr +a non reposé — action manuelle requise"
log "chattr +a reposé sur /etc/encrypted"
CLEAN_EOF

chmod 700 /usr/local/bin/cryoss-cleanup.sh
chown root:root /usr/local/bin/cryoss-cleanup.sh

# Remplacer le find/delete inline dans cryoss-backup.sh par cryoss-cleanup.sh
if ! grep -q "cryoss-cleanup" "$BACKUP_SCRIPT"; then
    python3 - "$BACKUP_SCRIPT" << 'PY_EOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    lines = f.readlines()
out = []
for line in lines:
    if 'find "$LOCAL_ENC"' in line and 'mtime +30' in line and '-delete' in line:
        out.append('/usr/local/bin/cryoss-cleanup.sh\n')
    elif out and out[-1] == '/usr/local/bin/cryoss-cleanup.sh\n' \
            and ('&& log' in line or '|| log' in line):
        pass  # supprimer la ligne de log inline (cleanup.sh a son propre log)
    else:
        out.append(line)
with open(path, 'w') as f:
    f.writelines(out)
print("OK: nettoyage remplacé par cryoss-cleanup.sh")
PY_EOF
    ok "cryoss-backup.sh patché : nettoyage via cryoss-cleanup.sh"
else
    warn "Patch cleanup déjà présent"
fi
ok "Couche 3 : chattr +a actif — archives locales protégées en append-only"

# =============================================================================
# ══════════════════════════════════════════════════════════════════════════════
#  COUCHE 4 — APPARMOR
# ══════════════════════════════════════════════════════════════════════════════
#  smbd (ENFORCE) :
#    - Écriture autorisée uniquement dans /etc/sauvegarde
#    - /etc/key, /root/.ssh, /usr/local/bin : accès interdit
#    - Même si smbd est exploité via une vulnérabilité, les clés AES/SSH
#      et les scripts CRYOSS ne sont pas accessibles
#
#  cryoss-backup.sh (COMPLAIN → ENFORCE après validation) :
#    - Lecture source : /etc/sauvegarde uniquement
#    - Écriture destination : /etc/encrypted uniquement
#    - Clés : lecture seule sur /etc/key
#    - Impossible de modifier les autres scripts CRYOSS
# ══════════════════════════════════════════════════════════════════════════════
step "Couche 4 : AppArmor — confinement smbd + cryoss-backup"

# ── Profil smbd ───────────────────────────────────────────────────────────────
cat > /etc/apparmor.d/usr.sbin.smbd << 'AA_SMBD'
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

    # Samba binaires et libs (ARM + x86)
    /usr/sbin/smbd                          mr,
    /usr/lib/x86_64-linux-gnu/samba/**      mr,
    /usr/lib/aarch64-linux-gnu/samba/**     mr,
    /usr/lib/arm-linux-gnueabihf/samba/**   mr,
    /usr/lib/*/samba/**                     mr,

    # État et config Samba
    /etc/samba/**                           r,
    /var/lib/samba/**                       rw,
    /var/cache/samba/**                     rw,
    /run/samba/**                           rw,
    /tmp/**                                 rw,
    /var/log/samba/**                       rw,

    # ── Partages autorisés ────────────────────────
    /etc/sauvegarde/                        rw,
    /etc/sauvegarde/**                      rw,
    /etc/encrypted/                         r,
    /etc/encrypted/**                       r,

    # Système minimal
    /proc/sys/kernel/hostname               r,
    /proc/sys/net/**                        r,
    /proc/*/net/**                          r,
    /sys/class/net/**                       r,
    /dev/urandom                            r,
    /dev/random                             r,
    /dev/null                               rw,

    # ── Interdictions explicites ──────────────────
    deny /etc/key/**                        rwx,
    deny /root/**                           rwx,
    deny /usr/local/bin/**                  rwx,
    deny /home/**                           rwx,
    deny /etc/ssh/**                        rwx,
    deny /etc/sudoers                       rwx,
    deny /etc/crontab                       rwx,
}
AA_SMBD

# ── Profil cryoss-backup.sh ───────────────────────────────────────────────────
cat > /etc/apparmor.d/usr.local.bin.cryoss-backup << 'AA_BACKUP'
#include <tunables/global>

profile cryoss-backup /usr/local/bin/cryoss-backup.sh {
    #include <abstractions/base>
    #include <abstractions/bash>

    # Script principal et sous-scripts autorisés
    /usr/local/bin/cryoss-backup.sh             r,
    /usr/local/bin/cryoss-cleanup.sh          rx,
    /usr/local/bin/cryoss-versions-purge.sh   rx,

    # Binaires nécessaires
    /bin/bash                                   ix,
    /usr/bin/openssl                            ix,
    /usr/bin/ssh                                ix,
    /usr/bin/find                               ix,
    /usr/bin/date                               ix,
    /usr/bin/basename                           ix,
    /usr/bin/du                                 ix,
    /usr/bin/rclone                             ix,
    /usr/bin/msmtp                              ix,
    /usr/bin/wc                                 ix,
    /usr/bin/grep                               ix,
    /usr/bin/stat                               ix,
    /usr/bin/rm                                 ix,
    /usr/bin/python3*                           ix,
    /usr/bin/tee                                ix,

    # Source — lecture seule
    /etc/sauvegarde/                            r,
    /etc/sauvegarde/**                          r,

    # Destination — écriture autorisée
    /etc/encrypted/                             rw,
    /etc/encrypted/**                           rw,

    # Clés — lecture seule, jamais d'écriture
    /etc/key/.key1conf                          r,
    /etc/key/.key2conf                          r,

    # SSH vers RPi2
    /root/.ssh/cryoss_rpi2                    r,
    /root/.ssh/config                           r,
    /root/.ssh/known_hosts                      rw,

    # rclone
    /root/.config/rclone/rclone.conf            r,
    /root/.config/rclone/                       r,
    /tmp/rclone*                                rw,

    # Logs et état
    /var/log/cryoss-backup.log                  rw,
    /var/log/rclone_cryoss.log                rw,
    /var/lib/cryoss/**                        rw,

    # Système minimal
    /proc/mounts                                r,
    /proc/meminfo                               r,
    /dev/urandom                                r,
    /etc/ssl/certs/**                           r,
    /etc/msmtprc                                r,

    # ── Interdictions explicites ──────────────────
    deny /etc/passwd                            w,
    deny /etc/shadow                            rwx,
    deny /root/.ssh/authorized_keys             w,
    deny /usr/local/bin/cryoss-health.sh      w,
    deny /usr/local/bin/cryoss-honeypot.sh    w,
    deny /etc/crontab                           rwx,
    deny /etc/sudoers                           rwx,
    deny /etc/apparmor.d/**                     w,
}
AA_BACKUP

# Charger les profils
apparmor_parser -r /etc/apparmor.d/usr.sbin.smbd 2>/dev/null \
    && ok "Profil AppArmor smbd chargé" \
    || warn "Profil AppArmor smbd : erreur au chargement — vérifiez /var/log/syslog"

apparmor_parser -r /etc/apparmor.d/usr.local.bin.cryoss-backup 2>/dev/null \
    && ok "Profil AppArmor cryoss-backup chargé" \
    || warn "Profil AppArmor cryoss-backup : erreur au chargement"

# smbd en ENFORCE immédiatement
aa-enforce /etc/apparmor.d/usr.sbin.smbd 2>/dev/null \
    && ok "smbd : mode ENFORCE" \
    || warn "aa-enforce smbd échoué — restera en complain"

# cryoss-backup en COMPLAIN (surveille sans bloquer)
# → passer en enforce après avoir validé 24h de logs AppArmor sans DENIED légitimes
aa-complain /etc/apparmor.d/usr.local.bin.cryoss-backup 2>/dev/null || true

systemctl restart smbd 2>/dev/null \
    && ok "smbd redemarré avec profil AppArmor enforce" \
    || warn "Redemarrage smbd echoue"

# [A6] Timer systemd one-shot : passe automatiquement en enforce apres 24h
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
systemctl enable --now cryoss-apparmor-enforce.timer
ok "Couche 4 : AppArmor — smbd enforce, cryoss-backup complain → enforce auto dans 24h"

# =============================================================================
#  LOGROTATE
# =============================================================================
cat >> /etc/logrotate.d/cryoss << 'LR_EOF'

/var/log/cryoss-honeypot.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    create 640 root root
}
LR_EOF
ok "Logrotate honeypot configuré"

# =============================================================================
#  VÉRIFICATION SYNTAXE cryoss-backup.sh final
# =============================================================================
step "Vérification syntaxe des scripts patchés"
bash -n "$BACKUP_SCRIPT" 2>/dev/null \
    && ok "cryoss-backup.sh : syntaxe OK" \
    || warn "cryoss-backup.sh : erreur de syntaxe — vérification manuelle requise"
bash -n /usr/local/bin/cryoss-cleanup.sh 2>/dev/null && ok "cryoss-cleanup.sh : syntaxe OK"
bash -n /usr/local/bin/cryoss-versions-purge.sh 2>/dev/null && ok "cryoss-versions-purge.sh : syntaxe OK"
bash -n /usr/local/bin/cryoss-honeypot.sh 2>/dev/null && ok "cryoss-honeypot.sh : syntaxe OK"

# Test honeypot immédiat
step "Test honeypot"
info "Déclenchement du honeypot pour vérifier l'alerte email..."
touch "$SENTINEL" 2>/dev/null && sleep 3 \
    && ok "Honeypot déclenché — vérifiez la réception de l'email alerte" \
    || warn "Touch sentinel échoué"

# =============================================================================
#  RÉSUMÉ FINAL
# =============================================================================
echo -e "\n${BOLD}${GREEN}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║      CRYOSS - Hardening terminé !                      ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "${BOLD}┌─ Couche 1 : Versioning SFTP ──────────────────────────┐${NC}"
echo "  Mécanisme    : rclone sync --backup-dir"
echo "  Stockage RPi : 0 octet"
echo "  Stockage SFTP: uniquement les fichiers qui changent (delta)"
echo "  Répertoire   : $SFTP_HOST:$VERSIONS_SFTP_DIR"
echo "  Structure    : _versions/YYYY-MM-DD/ (1 dossier par jour de modif)"
echo "  Rétention    : $RETENTION_DAYS jours, purge auto après chaque sync"
echo "  Compatible   : tout type de fichier (Veeam, BDD, bureautique...)"

echo -e "${BOLD}├─ Couche 2 : Honeypot inotify ─────────────────────────┤${NC}"
echo "  Leurre       : $SENTINEL"
echo "  Service      : cryoss-honeypot (permanent, restart auto)"
echo "  Alerte       : email HTML Analyss immédiat + contexte SMB"
echo "  Anti-flood   : cooldown 5min entre deux alertes"

echo -e "${BOLD}├─ Couche 3 : chattr +a ────────────────────────────────┤${NC}"
echo "  Périmètre    : /etc/encrypted (append-only)"
echo "  Nettoyage    : /usr/local/bin/cryoss-cleanup.sh uniquement"

echo -e "${BOLD}├─ Couche 4 : AppArmor ─────────────────────────────────┤${NC}"
echo "  smbd         : ENFORCE — écriture limitée à /etc/sauvegarde"
echo "  cryoss-backup: COMPLAIN → passer en enforce après 24h :"
echo "    aa-enforce /etc/apparmor.d/usr.local.bin.cryoss-backup"

echo -e "${BOLD}├─ Procédure restauration ransomware ───────────────────┤${NC}"
echo "  1. Isoler le poste client (couper réseau)"
echo "  2. Identifier la dernière version saine :"
echo "       rclone lsd cryoss-versions:"
echo "  3. Restaurer :"
echo "       rclone sync cryoss-versions:YYYY-MM-DD /etc/sauvegarde --checksum"
echo "  4. Relancer le backup :"
echo "       systemctl start cryoss-backup.service"

echo -e "${BOLD}├─ Commandes de diagnostic ─────────────────────────────┤${NC}"
echo "  Vérifier AppArmor smbd :"
echo "    grep 'DENIED.*smbd' /var/log/syslog"
echo "  Vérifier versioning SFTP :"
echo "    rclone lsd cryoss-versions:"
echo "  Logs honeypot :"
echo "    tail -f /var/log/cryoss-honeypot.log"

echo -e "${BOLD}└───────────────────────────────────────────────────────┘${NC}"
echo
echo -e "${RED}${BOLD}⚠  Redémarrage recommandé pour qu'AppArmor soit pleinement actif.${NC}"
echo
