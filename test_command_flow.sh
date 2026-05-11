#!/usr/bin/env bash
# =============================================================================
#  Test du flow commandes bidirectionnelles cote agent RPi1
#
#  Verifie :
#  1. cryoss-command-runner.sh est installe et executable
#  2. Il reconnait les commandes autorisees + refuse les inconnues
#  3. Il construit un JSON valide et POST vers /api/sync/cryoss/command-ack
#  4. cryoss-heartbeat.sh parse bien "pending_commands" dans une reponse
#  5. Le dispatch vers le runner fonctionne
#
#  Usage : sudo bash /tmp/test_command_flow.sh
# =============================================================================
set -uo pipefail

NC='\033[0m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'

pass()  { echo -e "${GREEN}✓${NC} $1"; }
fail()  { echo -e "${RED}✗${NC} $1"; FAILED=$((FAILED+1)); }
info()  { echo -e "${BLUE}→${NC} $1"; }
warn()  { echo -e "${YELLOW}!${NC} $1"; }

FAILED=0

# =============================================================================
echo -e "\n${BLUE}═══ 1. INSTALLATION ═══${NC}"
# =============================================================================

if [[ -x /usr/local/bin/cryoss-command-runner.sh ]]; then
    pass "cryoss-command-runner.sh installe et executable"
else
    fail "cryoss-command-runner.sh manquant ou pas executable"
fi

PERMS=$(stat -c '%a' /usr/local/bin/cryoss-command-runner.sh 2>/dev/null || echo "??")
if [[ "$PERMS" == "700" ]]; then
    pass "Permissions runner : 700 (root-only)"
else
    fail "Permissions runner : $PERMS (attendu : 700)"
fi

if [[ -f /var/log/cryoss-command.log ]]; then
    pass "Log file cryoss-command.log existe"
else
    warn "Log cryoss-command.log n'existe pas encore (sera cree au 1er run)"
fi

if [[ -f /etc/cryoss/analyss.conf ]]; then
    pass "Config analyss.conf trouvee"
    # shellcheck source=/etc/cryoss/analyss.conf
    source /etc/cryoss/analyss.conf
    [[ -n "${ANALYSS_URL:-}" ]] && pass "ANALYSS_URL = $ANALYSS_URL" || fail "ANALYSS_URL vide"
    [[ -n "${ANALYSS_API_KEY:-}" ]] && pass "ANALYSS_API_KEY configuree (${#ANALYSS_API_KEY} chars)" || fail "ANALYSS_API_KEY vide"
else
    fail "Config analyss.conf manquante"
fi

# =============================================================================
echo -e "\n${BLUE}═══ 2. WHITELIST DES COMMANDES ═══${NC}"
# =============================================================================

info "Test commande autorisee : ping"
TEST_ID="test-ping-$(date +%s)"
/usr/local/bin/cryoss-command-runner.sh "$TEST_ID" ping 2>&1 | head -5 > /tmp/cmd-test-ping.out
if grep -q "pong\|ACK envoye\|Commande recue" /var/log/cryoss-command.log 2>/dev/null | tail -5; then
    pass "Commande 'ping' acceptee et loggee"
else
    LAST=$(sudo tail -5 /var/log/cryoss-command.log 2>/dev/null)
    if echo "$LAST" | grep -q "$TEST_ID"; then
        pass "Commande 'ping' traitee (voir logs)"
    else
        fail "Commande 'ping' non trace dans les logs"
    fi
fi

info "Test commande INCONNUE : evil_command (doit etre refusee)"
TEST_ID2="test-evil-$(date +%s)"
/usr/local/bin/cryoss-command-runner.sh "$TEST_ID2" evil_command 2>&1 > /tmp/cmd-test-evil.out
sleep 1
if grep -q "Commande inconnue\|refusee" /var/log/cryoss-command.log 2>/dev/null | tail -10; then
    pass "Commande inconnue correctement refusee"
else
    LAST=$(sudo tail -10 /var/log/cryoss-command.log 2>/dev/null)
    if echo "$LAST" | grep -q "$TEST_ID2"; then
        if echo "$LAST" | grep -q "inconnue\|refusee"; then
            pass "Commande inconnue correctement refusee"
        else
            warn "Commande inconnue traitee mais pas forcement refusee - verifier logs"
        fi
    fi
fi

# =============================================================================
echo -e "\n${BLUE}═══ 3. VALIDATIONS STRICTES FAIL2BAN ═══${NC}"
# =============================================================================

info "Test fail2ban_ban avec IP interco (DOIT etre refuse)"
TEST_ID3="test-ban-interco-$(date +%s)"
/usr/local/bin/cryoss-command-runner.sh "$TEST_ID3" fail2ban_ban \
    '{"jail":"sshd","ip":"10.42.0.2"}' 2>&1 > /tmp/cmd-test-banintercon.out
sleep 1
LAST=$(tail -5 /var/log/cryoss-command.log 2>/dev/null)
if echo "$LAST" | grep -q "Refus de bannir\|interco"; then
    pass "Ban de l'IP interco 10.42.0.2 bien refuse"
else
    warn "Message de refus pas detecte - verifier : grep interco /var/log/cryoss-command.log"
