#!/bin/sh
trap '' HUP

clear
echo "=========================================================="
echo "    ПРОЗРАЧНЫЙ ШЛЮЗ OPENWRT: ADGUARD HOME + MIHOMO TUN    "
echo "        (МАКСИМАЛЬНО ОБЛЕГЧЕННАЯ СБОРКА ДЛЯ Z83)          "
echo "=========================================================="

# Автоопределение текущего IP без маски подсети
DETECTED_IP=$(uci -q get network.lan.ipaddr || ip -4 addr show dev br-lan 2>/dev/null | grep -o 'inet [0-9.]*' | awk '{print $2}' | head -n 1 || echo "192.168.1.1")
DETECTED_IP=$(echo "$DETECTED_IP" | cut -d'/' -f1)

DEFAULT_SUB_URL="https://gitlab.com/igareck/vpn-configs-for-russia/-/raw/main/Export/Clash/PROXIES_ONLY/BLACK_VLESS_RUS_mobile_clash_proxies.yaml"

# 1. Запрос ссылки на подписку Clash (с дефолтом)
echo "--- [1/2] Источник прокси-серверов ---"
printf "Введите ссылку на Clash-подписку\n[Enter для использования встроенной базы VLESS]:\n> "
read -r INPUT_SUB_URL
SUB_URL=${INPUT_SUB_URL:-$DEFAULT_SUB_URL}

# 2. Сетевые параметры
echo ""
echo "--- [2/2] Сетевые параметры шлюза ---"
printf "IP-адрес этого OpenWrt [по умолчанию $DETECTED_IP]: "
read -r INPUT_IP
ROUTER_IP=${INPUT_IP:-$DETECTED_IP}
ROUTER_IP=$(echo "$ROUTER_IP" | cut -d'/' -f1)

printf "IP основного роутера (шлюз) [по умолчанию 192.168.1.5]: "
read -r INPUT_GW
GATEWAY_IP=${INPUT_GW:-192.168.1.5}
GATEWAY_IP=$(echo "$GATEWAY_IP" | cut -d'/' -f1)

printf "Базовый DNS-сервер [по умолчанию 77.88.8.8]: "
read -r INPUT_DNS
DNS_IP=${INPUT_DNS:-77.88.8.8}
DNS_IP=$(echo "$DNS_IP" | cut -d'/' -f1)

echo ""
echo "=========================================================="
echo "Параметры для применения:"
echo "- IP устройства:  $ROUTER_IP"
echo "- Шлюз сети:      $GATEWAY_IP"
echo "- Базовый DNS:    $DNS_IP"
echo "- Авторизация:    ОТКЛЮЧЕНА (свободный вход в панели)"
echo "- Подписка:       $SUB_URL"
echo "- Автовыбор узла: Включен (AUTO url-test каждые 5 мин)"
echo "- Автообновление: Включено (раз в 24 часа)"
echo "- Fake-IP Filter: ВЫРЕЗАН (чистый Fake-IP)"
echo "- Sniffer:        ВЫРЕЗАН (0 нагрузки на CPU)"
echo "=========================================================="
printf "Применить конфигурацию и начать установку? [Y/n]: "
read -r CONFIRM
[ "$CONFIRM" = "n" ] || [ "$CONFIRM" = "N" ] && exit 0

echo ""
echo "=== [1/7] Настройка ядра Linux для маршрутизации ==="
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.all.send_redirects=0
sysctl -w net.ipv4.conf.default.send_redirects=0
sysctl -w net.ipv4.conf.all.accept_redirects=0
sysctl -w net.ipv4.conf.default.accept_redirects=0
sysctl -w net.ipv4.conf.all.rp_filter=2
sysctl -w net.ipv4.conf.default.rp_filter=2
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1

mkdir -p /etc/sysctl.d
cat << 'SYS_EOF' > /etc/sysctl.d/99-gateway-tun.conf
net.ipv4.ip_forward = 1
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
SYS_EOF

