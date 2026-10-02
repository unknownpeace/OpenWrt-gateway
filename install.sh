#!/bin/sh

###############################################################################
# OpenWrt 25.x Selective Gateway
#
# Z83ii / x86_64
#
# ARCHITECTURE
#
# Main router:
#   - DHCP
#   - Internet gateway
#
# OpenWrt Z83:
#   - static LAN IP
#   - NOT DHCP server
#   - AdGuard Home :53
#   - Mihomo DNS :1053
#   - Mihomo TUN
#
# Selected clients:
#   IP      -> DHCP from main router
#   Gateway -> Z83 IP
#   DNS     -> Z83 IP
#
# Routing:
#   LAN/local/RU -> DIRECT -> main router
#   everything else -> PROXY
#
###############################################################################

set -u

###############################################################################
# COLORS / OUTPUT
###############################################################################

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
RESET='\033[0m'

info() {
    printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$*"
}

ok() {
    printf '%s[ OK ]%s %s\n' "$GREEN" "$RESET" "$*"
}

warn() {
    printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*"
}

error() {
    printf '%s[FAIL]%s %s\n' "$RED" "$RESET" "$*" >&2
}

die() {
    error "$*"
    exit 1
}

###############################################################################
# ROOT CHECK
###############################################################################

[ "$(id -u)" = "0" ] || die "Скрипт необходимо запускать от root."

###############################################################################
# BASIC COMMAND CHECK
###############################################################################

for cmd in \
    awk \
    sed \
    grep \
    cut \
    tr \
    ip \
    uci \
    logger \
    curl
do
    command -v "$cmd" >/dev/null 2>&1 ||
        die "Не найдено обязательное приложение: $cmd"
done

###############################################################################
# CONFIGURATION
###############################################################################

DEFAULT_SUB_URL="https://gitlab.com/igareck/vpn-configs-for-russia/-/raw/main/Export/Clash/PROXIES_ONLY/BLACK_VLESS_RUS_mobile_clash_proxies.yaml"

LAN_IFACE="$(uci -q get network.lan.device 2>/dev/null || true)"

if [ -z "$LAN_IFACE" ]; then
    LAN_IFACE="br-lan"
fi

CURRENT_LAN_IP="$(
    uci -q get network.lan.ipaddr 2>/dev/null ||
    ip -4 addr show dev "$LAN_IFACE" 2>/dev/null |
        awk '/inet / {print $2}' |
        cut -d/ -f1 |
        head -n1
)"

CURRENT_LAN_IP="$(printf '%s' "$CURRENT_LAN_IP" | cut -d/ -f1)"

CURRENT_GATEWAY="$(
    ip -4 route show default 2>/dev/null |
        awk 'NR==1 {print $3}'
)"

[ -n "$CURRENT_LAN_IP" ] ||
    CURRENT_LAN_IP="192.168.1.10"

[ -n "$CURRENT_GATEWAY" ] ||
    CURRENT_GATEWAY="192.168.1.5"

###############################################################################
# HEADER
###############################################################################

clear 2>/dev/null || true

cat <<'BANNER'

=======================================================================
                 Z83ii OPENWRT SELECTIVE GATEWAY
=======================================================================

  Main router:
      DHCP + Internet

  Z83ii:
      Static LAN IP
      AdGuard Home
      Mihomo DNS
      Mihomo TUN
      Automatic DIRECT / PROXY routing

  Selected clients:
      Gateway = Z83
      DNS     = Z83

  Russian resources:
      DIRECT

  Other traffic:
      PROXY

=======================================================================

BANNER

###############################################################################
# USER INPUT
###############################################################################

printf "Ссылка на Clash/Mihomo подписку\n"
printf "[$DEFAULT_SUB_URL]\n> "
read -r INPUT_SUB_URL

SUB_URL="${INPUT_SUB_URL:-$DEFAULT_SUB_URL}"

printf "\nIP Z83ii в LAN [%s]\n> " "$CURRENT_LAN_IP"
read -r INPUT_IP

