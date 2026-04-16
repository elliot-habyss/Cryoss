# Gestion des secrets Cryoss

> Cryoss -- Sauvegarde chiffree triple-redondante sur paires de Raspberry Pi.
> Produit par Analyss.

---

## Inventaire des secrets

Le systeme Cryoss manipule les secrets suivants :

| Secret                         | Description                                                | Localisation                                  |
|--------------------------------|------------------------------------------------------------|-----------------------------------------------|
| Cles rclone (x3 paires)       | Paires de cles de chiffrement (C1, C2, C3)                | `/root/.config/rclone/rclone.conf`            |
| Sauvegarde des cles rclone     | Copie de secours des 3 paires                              | `/etc/cryoss/keys-backup.conf`                |
| Cle API locale                 | Authentification de l'API Cryoss locale                    | `/etc/cryoss/api-key`                         |
| Cle API Analyss                | Authentification vers la plateforme Analyss (heartbeat)    | `/etc/cryoss/analyss.conf`                    |
| Mot de passe SMTP              | Envoi des alertes email                                    | `/etc/msmtprc`                                |
| Mot de passe `ds-user`         | Compte Samba pour l'acces client                           | Systeme local (shadow)                        |
| Mot de passe `habyss`          | Compte d'administration                                    | Systeme local (shadow)                        |
| Mot de passe `ds-repl`         | Compte de replication RPi1 vers RPi2                       | Systeme local (shadow)                        |
| Cle SSH `cryoss_rpi2`          | Cle privee pour la connexion automatique RPi1 -> RPi2      | `/root/.ssh/cryoss_rpi2` (RPi1)              |

---

## Permissions des fichiers

Tous les fichiers contenant des secrets ont des permissions restrictives. Ne jamais les modifier.

| Fichier                                  | Proprietaire | Permissions |
|------------------------------------------|--------------|-------------|
| `/root/.config/rclone/rclone.conf`       | root:root    | 600         |
| `/etc/cryoss/keys-backup.conf`           | root:root    | 600         |
| `/etc/cryoss/api-key`                    | root:cryoss  | 640         |
| `/etc/cryoss/analyss.conf`               | root:root    | 600         |
| `/etc/msmtprc`                           | root:root    | 600         |
| `/root/.ssh/cryoss_rpi2`                 | root:root    | 600         |

Verifier periodiquement avec :

```bash
stat -c '%U:%G %a %n' /root/.config/rclone/rclone.conf /etc/cryoss/keys-backup.conf /etc/cryoss/api-key /etc/cryoss/analyss.conf /etc/msmtprc /root/.ssh/cryoss_rpi2
```

---

## Generation des cles

### Cles rclone

Les 3 paires de cles rclone sont **auto-generees** lors de l'execution de `install_rpi1.sh`. Chaque paire est constituee d'une cle de chiffrement et d'un sel (salt), utilisees par rclone pour le chiffrement crypt.

Les cles sont ecrites dans :
- `/root/.config/rclone/rclone.conf` -- fichier de configuration rclone actif.
- `/etc/cryoss/keys-backup.conf` -- copie de sauvegarde.

Les trois chemins de chiffrement :
- **C1** : chiffrement local sur RPi1 (donnees sur le RAID RPi1).
- **C2** : chiffrement pour la replication vers RPi2 (donnees transferees via interco).
- **C3** : chiffrement pour la copie cloud (si active).

### Cle SSH

La cle SSH `cryoss_rpi2` est generee par `install_rpi1.sh`. La cle publique est copiee dans le fichier `authorized_keys` de l'utilisateur `ds-repl` sur RPi2 lors de l'execution de `install_rpi2.sh`.

---

## Specificite air-gap de RPi2

RPi2 ne se connecte **jamais** a Internet. Ses cles sont derivees de celles de RPi1 au moment de l'installation :

- Les cles rclone du chemin C2 sont copiees de RPi1 vers RPi2 lors de `install_rpi2.sh`.
- La cle publique SSH est transmise de RPi1 vers RPi2 au meme moment.
- Apres l'installation, RPi2 est deconnecte du LAN. Toute communication passe exclusivement par l'interco 10.42.0.0/30.

**Consequence** : il n'est pas possible de regenerer les cles de RPi2 a distance. Toute rotation de cles sur RPi2 necessite un acces physique ou un passage par l'interco depuis RPi1.

