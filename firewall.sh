#!/bin/bash

# VARIÁVEIS

IF_WAN="enp0s3"
IF_LAN="enp0s8"
LAN_IP="192.168.0.1"
LAN_NETMASK="255.255.255.0"


# 0. Checagem de root

if [[ $EUID -ne 0 ]]; then
    echo "Este script precisa ser executado como root (use sudo)." >&2
    exit 1
fi


# 1. Instalando pacotes antes de reiniciar a rede

echo "==> Atualizando lista de pacotes..."
apt-get update -y
echo "==> Instalando dependências de rede..."
apt-get install -y iproute2 ifupdown iptables iptables-persistent dhcpcd-base


# 2. /etc/network/interfaces (configuração interfaces)

IFACES_FILE="/etc/network/interfaces"
BACKUP_FILE="/etc/network/interfaces.bkp"

echo "==> Criando backup em $BACKUP_FILE..."
cp "$IFACES_FILE" "$BACKUP_FILE"

echo "==> Escrevendo $IFACES_FILE..."
cat > "$IFACES_FILE" <<EOF
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

# WAN - internet via DHCP
auto ${IF_WAN}
iface ${IF_WAN} inet dhcp

# LAN - rede local fixa
auto ${IF_LAN}
iface ${IF_LAN} inet static
    address ${LAN_IP}
    netmask ${LAN_NETMASK}
EOF

# 3. Subir as interfaces

echo "==> Reiniciando serviço de rede..."
systemctl restart networking.service

echo "==> Habilitando IP forwarding..."
sed -i '/^net.ipv4.ip_forward/d' /etc/sysctl.conf
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ip-forward.conf
sysctl --system >/dev/null
systemctl enable networking.service


# 6. NAT / compartilhamento via iptables

echo "==> Limpando regras anteriores do iptables..."
iptables -F
iptables -t nat -F

echo "==> Configurando NAT e encaminhamento de pacotes..."
iptables -t nat -A POSTROUTING -o "$IF_WAN" -j MASQUERADE
iptables -A FORWARD -i "$IF_WAN" -o "$IF_LAN" -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i "$IF_LAN" -o "$IF_WAN" -j ACCEPT


# 7. Persistir regras do iptables

echo "==> Salvando regras do iptables..."
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
netfilter-persistent save
echo "==> Habilitando persistência das regras..."
systemctl enable netfilter-persistent

# Resumo

echo ""
echo "==> Configuração concluída."
echo "    WAN (${IF_WAN}): $(ip a | grep "$IF_WAN" | grep "inet " | cut -d" " -f6)"
echo "    LAN (${IF_LAN}): ${LAN_IP}/${LAN_NETMASK}"
echo "    IP forwarding: $(cat /proc/sys/net/ipv4/ip_forward)"
echo ""
echo "==> Configure manualmente cada cliente com:"
echo "    IP: 192.168.0.2 a 192.168.0.254 (um IP diferente por cliente)"
echo "    Máscara: ${LAN_NETMASK}"
echo "    Gateway: ${LAN_IP}"
echo "    DNS: use o DNS recebido pela WAN ou 8.8.8.8"