ROUTER_IP="${INPUT_IP:-$CURRENT_LAN_IP}"
ROUTER_IP="$(printf '%s' "$ROUTER_IP" | cut -d/ -f1)"

printf "\nIP основного роутера [%s]\n> " "$CURRENT_GATEWAY"
read -r INPUT_GW

GATEWAY_IP="${INPUT_GW:-$CURRENT_GATEWAY}"
GATEWAY_IP="$(printf '%s' "$GATEWAY_IP" | cut -d/ -f1)"

printf "\nМаска LAN [255.255.255.0]\n> "
read -r INPUT_MASK

NETMASK="${INPUT_MASK:-255.255.255.0}"

###############################################################################
# VALIDATION FUNCTIONS
###############################################################################

is_ipv4() {
    echo "$1" |
        awk -F. '
        NF == 4 {
            ok=1
            for (i=1;i<=4;i++) {
                if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255)
                    ok=0
            }
            if (ok) exit 0
        }
        { exit 1 }
        '
}

ip_to_int() {
    echo "$1" |
        awk -F. '
        {
            printf "%u\n",
            ($1*16777216)+
            ($2*65536)+
            ($3*256)+
            $4
        }'
}

mask_to_int() {
    ip_to_int "$1"
}

same_subnet() {
    IP1="$(ip_to_int "$1")" || return 1
    IP2="$(ip_to_int "$2")" || return 1
    MASK="$(mask_to_int "$3")" || return 1

    [ $((IP1 & MASK)) -eq $((IP2 & MASK)) ]
}

###############################################################################
# VALIDATE INPUT
###############################################################################

is_ipv4 "$ROUTER_IP" ||
    die "Некорректный IP Z83ii: $ROUTER_IP"

is_ipv4 "$GATEWAY_IP" ||
    die "Некорректный IP основного роутера: $GATEWAY_IP"

is_ipv4 "$NETMASK" ||
    die "Некорректная маска: $NETMASK"

same_subnet "$ROUTER_IP" "$GATEWAY_IP" "$NETMASK" ||
    die "Z83ii и основной роутер находятся не в одной подсети."

[ "$ROUTER_IP" != "$GATEWAY_IP" ] ||
    die "IP Z83ii не может совпадать с IP основного роутера."

case "$SUB_URL" in
    http://*|https://*)
        ;;
    *)
        die "SUB_URL должен начинаться с http:// или https://"
        ;;
esac

###############################################################################
# ARCHITECTURE
###############################################################################

ARCH="$(uname -m)"

case "$ARCH" in
    x86_64|amd64)
        MIHOMO_ARCH="amd64-compatible"
        ;;
    *)
        die "Этот установщик рассчитан на x86_64. Обнаружено: $ARCH"
        ;;
esac

###############################################################################
# CONFIRMATION
###############################################################################

cat <<EOF

-----------------------------------------------------------------------
ПРОВЕРЬ ПЕРЕД ПРОДОЛЖЕНИЕМ

LAN interface : $LAN_IFACE
Z83ii IP      : $ROUTER_IP
Main router   : $GATEWAY_IP
Netmask       : $NETMASK
Architecture  : $ARCH

DHCP на Z83ii будет отключён.
DHCP основного роутера НЕ будет изменён.

Выбранные клиенты должны использовать:

    Gateway = $ROUTER_IP
    DNS     = $ROUTER_IP

-----------------------------------------------------------------------

EOF

printf "Продолжить установку? [Y/n]: "
read -r CONFIRM

case "$CONFIRM" in
    n|N|no|NO|No)
        info "Установка отменена."
        exit 0
        ;;
esac

###############################################################################
# BACKUP
###############################################################################

BACKUP_DIR="/root/z83-gateway-backup-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR" ||
    die "Не удалось создать каталог резервной копии."

info "Создаю резервную копию: $BACKUP_DIR"

for file in \
    /etc/config/network \
    /etc/config/firewall \
    /etc/config/dhcp \
    /etc/config/adguardhome
do
    if [ -f "$file" ]; then
        cp -p "$file" "$BACKUP_DIR/" || true
    fi
