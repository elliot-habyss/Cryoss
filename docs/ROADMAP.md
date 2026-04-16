# Feuille de route Cryoss

## v2.0 (actuelle) — Avril 2026

- ✅ Migration openssl vers rclone crypt (XSalsa20-Poly1305)
- ✅ 3 chemins de backup independants
- ✅ Phone-home heartbeat vers Analyss
- ✅ API REST FastAPI
- ✅ 4 couches anti-ransomware
- ✅ Suite de tests automatises (62 tests)
- ✅ Script de migration DeepSave vers Cryoss
- ✅ Script de mise a jour sur (update.sh)

## v2.1 — Q3 2026

- Integration dashboard Analyss complete (graphiques historiques, tendances)
- Notifications push (Slack/Teams webhook en plus des emails)
- Restauration assistee depuis la console Analyss
- Tests automatises RPi2

## v2.2 — Q4 2026

- Support multi-RAID (plus de 2 arrays)
- Backup incremental (rclone --fast-list + delta sync)
- Chiffrement de bout en bout pour le heartbeat (payload chiffre)
- Mode maintenance planifie (suppression alertes pendant intervention)

## v3.0 — 2027

- Agent Python natif (remplacement progressif des scripts bash)
- Interface web locale sur RPi1 (dashboard client read-only)
- Support NVMe (en plus de SATA)
- Certification ISO 27001 du process de deploiement
