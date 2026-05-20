# Guide de deploiement Cryoss

> Cryoss -- Sauvegarde chiffree triple-redondante sur paires de Raspberry Pi.
> Produit par Analyss.

---

## Checklist pre-deploiement

Avant de partir sur site, verifier :

- [ ] 2x Raspberry Pi 5 (4 Go ou 8 Go RAM)
- [ ] 2x Penta SATA HAT (compatible RPi 5)
- [ ] 4x HDD pour RPi1 (RAID 5) + 2x HDD pour RPi2 (RAID 1)
- [ ] 2x carte microSD (32 Go minimum, classe A2 recommandee)
- [ ] 1x cable Ethernet RJ45 pour l'interconnexion directe RPi1-RPi2
- [ ] 1x cable Ethernet pour connecter RPi1 au LAN client
- [ ] Alimentations adaptees (5V/5A officielle RPi 5 pour chaque)
- [ ] Cle USB avec les scripts d'installation a jour
- [ ] Informations client : nom du client, adresse IP LAN disponible, passerelle, DNS, email contact (optionnel)
- [ ] Identifiants SMTP (mot de passe pour l'envoi d'alertes)
- [ ] Numero de serie attribue au format DS-XXXXXXXX (meme serial pour RPi1 et RPi2 de la paire)

---

## Etape 1 -- Preparation materielle

1. Assembler les Penta SATA HAT sur chaque RPi 5 selon la documentation constructeur.
2. Inserer les disques durs :
   - **RPi1** : 4 HDD dans les baies du Penta SATA HAT (RAID 5).
   - **RPi2** : 2 HDD dans les baies du Penta SATA HAT (RAID 1).
3. Ne pas encore brancher les cables Ethernet. On les connectera aux etapes appropriees.

---

## Etape 2 -- Installation du systeme d'exploitation

Sur les deux RPis :

1. Telecharger **Raspberry Pi OS Lite 64-bit** (derniere version stable, Bookworm minimum).
2. Flasher l'image sur chaque carte microSD avec Raspberry Pi Imager ou `dd`.
3. Configurer via Imager (ou fichiers dans la partition boot) :
   - Activer SSH.
   - Definir un mot de passe temporaire pour l'utilisateur `pi` (ou le compte par defaut).
   - Configurer le hostname : `cryoss-rpi1` et `cryoss-rpi2`.
4. Inserer les cartes SD et demarrer chaque RPi.
5. Se connecter en SSH pour verifier le bon demarrage.

---

## Etape 2bis -- Activation PCIe pour le Penta SATA HAT (CRITIQUE)

**A faire sur RPi1 ET RPi2 avant les scripts d'installation.** Sans cette
manip, le kernel Raspberry Pi 5 n'enumere pas le bus PCIe et les disques du
Penta SATA HAT sont invisibles (`lsblk` ne montre que `mmcblk0`).

### 2bis.1 Activer le PCIe

```bash
sudo nano /boot/firmware/config.txt
```

Ajouter en fin de fichier :

```ini
# Cryoss — Penta SATA HAT (PCIe x1 activation)
dtparam=pciex1
# Optionnel : forcer Gen 3 (5 GT/s). A activer SEULEMENT si dtparam=pciex1
# seul fonctionne deja, pour eviter les regressions sur cables/HATs limites.
# dtparam=pciex1_gen=3
```

```bash
sudo reboot
```

### 2bis.2 Verifier la detection

```bash
# 1) Le bus PCIe doit apparaitre
lspci
# Exemple : "0000:01:00.0 SATA controller: ASMedia Technology Inc. ASM1166"

# 2) Les disques doivent etre listes
lsblk -d -o NAME,SIZE,MODEL,SERIAL,TRAN
# Exemple :
#   sda  3.6T  ST4000VN008  WD-ABCDE12  sata
#   sdb  3.6T  ST4000VN008  WD-FGHIJ34  sata
#   sdc  3.6T  ST4000VN008  WD-KLMNO56  sata
#   sdd  3.6T  ST4000VN008  WD-PQRST78  sata
```

### 2bis.3 Identifier physiquement chaque disque

**A faire avant `install_rpi1.sh`** — le script formate les disques. Si on se
trompe d'identification, le depannage en cas de panne disque (remplacement a
chaud) sera laborieux : il faudra a nouveau passer par `dd` ou desassembler.