done

if [ -d /etc/mihomo ]; then
    cp -a /etc/mihomo "$BACKUP_DIR/mihomo.old" || true
fi

if [ -d /etc/adguardhome ]; then
    cp -a /etc/adguardhome "$BACKUP_DIR/adguardhome.old" || true
fi

echo "$BACKUP_DIR" > /root/z83-gateway-last-backup

###############################################################################
# NETWORK SNAPSHOT
###############################################################################

info "Текущая сеть:"

ip -4 addr show dev "$LAN_IFACE" || true
ip -4 route || true

###############################################################################
# SYSCTL
###############################################################################

info "Настраиваю IPv4 forwarding и защиту маршрутизации."

sysctl -w net.ipv4.ip_forward=1 >/dev/null

sysctl -w net.ipv4.conf.all.send_redirects=0 >/dev/null
sysctl -w net.ipv4.conf.default.send_redirects=0 >/dev/null

sysctl -w net.ipv4.conf.all.accept_redirects=0 >/dev/null
sysctl -w net.ipv4.conf.default.accept_redirects=0 >/dev/null

sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null

###############################################################################
# SYSCTL PERSISTENCE
###############################################################################

mkdir -p /etc/sysctl.d

cat > /etc/sysctl.d/99-z83-selective-gateway.conf <<'EOF'
net.ipv4.ip_forward=1

net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0

net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0

net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2

# This installation intentionally operates IPv4-only.
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF

sysctl -p /etc/sysctl.d/99-z83-selective-gateway.conf >/dev/null 2>&1 || true

###############################################################################
# NETWORK CONFIGURATION
###############################################################################

info "Настраиваю LAN Z83ii."

uci set network.lan.proto='static'
uci set network.lan.ipaddr="$ROUTER_IP"
uci set network.lan.netmask="$NETMASK"
uci set network.lan.gateway="$GATEWAY_IP"

# Do NOT delete WAN interfaces.
# They may be useful later and are unrelated to this topology.

# The OpenWrt box itself uses the main router for bootstrap/system DNS.
uci -q delete network.lan.dns
uci add_list network.lan.dns="$GATEWAY_IP"

###############################################################################
# DHCP
###############################################################################

info "Отключаю DHCP/RA на Z83ii."

uci set dhcp.lan.ignore='1'
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='disabled'
uci set dhcp.lan.ndp='disabled'

uci -q delete network.lan.ip6assign

###############################################################################
# DNSMASQ
###############################################################################

# AdGuard Home owns port 53.
# Keep dnsmasq alive on another port for OpenWrt internals.

uci set dhcp.@dnsmasq[0].port='54'

###############################################################################
# FIREWALL
###############################################################################

info "Настраиваю firewall."

# Never assume @zone[0] is LAN.
# Find the actual LAN zone.

LAN_ZONE=""

for Z in $(uci show firewall 2>/dev/null |
           sed -n "s/^firewall\.\([^=]*\)=zone$/\1/p")
do
    NETWORKS="$(uci -q get firewall."$Z".network 2>/dev/null || true)"

    case " $NETWORKS " in
        *" lan "*)
            LAN_ZONE="$Z"
            break
            ;;
    esac
done

[ -n "$LAN_ZONE" ] ||
    die "Не удалось определить firewall zone для LAN."

info "LAN firewall zone: $LAN_ZONE"

uci set firewall."$LAN_ZONE".forward='ACCEPT'
uci set firewall."$LAN_ZONE".output='ACCEPT'

###############################################################################
# MIHOMO TUN INTERFACE
###############################################################################

uci -q delete network.mihomo_tun

uci set network.mihomo_tun='interface'
uci set network.mihomo_tun.proto='none'
uci set network.mihomo_tun.device='tun0'

###############################################################################
# MIHOMO FIREWALL ZONE
###############################################################################

uci -q delete firewall.mihomo_tun

uci set firewall.mihomo_tun='zone'
uci set firewall.mihomo_tun.name='mihomo_tun'

