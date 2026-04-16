# Plan de reponse aux incidents Cryoss

**Produit :** Cryoss -- Sauvegarde chiffree triple-redondance
**Editeur :** Analyss
**Version du document :** 1.0
**Date :** 2026-04-16

---

## 1. Objectif

Ce document definit les procedures de detection, de reaction et de restauration en cas d'incident affectant une installation Cryoss. Il s'adresse aux administrateurs Analyss et aux techniciens intervenant sur site.

**Principe directeur :** en cas de doute, proteger le RPi2 en priorite. Le RPi2 est le dernier rempart local contre la perte de donnees.

---

## 2. Detection des incidents

### 2.1 Sources de detection

| Source | Type d'alerte | Criticite | Delai de detection |
|--------|--------------|-----------|-------------------|
| **Honeypot inotify** | Modification du fichier piege dans le partage Samba | Critique | Temps reel |
| **Health check** | Echec de verification d'integrite, espace disque insuffisant | Eleve | Periodique (cron) |
| **Heartbeat** | Absence de signal vers la console Analyss | Eleve | 15 minutes |
| **RAID monitoring** | RAID degrade (disque defaillant) | Eleve | Temps reel (mdadm monitor) |
| **Fail2ban** | Tentatives d'intrusion SSH repetees | Moyen | Temps reel |
| **Watchdog** | Service arrete (smbd, cryoss-backup, cryoss-api) | Moyen | Periodique |

### 2.2 Classification des incidents

| Niveau | Exemples | Delai de reaction |
|--------|----------|-------------------|
| **P1 -- Critique** | Ransomware detecte, compromission confirmee du RPi1, perte de donnees | **Immediat** |
| **P2 -- Eleve** | RAID degrade, echec de replication, RPi2 injoignable | **1 heure** |
| **P3 -- Moyen** | Tentatives d'intrusion bloquees, service redemarrable | **4 heures** |
| **P4 -- Bas** | Anomalie de monitoring, avertissement espace disque | **24 heures** |

---

## 3. Procedures d'action immediate

### 3.1 Ransomware detecte (P1)

**Declencheur :** alerte honeypot inotify ou constatation de fichiers chiffres/renommes dans `/etc/sauvegarde/`.

**Actions immediates :**

```
ETAPE 1 : ISOLER le(s) poste(s) client(s) infecte(s)
         -> Deconnecter physiquement le cable reseau du poste
         -> OU desactiver le port switch correspondant
         -> NE PAS eteindre le poste (preservation des preuves en memoire)

ETAPE 2 : NE PAS TOUCHER AU RPi2
         -> Le RPi2 est protege par l'air-gap
         -> Ne pas se connecter au RPi2 depuis un poste potentiellement compromis
         -> Ne pas debrancher le cable interco (sauf si RPi1 est compromis, voir 3.3)

ETAPE 3 : Evaluer l'etat du RPi1
         -> Se connecter en SSH depuis un poste sain
         -> Verifier l'etat de /etc/sauvegarde/ (fichiers modifies ?)
         -> Verifier l'etat de /etc/encrypted/ (chattr +a encore actif ?)
         -> Verifier les logs : journalctl -u smbd --since "1 hour ago"

ETAPE 4 : Bloquer l'acces Samba si necessaire
         -> systemctl stop smbd
         -> Cela empeche toute modification supplementaire via le partage

ETAPE 5 : Notifier
         -> Contacter Analyss : support@analyss.fr
         -> Objet : [SECURITE] [NOM_CLIENT] -- Ransomware detecte
         -> Informer le client
```

**Points critiques :**
- Ne jamais payer la rancon
- Ne pas tenter de dechiffrer les fichiers sans l'aide d'Analyss
- Preserver les logs et les fichiers chiffres par le ransomware (preuves)

---

### 3.2 RAID degrade (P2)

**Declencheur :** alerte mdadm, ou constatation dans `/proc/mdstat` d'un disque marque `[U_]` ou `[_U]`.

**Actions immediates :**

