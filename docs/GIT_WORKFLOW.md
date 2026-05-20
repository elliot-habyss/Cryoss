# Cryoss -- Workflow Git

> Conventions Git pour le projet Cryoss chez Analyss.

---

## Strategie de branches

| Branche | Role | Protection |
|---------|------|------------|
| `main` | Stable, deploye en production | Merge via PR uniquement, review obligatoire |
| `dev` | Developpement actif | Branche de travail commune |
| `feature/*` | Nouvelles fonctionnalites | Crees depuis `dev`, mergees dans `dev` |
| `fix/*` | Corrections de bugs | Crees depuis `dev` ou `main` (hotfix) |

### Cycle de vie

```
feature/ajout-endpoint-restore
        │
        └──► dev ──► (tests sur RPi dev) ──► main ──► (deploiement via update.sh)
```

Pour un hotfix critique :

```
fix/raid-alerte-manquante
        │
        └──► main (merge direct apres review + test)
        └──► dev  (cherry-pick pour garder dev a jour)
```

---

## Messages de commit

Commits conventionnels, **en francais**.

### Format

```
<type>: <description courte>

<corps optionnel : contexte, justification, impact>
```

### Types autorises

| Type | Usage |
|------|-------|
| `feat` | Nouvelle fonctionnalite |
| `fix` | Correction de bug |
| `docs` | Documentation uniquement |
| `refactor` | Restructuration sans changement fonctionnel |
| `security` | Amelioration de securite |
| `test` | Ajout ou modification de tests |
| `chore` | Maintenance (dependances, CI, configs) |

### Exemples

```
feat: ajouter endpoint API restauration depuis C3

Permet de lancer une restauration depuis les versions SFTP via
POST /api/v1/restore avec selection de la date.
```

```
fix: corriger detection RAID degrade dans le watchdog

Le grep sur /proc/mdstat ne detectait pas les etats "recovering".
Ajoute le pattern dans cryoss-health.sh.
```

```
security: restreindre les commandes sudo de cryoss-api

Retirer /usr/bin/rclone de la liste sudoers et passer par un
script intermediaire avec validation des arguments.
```

---

## Processus de Pull Request

1. **Creer la branche** depuis `dev` :
   ```bash
   git checkout dev && git pull
   git checkout -b feature/ma-fonctionnalite
   ```

2. **Developper et committer** en respectant les conventions ci-dessus.

3. **Tester sur un RPi dev** (ou VM) :
   - Deployer avec `update.sh` ou manuellement.
   - Lancer `tests/cryoss-test.sh` — tous les tests doivent passer.
   - Verifier les logs (`journalctl`, `/var/log/cryoss-*.log`).

4. **Ouvrir une PR** vers `dev` :
   - Description claire du changement et de son impact.
   - Mentionner les fichiers modifies et les tests effectues.
   - Ajouter des captures de log si pertinent.

5. **Review obligatoire** : au moins un autre membre de l'equipe.

6. **Merge** : squash ou merge commit selon la taille. Supprimer la branche apres merge.

---

## Processus de release

1. **Merger `dev` dans `main`** via PR (review obligatoire).

2. **Tagger la version** :
   ```bash
   git tag -a v1.2.0 -m "v1.2.0 : description courte"
   git push origin v1.2.0
   ```

3. **Mettre a jour CHANGELOG.md** (a la racine) avec les changements de la version.

4. **Deployer** chez les clients via `update.sh` :
   ```bash
   # Sur le RPi du client (via tunnel SSH)
   cd /chemin/vers/cryoss
   git pull origin main
   sudo bash update.sh
   sudo bash tests/cryoss-test.sh
   ```

### Versionnage

Format **semver** : `vMAJEUR.MINEUR.PATCH`

- **MAJEUR** : changement d'architecture, migration requise.
- **MINEUR** : nouvelle fonctionnalite, retro-compatible.
- **PATCH** : correction de bug, amelioration mineure.

---

## Regles de securite

- **Jamais de secrets dans le depot** : cles de chiffrement, mots de passe, cles API, tokens. Tout est genere a l'installation (`openssl rand`).
- Les fichiers de configuration contenant des secrets (`rclone.conf`, `api-key`, `keys-backup.conf`) sont crees par les scripts d'installation et ne doivent pas etre commites.
- Verifier avant chaque commit qu'aucun fichier sensible n'est inclus.
