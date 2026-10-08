#!/bin/bash

# VARIÁVEIS

IF_LAN="enp0s3"
SERVER_IP="192.168.0.2"
NETMASK="255.255.255.0"
NETWORK="192.168.0.0"
BROADCAST="192.168.0.255"
FIREWALL_IP="192.168.0.1"
DNS_IP="192.168.0.3"
RANGE_START="192.168.0.100"
RANGE_END="192.168.0.200"


# 0. Checagem de root

if [[ $EUID -ne 0 ]]; then
    echo "Este script precisa ser executado como root (use sudo)." >&2
    exit 1
fi


# 1. Instalando pacotes

echo "==> Atualizando lista de pacotes..."
apt-get update -y
echo "==> Instalando servidor DHCP..."
apt-get install -y ifupdown isc-dhcp-server


# 2. Configurando a interface de rede

IFACES_FILE="/etc/network/interfaces"
BACKUP_FILE="/etc/network/interfaces.bkp"

echo "==> Criando backup em $BACKUP_FILE..."
cp "$IFACES_FILE" "$BACKUP_FILE"

echo "==> Escrevendo $IFACES_FILE..."
cat > "$IFACES_FILE" <<EOF
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

# LAN - servidor DHCP com IP fixo
auto ${IF_LAN}
iface ${IF_LAN} inet static
    address ${SERVER_IP}
    netmask ${NETMASK}
    gateway ${FIREWALL_IP}
EOF


# 3. Configurando o serviço DHCP

DHCP_CONF="/etc/dhcp/dhcpd.conf"
DHCP_DEFAULT="/etc/default/isc-dhcp-server"

echo "==> Configurando escopo DHCP..."
cat > "$DHCP_CONF" <<EOF
authoritative;
default-lease-time 600;
max-lease-time 7200;

subnet ${NETWORK} netmask ${NETMASK} {
    range ${RANGE_START} ${RANGE_END};
    option subnet-mask ${NETMASK};
    option broadcast-address ${BROADCAST};
    option routers ${FIREWALL_IP};
    option domain-name-servers ${DNS_IP};
}
EOF

echo "==> Definindo interface do serviço DHCP..."
sed -i "s/^INTERFACESv4=.*/INTERFACESv4=\"${IF_LAN}\"/" "$DHCP_DEFAULT"


# 4. Aplicando configurações

read -r -p "Troque a placa virtual de NAT para Internal Network. A placa já foi trocada? [s/N] " RESPOSTA
if [[ ! "$RESPOSTA" =~ ^[sS]$ ]]; then
    echo "Operação cancelada. A rede não foi reiniciada."
    exit 1
fi

echo "==> Reiniciando serviço de rede..."
systemctl restart networking.service
echo "==> Validando configuração DHCP..."
dhcpd -t -cf "$DHCP_CONF"
echo "==> Habilitando e reiniciando servidor DHCP..."
systemctl enable --now isc-dhcp-server
systemctl restart isc-dhcp-server


# Resumo

echo ""
echo "==> Configuração concluída."
echo "    Interface: ${IF_LAN}"
echo "    Servidor DHCP: ${SERVER_IP}/24"
echo "    Escopo: ${RANGE_START} até ${RANGE_END}"
echo "    Gateway entregue aos clientes: ${FIREWALL_IP}"
echo "    DNS entregue aos clientes: ${DNS_IP}"