```
ETAPE 1 : Identifier le disque defaillant
         -> cat /proc/mdstat
         -> mdadm --detail /dev/md0

ETAPE 2 : Verifier les logs SMART
         -> smartctl -a /dev/sdX (remplacer X par le disque suspecte)

ETAPE 3 : Retirer le disque defaillant du RAID
         -> mdadm /dev/md0 --remove /dev/sdXN

ETAPE 4 : Remplacer le disque physiquement
         -> Eteindre le RPi1 proprement : shutdown -h now
         -> Remplacer le disque defaillant
         -> Redemarrer

ETAPE 5 : Ajouter le nouveau disque au RAID
         -> Partitionner le nouveau disque a l'identique
         -> mdadm /dev/md0 --add /dev/sdXN

ETAPE 6 : Surveiller la reconstruction
         -> watch cat /proc/mdstat
         -> La reconstruction peut prendre plusieurs heures

ETAPE 7 : Verifier
         -> cat /proc/mdstat -> doit afficher [UU]
         -> Les sauvegardes doivent reprendre normalement
```

**Attention :** pendant la reconstruction, le RAID n'est pas redondant. Eviter tout redemarrage ou intervention non necessaire.

---

### 3.3 RPi1 compromis (P1)

**Declencheur :** comportement anormal detecte, processus suspects, modifications non autorisees, ou compromission confirmee.

**Actions immediates :**

```
ETAPE 1 : DECONNECTER le RPi1 du LAN
         -> Debrancher le cable Ethernet LAN du RPi1
         -> Cela empeche toute propagation et toute exfiltration

ETAPE 2 : Evaluer la necessite de couper l'interco
         -> SI l'attaquant a potentiellement acces au compte ds-repl
            ou si des commandes suspectes sont en cours vers RPi2 :
            -> COUPER PHYSIQUEMENT le cable interco RPi1-RPi2
            -> Voir section 7 ("Reflexe coupe interco")
         -> SINON : laisser l'interco en place pour analyse ulterieure

ETAPE 3 : PRESERVER le RPi2
         -> Le RPi2 contient la copie C2
         -> Ne pas se connecter au RPi2 depuis le RPi1 compromis
         -> Si necessaire, acceder au RPi2 via un clavier/ecran directement

ETAPE 4 : Preservation des preuves sur RPi1
         -> Ne pas eteindre le RPi1 (memoire volatile = preuves)
         -> Si possible, realiser une image disque a froid ulterieurement
         -> Capturer les logs : journalctl --since "24 hours ago" > /tmp/logs.txt

ETAPE 5 : Notifier
         -> Contacter Analyss en urgence : support@analyss.fr
         -> Objet : [SECURITE] [NOM_CLIENT] -- RPi1 compromis
         -> Fournir : date de detection, symptomes, actions entreprises
```

---

### 3.4 RPi2 injoignable (P2)

**Declencheur :** echec de replication, timeout SSH vers 10.42.0.2, ou alerte de health check.

**Actions de diagnostic :**

```
ETAPE 1 : Verifier la connectivite interco depuis RPi1
         -> ping -c 3 10.42.0.2
         -> Si timeout -> verifier le cable physique

ETAPE 2 : Verifier le cable interco
         -> Verifier la connexion physique des deux cotes
         -> Verifier les LEDs d'activite sur les ports Ethernet
         -> Remplacer le cable si necessaire

ETAPE 3 : Verifier l'alimentation du RPi2
         -> Verifier que le RPi2 est sous tension (LED rouge allumee)
         -> Verifier l'alimentation electrique
         -> Si eteint, redemarrer le RPi2

ETAPE 4 : Tenter une connexion SSH
         -> ssh habyss@10.42.0.2
         -> Si la connexion aboutit : verifier les services
         -> systemctl status sshd
         -> ufw status

ETAPE 5 : Si le RPi2 ne repond toujours pas
         -> Connecter un clavier et un ecran directement au RPi2
         -> Verifier les messages de boot
         -> Verifier l'etat du systeme de fichiers
         -> Contacter Analyss si le probleme persiste
```

---

## 4. Procedures de restauration

### 4.1 Restauration apres ransomware

**Prerequis :**
- Les postes clients infectes sont isoles du reseau
- Le RPi1 est accessible et fonctionnel (ou reinstalle)
- Le RPi2 est intact

**Procedure de restauration depuis C2 (RPi2) :**