# Do not expose services from TUN to LAN.
uci set firewall.mihomo_tun.input='REJECT'
uci set firewall.mihomo_tun.output='ACCEPT'
uci set firewall.mihomo_tun.forward='REJECT'

# Proxy traffic leaving through TUN needs NAT.
uci set firewall.mihomo_tun.masq='1'
uci set firewall.mihomo_tun.mtu_fix='1'

uci add_list firewall.mihomo_tun.network='mihomo_tun'

###############################################################################
# LAN -> MIHOMO
###############################################################################

uci -q delete firewall.lan_to_mihomo

uci set firewall.lan_to_mihomo='forwarding'
uci set firewall.lan_to_mihomo.src="$LAN_ZONE"
uci set firewall.lan_to_mihomo.dest='mihomo_tun'

###############################################################################
# IMPORTANT:
# No tun -> lan ACCEPT rule.
#
# Replies are handled by conntrack.
# Broad tun -> lan forwarding would unnecessarily expose LAN services.
###############################################################################

###############################################################################
# COMMIT NETWORK
###############################################################################

uci commit network
uci commit dhcp
uci commit firewall

###############################################################################
# APPLY NETWORK
###############################################################################

info "Применяю сетевую конфигурацию."

/etc/init.d/network reload

sleep 3

###############################################################################
# BASIC CONNECTIVITY
###############################################################################

info "Проверяю основной роутер."

if ping -c 2 -W 2 "$GATEWAY_IP" >/dev/null 2>&1; then
    ok "Основной роутер доступен: $GATEWAY_IP"
else
    warn "Основной роутер пока не отвечает: $GATEWAY_IP"
fi

###############################################################################
# PACKAGE INSTALL
###############################################################################

info "Обновляю индексы OpenWrt."

apk update ||
    die "apk update завершился ошибкой."

info "Устанавливаю необходимые пакеты."

apk add \
    curl \
    ca-bundle \
    ca-certificates \
    gzip \
    tar \
    kmod-tun \
    adguardhome ||
    die "Не удалось установить необходимые пакеты."

###############################################################################
# TUN
###############################################################################

info "Проверяю TUN."

modprobe tun 2>/dev/null || true

mkdir -p /dev/net

if [ ! -c /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200 2>/dev/null || true
fi

[ -c /dev/net/tun ] ||
    die "/dev/net/tun недоступен."

ok "TUN device доступен."

###############################################################################
# MIHOMO DIRECTORIES
###############################################################################

mkdir -p \
    /etc/mihomo \
    /etc/mihomo/providers \
    /etc/mihomo/ui \
    /var/lib/mihomo

###############################################################################
# MIHOMO RELEASE
###############################################################################

info "Определяю актуальный стабильный Mihomo."

RELEASE_JSON="/tmp/mihomo-release.json"

curl -fsSL \
    --connect-timeout 10 \
    --max-time 30 \
    "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" \
    -o "$RELEASE_JSON" ||
    die "Не удалось получить информацию о последнем релизе Mihomo."

LATEST_TAG="$(
    sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$RELEASE_JSON" |
        head -n1
)"

[ -n "$LATEST_TAG" ] ||
    die "GitHub API не вернул tag_name."

info "Mihomo release: $LATEST_TAG"

###############################################################################
# MIHOMO ASSET
###############################################################################

MIHOMO_FILE="mihomo-linux-${MIHOMO_ARCH}-${LATEST_TAG}.gz"

MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_TAG}/${MIHOMO_FILE}"

info "Загрузка:"
info "$MIHOMO_FILE"

curl -fL \
    --connect-timeout 15 \
    --max-time 180 \
    --retry 3 \
    --retry-delay 2 \
    "$MIHOMO_URL" \
    -o /tmp/mihomo.gz ||
    die "Не удалось скачать Mihomo: $MIHOMO_URL"

###############################################################################
# GZIP VALIDATION
###############################################################################

gzip -t /tmp/mihomo.gz ||
    die "Скачанный Mihomo повреждён: gzip test failed."

