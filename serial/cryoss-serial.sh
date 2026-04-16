#!/bin/bash
# ===========================================================================
# Cryoss — Serial Number Generator & Manager
# ===========================================================================
# Chaque installation Cryoss possède un numéro de série unique.
#
# Format : DS-XXXXXXXX  (DS- + 8 chars hex uppercase)
# Exemple: DS-4A7F2C1E
#
# Stocké dans : /etc/cryoss/serial
# Permissions : 644 root:root (lisible par l'API et les scripts)
#
# Le serial est :
#   - Généré une seule fois à l'installation
#   - Inclus dans chaque réponse API (identification du RPi)
#   - Inclus dans les emails de rapport/alertes
#   - Affiché dans la bannière SSH
# ===========================================================================

set -euo pipefail

SERIAL_FILE="/etc/cryoss/serial"
SERIAL_DIR="/etc/cryoss"

generate_serial() {
    # Génère un serial unique : DS- + 8 hex uppercase
    # Source : /dev/urandom (CSPRNG)
    local hex
    hex=$(head -c 4 /dev/urandom | xxd -p | tr 'a-f' 'A-F')
    echo "DS-${hex}"
}

get_serial() {
    # Retourne le serial existant — erreur si pas defini
    if [[ -f "$SERIAL_FILE" ]]; then
        cat "$SERIAL_FILE"
        return 0
    fi

    echo "ERREUR: serial non defini. Lancez install_api.sh d'abord." >&2
    return 1
}

set_serial() {
    # Definit le serial (appele par install_api.sh)
    local serial="${1:-}"
    [[ -z "$serial" ]] && { echo "Usage: $0 set <SERIAL>" >&2; return 1; }
    mkdir -p "$SERIAL_DIR"
    echo "$serial" > "$SERIAL_FILE"
    chmod 644 "$SERIAL_FILE"
    echo "$serial"
}

show_info() {
    local serial=$(get_serial)
    echo "━━━ Cryoss Serial Info ━━━"
    echo "  Serial     : $serial"
    echo "  File       : $SERIAL_FILE"
}

# --- Main ---
case "${1:-info}" in
    generate)  generate_serial ;;
    get)       get_serial ;;
    set)       set_serial "${2:-}" ;;
    info)      show_info ;;
    *)
        echo "Usage: $0 {generate|get|set <SN>|info}"
        exit 1
        ;;
esac