```
ETAPE 1 : Verifier l'integrite des donnees sur RPi2
         -> Se connecter au RPi1
         -> rclone check cryoss-c2-crypt: /etc/encrypted/
         -> OU verifier manuellement les checksums

ETAPE 2 : Identifier la version a restaurer
         -> rclone lsf cryoss-versions:
         -> Identifier la derniere version saine (avant l'infection)
         -> Format attendu : YYYY-MM-DD/

ETAPE 3 : Restaurer les donnees en clair
         -> rclone sync cryoss-versions:YYYY-MM-DD /etc/sauvegarde/
         -> Remplacer YYYY-MM-DD par la date de la version saine

ETAPE 4 : Verifier la restauration
         -> Comparer le contenu restaure avec les attentes du client
         -> Verifier l'integrite des fichiers (ouverture, checksums)

ETAPE 5 : Re-chiffrer et resynchroniser
         -> Relancer le cycle de sauvegarde complet
         -> Verifier que les 3 copies (C1, C2, C3) sont a jour
```

**Procedure de restauration depuis C3 (distant) :**

Si le RPi2 n'est pas disponible ou si ses donnees sont suspectes :

```
ETAPE 1 : Se connecter au serveur SFTP distant
         -> rclone lsf cryoss-c3-crypt:

ETAPE 2 : Restaurer depuis C3
         -> rclone sync cryoss-c3-crypt: /etc/sauvegarde/ --progress

ETAPE 3 : Verifier et resynchroniser
         -> Meme verification que pour C2
         -> Resynchroniser les copies C1 et C2
```

### 4.2 Ordre de priorite des sources de restauration

| Priorite | Source | Avantage | Inconvenient |
|----------|--------|----------|--------------|
| 1 | **C2 (RPi2)** | Locale, rapide, air-gap | Necessite interco fonctionnelle |
| 2 | **C3 (distant)** | Independante du site | Plus lente (reseau), necessite Internet |
| 3 | **C1 (RPi1 RAID)** | Deja sur place | Potentiellement compromise si RPi1 est affecte |

---

## 5. Communication

### 5.1 Notification client

En cas d'incident P1 ou P2, le client doit etre informe :

**Contenu de la notification :**
1. Nature de l'incident (sans details techniques excessifs)
2. Impact sur le service de sauvegarde
3. Actions en cours
4. Delai estime de resolution
5. Actions attendues du client (isoler des postes, ne pas redemarrer, etc.)

**Canaux :** telephone puis confirmation par email.

### 5.2 Notification Analyss

Tout incident P1 ou P2 doit etre signale a Analyss :

- **Email :** support@analyss.fr
- **Objet :** `[SECURITE] [NOM_CLIENT] -- Description breve`
- **Contenu :** date, heure, symptomes, actions entreprises, etat actuel

Pour les incidents P1 (critique), contacter Analyss par telephone en complement de l'email.

---

## 6. Post-mortem

### 6.1 Declenchement

Un post-mortem est realise apres tout incident P1 ou P2 resolu. Il est optionnel pour les incidents P3 et P4.

### 6.2 Template de post-mortem

```
=== POST-MORTEM INCIDENT ===

Date de l'incident   : YYYY-MM-DD HH:MM
Date de resolution    : YYYY-MM-DD HH:MM
Duree totale         : X heures / jours
Classification       : P1 / P2 / P3 / P4
Client               : [NOM_CLIENT]
Redacteur            : [NOM_TECHNICIEN]

--- RESUME ---
Description en 2-3 phrases de l'incident et de son impact.

--- CHRONOLOGIE ---
HH:MM - Detection de l'incident (source : honeypot / health check / etc.)
HH:MM - Premiere action de confinement
HH:MM - Diagnostic termine
HH:MM - Debut de la restauration
HH:MM - Restauration terminee, service retabli
HH:MM - Verification post-restauration

--- CAUSE RACINE ---
Description de la cause profonde de l'incident.
Distinguer la cause directe (ex: disque defaillant) de la cause profonde
(ex: disque en fin de vie, pas de monitoring SMART).

--- IMPACT ---
- Donnees perdues : oui / non (si oui, quantifier)
- Duree d'indisponibilite du service de sauvegarde : X heures
- Postes clients affectes : X postes
- Copies de sauvegarde affectees : C1 / C2 / C3

--- ACTIONS CORRECTIVES ---
1. [ACTION] - Responsable - Delai
2. [ACTION] - Responsable - Delai
3. [ACTION] - Responsable - Delai

--- LECONS APPRISES ---
- Ce qui a bien fonctionne
- Ce qui peut etre ameliore
- Modifications a apporter aux procedures

--- VALIDATION ---
Valide par : [NOM_RESPONSABLE]
Date de validation : YYYY-MM-DD
```

