#!/bin/bash
# VARIÁVEIS
IF_LAN="enp0s3"
DNS_SERVER_IP="192.168.0.3"
NETMASK="255.255.255.0"
NETWORK="192.168.0.0"
FIREWALL_IP="192.168.0.1"
DNS_FORWARDER="8.8.8.8"
DOMAIN="fatec.com.br"
WWW_IP="192.168.0.4"
DHCP_SERVER_IP="192.168.0.2"

# 0. Checagem de root
if [[ $EUID -ne 0 ]]; then
    echo "Este script precisa ser executado como root (use sudo)." >&2
    exit 1
fi

# 1. Instalando pacotes
echo "==> Atualizando lista de pacotes..."
apt-get update -y
echo "==> Instalando servidor DNS (BIND9)..."
apt-get install -y bind9 bind9utils bind9-doc dnsutils

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
# LAN - servidor DNS com IP fixo
auto ${IF_LAN}
iface ${IF_LAN} inet static
address ${DNS_SERVER_IP}
netmask ${NETMASK}
gateway ${FIREWALL_IP}
EOF

# 3. Configurando o BIND9 - Opções globais
NAMED_OPTIONS="/etc/bind/named.conf.options"
NAMED_OPTIONS_BKP="/etc/bind/named.conf.options.bkp"
echo "==> Criando backup em $NAMED_OPTIONS_BKP..."
cp "$NAMED_OPTIONS" "$NAMED_OPTIONS_BKP"
echo "==> Configurando named.conf.options..."
cat > "$NAMED_OPTIONS" <<EOF
options {
    directory "/var/cache/bind";
    listen-on { ${DNS_SERVER_IP}; 127.0.0.1; };
    allow-query { ${NETWORK}/24; localhost; };
    allow-recursion { ${NETWORK}/24; localhost; };
    forwarders {
        ${DNS_FORWARDER};
    };
    dnssec-validation auto;
};
EOF

# 4. Configurando as zonas (direta e reversa)
NAMED_LOCAL="/etc/bind/named.conf.local"
NAMED_LOCAL_BKP="/etc/bind/named.conf.local.bkp"
echo "==> Criando backup em $NAMED_LOCAL_BKP..."
cp "$NAMED_LOCAL" "$NAMED_LOCAL_BKP"
echo "==> Configurando named.conf.local..."
cat > "$NAMED_LOCAL" <<EOF
// Zona direta para ${DOMAIN}
zone "${DOMAIN}" {
    type master;
    file "/etc/bind/db.${DOMAIN}";
    allow-update { none; };
};

// Zona reversa para a rede ${NETWORK}
zone "0.168.192.in-addr.arpa" {
    type master;
    file "/etc/bind/db.${NETWORK//./_}";
    allow-update { none; };
};
EOF

# 5. Criando o arquivo de zona direta
ZONE_FILE="/etc/bind/db.${DOMAIN}"
ZONE_FILE_BKP="/etc/bind/db.${DOMAIN}.bkp"
if [ -f "$ZONE_FILE" ]; then
    echo "==> Criando backup em $ZONE_FILE_BKP..."
    cp "$ZONE_FILE" "$ZONE_FILE_BKP"
fi
echo "==> Criando arquivo de zona direta $ZONE_FILE..."
cat > "$ZONE_FILE" <<EOF
\$TTL 86400
@   IN  SOA ns1.${DOMAIN}. admin.${DOMAIN}. (
        2026091801  ; Serial (AAAA MM DD RR)
        3600        ; Refresh
        900         ; Retry
        604800      ; Expire
        86400       ; Minimum TTL
)
; Servidores DNS
@       IN  NS      ns1.${DOMAIN}.
ns1     IN  A       ${DNS_SERVER_IP}

; Servidores da rede
dhcp    IN  A       ${DHCP_SERVER_IP}
dns     IN  A       ${DNS_SERVER_IP}
www     IN  A       ${WWW_IP}

; Alias (CNAME)
ftp     IN  CNAME   www.${DOMAIN}.
mail    IN  CNAME   www.${DOMAIN}.
EOF

# 6. Criando o arquivo de zona reversa
REVERSE_ZONE_FILE="/etc/bind/db.${NETWORK//./_}"
REVERSE_ZONE_FILE_BKP="/etc/bind/db.${NETWORK//./_}.bkp"
if [ -f "$REVERSE_ZONE_FILE" ]; then
    echo "==> Criando backup em $REVERSE_ZONE_FILE_BKP..."
    cp "$REVERSE_ZONE_FILE" "$REVERSE_ZONE_FILE_BKP"
fi
echo "==> Criando arquivo de zona reversa $REVERSE_ZONE_FILE..."
cat > "$REVERSE_ZONE_FILE" <<EOF
\$TTL 86400
@   IN  SOA ns1.${DOMAIN}. admin.${DOMAIN}. (
        2026091801  ; Serial
        3600        ; Refresh
        900         ; Retry
        604800      ; Expire
        86400       ; Minimum TTL
)
; Servidores DNS
@       IN  NS      ns1.${DOMAIN}.

; Mapeamento reverso
3       IN  PTR     ns1.${DOMAIN}.
2       IN  PTR     dhcp.${DOMAIN}.
4       IN  PTR     www.${DOMAIN}.
EOF

# 7. Ajustando permissões
echo "==> Ajustando permissões dos arquivos de zona..."
chown root:bind "$ZONE_FILE" "$REVERSE_ZONE_FILE"
chmod 640 "$ZONE_FILE" "$REVERSE_ZONE_FILE"

# 8. Aplicando configurações
read -r -p "Troque a placa virtual de NAT para Internal Network. A placa já foi trocada? [s/N] " RESPOSTA
if [[ ! "$RESPOSTA" =~ ^[sS]$ ]]; then
    echo "Operação cancelada. A rede não foi reiniciada."
    exit 1
fi

echo "==> Reiniciando serviço de rede..."
systemctl restart networking.service
echo "==> Validando configuração do BIND9..."
named-checkconf
named-checkzone "${DOMAIN}" "$ZONE_FILE"
named-checkzone "0.168.192.in-addr.arpa" "$REVERSE_ZONE_FILE"
echo "==> Habilitando e reiniciando servidor DNS..."
systemctl enable --now bind9
systemctl restart bind9

# 9. Configurando resolução local
RESOLV_CONF="/etc/resolv.conf"
echo "==> Configurando resolv.conf para usar o DNS local..."
cat > "$RESOLV_CONF" <<EOF
nameserver ${DNS_SERVER_IP}
nameserver ${DNS_FORWARDER}
search ${DOMAIN}
EOF

# Resumo
echo ""
echo "==> Configuração concluída."
echo "    Interface: ${IF_LAN}"
echo "    Servidor DNS: ${DNS_SERVER_IP}/24"
echo "    Domínio configurado: ${DOMAIN}"
echo "    www.${DOMAIN} -> ${WWW_IP}"
echo "    dhcp.${DOMAIN} -> ${DHCP_SERVER_IP}"
echo "    dns.${DOMAIN} -> ${DNS_SERVER_IP}"
echo "    Forwarder (DNS externo): ${DNS_FORWARDER}"
echo ""
echo "==> Testes sugeridos:"
echo "    nslookup www.${DOMAIN} ${DNS_SERVER_IP}"
echo "    nslookup ${WWW_IP} ${DNS_SERVER_IP}"
echo "    dig www.${DOMAIN} @${DNS_SERVER_IP}"