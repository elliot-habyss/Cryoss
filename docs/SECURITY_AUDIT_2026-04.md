# Cryoss — Audit de sécurité ciblé (2026-04-30)

Audit ciblé sur les surfaces les plus sensibles, complémentaire à
l'audit externe automatisé (`.github/workflows/security.yml`).

Périmètre : `api/cryoss-api.py`, `heartbeat/cryoss-command-runner.sh`,
`tunnel/cryoss-tunnel.sh`.

**Statut : tous les findings corrigés (2026-04-30).**

---

## Synthèse

| # | Gravité | Fichier | Sujet | Statut |
|---|---------|---------|-------|--------|
| 1 | **Élevée** | `api/cryoss-api.py` | `subprocess.run(..., shell=True)` systématique avec `f"sudo {cmd}"` | ✅ Corrigé |
| 2 | **Élevée** | `heartbeat/cryoss-command-runner.sh` | `source $CONF_FILE` ⇒ RCE si `/etc/cryoss/analyss.conf` est compromis | ✅ Corrigé |
| 3 | **Moyenne** | `api/cryoss-api.py:533` | `grep -i '{safe_q}'` — escape OK mais fragile, à refactorer en argv | ✅ Corrigé |
| 4 | **Moyenne** | `tunnel/cryoss-tunnel.sh:91-92` | `StrictHostKeyChecking=accept-new` sans afficher le fingerprint à valider | ✅ Corrigé |
| 5 | **Moyenne** | `tunnel/cryoss-tunnel.sh:99-124` | `$VPS_HOST/$VPS_USER/$VPS_PORT` injectés dans l'unit systemd sans validation | ✅ Corrigé |
| 6 | **Moyenne** | `api/cryoss-api.py:45` | `CORSMiddleware` importé jamais enregistré (dead import — bruit) | ✅ Corrigé |
| 7 | **Faible** | `api/cryoss-api.py:718` | `/healthz` sans rate-limit (acceptable car bind 127.0.0.1) | ⚪ Accepté |
| 8 | **Faible** | `heartbeat/cryoss-command-runner.sh` | Parsing JSON via `grep -oP` (whitelist sauve, mais fragile) | ✅ Corrigé |

---

## 1. `shell=True` systématique dans l'API — Élevée