###############################################################################
# EXTRACT
###############################################################################

rm -f /tmp/mihomo

gzip -dc /tmp/mihomo.gz > /tmp/mihomo ||
    die "Не удалось распаковать Mihomo."

chmod 0755 /tmp/mihomo

###############################################################################
# BINARY VALIDATION
###############################################################################

/tmp/mihomo -v >/tmp/mihomo-version.txt 2>&1 ||
    die "Скачанный файл не является рабочим Mihomo."

cat /tmp/mihomo-version.txt

###############################################################################
# INSTALL BINARY
###############################################################################

install -m 0755 \
    /tmp/mihomo \
    /usr/bin/mihomo ||
    die "Не удалось установить /usr/bin/mihomo."

rm -f /tmp/mihomo /tmp/mihomo.gz

ok "Mihomo установлен."

###############################################################################
# GEO DATA
###############################################################################

info "Создаю каталог GeoData."

mkdir -p /etc/mihomo/geo

###############################################################################
# RANDOM API SECRET
###############################################################################

generate_secret() {
    if [ -r /dev/urandom ]; then
        od -An -N32 -tx1 /dev/urandom |
            tr -d ' \n'
    else
        date +%s%N
    fi
}

MIHOMO_SECRET="$(generate_secret)"

[ -n "$MIHOMO_SECRET" ] ||
    die "Не удалось создать Mihomo API secret."

###############################################################################
# MIHOMO CONFIG
###############################################################################

info "Создаю конфигурацию Mihomo."

cat > /etc/mihomo/config.yaml <<EOF
###############################################################################
# Mihomo - Z83ii Selective Gateway
###############################################################################

mixed-port: 7890

allow-lan: true

mode: rule

log-level: info

ipv6: false

external-controller: ${ROUTER_IP}:9090

external-ui: ui

secret: "${MIHOMO_SECRET}"

geodata-mode: true

geo-auto-update: true

geo-update-interval: 24

geox-url:
  geoip: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat"
  geosite: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat"

###############################################################################
# DNS
###############################################################################

dns:
  enable: true

  listen: 127.0.0.1:1053

  ipv6: false

  cache-algorithm: arc

  enhanced-mode: fake-ip

  fake-ip-range: 198.18.0.1/16

  fake-ip-filter-mode: blacklist

  fake-ip-filter:
    - "*.lan"
    - "*.local"
    - "localhost"
    - "+.localhost"
    - "+.local"
    - "+.lan"
    - "time.*.com"
    - "time.*.gov"
    - "time.*.edu"
    - "ntp.*"
    - "+.pool.ntp.org"

  default-nameserver:
    - 77.88.8.8
    - 77.88.8.1

  proxy-server-nameserver:
    - 77.88.8.8
    - 77.88.8.1

  direct-nameserver:
    - 77.88.8.8
    - 77.88.8.1

  direct-nameserver-follow-policy: false

  nameserver:
    - "https://dns.google/dns-query#PROXY"
    - "https://cloudflare-dns.com/dns-query#PROXY"

###############################################################################
# TUN
###############################################################################

tun:
  enable: true

  device: tun0

  stack: system

  mtu: 1500

  auto-route: true

  auto-redirect: false

  auto-detect-interface: true

  strict-route: false

  dns-hijack:
    - "any:53"
    - "tcp://any:53"

  route-exclude-address:
    - "${ROUTER_IP}/32"
    - "${GATEWAY_IP}/32"
    - "192.168.0.0/16"
    - "10.0.0.0/8"
    - "172.16.0.0/12"
    - "127.0.0.0/8"
    - "169.254.0.0/16"
    - "224.0.0.0/4"
    - "255.255.255.255/32"

###############################################################################
# PROXY PROVIDER
###############################################################################

proxy-providers:

  my-subscription:

    type: http

    url: "${SUB_URL}"

    interval: 3600

    path: ./providers/sub.yaml

    health-check:
      enable: true
      interval: 300
      url: "https://www.gstatic.com/generate_204"

###############################################################################
# PROXY GROUPS
###############################################################################