---

## 7. Reflexe "coupe interco"

### 7.1 Principe

La deconnexion physique du cable interco entre RPi1 et RPi2 est le **dernier recours** pour proteger la copie C2 sur RPi2. Cette action isole completement le RPi2 de tout acces reseau.

### 7.2 Quand couper l'interco

**COUPER immediatement si :**

- Le RPi1 est confirme compromis ET l'attaquant a potentiellement acces aux credentials `ds-repl`
- Des transferts SFTP suspects sont observes vers RPi2 (fichiers non attendus, volume anormal)
- Un processus malveillant tente activement d'acceder a 10.42.0.2
- En cas de doute serieux sur l'integrite du RPi1 et impossibilite de verifier rapidement

**NE PAS couper si :**

- L'incident est limite aux postes clients (ransomware via Samba uniquement)
- Le RPi1 est fonctionnel et non compromis
- Le probleme est un RAID degrade ou une panne materielle
- Il s'agit d'une tentative d'intrusion SSH bloquee par fail2ban

### 7.3 Procedure de coupure

```
ETAPE 1 : Localiser le cable Ethernet interco
         -> Cable reliant directement RPi1 a RPi2
         -> Distinct du cable LAN du RPi1

ETAPE 2 : Debrancher physiquement le cable
         -> Cote RPi1 de preference (plus accessible)
         -> Etiqueter le cable pour le retrouver facilement

ETAPE 3 : Documenter l'action
         -> Heure de deconnexion
         -> Raison de la deconnexion
         -> Etat du RPi2 avant deconnexion (si connu)

ETAPE 4 : Notifier Analyss
         -> Mentionner que l'interco a ete coupee
         -> L'equipe Analyss guidera la procedure de reconnexion
```

### 7.4 Reconnexion de l'interco

La reconnexion ne doit etre effectuee qu'apres :

1. Confirmation que le RPi1 est sain (reinstalle ou nettoye)
2. Verification de l'integrite des donnees sur RPi2
3. Regeneration des cles SSH de `ds-repl` (par precaution)
4. Validation par l'equipe Analyss

```
ETAPE 1 : Regenerer les cles SSH de ds-repl
         -> ssh-keygen -t ed25519 -f /home/ds-repl/.ssh/id_ed25519
         -> Copier la nouvelle cle publique sur RPi2

ETAPE 2 : Rebrancher le cable interco

ETAPE 3 : Tester la connectivite
         -> ping -c 3 10.42.0.2
         -> sftp ds-repl@10.42.0.2

ETAPE 4 : Relancer la replication
         -> Verifier que la replication fonctionne normalement
         -> Surveiller les premieres synchronisations
```

---

## 8. Contacts d'urgence

| Contact | Coordonnees | Disponibilite |
|---------|-------------|---------------|
| Support Analyss | support@analyss.fr | Lun-Ven 9h-18h |
| Urgence securite | support@analyss.fr (objet [SECURITE]) | 4h ouvrables |
| Technicien de deploiement | Selon contrat client | Selon contrat |

---

## 9. Exercices et tests

### 9.1 Frequence

| Test | Frequence | Responsable |
|------|-----------|-------------|
| Test de restauration depuis C2 | **Semestriel** | Analyss |
| Test de restauration depuis C3 | **Annuel** | Analyss |
| Simulation d'alerte honeypot | **Annuel** | Analyss |
| Verification de la procedure RAID | **A chaque remplacement** | Technicien |
| Revue du plan de reponse | **Annuel** | Equipe securite |

### 9.2 Documentation des tests

Chaque test est documente avec :
- Date et heure du test
- Procedure suivie
- Resultat (succes / echec / partiel)
- Temps de restauration mesure (RTO reel)
- Actions correctives si necessaire

---

*Document maintenu par l'equipe securite Analyss. Ce plan doit etre accessible a tout technicien intervenant sur une installation Cryoss, y compris en version imprimee sur site.*