---

## Politique de rotation des cles

### Cles rclone

- **Frequence recommandee** : annuelle, ou immediatement en cas de compromission suspectee.
- **Procedure** : reinstallation via `install_rpi1.sh` avec regeneration des cles. Les donnees chiffrees existantes devront etre re-chiffrees avec les nouvelles cles ou conservees avec une copie des anciennes cles.
- **Attention** : changer les cles rclone rend les sauvegardes chiffrees anterieures illisibles sans les anciennes cles. Conserver impérativement une copie des anciennes cles avant rotation.

### Cle API Analyss

- Rotation sur demande via le dashboard Analyss.
- Mettre a jour `/etc/cryoss/analyss.conf` sur RPi1 apres rotation.
- Redemarrer le service heartbeat : `sudo systemctl restart cryoss-heartbeat.timer`.

### Mot de passe SMTP

- Rotation selon la politique du fournisseur SMTP.
- Mettre a jour `/etc/msmtprc` sur RPi1.
- Tester l'envoi : `echo "test" | msmtp support@habyss.fr`.

### Mots de passe utilisateurs

- Rotation recommandee tous les 6 mois.
- `sudo passwd <utilisateur>` sur le RPi concerne.
- Pour `ds-repl`, mettre a jour sur les deux RPis.

### Cle SSH

- Rotation annuelle ou en cas de compromission.
- Regenerer sur RPi1 : `ssh-keygen -t ed25519 -f /root/.ssh/cryoss_rpi2 -N ""`.
- Copier la nouvelle cle publique sur RPi2 : `ssh-copy-id -i /root/.ssh/cryoss_rpi2.pub ds-repl@10.42.0.2`.

---

## Sauvegarde des secrets

### Fichier maitre

Le fichier `/etc/cryoss/keys-backup.conf` est la **sauvegarde maitre** de toutes les cles rclone. C'est le fichier le plus critique du systeme.

### Copie offline obligatoire

Apres chaque installation ou rotation de cles :

1. Copier `keys-backup.conf` sur un support externe chiffre (cle USB chiffree, coffre-fort).
2. Remettre cette copie au responsable designe chez le client ou la conserver dans le coffre Analyss.
3. Ne **jamais** laisser cette copie sur un support non chiffre ou accessible via le reseau.

```bash
# Exemple : copie sur cle USB montee en /media/usb
sudo cp /etc/cryoss/keys-backup.conf /media/usb/cryoss-keys-DS-XXXXXXXX.conf
sudo umount /media/usb
```

---

## Perte de cles -- Procedure de recuperation

### Cas 1 : `rclone.conf` corrompu mais `keys-backup.conf` intact

```bash
sudo cp /etc/cryoss/keys-backup.conf /root/.config/rclone/rclone.conf
sudo chmod 600 /root/.config/rclone/rclone.conf
```

Redemarrer les services de sauvegarde.

### Cas 2 : Les deux fichiers perdus mais copie offline disponible

1. Recuperer la copie offline de `keys-backup.conf`.
2. Restaurer comme dans le cas 1.

### Cas 3 : Toutes les cles perdues

**Situation critique.** Les donnees chiffrees sur le RAID (via rclone crypt) sont **irrecuperables** sans les cles.

Cependant :
- Les donnees locales dans `/etc/sauvegarde` sont stockees **en clair**. Elles restent accessibles.
- Il faudra **reinstaller** le systeme Cryoss (execution complete de `install_rpi1.sh` puis `install_rpi2.sh`) pour generer de nouvelles cles.
- Les anciennes sauvegardes chiffrees seront perdues.

---

## Regles absolues

1. **Jamais dans git** : aucun secret ne doit etre commite dans un depot git. Verifier les `.gitignore`.
2. **Jamais dans les logs** : les scripts Cryoss ne loguent jamais de cles ou mots de passe. Ne pas ajouter de `echo` debug qui afficheraient des secrets.
3. **Jamais dans le heartbeat** : le payload heartbeat envoye a Analyss ne contient **aucun** secret. Il transmet uniquement des metriques systeme et des etats de service.
4. **Jamais en clair sur le reseau** : toute transmission de cles se fait via SSH (interco) ou HTTPS (Analyss).
5. **Jamais sur un poste non autorise** : les cles ne doivent etre manipulees que sur les RPis Cryoss ou sur le support offline securise.