proxy-groups:

  - name: "PROXY"

    type: select

    proxies:
      - "AUTO"
      - "DIRECT"

    use:
      - my-subscription

  - name: "AUTO"

    type: url-test

    use:
      - my-subscription

    url: "https://www.gstatic.com/generate_204"

    interval: 300

    tolerance: 50

    lazy: true

###############################################################################
# ROUTING
###############################################################################

rules:

  # Local networks must never go through VLESS.
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve

  # Russian domains.
  - GEOSITE,category-ru,DIRECT

  # Russian IPv4 addresses.
  - GEOIP,RU,DIRECT,no-resolve

  # Everything else goes through the proxy group.
  - MATCH,PROXY

###############################################################################
EOF

###############################################################################
# MIHOMO CONFIG TEST
###############################################################################

info "Проверяю конфигурацию Mihomo ДО запуска."

mihomo -t -d /etc/mihomo >/tmp/mihomo-config-test.log 2>&1

MIHOMO_TEST_RC=$?

cat /tmp/mihomo-config-test.log

[ "$MIHOMO_TEST_RC" -eq 0 ] ||
    die "Конфигурация Mihomo не прошла проверку."

ok "Конфигурация Mihomo корректна."

###############################################################################
# MIHOMO INIT SCRIPT
###############################################################################

info "Создаю procd service для Mihomo."

cat > /etc/init.d/mihomo <<'EOF'
#!/bin/sh /etc/rc.common

START=95
STOP=10

USE_PROCD=1

PROG="/usr/bin/mihomo"
CONF_DIR="/etc/mihomo"

start_service() {
    procd_open_instance

    procd_set_param command \
        "$PROG" \
        -d "$CONF_DIR"

    procd_set_param respawn \
        3600 \
        5 \
        0

    procd_set_param file \
        "$CONF_DIR/config.yaml"

    procd_set_param stdout 1
    procd_set_param stderr 1

    procd_close_instance
}
EOF

chmod 0755 /etc/init.d/mihomo

###############################################################################
# METACUBEXD
###############################################################################

info "Устанавливаю MetaCubeXD."

rm -rf /tmp/metacubexd

mkdir -p /tmp/metacubexd

curl -fL \
    --connect-timeout 15 \
    --max-time 120 \
    --retry 3 \
    "https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz" \
    -o /tmp/metacubexd.tgz ||
    warn "Не удалось скачать MetaCubeXD. Сам Mihomo продолжит работать."

if [ -s /tmp/metacubexd.tgz ]; then
    tar -xzf /tmp/metacubexd.tgz \
        -C /tmp/metacubexd 2>/dev/null || true

    find /tmp/metacubexd \
        -type f \
        -maxdepth 3 \
        -exec cp -f {} /etc/mihomo/ui/ \; 2>/dev/null || true
fi

rm -rf /tmp/metacubexd /tmp/metacubexd.tgz

###############################################################################
# ADGUARD HOME
###############################################################################

info "Настраиваю AdGuard Home."

mkdir -p \
    /etc/adguardhome \
    /opt/adguardhome

###############################################################################
# AGH CONFIG
###############################################################################

cat > /etc/adguardhome/adguardhome.yaml <<EOF
http:
  address: ${ROUTER_IP}:3000
  session_ttl: 24h

users: []

dns:
  bind_hosts:
    - ${ROUTER_IP}

  port: 53

  protection_enabled: true

  filtering_enabled: true

  blocking_mode: default

  blocked_response_ttl: 10

  upstream_dns:
    - 127.0.0.1:1053

  bootstrap_dns:
    - 77.88.8.8
    - 77.88.8.1

  fallback_dns: []

  upstream_mode: parallel

  cache_enabled: true

  cache_size: 4194304

  cache_ttl_min: 60

  cache_ttl_max: 86400

  serve_plain_dns: true

  hostsfile_enabled: true

  use_http3_upstreams: false

  serve_http3: false

  pending_requests:
    enabled: true

