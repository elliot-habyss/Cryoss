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

1. Telecharger **Raspberry Pi OS Lite 64-bit** (derniere version stable).
2. Flasher l'image sur chaque carte microSD avec Raspberry Pi Imager ou `dd`.
3. Configurer via Imager (ou fichiers dans la partition boot) :
   - Activer SSH.
   - Definir un mot de passe temporaire pour l'utilisateur `pi` (ou le compte par defaut).
   - Configurer le hostname : `cryoss-rpi1` et `cryoss-rpi2`.
4. Inserer les cartes SD et demarrer chaque RPi.
5. Se connecter en SSH pour verifier le bon demarrage.

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
- Activation SFTP (optionnel, pour l'acces client direct).

### 4.3 Ce que fait le script

Le script `install_rpi1.sh` effectue dans l'ordre :

1. **Paquets** : installation de mdadm, rclone, samba, msmtp, jq, smartmontools, etc.
2. **IP fixe** : configuration de l'interface LAN avec l'IP client et de l'interface interco en 10.42.0.1/30.
3. **RAID 5** : creation de la grappe RAID 5 sur les 4 disques, formatage ext4, montage sur `/mnt/raid`.
4. **Utilisateurs** : creation des comptes `ds-user` (acces Samba), `habyss` (administration), `ds-repl` (replication vers RPi2).
5. **Cles rclone** : generation de 3 paires de cles de chiffrement (C1, C2, C3), stockees dans `/root/.config/rclone/rclone.conf` et sauvegardees dans `/etc/cryoss/keys-backup.conf`.
6. **Samba** : configuration du partage pour le client (acces via `ds-user`).
7. **SSH** : generation de la cle SSH `cryoss_rpi2` pour la connexion automatique vers RPi2.
8. **Script de sauvegarde** : installation de `cryoss-backup.sh` et du timer systemd associe.
9. **Script de sante** : installation de `cryoss-health.sh` et des timers (quotidien, hebdomadaire, watchdog).
10. **Timers systemd** : activation de tous les timers.

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

> **Important** : RPi2 ne recoit **pas** le script `install_security.sh` et n'a **pas** de heartbeat.

---

## Etape 6 -- Durcissement securitaire (RPi1 uniquement)

```bash
cd /opt/Cryoss
sudo bash install_security.sh
```

Ce script s'execute **uniquement sur RPi1**. Il met en place :

- Regles iptables/nftables restrictives.
- Fail2ban.
- Honeypot de detection d'intrusion.
- Desactivation des services inutiles.
- Parametres sysctl de securite.

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
sudo bash test_installation.sh
```

Le script `test_installation.sh` verifie automatiquement :
- Etat des grappes RAID (RPi1 et RPi2).
- Connectivite interco (ping 10.42.0.2 depuis RPi1).
- Services actifs (samba, ssh, api, timers).
- Cles rclone presentes et coherentes.
- Replication fonctionnelle (test de transfert).
- Envoi d'email de test.
- Heartbeat fonctionnel.

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
- [ ] Script `test_installation.sh` passe sans erreur
- [ ] RPi2 deconnecte du LAN client
- [ ] Numero de serie DS-XXXXXXXX note dans le dossier client
- [ ] Copie offline des cles remise au responsable (si politique client)