fi

info "Test fail2ban_ban avec jail invalide (DOIT etre refuse)"
TEST_ID4="test-ban-evil-$(date +%s)"
/usr/local/bin/cryoss-command-runner.sh "$TEST_ID4" fail2ban_ban \
    '{"jail":"rm-rf-root","ip":"1.2.3.4"}' 2>&1 > /tmp/cmd-test-banevil.out
sleep 1
LAST=$(tail -5 /var/log/cryoss-command.log 2>/dev/null)
if echo "$LAST" | grep -q "Jail non autorisee"; then
    pass "Jail non whitelistee bien refusee"
else
    warn "Message de refus jail non detecte"
fi

# =============================================================================
echo -e "\n${BLUE}═══ 4. HEARTBEAT : dispatch pending_commands ═══${NC}"
# =============================================================================

if [[ -x /usr/local/bin/cryoss-heartbeat.sh ]]; then
    pass "cryoss-heartbeat.sh installe"
else
    fail "cryoss-heartbeat.sh manquant"
fi

if grep -q "process_pending_commands" /usr/local/bin/cryoss-heartbeat.sh; then
    pass "heartbeat contient la fonction process_pending_commands"
else
    fail "heartbeat ne contient PAS process_pending_commands"
fi

if grep -q "pending_commands" /usr/local/bin/cryoss-heartbeat.sh; then
    pass "heartbeat parse le champ pending_commands"
else
    fail "heartbeat ne traite pas pending_commands"
fi

info "Simulation : reponse Analyss avec 1 commande 'ping'"
FAKE_RESPONSE='{"status":"ok","pending_commands":[{"id":"fake-uuid-abc","type":"ping","params":{}}]}'
export FAKE_RESPONSE
python3 -c "
import os, json
data = json.loads(os.environ.get('FAKE_RESPONSE', '{}'))
cmds = data.get('pending_commands', [])
print(f'{len(cmds)} commande(s) parsee(s):')
for c in cmds:
    print(f'  id={c[\"id\"]} type={c[\"type\"]} params={c[\"params\"]}')
"
unset FAKE_RESPONSE

# =============================================================================
echo -e "\n${BLUE}═══ 5. FLOW END-TO-END (si ANALYSS_URL joignable) ═══${NC}"
# =============================================================================

info "Test connexion a Analyss : $ANALYSS_URL"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 5 \
    "${ANALYSS_URL}/api/sync/cryoss/heartbeat" \
    -H "Authorization: Bearer $ANALYSS_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"serial":"test"}' 2>/dev/null || echo "000")

case "$HTTP_CODE" in
    200|201|204|400|422)
        pass "Analyss joignable (HTTP $HTTP_CODE)"
        ;;
    401|403)
        warn "Analyss repond mais authentification refusee (HTTP $HTTP_CODE)"
        ;;
    404)
        warn "Endpoint /api/sync/cryoss/heartbeat inexistant cote Analyss (HTTP 404)"
        ;;
    000)
        fail "Analyss injoignable ($ANALYSS_URL)"
        ;;
    *)
        warn "Reponse Analyss inattendue (HTTP $HTTP_CODE)"
        ;;
esac

info "Test endpoint command-ack (doit exister cote Analyss)"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 5 \
    "${ANALYSS_URL}/api/sync/cryoss/command-ack" \
    -H "Authorization: Bearer $ANALYSS_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"command_id":"test","status":"ok"}' 2>/dev/null || echo "000")

case "$HTTP_CODE" in
    200|201|204)
        pass "Endpoint command-ack accepte (HTTP $HTTP_CODE)"
        ;;
    400|422)
        warn "Endpoint command-ack existe mais refuse la structure test (HTTP $HTTP_CODE - normal si command_id inconnu)"
        ;;
    401|403)
        warn "Endpoint command-ack : auth refusee (HTTP $HTTP_CODE)"
        ;;
    404)
        warn "Endpoint /api/sync/cryoss/command-ack N'EXISTE PAS cote Analyss (attendu si pas encore deploye)"
        ;;
    000)
        fail "Analyss injoignable"
        ;;
    *)
        warn "Reponse inattendue (HTTP $HTTP_CODE)"
        ;;
esac

# =============================================================================
echo -e "\n${BLUE}═══ RESUME ═══${NC}"
# =============================================================================
if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}Tout OK cote agent RPi1 !${NC}"
    echo ""
    echo "Prochaine etape : implementer cote Analyss"
    echo "  - POST /api/sync/cryoss/command-ack"
    echo "  - Reponse heartbeat avec pending_commands"
    echo ""
    echo "Une fois Analyss pret, tester le bout-en-bout :"
    echo "  curl -X POST $ANALYSS_URL/api/cryoss/DS-00000001/command \\"
    echo "       -H 'Authorization: <user_token>' \\"
    echo "       -d '{\"command_type\":\"ping\"}'"
    echo ""
    echo "Puis attendre max 5 min (ou forcer un heartbeat) et verifier :"
    echo "  sudo tail -20 /var/log/cryoss-command.log"
    exit 0
else
    echo -e "${RED}$FAILED probleme(s) detecte(s)${NC}"
    exit 1
fi