querylog:
  enabled: true
  file_enabled: true
  interval: 168h
  size_memory: 1000
  dir_path: /opt/adguardhome/work/data/querylog

statistics:
  enabled: true
  interval: 24h
  dir_path: /opt/adguardhome/work/data/stats

filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1

whitelist_filters: []

user_rules:

  # User-requested exceptions preserved from the original configuration.
  - '@@||whoer.net^$important'
  - '@@||aniliberty.top^$important'
  - '@@||anilibria.top^$important'
  - '@@||*.libria.fun^$important'

filtering:
  rewrites:

    - domain: router.lan
      answer: ${GATEWAY_IP}

      enabled: true

    - domain: openwrt.lan
      answer: ${ROUTER_IP}

      enabled: true

  filters_update_interval: 24

tls:
  enabled: false

dhcp:
  enabled: false

schema_version: 34
EOF

###############################################################################
# AGH OPENWRT CONFIG
###############################################################################

# Official OpenWrt package stores persistent configuration under
# /etc/adguardhome and working data can be configured in /etc/config/adguardhome.

if [ -f /etc/config/adguardhome ]; then

    uci set adguardhome.@adguardhome[0].workdir='/opt/adguardhome/work' 2>/dev/null || true

    uci commit adguardhome 2>/dev/null || true

else

    cat > /etc/config/adguardhome <<'EOF'
config adguardhome 'main'
    option workdir '/opt/adguardhome/work'
EOF

fi

###############################################################################
# AGH SERVICE
###############################################################################

/etc/init.d/adguardhome enable 2>/dev/null || true

###############################################################################
# DNSMASQ / AGH CONFLICT CHECK
###############################################################################

info "Проверяю конфликт DNS-портов."

if netstat -lnup 2>/dev/null |
    grep -q ':53 '; then

    warn "Порт 53 уже занят. Перезапуск dnsmasq будет выполнен перед AGH."

fi

###############################################################################
# START SERVICES
###############################################################################

info "Перезапускаю dnsmasq."

/etc/init.d/dnsmasq restart ||
    warn "dnsmasq не удалось перезапустить."

info "Запускаю Mihomo."

/etc/init.d/mihomo enable

/etc/init.d/mihomo restart ||
    die "Mihomo не удалось запустить."

sleep 3

###############################################################################
# MIHOMO PROCESS CHECK
###############################################################################

if pgrep mihomo >/dev/null 2>&1; then
    ok "Mihomo запущен."
else
    error "Mihomo не запущен."
    logread -e mihomo | tail -n 80 || true
    exit 1
fi

###############################################################################
# AGH START
###############################################################################

info "Запускаю AdGuard Home."

/etc/init.d/adguardhome restart ||
    die "AdGuard Home не удалось запустить."

sleep 3

###############################################################################
# SERVICE CHECKS
###############################################################################

if pgrep -f '[A]dGuardHome' >/dev/null 2>&1; then
    ok "AdGuard Home запущен."
else
    error "AdGuard Home не запущен."
    logread -e AdGuardHome | tail -n 80 || true
    exit 1
fi

###############################################################################
# SOCKET CHECKS
###############################################################################

info "Проверяю listening sockets."

netstat -lnpt 2>/dev/null | grep -E ':(53|3000|7890|9090|1053)\b' || true
netstat -lnup 2>/dev/null | grep -E ':(53|1053)\b' || true

###############################################################################
# TUN CHECK
###############################################################################

sleep 2

if ip link show tun0 >/dev/null 2>&1; then
    ok "tun0 создан."
else
    warn "tun0 пока не найден."

    logread -e mihomo | tail -n 100 || true
fi

###############################################################################
# ROUTING CHECK
###############################################################################

info "Маршрутизация Z83ii:"

ip -4 route || true

###############################################################################
# DNS CHECK
###############################################################################

info "Проверяю DNS Mihomo."

if command -v nslookup >/dev/null 2>&1; then

    nslookup example.com 127.0.0.1#1053 2>/dev/null ||
        warn "nslookup к Mihomo DNS не прошёл."

fi

