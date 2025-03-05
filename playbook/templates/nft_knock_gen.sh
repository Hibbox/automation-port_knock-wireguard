#!/usr/bin/env bash

##############################################################################
# Génération d’une séquence de knocking en nftables                          #
# - Demande le nombre de ports pour le knock (N)                             #
# - Demande le port SSH final à protéger                                     #
# - Gère la vérification basique des entrées utilisateur                     #
# - Évite que la séquence contienne le port SSH final                        #
# - Créé un /etc/nftables.conf complet avec la logique de knocking          #
# - Recharge la configuration immédiatement                                  #
##############################################################################

# 1. Vérifier que le script est lancé en root
if [ "$EUID" -ne 0 ]; then
  echo "Veuillez exécuter ce script en tant que root."
  exit 1
fi

# 2. Lecture du nombre de ports de knock souhaité
read -rp "Nombre de ports dans la séquence de knock (défaut: 4) : " NB_KNOCKS
NB_KNOCKS="${NB_KNOCKS:-4}"

# Vérifier que NB_KNOCKS est un nombre entier > 0
if ! [[ "$NB_KNOCKS" =~ ^[0-9]+$ ]] || [ "$NB_KNOCKS" -lt 1 ]; then
  echo "Erreur : le nombre de knocks doit être un entier positif."
  exit 1
fi

# 3. Lecture du port SSH final à protéger
read -rp "Port SSH final à protéger (défaut: 22599) : " SSH_PORT
SSH_PORT="${SSH_PORT:-22599}"

# Vérifier que SSH_PORT est un nombre entier dans [1..65535]
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
  echo "Erreur : le port SSH doit être un entier entre 1 et 65535."
  exit 1
fi

# 4. Génération aléatoire des ports de knock
#    On évite le port SSH final et on évite les duplicats.
declare -a KNOCK_PORTS=()

while [ "${#KNOCK_PORTS[@]}" -lt "$NB_KNOCKS" ]; do
  rand_port=$(shuf -i 1024-65535 -n 1)  # on évite les ports < 1024
  # Vérifier que ce port n’est pas déjà dans la liste et n’est pas égal au port SSH final
  conflict="non"
  if [ "$rand_port" -eq "$SSH_PORT" ]; then
    conflict="oui"
  else
    for p in "${KNOCK_PORTS[@]}"; do
      if [ "$p" -eq "$rand_port" ]; then
        conflict="oui"
        break
      fi
    done
  fi

  if [ "$conflict" = "non" ]; then
    KNOCK_PORTS+=( "$rand_port" )
  fi
done

# 5. Sauvegarde de la configuration actuelle de nftables
BACKUP_FILE="/etc/nftables.conf.bak_$(date +%Y%m%d-%H%M%S)"
cp /etc/nftables.conf "$BACKUP_FILE"
echo "Sauvegarde de l'ancienne configuration dans : $BACKUP_FILE"

# 6. Génération du nouveau /etc/nftables.conf
cat <<EOF > /etc/nftables.conf
#!/usr/sbin/nft -f
flush ruleset

##############################################################################
# Configuration nftables avec séquence de knocking dynamique                 #
##############################################################################

define pub_iface = "eth1"
define wg_iface  = "wg0"
define wg_port   = 51820

table ip nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        oifname \$pub_iface masquerade
    }
}

table ip6 nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        oifname \$pub_iface masquerade
    }
}

table inet filter {

EOF
# 6a. Création des sets dynamiques P1..PN
#
for ((i=1; i<=$NB_KNOCKS; i++)); do
  echo "    set P$i {" >> /etc/nftables.conf
  echo "        type ipv4_addr" >> /etc/nftables.conf
  echo "        flags dynamic, timeout" >> /etc/nftables.conf
  echo "        timeout 10s" >> /etc/nftables.conf
  echo "    }" >> /etc/nftables.conf
done

cat <<EOF >> /etc/nftables.conf

    chain input {
        type filter hook input priority 0; policy drop;

        # Autoriser loopback
        iif "lo" accept

        # Autoriser ICMP (ping, etc.)
        meta l4proto { icmp, ipv6-icmp } accept

        # Accepter les paquets établis/related, droper l’invalide
        ct state invalid drop
        ct state established,related accept

        #################################################################
        # Phase 1 : le 1er knock
        # Toute IP qui toquera sur le premier port sera ajoutée au set P1
        #################################################################
        tcp dport ${KNOCK_PORTS[0]} update @P1 { ip saddr timeout 10s } accept
EOF

# 6b. Création des règles pour les phases suivantes (2..N)
for ((i=2; i<=$NB_KNOCKS; i++)); do
  prev=$((i-1))
  echo "        # Phase $i : knock sur ${KNOCK_PORTS[$((i-1))]} si l'IP figure déjà dans P$prev" >> /etc/nftables.conf
  echo "        tcp dport ${KNOCK_PORTS[$((i-1))]} ip saddr @P$prev jump into_p$i" >> /etc/nftables.conf
  echo "" >> /etc/nftables.conf
done

# 6c. Règles finales SSH et autres règles
cat <<EOF >> /etc/nftables.conf
        #################################################################
        # Autoriser SSH seulement si l'adresse est dans le dernier set P$NB_KNOCKS
        #################################################################
        tcp dport $SSH_PORT ip saddr @P$NB_KNOCKS accept

        # Sinon, on drop pour toute nouvelle connexion SSH
        tcp dport $SSH_PORT ct state new drop

        # (Optionnel) Limiter le flood sur les nouvelles connexions
        ct state new limit rate over 1/second burst 10 packets drop

        #################################################################
        # Autoriser WireGuard
        #################################################################
        iifname \$pub_iface udp dport \$wg_port accept
        iifname \$wg_iface tcp dport $SSH_PORT accept

        # Dernière règle : on rejette tout le reste
        reject
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
        ct state established,related accept
        iifname \$wg_iface oifname \$wg_iface accept
        reject
    }
EOF

# 6d. Génération des chaînes into_p2..into_pN
for ((i=2; i<=$NB_KNOCKS; i++)); do
  prev=$((i-1))
  cat <<EOF >> /etc/nftables.conf

    chain into_p$i {
        # Retirer l’IP de P$prev
        delete @P$prev { ip saddr }
        # Ajouter l’IP dans P$i
        update @P$i { ip saddr timeout 10s }
        # Log pour le debug
        log prefix "INTO P$i: "
        accept
    }
EOF
done

# 6e. Fermeture du bloc
echo "}" >> /etc/nftables.conf

# 7. Appliquer la configuration
if nft -f /etc/nftables.conf; then
  echo "La configuration nftables a été rechargée avec succès."
else
  echo "Échec du rechargement de nftables. Restauration de la config précédente."
  cp "$BACKUP_FILE" /etc/nftables.conf
  nft -f /etc/nftables.conf
  exit 1
fi

# 8. Affichage final des informations
echo
echo "Knocking configuré avec succès !"
echo "Les ports générés pour la séquence sont : ${KNOCK_PORTS[*]}"
echo "Le port SSH protégé est : $SSH_PORT"
echo
echo "Exemple de knock côté client :"
echo "  knock <IP_SERVEUR> ${KNOCK_PORTS[*]}"
echo
echo "Pour vérifier la config :"
echo "  nft list ruleset"
