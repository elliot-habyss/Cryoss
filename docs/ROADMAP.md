# Feuille de route Cryoss

## v2.1 (actuelle) — Mai 2026

Consolidation post-v2.0 :

- ✅ Migration openssl vers rclone crypt (XSalsa20-Poly1305)
- ✅ 3 chemins de backup independants (C1 local / C2 RPi2 SFTP / C3 SFTP distant)
- ✅ Phone-home heartbeat vers Analyss + commandes bidirectionnelles (contrat v4)
- ✅ API REST FastAPI + helper Fernet pour params chiffres
- ✅ 4 couches anti-ransomware (versioning SFTP, honeypot, chattr +a, AppArmor)
  desormais integrees a install_rpi1.sh (steps 16-19)
- ✅ Suite de tests unifiee `tests/cryoss-test.sh` (install + runner)
- ✅ Lib UI commune `lib/cryoss-installer-ui.sh` (banner, spinner, resume framework)
  partagee par install_rpi1.sh et install_rpi2.sh
- ✅ Consolidation scripts : 4 entry points top-level (install_rpi1, install_rpi2,
  install_api, update) + patches/migrations/tests separes supprimes
- ✅ Console URL = `analyss.app` (refresh 2026-05-11)

## v2.2 — Q3 2026

- Handoff automatique email RPi1 → RPi2 (eviter double prompt operateur)
- `expected_silence_minutes` cote Console pour mute alertes pendant shutdown
- Restauration assistee depuis la console Analyss
- Notifications push (Slack/Teams webhook en plus des emails)
- Migration `/etc/sauvegarde` / `/etc/encrypted` vers `/srv/cryoss/...` (FHS-compliant)

## v2.3 — Q4 2026

- Support multi-RAID (plus de 2 arrays)
- Backup incremental (rclone --fast-list + delta sync)
- Chiffrement de bout en bout pour le heartbeat (payload chiffre)
- Mode maintenance planifie (suppression alertes pendant intervention)

## v3.0 — 2027

- Agent Python natif (remplacement progressif des scripts bash)
- Interface web locale sur RPi1 (dashboard client read-only)
- Support NVMe (en plus de SATA)
- Rotation auto master key Fernet (vs procedure manuelle ADR 0001 §4)