passwd -d root 2>/dev/null || true

echo "=== [2/7] Применение сетевых настроек и устранение конфликтов DHCP ==="
killall udhcpc 2>/dev/null || true

uci set network.lan.proto='static'
uci set network.lan.ipaddr="$ROUTER_IP"
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway="$GATEWAY_IP"
uci delete network.lan.dns 2>/dev/null || true
uci add_list network.lan.dns="$DNS_IP"
uci add_list network.lan.dns="$GATEWAY_IP"

uci delete network.wan 2>/dev/null || true
uci delete network.wan6 2>/dev/null || true

uci set dhcp.lan.ignore='1'
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='disabled'
uci set dhcp.lan.ndp='disabled'
uci delete network.lan.ip6assign 2>/dev/null || true

uci set firewall.@zone[0].forward='ACCEPT'
uci set firewall.@zone[0].output='ACCEPT'
uci set firewall.@zone[0].masq='1'
uci set firewall.@zone[0].mtu_fix='1'

uci set dhcp.@dnsmasq[0].port='54'

uci set network.mihomo_tun=interface
uci set network.mihomo_tun.proto='none'
uci set network.mihomo_tun.device='tun0'

uci delete firewall.mihomo_zone 2>/dev/null || true
uci set firewall.mihomo_zone=zone
uci set firewall.mihomo_zone.name='tun'
uci set firewall.mihomo_zone.input='ACCEPT'
uci set firewall.mihomo_zone.output='ACCEPT'
uci set firewall.mihomo_zone.forward='ACCEPT'
uci set firewall.mihomo_zone.masq='1'
uci set firewall.mihomo_zone.mtu_fix='1'
uci add_list firewall.mihomo_zone.network='mihomo_tun'

uci delete firewall.lan_to_tun 2>/dev/null || true
uci set firewall.lan_to_tun=forwarding
uci set firewall.lan_to_tun.src='lan'
uci set firewall.lan_to_tun.dest='tun'

uci delete firewall.tun_to_lan 2>/dev/null || true
uci set firewall.tun_to_lan=forwarding
uci set firewall.tun_to_lan.src='tun'
uci set firewall.tun_to_lan.dest='lan'

uci commit dhcp
uci commit network
uci commit firewall

/etc/init.d/odhcpd disable 2>/dev/null || true
/etc/init.d/odhcpd stop 2>/dev/null || true

/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart
/etc/init.d/network reload

echo "nameserver $DNS_IP" > /tmp/resolv.conf
echo "nameserver $GATEWAY_IP" >> /tmp/resolv.conf

echo "Ожидание применения настроек сети..."
sleep 3
retry=0
ONLINE=0
while [ "$retry" -lt 10 ]; do
    if ping -c 1 -W 2 "$GATEWAY_IP" >/dev/null 2>&1 || ping -c 1 -W 2 "$DNS_IP" >/dev/null 2>&1; then
        ONLINE=1
        break
    fi
    retry=$((retry + 1))
    sleep 1
done

if [ "$ONLINE" -eq 1 ]; then
    echo "Сеть активна!"
else
    echo "Предупреждение: Шлюз не ответил на ICMP, продолжаем установку..."
fi

echo "=== [3/7] Установка пакетов ядра и AdGuard Home ==="
PACKAGES="curl ca-certificates kmod-tun adguardhome"
apk update || true
apk add $PACKAGES || true

