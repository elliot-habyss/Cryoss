# Monitoring et alertes Cryoss

> Cryoss -- Sauvegarde chiffree triple-redondante sur paires de Raspberry Pi.
> Produit par Analyss.

---

## Vue d'ensemble

Le systeme de monitoring Cryoss fonctionne sur trois niveaux complementaires :

| Niveau          | Frequence          | Objectif                                      |
|-----------------|--------------------|-----------------------------------------------|
| Health daily    | Tous les jours 07h00 | Verification complete, rapport email          |
| Health weekly   | Lundi 08h00          | Analyse SMART approfondie, tendances          |
| Watchdog        | Toutes les 15 min    | Detection immediate des pannes critiques      |
| Heartbeat       | Toutes les 5 min     | Remontee d'etat vers la plateforme Analyss    |

Tous les checks sont executes par `cryoss-health.sh` avec differents modes, pilotes par des timers systemd.

---

## Health check quotidien (07h00)

Declenchement : timer systemd `cryoss-health-daily.timer`, tous les jours a 07h00.

Verifications effectuees :

1. **Etat RAID** : verification de `/proc/mdstat` sur RPi1 (RAID 5) et RPi2 (RAID 1 via interco). Detection de disques manquants ou grappes degradees.
2. **Espace disque** : pourcentage d'utilisation des partitions RAID et systeme. Seuils : avertissement a 75%, critique a 85%.
3. **Services actifs** : verification que les services essentiels tournent (smbd, sshd, cryoss-api, cryoss-backup.timer, cryoss-heartbeat.timer).
4. **Age de la derniere replication** : verification de la date du dernier transfert reussi vers RPi2. Seuils adaptatifs (voir section dediee).
5. **Temperature CPU** : lecture de la sonde thermique. Avertissement a 70 C, critique a 80 C.
6. **Logs d'erreur** : analyse des logs de sauvegarde et de replication pour detecter les echecs recents.

A la fin du check, un **rapport HTML** est envoye par email a :
- `support@habyss.fr` (toujours)
- Adresse email du client (si configuree dans `/etc/cryoss/analyss.conf`)

---

## Health check hebdomadaire (lundi 08h00)

Declenchement : timer systemd `cryoss-health-weekly.timer`, chaque lundi a 08h00.

En plus des verifications quotidiennes, le check hebdomadaire effectue :

1. **Scan SMART complet** : execution de `smartctl -t long` sur chaque disque, puis lecture des resultats. Detection des secteurs defectueux, reallocations, erreurs de lecture.
2. **Analyse de tendances** : comparaison des metriques SMART avec les releves precedents. Detection de degradation progressive (augmentation des secteurs realloues, temperature moyenne en hausse, etc.).
3. **Verification d'integrite RAID** : lancement d'un scrub/check RAID pour detecter les incoherences silencieuses.
4. **Rapport de tendances** : synthese des evolutions sur les 4 dernieres semaines.

Le rapport hebdomadaire est plus detaille que le quotidien et inclut les graphiques de tendances (si le client est inscrit au dashboard Analyss).

---

## Watchdog (toutes les 15 minutes)

Declenchement : timer systemd `cryoss-watchdog.timer`, toutes les 15 minutes.

Le watchdog est concu pour la **detection immediate** des situations critiques. Il ne genere un rapport que si un probleme est detecte.

Conditions surveillees :

| Condition                     | Seuil                  | Severite  |
|-------------------------------|------------------------|-----------|
| RAID degrade                  | Disque manquant/faulty | Critique  |
| Service arrete                | Service inactif        | Critique  |
| Espace disque critique        | > 85% utilise          | Critique  |
| Espace disque avertissement   | > 75% utilise          | Warning   |
| Temperature CPU               | > 80 C                 | Critique  |
| Sauvegarde en echec           | Derniere sauvegarde echouee | Critique |
| RPi2 injoignable              | Pas de reponse ping via interco | Critique |
| Instance hors ligne           | Pas de heartbeat depuis > 10 min | Critique |

En cas de detection d'un probleme critique, une **alerte immediate** est envoyee par email (HTML formate) a `support@habyss.fr` et a l'email client.

### Auto-resolution