###############################################################################
# AGH DNS CHECK
###############################################################################

if command -v nslookup >/dev/null 2>&1; then

    nslookup example.com "$ROUTER_IP" 2>/dev/null ||
        warn "DNS через AdGuard Home пока не отвечает."

fi

###############################################################################
# SUBSCRIPTION CHECK
###############################################################################

info "Проверяю доступность подписки."

if curl -fsSL \
    --connect-timeout 10 \
    --max-time 30 \
    -A "clash.meta" \
    "$SUB_URL" \
    -o /tmp/subscription-test.yaml
then

    if [ -s /tmp/subscription-test.yaml ]; then
        ok "Подписка доступна."
    else
        warn "Подписка вернула пустой файл."
    fi

else

    warn "Не удалось проверить подписку."

fi

rm -f /tmp/subscription-test.yaml

###############################################################################
# FINAL MIHOMO CONFIG TEST
###############################################################################

info "Финальная проверка Mihomo."

mihomo -t -d /etc/mihomo >/tmp/mihomo-final-test.log 2>&1

if [ "$?" -eq 0 ]; then
    ok "Финальная конфигурация Mihomo корректна."
else
    error "Финальная конфигурация Mihomo имеет ошибки."
    cat /tmp/mihomo-final-test.log
fi

###############################################################################
# SAVE SECRET
###############################################################################

chmod 0600 /etc/mihomo/config.yaml

cat > /root/z83-mihomo-info.txt <<EOF
Z83ii Selective Gateway
=======================

Z83 IP:
${ROUTER_IP}

Main router:
${GATEWAY_IP}

AdGuard Home:
http://${ROUTER_IP}:3000

Mihomo API:
http://${ROUTER_IP}:9090

Mihomo DNS:
${ROUTER_IP}:1053

Client gateway:
${ROUTER_IP}

Client DNS:
${ROUTER_IP}

Mihomo API secret:
${MIHOMO_SECRET}

Backup:
${BACKUP_DIR}

Subscription:
${SUB_URL}
EOF

chmod 0600 /root/z83-mihomo-info.txt

###############################################################################
# FINAL FIREWALL COMMIT
###############################################################################

uci commit firewall
uci commit network
uci commit dhcp

/etc/init.d/firewall restart ||
    warn "Firewall restart завершился с ошибкой."

###############################################################################
# FINAL STATUS
###############################################################################

cat <<EOF

=======================================================================
                         УСТАНОВКА ЗАВЕРШЕНА
=======================================================================

 Z83ii:
     IP       : ${ROUTER_IP}
     Gateway  : ${GATEWAY_IP}

 AdGuard Home:
     DNS      : ${ROUTER_IP}:53
     Web      : http://${ROUTER_IP}:3000

 Mihomo:
     DNS      : 127.0.0.1:1053
     TUN      : tun0
     API      : ${ROUTER_IP}:9090

 Маршрутизация:

     LAN / private       -> DIRECT
     Russian domains     -> DIRECT
     Russian IPv4        -> DIRECT
     Everything else     -> PROXY

 DHCP:
     Z83ii DHCP           : DISABLED
     Main router DHCP     : UNCHANGED

 Выбранному клиенту:

     IP      -> DHCP основного роутера
     Gateway -> ${ROUTER_IP}
     DNS     -> ${ROUTER_IP}

 Backup:
     ${BACKUP_DIR}

 API secret:
     /root/z83-mihomo-info.txt

=======================================================================

 ВАЖНО:

 1. Не меняй DHCP gateway основного роутера на Z83.
 2. Не включай DHCP на Z83.
 3. Для выбранного клиента укажи gateway/DNS = ${ROUTER_IP}.
 4. Остальные устройства продолжат использовать основной роутер.
 5. После изменения gateway клиенту желательно переподключить сеть.

=======================================================================

EOF

###############################################################################
# LOGGING
###############################################################################

logger -t z83-gateway \
    "Selective gateway installed: Z83=${ROUTER_IP}, GW=${GATEWAY_IP}"

ok "Z83ii Selective Gateway готов."