modprobe tun 2>/dev/null || true
mkdir -p /dev/net
[ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200

echo "=== [4/7] Загрузка ядра Mihomo, веб-панели и баз геоданных ==="
mkdir -p /etc/mihomo/providers /etc/mihomo/ui

LATEST_TAG=$(curl -sI https://github.com/MetaCubeX/mihomo/releases/latest | tr -d '\r' | grep -i "^location:" | awk -F'/tag/' '{print $2}' | tr -d ' ' || true)
if [ -z "$LATEST_TAG" ]; then
    LATEST_TAG=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
fi
LATEST_TAG=${LATEST_TAG:-v1.19.32}
echo "Актуальная версия Mihomo: $LATEST_TAG"

MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_TAG}/mihomo-linux-amd64-compatible-${LATEST_TAG}.gz"

echo "Скачивание ядра Mihomo..."
curl -sL "$MIHOMO_URL" -o /tmp/mihomo.gz

if ! gunzip -t /tmp/mihomo.gz >/dev/null 2>&1; then
    echo "Предупреждение: Не удалось загрузить $LATEST_TAG, используется проверенная v1.19.32"
    curl -sL "https://github.com/MetaCubeX/mihomo/releases/download/v1.19.32/mihomo-linux-amd64-compatible-v1.19.32.gz" -o /tmp/mihomo.gz
fi

gunzip -f /tmp/mihomo.gz
mv /tmp/mihomo /usr/bin/mihomo
chmod +x /usr/bin/mihomo

# Веб-панель MetaCubeXD
echo "Скачивание веб-интерфейса MetaCubeXD..."
mkdir -p /tmp/metaui_tmp
curl -sL https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.tar.gz -o /tmp/metacubexd.tar.gz
tar -xzf /tmp/metacubexd.tar.gz -C /tmp/metaui_tmp
cp -r /tmp/metaui_tmp/*/* /etc/mihomo/ui/
rm -rf /tmp/metaui_tmp /tmp/metacubexd.tar.gz

# Базы GeoIP и GeoSite
echo "Скачивание баз маршрутизации GeoIP и GeoSite..."
curl -sL https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat -o /etc/mihomo/geoip.dat || true
curl -sL https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat -o /etc/mihomo/geosite.dat || true

# Предварительная загрузка подписки
curl -sL -A "clash.meta" "${SUB_URL}" -o /etc/mihomo/providers/sub.yaml || true

echo "=== [5/7] Создание облегченной конфигурации Mihomo ==="
cat <<CONFIG_EOF > /etc/mihomo/config.yaml
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info
ipv6: false
external-controller: 0.0.0.0:9090
external-ui: ui
secret: ""

geodata-mode: true
geo-auto-update: true
geo-update-interval: 24
geox-url:
  geoip: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat"
  geosite: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat"

dns:
  enable: true
  listen: 127.0.0.1:1053
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  default-nameserver:
    - ${DNS_IP}
    - ${GATEWAY_IP}
    - 77.88.8.8
  nameserver:
    - ${DNS_IP}
    - 77.88.8.8
    - 77.88.8.1

tun:
  enable: true
  device: tun0
  stack: mixed
  mtu: 1400
  auto-route: true
  auto-redirect: false
  auto-detect-interface: true

proxy-providers:
  my-subscription:
    type: http
    url: "${SUB_URL}"
    interval: 86400
    path: ./providers/sub.yaml
    health-check:
      enable: true
      interval: 300
      url: https://www.gstatic.com/generate_204

proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - "AUTO"
      - DIRECT
    use:
      - my-subscription

  - name: "AUTO"
    type: url-test
    use:
      - my-subscription
    url: https://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    lazy: false

rules:
  - AND,((NETWORK,udp),(DST-PORT,443)),REJECT
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - GEOSITE,category-ru,DIRECT
  - GEOIP,RU,DIRECT,no-resolve
  - MATCH,PROXY
CONFIG_EOF

echo "=== [6/7] Создание службы init.d для Mihomo ==="
cat <<'INIT_EOF' > /etc/init.d/mihomo
#!/bin/sh /etc/rc.common

START=95
STOP=10
USE_PROCD=1

PROG=/usr/bin/mihomo
CONF_DIR=/etc/mihomo

start_service() {
    procd_open_instance
    procd_set_param command "$PROG" -d "$CONF_DIR"
    procd_set_param respawn 3600 5 0
    procd_set_param file "$CONF_DIR/config.yaml"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
INIT_EOF
chmod +x /etc/init.d/mihomo

echo "=== [7/7] Конфигурация AdGuard Home ==="
/etc/init.d/adguardhome stop 2>/dev/null || true
mkdir -p /etc/adguardhome

cat << ADG_EOF > /etc/adguardhome/adguardhome.yaml
http:
  pprof:
    port: 6060
    enabled: false
  doh:
    routes:
      - GET /dns-query
      - POST /dns-query
      - GET /dns-query/{ClientID}
      - POST /dns-query/{ClientID}
    insecure_enabled: false
  address: 0.0.0.0:3000
  session_ttl: 30d
users: []
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: ""
theme: auto
dns:
  bind_hosts:
    - 0.0.0.0
  port: 53
  anonymize_client_ip: false
  ratelimit: 0
  ratelimit_subnet_len_ipv4: 24
  ratelimit_subnet_len_ipv6: 56
  ratelimit_whitelist: []
  refuse_any: true
  upstream_dns:
    - 127.0.0.1:1053
  upstream_dns_file: ""
  bootstrap_dns:
    - ${DNS_IP}
    - ${GATEWAY_IP}
  fallback_dns:
    - ${DNS_IP}
  upstream_mode: load_balance
  fastest_timeout: 1s
  allowed_clients: []
  disallowed_clients: []
  blocked_hosts:
    - version.bind
    - id.server
    - hostname.bind
  trusted_proxies:
    - 127.0.0.0/8
    - ::1/128
  cache_enabled: false
  cache_size: 0
  cache_ttl_min: 0
  cache_ttl_max: 0
  cache_optimistic: false
  cache_optimistic_answer_ttl: 30s
  cache_optimistic_max_age: 12h
  bogus_nxdomain: []
  aaaa_disabled: false
  enable_dnssec: false
  edns_client_subnet:
    custom_ip: ""
    enabled: false
    use_custom: false
  max_goroutines: 300
  handle_ddr: true
  ipset: []
  ipset_file: ""
  bootstrap_prefer_ipv6: false
  upstream_timeout: 5s
  private_networks: []
  use_private_ptr_resolvers: true
  local_ptr_upstreams: []
  use_dns64: false
  dns64_prefixes: []
  serve_http3: false
  use_http3_upstreams: false
  serve_plain_dns: true
  hostsfile_enabled: true
  pending_requests:
    enabled: true
tls:
  enabled: false
  server_name: ""
  force_https: false
  port_https: 443
  port_dns_over_tls: 853
  port_dns_over_quic: 853
  port_dnscrypt: 0
  dnscrypt_config_file: ""
  certificate_chain: ""
  private_key: ""
  certificate_path: ""
  private_key_path: ""
  strict_sni_check: false
querylog:
  dir_path: ""
  ignored: []
  interval: 90d
  size_memory: 1000
  enabled: true
  ignored_enabled: false
  file_enabled: true
statistics:
  dir_path: ""
  ignored: []
  interval: 1d
  enabled: true
  ignored_enabled: false
filters: []
whitelist_filters: []
user_rules:
  - '@@||whoer.net^\$important'
  - '@@||aniliberty.top^\$important'
  - '@@||anilibria.top^\$important'
  - '@@||*.libria.fun^\$important'
dhcp:
  enabled: false
  interface_name: ""
  local_domain_name: lan
  dhcpv4:
    gateway_ip: ""
    subnet_mask: ""
    range_start: ""
    range_end: ""
    lease_duration: 86400
    icmp_timeout_msec: 1000
    options: []
  dhcpv6:
    range_start: ""
    lease_duration: 86400
    ra_slaac_only: false
    ra_allow_slaac: false
filtering:
  blocking_ipv4: ""
  blocking_ipv6: ""
  blocked_services:
    schedule:
      time_zone: UTC
    ids: []
  protection_disabled_until: null
  safe_search:
    enabled: false
    bing: true
    duckduckgo: true
    ecosia: true
    google: true
    pixabay: true
    yandex: true
    youtube: true
  blocking_mode: default
  parental_block_host: family-block.dns.adguard.com
  safebrowsing_block_host: standard-block.dns.adguard.com
  rewrites:
    - domain: router.lan
      answer: ${GATEWAY_IP}
      enabled: true
    - domain: openwrt.lan
      answer: ${ROUTER_IP}
      enabled: true
  safe_fs_patterns: []
  max_http_size: 256MB
  safebrowsing_cache_size: 1048576
  safesearch_cache_size: 1048576
  parental_cache_size: 1048576
  cache_time: 30
  filters_update_interval: 24
  blocked_response_ttl: 10
  filtering_enabled: true
  rewrites_enabled: true
  parental_enabled: false
  safebrowsing_enabled: false
  protection_enabled: true
clients:
  runtime_sources:
    whois: true
    arp: true
    rdns: true
    dhcp: true
    hosts: true
  persistent: []
log:
  enabled: true
  file: ""
  max_backups: 0
  max_size: 100
  max_age: 3
  compress: false
  local_time: false
  verbose: false
os:
  group: ""
  user: ""
  rlimit_nofile: 0
schema_version: 34
ADG_EOF

cp /etc/adguardhome/adguardhome.yaml /etc/adguardhome.yaml 2>/dev/null || true

echo "=== Запуск служб и проведение диагностики ==="
/etc/init.d/mihomo enable
/etc/init.d/mihomo restart
sleep 4

/etc/init.d/adguardhome enable 2>/dev/null || true
/etc/init.d/adguardhome restart 2>/dev/null || true
sleep 3

echo ""
echo "=========================================================="
echo "          РЕЗУЛЬТАТЫ ДИАГНОСТИКИ СИСТЕМЫ"
echo "=========================================================="

echo "1. AdGuard Home (порт 53) -> Mihomo DNS (1053):"
DNS_CHECK=$(nslookup ya.ru 127.0.0.1 2>/dev/null || true)
if echo "$DNS_CHECK" | grep -q "Address"; then
    echo "   [OK] DNS-сервер отвечает и мгновенно резолвит имена!"
else
    echo "   [FAIL] Порт 53 не отвечает на запросы."
fi

echo "2. Доступ к РФ ресурсам напрямую (DIRECT):"
if curl -sI --connect-timeout 4 https://ya.ru >/dev/null 2>&1; then
    echo "   [OK] Прямой доступ к ya.ru работает."
else
    echo "   [WARN] Трафик к ya.ru не прошел."
fi

echo "3. Проверка прокси-ноды через порт Mihomo (7890):"
PROXY_TEST=$(curl -s -x http://127.0.0.1:7890 --connect-timeout 8 https://api.ipify.org 2>/dev/null || true)
if [ -n "$PROXY_TEST" ]; then
    echo "   [OK] Прокси активен! Внешний IP через туннель: $PROXY_TEST"
else
    echo "   [FAIL] Прокси не отвечает. Проверьте подписку."
fi

echo "4. Проверка виртуального интерфейса tun0 в ядре:"
if ip addr show dev tun0 >/dev/null 2>&1; then
    echo "   [OK] Интерфейс tun0 успешно поднят."
else
    echo "   [FAIL] Интерфейс tun0 не найден!"
fi

echo "=========================================================="
echo "ШЛЮЗ НАСТРОЕН: МАКСИМАЛЬНАЯ СКОРОСТЬ FAKE-IP АКТИВНА"
echo ""
echo "Веб-интерфейсы:"
echo "- AdGuard Home: http://$ROUTER_IP:3000 (Вход свободный)"
echo "- MetaCubeXD:   http://$ROUTER_IP:9090/ui (Секрет пустой, подключается сразу)"
echo "- SSH / Консоль: порт 22 (Пользователь: root, пароль пустой)"
echo "=========================================================="