Quand une condition d'alerte **disparait** (par exemple : un service redemarre, l'espace disque redescend sous le seuil), le watchdog envoie un email de **resolution** indiquant que le probleme est corrige. Cela evite les alertes fantomes et confirme le retour a la normale.

---

## Seuils adaptatifs pour la replication

La replication de RPi1 vers RPi2 se fait en general pendant les heures de travail. Les seuils d'alerte s'adaptent au calendrier :

| Periode                        | Seuil d'alerte (age max de la derniere replication) |
|--------------------------------|-----------------------------------------------------|
| Jour de semaine (lun-ven)      | 26 heures                                           |
| Week-end (sam-dim) et feries   | 74 heures                                           |

Ces seuils tiennent compte du fait que :
- En semaine, une replication doit avoir lieu au moins une fois par jour ouvre.
- Le week-end, il est normal qu'aucune nouvelle donnee ne soit generee pendant 2-3 jours.

Si le seuil est depasse, le watchdog declenche une alerte de type "replication silencieuse".

---

## Heartbeat vers Analyss

### Fonctionnement

RPi1 envoie un heartbeat toutes les 5 minutes vers :

```
POST https://app.analyss.fr/api/sync/cryoss/heartbeat
```

La configuration est dans `/etc/cryoss/analyss.conf` (cle API, serial DS-XXXXXXXX).

### Contenu du payload

Le heartbeat transmet l'etat complet du systeme :

- Etat RAID RPi1 et RPi2.
- Espace disque utilise.
- Services actifs/inactifs.
- Temperature CPU.
- Date de la derniere sauvegarde reussie.
- Date de la derniere replication reussie.
- Alertes actives.
- Version des scripts Cryoss installes.

**Important** : le payload ne contient **aucun secret** (pas de cles, pas de mots de passe, pas de donnees client).

Les donnees de RPi2 sont collectees par RPi1 via l'interco avant l'envoi du heartbeat. RPi2 ne contacte jamais la plateforme Analyss directement.

### Dashboard Analyss

Le dashboard `https://app.analyss.fr` offre une vue temps reel de toutes les instances Cryoss deployees :

- Etat de chaque paire (en ligne/hors ligne).
- Dernier heartbeat recu.
- Alertes actives.
- Historique des metriques.
- Notifications push en cas de perte de contact.

---

## Conditions d'alerte detaillees

### 1. RAID degrade

- **Detection** : disque marque `faulty` ou `removed` dans `/proc/mdstat`.
- **Action** : alerte immediate. Planifier le remplacement du disque defaillant.
- **Resolution** : RAID reconstruit avec succes, tous les disques actifs.

### 2. Service arrete

- **Detection** : `systemctl is-active` retourne `inactive` ou `failed` pour un service critique (smbd, sshd, cryoss-api, cryoss-backup.timer, cryoss-heartbeat.timer).
- **Action** : alerte immediate. Tenter un redemarrage : `sudo systemctl restart <service>`.
- **Resolution** : le service repasse en etat `active`.

### 3. Espace disque critique (> 85%)

- **Detection** : `df` indique une utilisation superieure a 85% sur la partition RAID.
- **Action** : alerte immediate. Identifier les fichiers volumineux, purger les anciennes sauvegardes si possible.
- **Resolution** : utilisation repassee sous 85%.

### 4. Espace disque avertissement (> 75%)

- **Detection** : utilisation entre 75% et 85%.
- **Action** : alerte de type warning dans le rapport quotidien. Pas d'alerte immediate du watchdog.
- **Resolution** : utilisation repassee sous 75%.

### 5. Surchauffe CPU (> 80 C)

- **Detection** : lecture de `/sys/class/thermal/thermal_zone0/temp`.
- **Action** : alerte immediate. Verifier la ventilation, l'environnement physique du RPi.
- **Resolution** : temperature repassee sous 70 C.

### 6. Sauvegarde en echec

- **Detection** : le dernier log de sauvegarde contient une erreur ou un code retour non nul.
- **Action** : alerte immediate. Consulter `/var/log/cryoss-backup.log` pour diagnostiquer.
- **Resolution** : prochaine sauvegarde reussie.

### 7. RPi2 injoignable

- **Detection** : `ping -c 3 10.42.0.2` echoue depuis RPi1.
- **Action** : alerte immediate. Verifier le cable interco, l'alimentation de RPi2, l'etat de l'interface reseau.
- **Resolution** : RPi2 repond de nouveau au ping.

