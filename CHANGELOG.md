# Changelog

Toutes les modifications notables du projet Cryoss sont documentees dans ce fichier.

Le format est base sur [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/).

---

## [2.3.0] - 2026-05-12

Consolidation : un script par Pi + script API. Suppression des patches/migrations
legacy et fold du hardening anti-ransomware dans install_rpi1.sh.

### Ajouté

- **Lib UI commune** `lib/cryoss-installer-ui.sh` (404L) : bannière, spinner,
  `cryoss_run`, `cryoss_apt_install`, resume framework complet (`cryoss_step`,
  `cryoss_done`, `cryoss_save_env`, `cryoss_load_env`, `cryoss_list_steps`,
  `cryoss_reset_*`). Sourcée par install_rpi1.sh et install_rpi2.sh.
- **install_rpi2.sh resume framework** : supporte maintenant `--resume`,
  `--from-step`, `--only-step`, `--list-steps`, `--reset` (alignement avec rpi1).
- **Steps anti-ransomware 16-19 dans install_rpi1.sh** : `16-versioning-sftp`,
  `17-honeypot`, `18-chattr-append`, `19-apparmor` (anciennement install_security.sh).
- **`tests/cryoss-test.sh`** : suite unifiée avec subcommands `install`, `runner`,
  `all` ; auto-detect RPi1/RPi2 ou override `--rpi1`/`--rpi2`.
- **`update.sh` deployé par install_api.sh** vers `/usr/local/bin/update.sh`
  pour que `apt_update_check`/`apt_upgrade` du runner trouvent le script.
- **Master key prompt dans install_api.sh** : detecte l'absence de
  `/etc/cryoss/master_key` et propose de la deposer (skippable).
- **`/etc/cryoss/config.env.example`** : template commenté avec les 4 clés
  acceptées par le runner (`CRYOSS_SHARE_ROOT`, `CRYOSS_ARCHIVE_ROOT`, etc.).

### Modifié

- **Runner `decrypt_path` v3 → v4** : param `path` → `rclone_path` (chain-relative,
  pas de prefixe FS bidon). Validation locale defense in depth (no `..`, no
  leading `/`, charset strict). Raison : c2/c3 sont SFTP-backed, leurs blobs ne
  vivent pas sur `/etc/encrypted` localement.
- **Runner `shutdown`** : `systemctl stop cryoss-watchdog.timer` avant le sleep 30s
  pour eviter qu'un fire du watchdog parasite envoie une alerte email pendant
  la fenêtre d'arret.
- **install_rpi1.sh fix `f2b_bans_today/week`** : remplacement de `grep -c ... ||
  echo "0"` par `... || true`. Ancien code produisait `"0\n0"` qui cassait
  `(( bans > 20 ))` dans le rapport hebdo.
- **install_rpi1.sh step 03-raid** : output `wipefs`/`mdadm --stop` redirigé vers
  log au lieu de polluer le stdout du terminal.
- **install_rpi1.sh step 15-master-key** : `mkdir -p /etc/cryoss` ajouté pour
  que `--only-step 15-master-key` marche standalone sans steps amont.
- **install_rpi2.sh : prompts inutiles supprimés** : INTERCO_IFACE = `eth0` fixe,
  DISK1/DISK2 = `sda`/`sdb` fixes (avec validation `-b`), RPI2_DIR =
  `/etc/encrypted/rpi1` fixe. Email peut être pré-set via env var
  `CRYOSS_R2_EMAIL_TO`.
- **install_rpi1.sh : prompt RPI2_DIR supprimé** (fixé à `/etc/encrypted/rpi1`).

### Supprimé

- `install_security.sh` (930L) — foldé dans install_rpi1.sh steps 16-19
- `test_installation.sh` + `test_command_flow.sh` — mergés dans tests/cryoss-test.sh
- `patch_backup.sh`, `patch_email_html.sh`, `patch_honeypot.sh`, `patch_manifest.sh`,
  `patch_watchdog.sh`, `patch_watchdog_v2.sh`, `patch_watchdog_v3.sh` — hotfixes
  one-shot dont les corrections sont déjà dans le source
- `migrate_deepsave_to_cryoss.sh` — migration one-shot DeepSave → Cryoss
- `docs/ANALYSS_UPDATE_PROMPT.md` — prompt v1 obsolète (contrat à v4 maintenant)
- `docs/ONBOARDING.md` — guide « nouveaux membres équipe », sans objet en mode solo