**Fichier** : [cryoss-api.py:75-95](api/cryoss-api.py#L75-L95)

```python
def sh(cmd: str, timeout: int = 30) -> dict[str, Any]:
    r = subprocess.run(
        f"sudo {cmd}", shell=True, capture_output=True, ...
    )
```

**Constat** : tous les call-sites passent par `sh(f"...{var}...")` avec
interpolation. À ce jour, `var` est :
- soit hardcodé (sûr)
- soit validé par regex (`disk` lignes 347, 649)
- soit whitelisté (`name` ligne 516, `mode` ligne 378)
- soit typé `int` via `Query(ge=…, le=…)` (`lines`)

⇒ **Pas de RCE exploitable trouvée**, mais le pattern est anti-défense en profondeur. Une régression future (ex. nouveau endpoint qui oublie la regex) introduirait une RCE racine via `sudo`.

**Recommandation** :
1. Refactorer `sh()` pour accepter `list[str]` et appeler avec `shell=False`.
2. Ajouter dans `sudoers` une whitelist explicite (`Cmnd_Alias CRYOSS_CMDS = ...`)
   plutôt qu'un `NOPASSWD: ALL`.
3. Marquer `sh(cmd: str, ...)` comme `_sh_unsafe()` interne, exposer
   `sh_argv(["mdadm", "--detail", "/dev/md0"])` comme API publique.
4. Activer la règle Semgrep `python.lang.security.audit.dangerous-subprocess-use` (incluse dans `p/python`).

## 2. `source $CONF_FILE` dans command-runner — Élevée

**Fichier** : [cryoss-command-runner.sh:43-46](heartbeat/cryoss-command-runner.sh#L43-L46)

```bash
if [[ -f "$CONF_FILE" ]]; then
    source "$CONF_FILE"   # exécution arbitraire si fichier compromis
fi
```

**Constat** : `analyss.conf` est documenté `chmod 600 root:root` ([SECRETS.md](docs/ops/SECRETS.md)) — sûr **tant que le modèle de menace tient**. Mais le `source` exécute tout le contenu, pas seulement les `KEY=value`. Un attaquant qui obtient une écriture (CVE futur, mauvaise migration) obtient root immédiatement.

**Recommandation** :
```bash
# Lecture stricte clé=valeur, sans exécution
while IFS='=' read -r k v; do
    [[ "$k" =~ ^(ANALYSS_URL|ANALYSS_API_KEY|CLIENT_EMAIL)$ ]] || continue
    declare "$k=${v//\"/}"
done < "$CONF_FILE"
```
+ Vérifier `[[ $(stat -c '%U:%a' "$CONF_FILE") == "root:600" ]]` avant lecture.

## 3. Recherche dans les logs via `grep '{safe_q}'` — Moyenne

**Fichier** : [cryoss-api.py:521-534](api/cryoss-api.py#L521-L534)

L'escape `q.replace("'", "'\\''")` est correct pour bash (séquence `'\''`), mais :
- dépend de `shell=True` qui devrait disparaître (cf. finding #1)
- couplé à `grep` invoqué via shell, expose à des comportements inattendus si `q` contient des metacaractères regex (`$.*`) — fonctionnel mais peut produire des résultats trompeurs, et un opérateur peut croire que c'est sain.

**Recommandation** : passer en `subprocess.run(["grep", "-iF", q, log_path], …)` avec `-F` (fixed string) si la sémantique « recherche littérale » suffit.

## 4. Tunnel SSH — `accept-new` silencieux — Moyenne

**Fichier** : [cryoss-tunnel.sh:91-92](tunnel/cryoss-tunnel.sh#L91-L92)

```bash
ssh -o StrictHostKeyChecking=accept-new ... "$VPS_USER@$VPS_HOST" "echo ok"
```

**Constat** : TOFU sans présentation de l'empreinte au technicien.
Risque MITM lors du *premier* déploiement (faible probabilité, mais persistant — la clé reste pinnée).

**Recommandation** :
```bash
echo "Empreinte attendue du VPS (à vérifier hors-bande) :"
ssh-keyscan -t ed25519 -p "$VPS_PORT" "$VPS_HOST" 2>/dev/null | ssh-keygen -lf -
read -rp "  Empreinte correspond ? [o/N] : " OK
[[ "${OK,,}" == "o" ]] || err "Abandon"
```

## 5. Injection dans l'unit systemd du tunnel — Moyenne

**Fichier** : [cryoss-tunnel.sh:99-124](tunnel/cryoss-tunnel.sh#L99-L124)

`$VPS_HOST`, `$VPS_USER`, `$VPS_PORT` sont injectés dans un heredoc non-quoté
sans validation. L'opérateur est root, donc le risque pratique est faible
(self-pwn), mais une faute de frappe avec des caractères spéciaux peut produire
une unit malformée détectée seulement au démarrage.

**Recommandation** :
```bash
[[ "$VPS_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || err "Hostname invalide"
[[ "$VPS_PORT" =~ ^[0-9]{1,5}$ ]] || err "Port invalide"
[[ "$VPS_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || err "User invalide"
```

## 6. `CORSMiddleware` importé jamais utilisé — Moyenne

**Fichier** : [cryoss-api.py:45](api/cryoss-api.py#L45)

Pas de risque actif (CORS non activé = navigateurs bloquent), mais l'import
suggère qu'on hésite. Si quelqu'un l'active avec `allow_origins=["*"]` plus
tard, le bind localhost ne suffira plus en cas d'exposition par tunnel.

**Recommandation** : supprimer l'import, ou ajouter un commentaire explicite
`# NE PAS activer — bind localhost uniquement`.

## 7. `/healthz` non authentifié — Faible

Acceptable : bind 127.0.0.1, ne fuite ni serial ni état. À surveiller si le tunnel ouvre l'API au VPS — dans ce cas, le `/healthz` sera exposé via tunnel.

## 8. JSON parsing par `grep -oP` — Faible

Le command-runner extrait `service`, `jail`, `ip`, `log`, `lines` via regex.
Toutes les valeurs extraites passent ensuite par une whitelist `case/esac`
ou un regex strict ⇒ pas d'injection exploitable. Mais la robustesse est
faible : un JSON `{"service":"a","note":"\"; rm -rf /"}` cassera le parsing
à cause des guillemets imbriqués. ⇒ Migrer vers `jq -r '.service'` (déjà
dépendance probable du heartbeat). Sinon, valider que `python3` est
toujours installé et utiliser `python3 -c 'import json,sys; print(json.load(sys.stdin)["service"])'`.

---

## Résumé exploitabilité

À date de cet audit, **aucune vulnérabilité directement exploitable** n'a
été identifiée dans les 3 fichiers audités. Les findings étaient des
faiblesses de défense en profondeur : tout dépendait de la solidité de
chaque whitelist/regex. Une régression future était probable sans garde-fou
automatisé — d'où la mise en place du pipeline CI (cf. [SECURITY_CI.md](SECURITY_CI.md))
et la correction préventive de l'ensemble des findings.

## Détails des corrections appliquées (2026-04-30)

### #1 — `sh()` + `sh_argv()`
- `sh(cmd: str)` conserve `shell=True` mais sa docstring interdit explicitement
  toute interpolation d'entrée utilisateur. `# nosec B602` documenté.
- Nouveau `sh_argv(argv: list[str])` (`shell=False`) ajouté.
- Tous les call-sites avec entrée utilisateur (validée ou non) migrés :
  `smart`, `health`, `backup_history`, `tail_log`, `search_log`, `rpi2_smart`,
  `rpi2_logs`, plus le bloc `disks` du `/status` et tous les wrappers SSH RPi2.
- `detect_role()` : `subprocess.run(..., shell=True)` remplacé par `["ip", "addr", "show"]`.
- Le `sudo` est ajouté en tête de la liste argv côté `sh_argv` quand `use_sudo=True`.

### #2 — `source $CONF_FILE` → parser strict
- Nouvelle fonction `load_conf()` dans `cryoss-command-runner.sh` :
  - whitelist explicite des clés (`ANALYSS_URL|ANALYSS_API_KEY|CLIENT_EMAIL|SERIAL`)
  - parsing ligne par ligne, pas d'exécution shell
  - vérification permissions `root:600` avec log d'avertissement si déviation
- Une variable inconnue dans le fichier de conf est désormais loguée et ignorée,
  pas exécutée.

### #3 — `grep` argv-based
- `search_log` utilise `sh_argv(["grep", "-iF", "--", q, ...])` :
  - `-F` : recherche littérale (pas de regex), évite les comportements inattendus
  - `--` : protège contre un `q` commençant par `-`
  - `shell=False` : pas d'escape requis, pas d'injection possible
- Le `tail` est fait en Python (`splitlines()[-lines:]`) — plus de pipe shell.

### #4 — Empreinte SSH affichée à l'opérateur
- Avant la première connexion au VPS, `cryoss-tunnel.sh` :
  - récupère la clé via `ssh-keyscan -t ed25519`
  - calcule l'empreinte via `ssh-keygen -lf -`
  - l'affiche en gras et demande confirmation explicite hors-bande
  - bascule en TOFU avec confirmation séparée si la clé n'est pas joignable

### #5 — Validation des entrées tunnel
- `VPS_HOST` : regex `^[A-Za-z0-9][A-Za-z0-9.-]{0,253}$` (RFC 1123-ish)
- `VPS_USER` : regex `^[a-z_][a-z0-9_-]{0,31}$` (POSIX user)
- `VPS_PORT` : regex `^[0-9]{1,5}$` + bornes 1..65535
- Erreur immédiate (`err`) si invalide, donc le heredoc systemd ne peut plus
  recevoir de caractères de contrôle ou de guillemets.

### #6 — Imports morts retirés
- Suppression de `CORSMiddleware`, `JSONResponse`, `os`, `Enum`, `Field`.
- `asyncio` remonté en haut de fichier (était dans le corps de `verify_auth`).

### #7 — `/healthz` non authentifié
- **Décision : accepté.** Bind 127.0.0.1 + ne fuite ni serial ni état.
  Risque uniquement si le tunnel inverse expose l'API au VPS — dans ce cas,
  le VPS Analyss est de toute façon de confiance (c'est le serveur de gestion).

### #8 — JSON via `python3 -c json.loads`
- Helper `json_get` ajouté dans `cryoss-command-runner.sh`.
- 6 call-sites migrés : `restart_service`, `get_logs`, `fail2ban_jail_status`,
  `fail2ban_unban`, `fail2ban_ban` (× 2 clés chacun).
- Validation supplémentaire pour `LOG_LINES` : entier 1..1000 forcé.

## Suite

- Audit étendu à `install_security.sh` (930 lignes), `cryoss-heartbeat.sh`,
  `cryoss-email.sh`, `cryoss-serial.sh` : à planifier en passe 2.
- Tests d'intégration sur les nouveaux helpers (`sh_argv`, `load_conf`, `json_get`).
- Activation du workflow CI sur le repo et triage initial des findings remontés
  par les outils.
