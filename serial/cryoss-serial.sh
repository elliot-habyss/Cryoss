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
#   - Utilisé pour dériver le port du tunnel SSH inverse (unicité)
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

get_tunnel_port() {
    # Dérive un port SSH tunnel unique à partir du serial
    # Range : 20000-29999 (10000 ports possibles = largement assez pour 50+ clients)
    #
    # Algorithme : hash du serial → modulo 10000 + 20000
    local serial="${1:-$(get_serial)}"
    local hash
    hash=$(echo -n "$serial" | sha256sum | head -c 8)
    local port=$(( 16#$hash % 10000 + 20000 ))
    echo "$port"
}

get_api_tunnel_port() {
    # Port tunnel pour l'API = tunnel_port + 10000
    # Range : 30000-39999
    local ssh_port="${1:-$(get_tunnel_port)}"
    echo $(( ssh_port + 10000 ))
}

show_info() {
    local serial=$(get_serial)
    local ssh_port=$(get_tunnel_port "$serial")
    local api_port=$(get_api_tunnel_port "$ssh_port")
    echo "━━━ Cryoss Serial Info ━━━"
    echo "  Serial     : $serial"
    echo "  SSH tunnel : port $ssh_port"
    echo "  API tunnel : port $api_port"
    echo "  File       : $SERIAL_FILE"
}

# --- Main ---
case "${1:-info}" in
    generate)  generate_serial ;;
    get)       get_serial ;;
    set)       set_serial "${2:-}" ;;
    port)      get_tunnel_port ;;
    api-port)  get_api_tunnel_port ;;
    info)      show_info ;;
    *)
        echo "Usage: $0 {generate|get|set <SN>|port|api-port|info}"
        exit 1
        ;;
esac