### Sécurité

- Step 19-apparmor : profil smbd renforcé (`deny /etc/cryoss/**` au lieu de
  `/etc/key/**` qui n'existait pas dans Cryoss natif).
- Runner `decrypt_path` : `chown root:root` explicite sur le dossier de destination
  pour eviter une race de permission.

### Documentation

- `README.md`, `CRYOSS_DEPLOIEMENT.md`, `docs/CONFIGURATION.md`,
  `docs/ops/DEPLOYMENT.md`, `docs/GIT_WORKFLOW.md`, `docs/ROADMAP.md`,
  `.github/PULL_REQUEST_TEMPLATE.md` : mis à jour avec la nouvelle structure
  (4 scripts top-level, tests unifiés, hardening intégré).

---

## [2.2.0] - 2026-05-03

Alignement avec le contrat Console Analyss v3 (`docs/cryoss-runner-contract.md`
côté Analyss, ADR 0001 §4 + §F'4 + §G + §I).

### Ajouté

- **Helper Fernet** : `cryoss-decrypt-secret` (Python, ~30 lignes), invoqué
  depuis le runner Bash pour déchiffrer les params `enc:v1:<token>` envoyés
  par la Console. Lit `/etc/cryoss/master_key` (0600 root:root). Aucun
  cleartext logué — défense en profondeur.
- **Étape `15-master-key`** dans `install_rpi1.sh` (interactive) : pose la
  master key Fernet avec validation encrypt+decrypt avant écriture, installe
  la dépendance `python3-cryptography` si absente. Skippable.
- **Timer de cleanup `decrypted/`** : `cryoss-decrypted-cleanup.timer`
  (toutes les 10min) supprime les déchiffrés à la demande après TTL 1h
  (marker `.expires_at` posé par `decrypt_path`).
- **Roots filesystem split** :
  - `CRYOSS_SHARE_ROOT=/etc/sauvegarde` — racine des partages Samba
  - `CRYOSS_ARCHIVE_ROOT=/etc/encrypted` — racine des chaînes rclone-crypt
  - `CRYOSS_DECRYPT_DIR=/var/lib/cryoss/decrypted` — dest. déchiffrement
  - Override possible via `/etc/cryoss/config.env` (parser strict whitelist).
- **Flag `--check`** sur `update.sh` : dry-run informatif listant les MAJ
  disponibles sur les paquets Cryoss-critiques (rclone, samba, mdadm,
  fail2ban, ufw, msmtp, etc.) sans rien modifier.

#### Runner — 28 nouvelles commandes (cryoss-command-runner.sh)

**§G — déchiffrement par chemin** :
- `list_backups` — JSON `[{path, size_bytes, modified_at, encrypted, chain}]`
  via énumération `rclone lsjson` sur les 3 chaînes crypt (c1/c2/c3).
- `decrypt_path (chain, path, danger)` — déchiffre via `rclone copy` vers
  `/var/lib/cryoss/decrypted/<command_id>/`, output JSON
  `{decrypted_path, chain, expires_at}`. Refuse path hors `CRYOSS_ARCHIVE_ROOT`,
  refuse racine nue. **Audit email immédiat** via `cryoss-email.sh`.

**§F'4 — diagnostics read-only (12)** :
- `disk_usage`, `raid_status`, `smart_status`, `system_info`, `network_status`
- `firewall_status`, `samba_sessions`, `samba_testconfig`
- `last_logins`, `failed_logins (lines)`, `backup_status`, `rclone_status`
- `service_status (service)` — whitelist étendue (cryoss-api, smbd, fail2ban, …)

**§F'4 — write/système (3)** :
- `apt_update_check` → `update.sh --check` (dry-run, paquets Cryoss-critiques)
- `apt_upgrade (danger)` → `update.sh` (snapshot RAID + upgrade + verif)
- `shutdown (shutdown_reason, danger)` — persiste la raison dans
  `/var/lib/cryoss/last-shutdown.txt`, ack avant le `poweroff` (délai 30s).

**§I — gestion users Samba (6)** :
- `samba_user_list` — JSON `[{username, enabled, last_change}]` (cache 60s).
- `samba_user_add (username, password★)` — pattern strict Cryoss :
  `useradd -r -M -s /usr/sbin/nologin -d /nonexistent` + `passwd -l` +
  `smbpasswd -a`. Idempotent : refuse silent overwrite, détecte états partiels
  (Unix sans Samba ou inverse). **Param `create_system_user` retiré du contrat
  Console** — profil Cryoss = toujours strict.
- `samba_user_delete (username, danger)`, `samba_user_set_password (password★)`
- `samba_user_disable`, `samba_user_enable`

**§I — gestion shares Samba (4)** :
- `samba_share_list` — JSON depuis `/etc/cryoss/shares.conf` (source de vérité,
  partagée avec le wizard CLI `11b-samba-wizard`).
- `samba_share_add (name, path, valid_users, write_list, read_only, danger)`
- `samba_share_modify`, `samba_share_delete (danger)` — préserve les fichiers
  sur disque (don't-delete-data default).

#### Sécurité

- **Pas de cleartext en log** : la ligne `log INFO "Commande recue ..."` scrubbe
  les champs `password` (→ `***`) et tout token `enc:v1:*` (→ `enc:v1:***`)
  avant écriture, défense en profondeur contre fuites par le log de commandes.
- Variables sensibles (`SU_PWD`, `MASTER_KEY`) systématiquement `unset` après
  usage. Mots de passe injectés via stdin de `smbpasswd` (jamais en argv).
- `printf '%s'` pour toutes les interpolations user-supplied — aucun `eval`,
  aucun `bash -c "...$user_param..."` non-quoté.
- Output runner tronqué à **8192 bytes strict** (vs 8000 précédemment) — aligné
  avec `OUTPUT_MAX_BYTES` du contrat.
- Helpers `valid_samba_name` (`[a-z][a-z0-9_-]{1,31}`), `is_protected_user`
  (`habyss`, `ds-user`, `ds-repl`, `root`), `is_protected_share` (`sauvegarde`,
  `encrypted_backup`, `global`, `homes`, `printers`).

#### Source de vérité partagée — pas de fichier parallèle

Le runner et le wizard CLI `11b-samba-wizard` partagent **la même source de
vérité** :
- Metadata : `/etc/cryoss/shares.conf` (format `USER`/`SHARE`/`PERM`)
- Fichier d'inclusion Samba : `/etc/samba/cryoss-shares.conf` (régénéré depuis
  la metadata, jamais édité à la main).

Pas de `console-shares.conf` séparé. Le runner régénère atomiquement
(`tmp + rename`) et reload Samba (`testparm -s` + `smbcontrol all reload-config`).

### Modifié

- `install_api.sh` : déploie `cryoss-decrypt-secret` + dépendance
  `python3-cryptography` + service/timer `cryoss-decrypted-cleanup`.
- `install_rpi1.sh` : nouvelle étape `15-master-key` (16 étapes au total).
- `update.sh` : argument `--check` (dry-run paquets Cryoss-critiques).
- Le runner Cryoss passe de 503 à 1431 lignes ; bash strict, dispatcher unique
  case, helpers en haut.

### Documentation

- Ajout d'une section "Commandes bidirectionnelles" dans
  `CRYOSS_DEPLOIEMENT.md` (master_key, contrat, audit decrypt_path).
- Tableau des fichiers importants enrichi (`master_key`, `config.env`,
  `last-shutdown.txt`, `decrypted/`).

---

## [2.1.0] - 2026-05-02

### Ajoute

- **Reprise par etapes (`install_rpi1.sh`)** : 15 etapes numerotees avec
  checkpoints persistants (`/var/lib/cryoss/install.state`). Nouveaux flags :
  - `--resume` : reprend apres une interruption
  - `--from-step ID` : rejoue depuis une etape (ex. `11-samba`)
  - `--only-step ID` : rejoue UNE seule etape sans toucher au reste
  - `--list-steps` : statut visuel des etapes (✓ fait / ○ a faire)
  - `--reset` : efface l'etat et redemarre a zero
  - `--help` : aide complete
- **Persistance des variables d'install** dans `/var/lib/cryoss/install.env`
  (mode 600 root) — permet la reprise sans redemander les mots de passe SMTP/SFTP.
- **Wizard Samba interactif** (etape `11b-samba-wizard`) :
  - Creation dynamique de partages personnalises sous `/etc/sauvegarde`
  - Utilisateurs Samba **purs** (`useradd -r -M -s /usr/sbin/nologin` +
    `passwd -l`) — aucun acces SSH ou console possible, seul Samba authentifie
  - Matrice de droits user × partage avec niveaux R / RW / refus explicite
  - Persistance dans `/etc/cryoss/shares.conf` + `/etc/samba/cryoss-shares.conf`
  - Validation des noms (pattern + reserves bloques) et des mots de passe (min 8 chars)
- **Visuels Cryoss** : bannieres ASCII bleu glace, spinner Unicode (`⣾⣽⣻⢿⡿⣟⣯⣷`),
  barres de progression, labels colores, log brut centralise dans
  `/var/log/cryoss-install.log`. Wrapper `cryoss_run` pour les commandes
  encapsulees (apt-get, curl, mdadm, mkfs.ext4) avec ✓/✗ et tail des 20
  dernieres lignes du log en cas d'echec.

### Documentation

- **Procedure pre-install RPi 5 + Penta SATA HAT** : section dediee
  `dtparam=pciex1` dans `/boot/firmware/config.txt` pour activation PCIe.
  Sans ca, les disques ne sont pas detectes (`lsblk` n'affiche que `mmcblk0`).
- **Identification physique des disques** : commandes `dd` pour faire
  clignoter, `smartctl -i` pour les serials, regles udev pour des liens
  stables `/dev/cryoss/baieN`. Schema layout Cryoss (S1+S2 = md0
  `/etc/sauvegarde`, S3+S4 = md1 `/etc/encrypted`).
- Mise a jour de `CRYOSS_DEPLOIEMENT.md`, `docs/ops/DEPLOYMENT.md`,
  `docs/ONBOARDING.md`, `docs/CONFIGURATION.md` et `README.md`.

### Modifie

- `smb.conf` inclut desormais `/etc/samba/cryoss-shares.conf` pour les
  partages dynamiques (ne casse pas les `[sauvegarde]` et `[encrypted_backup]`
  existants).
- Toutes les commandes `apt-get install`, `curl ... | bash` (rclone), `mdadm
  --create`, `mkfs.ext4` sont desormais encapsulees avec spinner + log au
  lieu d'afficher leur sortie brute.

### Securite

- Les utilisateurs ajoutes via le wizard ne sont **jamais** des comptes systeme
  exploitables : nologin shell, no home, mot de passe Unix verrouille (`passwd
  -l`). Authentification Samba uniquement.

---

## [2.0.0] - 2026-04-16

Reecriture majeure depuis DeepSave v1. Cryoss remplace integralement le systeme DeepSave avec une architecture repensee, un chiffrement renforce et un monitoring centralise.

### Modifie

- Migration du chiffrement `openssl enc` (AES-256-CBC) vers `rclone crypt` (XSalsa20-Poly1305 + AES-256-EME)
- Remplacement du tunnel SSH par un heartbeat HTTPS vers la console Analyss (toutes les 5 minutes)

### Ajoute

- 3 paires de cles independantes par installation (une par chemin de sauvegarde C1/C2/C3)
- API REST FastAPI pour le monitoring et la gestion a distance (`cryoss-api.py`, `install_api.sh`)
- Anti-ransomware 4 couches : versioning SFTP, honeypot inotify, `chattr +a`, AppArmor
- Numero de serie unique par installation (format `DS-XXXXXXXX`)
- Suite de tests automatises (62 tests) via `test_installation.sh`
- Script de mise a jour securise (`update.sh`) preservant RAID, cles et configuration
- Script de migration depuis DeepSave v1 (`migrate_deepsave_to_cryoss.sh`)
- Heartbeat phone-home HTTPS vers la console centrale Analyss
- Rapports de sante automatiques (`cryoss-health.sh`)
- Installateurs separes par composant (`install_rpi1.sh`, `install_rpi2.sh`, `install_security.sh`, `install_api.sh`)

### Securite

- Chiffrement XSalsa20-Poly1305 pour les donnees (remplace AES-256-CBC)
- Chiffrement AES-256-EME pour les noms de fichiers
- Isolation air-gap du RPi2 renforcee
- Profils AppArmor dedies pour les services Cryoss
- Detection de ransomware par honeypot avec notification immediate

---

## [1.x] - DeepSave (obsolete)

Version initiale du systeme de sauvegarde sous le nom DeepSave.
Remplacee integralement par Cryoss 2.0.0.
Utilisez `migrate_deepsave_to_cryoss.sh` pour migrer une installation existante.
