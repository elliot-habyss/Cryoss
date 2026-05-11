# Cryoss — pipeline d'audit sécurité

Ce document décrit la chaîne de scanners automatisés câblée dans la CI.
Pour la revue manuelle ciblée du code, voir [SECURITY_AUDIT_2026-04.md](SECURITY_AUDIT_2026-04.md).

## Vue d'ensemble

| Outil      | Cible                          | Bloquant en CI ? | Rapport         |
|------------|--------------------------------|------------------|-----------------|
| Bandit     | `api/*.py`                     | Oui (HIGH)       | SARIF → Security tab |
| Semgrep    | Python + Bash + custom Cryoss  | Oui (ERROR)      | SARIF → Security tab |
| ShellCheck | tous les `*.sh` (sauf `docs/`) | Oui (warning+)   | annotations PR  |
| Trivy      | filesystem (vuln + secret + misconfig) | Oui (HIGH/CRITICAL) | SARIF → Security tab |
| Gitleaks   | historique git                 | Oui              | annotations PR  |

Pas de Trivy sur Dockerfile : Cryoss se déploie via scripts bash sur
Raspberry Pi, pas via container. Trivy tourne en mode `fs` pour
détecter secrets, CVE de manifests éventuels et misconfig (terraform/k8s
absents pour l'instant — la règle est en place pour le futur).

## Fichiers de config

- [`.github/workflows/security.yml`](../.github/workflows/security.yml) — workflow GitHub Actions
- [`.bandit`](../.bandit) — config Bandit (tests retenus + dossiers exclus)
- [`.semgrep.yml`](../.semgrep.yml) — règles custom Cryoss (shell=True, bind, CORS, source untrusted, eval, curl -k…)
- [`.gitleaks.toml`](../.gitleaks.toml) — règles secrets Analyss / rclone / msmtp
- [`.shellcheckrc`](../.shellcheckrc) — exclusions ShellCheck (SC1091, SC2034)
- [`.pre-commit-config.yaml`](../.pre-commit-config.yaml) — exécution locale avant commit

## Triggers

- **push / pull_request** sur `main` et `master`
- **schedule** : lundi 04:00 UTC (CVE des deps figées)
- **workflow_dispatch** : déclenchement manuel

## Règles Semgrep custom (extrait)

Les règles Cryoss-spécifiques visent les patterns récurrents du projet :

- `cryoss-shell-true-with-fstring` — `subprocess.run(f"...", shell=True)` ⇒ ERROR
- `cryoss-bind-non-localhost` — `host="0.0.0.0"` ⇒ ERROR (cf. [threat-model](architecture/THREAT_MODEL.md) si présent)
- `cryoss-cors-allow-all` — `allow_origins=["*"]` ⇒ ERROR
- `cryoss-bash-source-untrusted` — `source $FILE` ⇒ WARNING (cf. finding #2 du dernier audit)
- `cryoss-curl-insecure` — `curl -k` / `--insecure` ⇒ ERROR
- `cryoss-ssh-no-strict-host` — `StrictHostKeyChecking=no` ⇒ WARNING
- `cryoss-rm-rf-var` — `rm -rf $VAR` non-quoté/non-validé ⇒ ERROR
- `cryoss-yaml-unsafe-load`, `cryoss-pickle-load` — désérialisation dangereuse

Liste complète dans [`.semgrep.yml`](../.semgrep.yml).

## Exécution locale

```bash
# Setup (une fois)
pip install pre-commit bandit semgrep
pre-commit install

# Avant chaque commit : automatique (hook installé)
# Run manuel sur tout le repo
pre-commit run --all-files

# Scanners individuels
bandit -r api/ -c .bandit
semgrep scan --config .semgrep.yml --config p/python --config p/bash
shellcheck **/*.sh
```

## Gestion des findings

1. Les findings **HIGH/ERROR** bloquent la PR.
2. Les findings **MEDIUM/WARNING** sont remontés mais non bloquants.
3. Les SARIF sont uploadés dans l'onglet **Security → Code scanning** du repo
   pour suivi historique et triage.
4. Faux positif : ajouter dans le fichier de config approprié (jamais de
   `# nosec` / `# nosemgrep` inline sans justification documentée).

## Rotation et maintenance

- Mise à jour mensuelle des versions (Bandit, Semgrep, Trivy, Gitleaks)
  via Dependabot — à activer dans `.github/dependabot.yml` (TODO).
- Revue trimestrielle des règles custom Semgrep : ajouter les patterns
  nouvellement identifiés en revue manuelle.
- En cas de CVE remontée par Trivy sur un manifeste : créer un ticket
  immédiat, ne pas suppressifier.