### 8. Instance hors ligne

- **Detection** : cote Analyss, aucun heartbeat recu depuis plus de 10 minutes.
- **Action** : notification sur le dashboard Analyss. Verifier la connectivite Internet de RPi1.
- **Resolution** : heartbeat recu a nouveau.

---

## Alertes email

### Format

Les alertes sont envoyees au format **HTML** pour une lecture facile. Chaque email contient :

- Nom du client et numero de serie DS-XXXXXXXX.
- Type d'alerte (critique, warning, resolution).
- Description du probleme.
- Horodatage de la detection.
- Actions recommandees.

### Destinataires

| Destinataire          | Configurable | Obligatoire |
|-----------------------|--------------|-------------|
| `support@habyss.fr`  | Non          | Oui         |
| Email client          | Oui          | Non         |

L'email client est configure dans `/etc/cryoss/analyss.conf` lors de l'installation. Il peut etre modifie ulterieurement en editant ce fichier.

### Configuration SMTP

L'envoi passe par msmtp, configure dans `/etc/msmtprc`. En cas de probleme d'envoi, verifier :

```bash
# Test d'envoi manuel
echo "Test Cryoss" | msmtp -v support@habyss.fr
```

---

## Fichiers de logs

Tous les logs Cryoss sont stockes dans `/var/log/` :

| Fichier                        | Contenu                                          |
|--------------------------------|--------------------------------------------------|
| `cryoss-backup.log`           | Execution des sauvegardes (succes, erreurs)      |
| `cryoss-health.log`           | Resultats des health checks (daily, weekly)      |
| `cryoss-heartbeat.log`        | Envois heartbeat (succes, erreurs HTTP)          |
| `cryoss-honeypot.log`         | Detections du honeypot de securite (RPi1)        |
| `rclone_cryoss_c1.log`        | Logs rclone pour le chemin de chiffrement C1     |
| `rclone_cryoss_c2.log`        | Logs rclone pour le chemin de chiffrement C2     |
| `rclone_cryoss_c3.log`        | Logs rclone pour le chemin de chiffrement C3     |
| `cryoss-api.log`              | Logs de l'API locale Cryoss                      |

### Consultation

```bash
# Derniere sauvegarde
sudo tail -50 /var/log/cryoss-backup.log

# Erreurs recentes dans les health checks
sudo grep -i "error\|critical\|failed" /var/log/cryoss-health.log | tail -20

# Statut du heartbeat
sudo tail -20 /var/log/cryoss-heartbeat.log
```

---

## Rotation des logs (logrotate)

La rotation est configuree automatiquement lors de l'installation. Parametres :

| Parametre      | Valeur        |
|----------------|---------------|
| Frequence      | Hebdomadaire  |
| Retention      | 8 rotations   |
| Compression    | Oui (gzip)    |
| Delai compress | 1 rotation    |

Configuration dans `/etc/logrotate.d/cryoss` :

```
/var/log/cryoss-*.log /var/log/rclone_cryoss_*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 640 root adm
}
```

Cela signifie que chaque log est conserve pendant environ 2 mois (8 semaines) avant d'etre supprime. Les fichiers compresses occupent peu d'espace.

### Verification

```bash
# Verifier la config logrotate
sudo logrotate -d /etc/logrotate.d/cryoss

# Forcer une rotation manuelle (test)
sudo logrotate -f /etc/logrotate.d/cryoss
```

---

## Commandes utiles pour le diagnostic

```bash
# Etat general rapide
sudo cryoss-health.sh status

# Forcer un health check quotidien
sudo cryoss-health.sh daily

# Forcer un health check hebdomadaire
sudo cryoss-health.sh weekly

# Forcer un heartbeat immediat
sudo cryoss-heartbeat.sh send

# Lister tous les timers Cryoss
systemctl list-timers 'cryoss-*'

# Etat du RAID
cat /proc/mdstat

# Etat SMART d'un disque
sudo smartctl -a /dev/sda

# Verifier la connectivite interco
ping -c 3 10.42.0.2

# Verifier la connectivite Analyss
curl -s -o /dev/null -w '%{http_code}' https://app.analyss.fr/api/sync/cryoss/heartbeat
```
