#!/bin/bash
# =============================================================================
#  CRYOSS - Patch bug manifest : c{1,2,3}_status literal au lieu de ok/error
#
#  Bug : dans cryoss-backup.sh, les lignes
#    echo "  \"c1_status\": \"$(( ERR_C1 == 0 )) && echo ok || echo error\","
#  produisent dans le manifeste :
#    "c1_status": "1 && echo ok || echo error"
#  au lieu de :
#    "c1_status": "ok"
#
#  Cause : $(( ... )) = expansion arithmetique (retourne 1/0),
#          il faut $(  (( ... )) && echo ... || echo ...  ) = sous-shell.
#
#  Fix : 1) Patch /usr/local/bin/cryoss-backup.sh
#        2) Re-ecriture du manifeste courant pour qu'il soit valide
#
#  Usage : sudo bash /tmp/patch_manifest.sh
# =============================================================================
set -euo pipefail

BACKUP_SCRIPT="/usr/local/bin/cryoss-backup.sh"
BAK="$BACKUP_SCRIPT.bak-manifest-$(date +%s)"

if [[ ! -f "$BACKUP_SCRIPT" ]]; then
    echo "ERREUR : $BACKUP_SCRIPT introuvable"
    exit 1
fi

cp "$BACKUP_SCRIPT" "$BAK"
echo "Backup : $BAK"

# Patch : remplacer $(( ERR_Cx == 0 )) par $( (( ERR_Cx == 0 )) )
sed -i \
    -e 's|\\"c1_status\\": \\"\$(( ERR_C1 == 0 )) && echo ok \|\| echo error\\"|\\"c1_status\\": \\"\$( (( ERR_C1 == 0 )) \&\& echo ok \|\| echo error )\\"|' \
    -e 's|\\"c2_status\\": \\"\$(( ERR_C2 == 0 )) && echo ok \|\| echo error\\"|\\"c2_status\\": \\"\$( (( ERR_C2 == 0 )) \&\& echo ok \|\| echo error )\\"|' \
    -e 's|\\"c3_status\\": \\"\$(( ERR_C3 == 0 )) && echo ok \|\| echo error\\"|\\"c3_status\\": \\"\$( (( ERR_C3 == 0 )) \&\& echo ok \|\| echo error )\\"|' \
    "$BACKUP_SCRIPT"

# Verifier avec python pour etre sur
python3 - "$BACKUP_SCRIPT" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Pattern buggé : $(( ERR_CX == 0 )) && echo ok || echo error
# Fix : $( (( ERR_CX == 0 )) && echo ok || echo error )
old_pat = re.compile(
    r'echo "  \\"c(\d)_status\\": \\"\$\(\( ERR_C\1 == 0 \)\) && echo ok \|\| echo error\\","'
)
new_content, n = old_pat.subn(
    r'echo "  \\"c\1_status\\": \\"$( (( ERR_C\1 == 0 )) && echo ok || echo error )\\",",
    content
)
if n > 0:
    content = new_content
    with open(path, 'w') as f:
        f.write(content)
    print(f"  Fix applique : {n} ligne(s) corrigee(s)")
else:
    # Verifier si c'est deja correct
    if re.search(r'\$\( \(\( ERR_C\d == 0 \)\) && echo ok \|\| echo error \)', content):
        print("  Deja applique")
    else:
        print("  ATTENTION : pattern non trouve - verifier manuellement")
PYEOF

# Verifier syntaxe
if bash -n "$BACKUP_SCRIPT"; then
    echo "OK : syntaxe valide"
else
    echo "ERREUR : syntaxe invalide - restauration"
    cp "$BAK" "$BACKUP_SCRIPT"
    exit 1
fi

# -----------------------------------------------------------------------------
# Reparer le manifeste existant pour que le prochain heartbeat lise "ok"
# -----------------------------------------------------------------------------
MANIFEST_DIR="/var/lib/cryoss/manifests"
LATEST=$(ls -t "$MANIFEST_DIR"/manifest-*.json 2>/dev/null | head -1)

if [[ -n "$LATEST" && -f "$LATEST" ]]; then
    echo ""
    echo "Reparation du manifeste : $LATEST"
    BAK_MANIFEST="${LATEST}.bak-$(date +%s)"
    cp "$LATEST" "$BAK_MANIFEST"

    # Remplacer "1 && echo ok || echo error" par "ok" et "0 && echo ok || echo error" par "error"
    sed -i \
        -e 's|"1 && echo ok || echo error"|"ok"|g' \
        -e 's|"0 && echo ok || echo error"|"error"|g' \
        "$LATEST"

    # Valider le JSON
    if python3 -c "import json; json.load(open('$LATEST'))" 2>/dev/null; then
        echo "  OK : manifeste valide apres reparation"
        echo ""
        echo "Contenu corrige :"
        cat "$LATEST"
    else
        echo "  ERREUR : JSON invalide apres reparation - restauration"
        cp "$BAK_MANIFEST" "$LATEST"
        exit 1
    fi
fi

echo ""
echo "==> Fix applique."
echo ""
echo "Pour tester : lance un nouveau backup, le manifeste aura c1/c2/c3 corrects"
echo "  sudo /usr/local/bin/cryoss-backup.sh"
echo ""
echo "Le prochain heartbeat devrait envoyer :"
echo '  "backup": {..., "c1_status": "ok", "c2_status": "ok", "c3_status": "ok"}'