```bash
# Faire clignoter chaque disque tour a tour pour reperer la baie HAT
for d in /dev/sda /dev/sdb /dev/sdc /dev/sdd; do
    echo "Clignotement de $d pendant 10s — observe les LEDs..."
    sudo dd if="$d" of=/dev/null bs=1M count=2000 status=none &
    sleep 10
    wait
    read -rp "  Quelle baie HAT ? (1/2/3/4) : " baie
    serial=$(sudo smartctl -i "$d" | awk '/Serial Number/{print $3}')
    echo "  → Baie $baie = $d = serial $serial"
done
```

**Coller une etiquette physique sur chaque disque** :
- Numero de baie HAT (1 a 4)
- 6 derniers chiffres du serial
- Role Cryoss (md0=sauvegarde / md1=encrypted)

**Layout de reference Cryoss** :

| Baie HAT | /dev/* | RAID | Role |
|----------|--------|------|------|
| S1 (haut-gauche)  | sda | md0 | /etc/sauvegarde (donnees client) |
| S2 (haut-droit)   | sdb | md0 | /etc/sauvegarde (miroir) |
| S3 (bas-gauche)   | sdc | md1 | /etc/encrypted (chiffre rclone) |
| S4 (bas-droit)    | sdd | md1 | /etc/encrypted (miroir) |

### 2bis.4 (Recommande) Liens stables via udev

Les noms `sdX` peuvent permuter au reboot. Cryoss utilise les UUID donc le
RAID n'est pas affecte, mais des liens stables `/dev/cryoss/baieN` facilitent
le depannage :

```bash
sudo tee /etc/udev/rules.d/99-cryoss-disks.rules <<'EOF'
# Remplacer chaque WD-XXXX par les serials releves a l'etape 2bis.3
SUBSYSTEM=="block", ATTRS{serial}=="WD-XXXX1", SYMLINK+="cryoss/baie1"
SUBSYSTEM=="block", ATTRS{serial}=="WD-XXXX2", SYMLINK+="cryoss/baie2"
SUBSYSTEM=="block", ATTRS{serial}=="WD-XXXX3", SYMLINK+="cryoss/baie3"
SUBSYSTEM=="block", ATTRS{serial}=="WD-XXXX4", SYMLINK+="cryoss/baie4"
EOF

sudo udevadm control --reload-rules
sudo udevadm trigger
ls -l /dev/cryoss/   # → baie1 -> ../sda, etc.
```

---

## Etape 3 -- Planification reseau

Deux reseaux sont necessaires :

| Reseau       | Sous-reseau       | RPi1           | RPi2           | Usage                        |
|--------------|-------------------|----------------|----------------|------------------------------|
| LAN client   | Selon le client   | IP fixe client | Aucune         | Acces Samba, API, heartbeat  |
| Interco      | 10.42.0.0/30      | 10.42.0.1      | 10.42.0.2      | Replication RPi1 vers RPi2   |

- RPi1 a deux interfaces reseau : LAN client (eth0) + interco (eth1 ou USB-Ethernet).
- RPi2 n'a qu'une seule interface : interco uniquement (eth0). **RPi2 ne doit jamais etre connecte a Internet.**

Collecter aupres du client :
- Adresse IP disponible sur le LAN pour RPi1.
- Passerelle par defaut.
- Serveur(s) DNS.

---

## Etape 4 -- Installation de RPi1

### 4.1 Copie des scripts

```bash
# Depuis la cle USB ou via SCP
sudo mkdir -p /opt/Cryoss
sudo cp -r /media/usb/cryoss-scripts/* /opt/Cryoss/
sudo chmod +x /opt/Cryoss/*.sh
```

### 4.2 Execution du script d'installation

```bash
cd /opt/Cryoss
sudo bash install_rpi1.sh
```

Le script est **interactif**. Il demandera :
- Nom du client (utilise pour les chemins et la config).
- Mot de passe SMTP (pour l'envoi des alertes email).
- Configuration reseau : IP LAN client, passerelle, DNS, masque.
- Activation SFTP distant (optionnel, chemin C3).
- Lancement du wizard de partages Samba personnalises (etape 11b).

#### Modes de reprise et de rejeu

L'install est decoupee en 15 etapes avec checkpoints persistants. Si elle est
interrompue ou si un parametre doit etre change apres coup :

```bash
# Voir l'etat des etapes
sudo bash install_rpi1.sh --list-steps

# Reprendre apres interruption
sudo bash install_rpi1.sh --resume

# Repartir depuis une etape precise (rejoue celle-la + suivantes)
sudo bash install_rpi1.sh --from-step 11-samba

# Rejouer UNE SEULE etape (ex : ajouter de nouveaux partages plus tard)
sudo bash install_rpi1.sh --only-step 11b-samba-wizard

# Tout effacer pour repartir de zero
sudo bash install_rpi1.sh --reset

# Aide
sudo bash install_rpi1.sh --help
```

**Fichiers d'etat (mode 600 root)** :
- `/var/lib/cryoss/install.state` — etapes validees
- `/var/lib/cryoss/install.env` — variables collectees (mots de passe inclus)
- `/var/log/cryoss-install.log` — log brut des commandes

### 4.3 Ce que fait le script

Le script `install_rpi1.sh` effectue dans l'ordre (15 etapes, IDs entre parentheses) :

1. **Paquets** (`01-packages`) : installation de mdadm, rclone, samba, msmtp, smartmontools, ufw, fail2ban, etc.
2. **IP fixe** (`02-network`) : configuration de l'interface LAN avec l'IP client et de l'interface interco en 10.42.0.1/30.
3. **RAID 1** (`03-raid`) : creation de md0 (sda+sdb -> /etc/sauvegarde) et md1 (sdc+sdd -> /etc/encrypted), formatage ext4.
4. **Repertoires et montage** (`04-mounts`) : montage des md, persistance fstab, mdadm.conf, initramfs.
5. **Utilisateurs systeme** (`05-users`) : creation des comptes `ds-user` (Samba R/W, nologin), `habyss` (admin sudo+SSH+Samba).
6. **rclone** (`06-rclone`) : generation des 3 paires de cles (C1/C2/C3), config rclone avec 3 remotes crypt independants, sauvegarde dans `/etc/cryoss/keys-backup.conf`.
7. **Cle SSH RPi2** (`07-ssh-rpi2`) : generation de la cle ED25519 `cryoss_rpi2`, copie automatique vers RPi2.
8. **msmtp + relais SMTP** (`09-msmtp`) : config msmtp pour les alertes, postfix null-client pour relayer les emails du RPi2.
9. **Librairie email HTML** (`09b-emaillib`) : `/usr/local/lib/cryoss-email.sh` partagee.
10. **Script backup** (`10-backup-script`) : `/usr/local/bin/cryoss-backup.sh` (3 chemins independants, lockfile, alertes HTML).
11. **Samba de base** (`11-samba`) : `[sauvegarde]` (R/W ds-user+habyss) et `[encrypted_backup]` (R-only habyss). SMB2+ + chiffrement force.
12. **Wizard Samba** (`11b-samba-wizard`) : (interactif) creation de partages personnalises, utilisateurs Samba purs (nologin + Unix locked), matrice de droits.
13. **Services et timers** (`12-systemd`) : `cryoss-backup.timer` (02h), `cryoss-sftp-sync.timer` (06h/08h/14h/20h).
14. **Durcissement** (`13-hardening`) : SSH durci, UFW, fail2ban, sysctl, logrotate.
15. **Monitoring** (`14-monitoring`) : `cryoss-health.sh` + timers daily/weekly/watchdog.

#### Wizard de partages personnalises (etape 11b)

Cree des dossiers-partages supplementaires sous `/etc/sauvegarde` (ou autre
chemin) avec des utilisateurs Samba **purs** :

- `useradd -r -M -s /usr/sbin/nologin -d /nonexistent` — pas de home, pas de shell
- `passwd -l` — mot de passe Unix verrouille (impossible de SSH ou login console)
- `smbpasswd -a` — seul Samba peut authentifier ces utilisateurs

La **matrice user × partage** definit pour chaque combinaison : `R` (lecture
seule), `RW` (lecture + ecriture) ou `–` (refus). Le wizard genere les blocs
Samba avec `valid users` / `read list` / `write list` / `invalid users` qui vont.

Persistance :
- `/etc/cryoss/shares.conf` — source de verite (rejouable)
- `/etc/samba/cryoss-shares.conf` — partages effectifs inclus depuis `smb.conf`

Pour ajouter / modifier des partages plus tard, sans toucher au reste :

```bash
sudo bash install_rpi1.sh --only-step 11b-samba-wizard
```

---

## Etape 5 -- Installation de RPi2

### 5.1 Connexion a RPi2

Deux methodes possibles :

- **Depuis RPi1 via interco** : RPi2 est deja accessible en 10.42.0.2 si le cable interco est branche et RPi2 demarre avec une IP temporaire.
- **Via le LAN temporairement** : brancher RPi2 au LAN client le temps de l'installation, puis le debrancher.

```bash
# Depuis RPi1
ssh pi@10.42.0.2
```

### 5.2 Copie des scripts et execution

```bash
sudo mkdir -p /opt/Cryoss
# Copier les scripts (SCP depuis RPi1 ou cle USB)
scp -r /opt/Cryoss/* pi@10.42.0.2:/tmp/cryoss/
# Sur RPi2 :
sudo cp -r /tmp/cryoss/* /opt/Cryoss/
sudo chmod +x /opt/Cryoss/*.sh
cd /opt/Cryoss
sudo bash install_rpi2.sh
```

Le script est **interactif**. Il demandera :
- Nom du client.
- Mots de passe pour les utilisateurs locaux.

### 5.3 Ce que fait le script

Le script `install_rpi2.sh` effectue :

1. **Paquets** : installation de mdadm, rclone, openssh-server, smartmontools, etc.
2. **IP fixe** : configuration de l'interface interco en 10.42.0.2/30. Pas d'interface LAN.
3. **RAID 1** : creation de la grappe RAID 1 sur les 2 disques, formatage ext4, montage sur `/mnt/raid`.
4. **Utilisateurs** : creation des comptes necessaires, dont `ds-repl` pour recevoir la replication.
5. **SFTP chroot** : configuration du chroot SFTP pour l'utilisateur de replication (securisation).
6. **SSH hardening** : desactivation de l'authentification par mot de passe, cle publique uniquement (cle de RPi1).
7. **Script de sante** : installation de `cryoss-health.sh` (version RPi2).

> **Important** : RPi2 n'a **pas** de heartbeat (air-gappe) et son install
> n'inclut pas le hardening anti-ransomware (concerne uniquement RPi1).

---

## Etape 6 -- Hardening anti-ransomware (integre a install_rpi1.sh)

Le hardening 4 couches est desormais integre a `install_rpi1.sh` (steps 16-19),
plus de script `install_security.sh` separe. Il s'execute automatiquement en
fin d'install. Pour rejouer uniquement ce hardening :

```bash
cd /opt/Cryoss
sudo bash install_rpi1.sh --from-step 16-versioning-sftp
```

Couches mises en place :
- **C1 — Versioning SFTP** (step 16-versioning-sftp) : `rclone --backup-dir`
  conserve les anciennes versions cote SFTP distant avec retention 30j.
- **C2 — Honeypot inotify** (step 17-honeypot) : fichier leurre + alerte
  email immediate.
- **C3 — chattr +a** (step 18-chattr-append) : `/etc/encrypted` append-only.
- **C4 — AppArmor** (step 19-apparmor) : profils smbd (enforce) +
  cryoss-backup (complain -> enforce auto a T+24h).

Le durcissement systeme de base (fail2ban, sysctl, sshd, UFW) est en
step 13-hardening (toujours execute).

---

## Etape 7 -- API et heartbeat

Executer sur **les deux RPis** :

```bash
# Sur RPi1
cd /opt/Cryoss
sudo bash install_api.sh

# Sur RPi2 (depuis RPi1 via SSH ou directement)
ssh ds-repl@10.42.0.2
cd /opt/Cryoss
sudo bash install_api.sh
```

Sur RPi1, le script installe :
- L'API locale Cryoss (port configure).
- Le service heartbeat (envoi toutes les 5 minutes vers `https://app.analyss.fr/api/sync/cryoss/heartbeat`).
- La configuration dans `/etc/cryoss/analyss.conf`.

Sur RPi2, le script installe :
- L'API locale uniquement. **Pas de heartbeat** (RPi2 est air-gappe).

---

## Etape 8 -- Enregistrement aupres d'Analyss

Sur RPi1 uniquement :

```bash
sudo cryoss-heartbeat.sh register
```

Cette commande enregistre la paire Cryoss aupres de la plateforme Analyss avec le numero de serie DS-XXXXXXXX. Elle effectue un premier heartbeat de validation.

Verifier que l'instance apparait sur le dashboard Analyss (`https://app.analyss.fr`).

---

## Etape 9 -- Tests post-installation

```bash
cd /opt/Cryoss
sudo bash tests/cryoss-test.sh            # = all (auto-detect role)
sudo bash tests/cryoss-test.sh install    # post-install validation uniquement
sudo bash tests/cryoss-test.sh runner     # tests command-flow runtime (RPi1)
```

Le script `tests/cryoss-test.sh` verifie automatiquement :
- Etat des grappes RAID (RPi1 et RPi2).
- Connectivite interco (ping 10.42.0.2 depuis RPi1).
- Services actifs (samba, ssh, api, timers).
- Cles rclone presentes et coherentes.
- Replication fonctionnelle (test de transfert).
- Envoi d'email de test.
- Heartbeat fonctionnel.
- (RPi1 only) Runner command-flow : whitelist, dispatch, ACK Analyss.

Corriger toute erreur avant de passer a l'etape finale.

---

## Etape 10 -- Finalisation

1. **Deconnecter RPi2 du LAN** (si il etait temporairement connecte). Seul le cable interco doit rester branche entre RPi1 et RPi2.
2. **Verifier l'air-gap** : depuis RPi2, confirmer qu'aucune route vers Internet n'existe :
   ```bash
   # Sur RPi2
   ping -c 1 8.8.8.8   # Doit echouer
   ip route             # Ne doit afficher que 10.42.0.0/30
   ```
3. **Redemarrer les deux RPis** :
   ```bash
   # Sur RPi1
   sudo reboot
   # Sur RPi2 (depuis RPi1 apres reboot)
   ssh ds-repl@10.42.0.2 'sudo reboot'
   ```
4. Apres redemarrage, attendre 5 minutes puis verifier :
   - Le heartbeat remonte sur le dashboard Analyss.
   - Le partage Samba est accessible depuis le poste client.
   - Les timers systemd sont actifs (`systemctl list-timers`).

---

## Checklist post-installation

- [ ] `dtparam=pciex1` present dans `/boot/firmware/config.txt` (les deux RPis)
- [ ] Disques etiquetes physiquement (baie HAT + role md0/md1)
- [ ] Tous les disques detectes (`lsblk` montre sda/sdb/sdc/sdd sur RPi1)
- [ ] RAID RPi1 en etat `active` (4/4 disques)
- [ ] RAID RPi2 en etat `active` (2/2 disques)
- [ ] Interco fonctionnelle (ping 10.42.0.1 <-> 10.42.0.2)
- [ ] RPi2 sans acces Internet (air-gap confirme)
- [ ] Partage Samba accessible depuis le poste client
- [ ] Cles rclone presentes dans `/root/.config/rclone/rclone.conf` (3 paires)
- [ ] Sauvegarde des cles dans `/etc/cryoss/keys-backup.conf`
- [ ] Heartbeat actif et visible sur le dashboard Analyss
- [ ] Email de test recu par `support@habyss.fr`
- [ ] Tous les timers systemd actifs (`systemctl list-timers --all`)
- [ ] Suite `tests/cryoss-test.sh` passe sans erreur (sur RPi1 ET RPi2)
- [ ] RPi2 deconnecte du LAN client
- [ ] Numero de serie DS-XXXXXXXX note dans le dossier client
- [ ] Copie offline des cles remise au responsable (si politique client)
- [ ] **Decision sur `/var/lib/cryoss/install.env`** (contient mots de passe SMTP/SFTP en clair, mode 600 root) :
  - Soit le conserver pour permettre `--resume`/`--from-step` (poste dedie)
  - Soit le supprimer apres install reussie : `sudo rm /var/lib/cryoss/install.env`
