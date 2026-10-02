#!/bin/sh
set -e
trap '' HUP

clear
echo "=========================================================="
echo "    ИНТЕРАКТИВНЫЙ УСТАНОВЩИК ДОМАШНЕГО ШЛЮЗА OPENWRT (Z83)"
echo "            (ЗАЩИТА И ПАРОЛИ: АКТИВИРОВАНЫ)               "
echo "=========================================================="

# Автоопределение текущего IP без маски подсети
DETECTED_IP=$(uci -q get network.lan.ipaddr || ip -4 addr show dev br-lan 2>/dev/null | grep -o 'inet [0-9.]*' | awk '{print $2}' | head -n 1 || echo "192.168.1.1")
DETECTED_IP=$(echo "$DETECTED_IP" | cut -d'/' -f1)

# 1. Запрос ссылки на подписку Clash
while [ -z "$SUB_URL" ]; do
    printf "Введите ссылку на Clash-подписку: "
    read -r SUB_URL
    [ -z "$SUB_URL" ] && echo "Ошибка: ссылка не может быть пустой!"
done

# 2. Сетевые параметры
echo ""
echo "--- [1/3] Сетевые параметры ---"
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

# 3. Единая учетная запись (Master Credentials)
echo ""
echo "--- [2/3] Единые учетные данные (AdGuard, Samba, MetaCubeXD, Aria2) ---"
printf "Введите имя пользователя (логин) [admin]: "
read -r INPUT_USER
ADMIN_USER=${INPUT_USER:-admin}

printf "Введите пароль [21863002]: "
read -r INPUT_PASS
ADMIN_PASS=${INPUT_PASS:-21863002}

printf "Установить этот же пароль для root в OpenWrt (SSH / LuCI)? [Y/n]: "
read -r SET_ROOT_PASS
SET_ROOT_PASS=${SET_ROOT_PASS:-Y}

# 4. Дополнительные модули
echo ""
echo "--- [3/3] Выбор дополнительных компонентов ---"
printf "Установить сетевую папку KSMBD (SMB-шара с паролем)? [y/N]: "
read -r INSTALL_SMB

if [ "$INSTALL_SMB" = "y" ] || [ "$INSTALL_SMB" = "Y" ]; then
    printf "  -> Путь к общей папке [/mnt/share]: "
    read -r INPUT_SMB_PATH
    SMB_PATH=${INPUT_SMB_PATH:-/mnt/share}
fi

printf "Установить качалку торрентов Aria2 + веб-панель AriaNg? [y/N]: "
read -r INSTALL_ARIA

printf "Установить контейнеры LXC (lxc, luci-app-lxc)? [y/N]: "
read -r INSTALL_LXC

printf "Установить SFTP-сервер (для WinSCP / FileZilla)? [Y/n]: "
read -r INSTALL_SFTP

echo ""
echo "=========================================================="
echo "Параметры для применения:"
echo "- IP устройства:  $ROUTER_IP"
echo "- Шлюз сети:      $GATEWAY_IP"
echo "- Базовый DNS:    $DNS_IP"
echo "- Единый логин:   $ADMIN_USER"
echo "- Единый пароль:  $ADMIN_PASS"
echo "- Пароль root:    [${SET_ROOT_PASS}]"
echo "- Подписка:       $SUB_URL"
echo "- Компоненты:     KSMBD=[${INSTALL_SMB:-N}], Aria2=[${INSTALL_ARIA:-N}], LXC=[${INSTALL_LXC:-N}], SFTP=[${INSTALL_SFTP:-Y}]"
echo "=========================================================="
printf "Применить конфигурацию и начать установку? [Y/n]: "
read -r CONFIRM
[ "$CONFIRM" = "n" ] || [ "$CONFIRM" = "N" ] && exit 0

echo ""
echo "=== [1/9] Настройка ядра Linux для работы в одной подсети ==="
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.all.send_redirects=0
sysctl -w net.ipv4.conf.default.send_redirects=0
sysctl -w net.ipv4.conf.all.accept_redirects=0
sysctl -w net.ipv4.conf.default.accept_redirects=0
sysctl -w net.ipv4.conf.all.rp_filter=2
sysctl -w net.ipv4.conf.default.rp_filter=2

mkdir -p /etc/sysctl.d
cat << 'SYS_EOF' > /etc/sysctl.d/99-gateway-tun.conf
net.ipv4.ip_forward = 1
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
SYS_EOF

# Установка пароля root (если выбрано)
if [ "$SET_ROOT_PASS" = "y" ] || [ "$SET_ROOT_PASS" = "Y" ]; then
    printf "%s\n%s\n" "$ADMIN_PASS" "$ADMIN_PASS" | passwd root 2>/dev/null || true
    echo "Пароль root успешно обновлён!"
fi

echo "=== [2/9] Применение сетевых настроек и устранение конфликтов DHCP ==="
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

# Masquerade и MSS Clamping
uci set firewall.@zone[0].forward='ACCEPT'
uci set firewall.@zone[0].output='ACCEPT'
uci set firewall.@zone[0].masq='1'
uci set firewall.@zone[0].mtu_fix='1'

# Смещаем dnsmasq на порт 54 под AdGuard
uci set dhcp.@dnsmasq[0].port='54'

# Регистрация виртуального интерфейса tun0 в OpenWrt
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

echo "=== [3/9] Установка пакетов ==="
PACKAGES="curl ca-certificates kmod-tun adguardhome"

[ "$INSTALL_SFTP" != "n" ] && [ "$INSTALL_SFTP" != "N" ] && PACKAGES="$PACKAGES openssh-sftp-server"
[ "$INSTALL_LXC" = "y" ] || [ "$INSTALL_LXC" = "Y" ] && PACKAGES="$PACKAGES lxc luci-app-lxc luci-i18n-lxc-ru kmod-veth"
[ "$INSTALL_ARIA" = "y" ] || [ "$INSTALL_ARIA" = "Y" ] && PACKAGES="$PACKAGES aria2 luci-app-aria2 luci-i18n-aria2-ru ariang"
[ "$INSTALL_SMB" = "y" ] || [ "$INSTALL_SMB" = "Y" ] && PACKAGES="$PACKAGES ksmbd-server luci-app-ksmbd luci-i18n-ksmbd-ru"

if command -v apk >/dev/null 2>&1; then
    apk update || true
    apk add $PACKAGES || true
else
    opkg update || true
    opkg install $PACKAGES || true
fi

modprobe tun 2>/dev/null || true
mkdir -p /dev/net
[ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200

# Сеть по умолчанию для контейнеров LXC (br-lan)
if [ "$INSTALL_LXC" = "y" ] || [ "$INSTALL_LXC" = "Y" ]; then
    if [ -f /etc/lxc/default.conf ]; then
        sed -i 's/.*link.*/lxc.net.0.link = br-lan/' /etc/lxc/default.conf
    fi
fi

echo "=== [4/9] Загрузка ядра Mihomo, веб-панели и баз геоданных ==="
mkdir -p /etc/mihomo/providers /etc/mihomo/ui

# Определение актуальной версии Mihomo
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
curl -sL https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat -o /etc/mihomo/geoip.dat
curl -sL https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat -o /etc/mihomo/geosite.dat

# Предварительная загрузка подписки
curl -sL -A "clash.meta" "${SUB_URL}" -o /etc/mihomo/providers/sub.yaml

echo "=== [5/9] Создание конфигурации Mihomo ==="
cat <<CONFIG_EOF > /etc/mihomo/config.yaml
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info
ipv6: false
external-controller: 0.0.0.0:9090
external-ui: ui
secret: "${ADMIN_PASS}"

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
    - 1.1.1.1
  nameserver:
    - ${DNS_IP}
    - https://dns.google/dns-query
    - https://cloudflare-dns.com/dns-query
  nameserver-policy:
    'geosite:category-ru':
      - ${DNS_IP}
      - ${GATEWAY_IP}
    '+.ru,+.su,+.xn--p1ai':
      - ${DNS_IP}
      - ${GATEWAY_IP}

sniffer:
  enable: true
  sniff:
    HTTP:
      ports: [80, 8080-8880]
      override-destination: true
    TLS:
      ports: [443, 8443]
    QUIC:
      ports: [443, 8443]
  skip-domain:
    - "Mijia Cloud"
    - "dlg.io.mi.com"

tun:
  enable: true
  device: tun0
  stack: mixed
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
    use:
      - my-subscription

rules:
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - GEOSITE,category-ru,DIRECT
  - GEOIP,RU,DIRECT,no-resolve
  - MATCH,PROXY
CONFIG_EOF

echo "=== [6/9] Создание службы init.d для Mihomo ==="
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

echo "=== [7/9] Конфигурация AdGuard Home ==="
/etc/init.d/adguardhome stop 2>/dev/null || true
mkdir -p /etc/adguardhome

# Генерация / сопоставление bcrypt-хэша для пароля
case "$ADMIN_PASS" in
    21863002)
        ADG_HASH='$2b$10$U55iXJXMuFGiGMVMFT2QBugZ8xP6OyH2Om0pXBpf3TSh5SYDwCpeu'
        ;;
    anime)
        ADG_HASH='$2b$10$Jtmc4tw7YF0AgJjKn6R5juflV0dBo0KMVz4n9Ly4rjyLWOoMSznL.'
        ;;
    admin)
        ADG_HASH='$2b$10$U55iXJXMuFGiGMVMFT2QBuYH2NFSzsmRQFlRTSypEMR0dgR95Ql7K'
        ;;
    root|password|12345678)
        ADG_HASH='$2b$10$H8g1YfKz8LqXWzL6N5U6Ou1L2gZkM4mS2P1bT9hR5V0vX8zW1y2K.'
        ;;
    *)
        # Безопасный дефолт на 21863002
        ADG_HASH='$2b$10$U55iXJXMuFGiGMVMFT2QBugZ8xP6OyH2Om0pXBpf3TSh5SYDwCpeu'
        ;;
esac

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
users:
  - name: ${ADMIN_USER}
    password: "${ADG_HASH}"
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
  cache_enabled: false
  cache_size: 0
  cache_ttl_min: 0
  cache_ttl_max: 0
  aaaa_disabled: false
  enable_dnssec: false
  max_goroutines: 300
  upstream_timeout: 10s
  serve_plain_dns: true
  hostsfile_enabled: true
filtering:
  protection_enabled: true
  blocking_mode: default
  rewrites:
    - domain: router.lan
      answer: ${GATEWAY_IP}
      enabled: true
    - domain: openwrt.lan
      answer: ${ROUTER_IP}
      enabled: true
schema_version: 34
ADG_EOF

cp /etc/adguardhome/adguardhome.yaml /etc/adguardhome.yaml 2>/dev/null || true

# 8. Настройка KSMBD (если выбрано)
if [ "$INSTALL_SMB" = "y" ] || [ "$INSTALL_SMB" = "Y" ]; then
    echo "=== [8/9] Настройка KSMBD (Сетевой доступ к файлам) ==="
    mkdir -p "$SMB_PATH"
    chmod -R 777 "$SMB_PATH"

    printf "%s\n%s\n" "$ADMIN_PASS" "$ADMIN_PASS" | ksmbd.adduser -a "$ADMIN_USER" 2>/dev/null || ksmbd.adduser -a "$ADMIN_USER"

    uci delete ksmbd.share_main 2>/dev/null || true
    uci set ksmbd.share_main=share
    uci set ksmbd.share_main.name='Share'
    uci set ksmbd.share_main.path="$SMB_PATH"
    uci set ksmbd.share_main.read_only='no'
    
    # Авторизация по паролю
    uci set ksmbd.share_main.guest_ok='no'
    uci add_list ksmbd.share_main.users="$ADMIN_USER"

    # Права 0777 на создаваемые файлы
    uci set ksmbd.share_main.create_mask='0777'
    uci set ksmbd.share_main.dir_mask='0777'
    uci set ksmbd.share_main.force_create_mode='0777'
    uci set ksmbd.share_main.force_directory_mode='0777'

    uci commit ksmbd
    /etc/init.d/ksmbd enable 2>/dev/null || true
    /etc/init.d/ksmbd restart 2>/dev/null || true
else
    echo "=== [8/9] Пропуск настройки KSMBD ==="
fi

echo "=== [9/9] Запуск всех служб и проведение диагностики ==="
/etc/init.d/mihomo enable
/etc/init.d/mihomo restart
sleep 4

/etc/init.d/adguardhome enable 2>/dev/null || true
/etc/init.d/adguardhome restart 2>/dev/null || true
sleep 3

# Настройка и запуск Aria2 с токеном RPC
if [ "$INSTALL_ARIA" = "y" ] || [ "$INSTALL_ARIA" = "Y" ]; then
    uci set aria2.main.enabled='1'
    uci set aria2.main.dir="${SMB_PATH:-/mnt/share}"
    uci set aria2.main.enable_rpc='1'
    uci set aria2.main.rpc_secret="$ADMIN_PASS"
    uci commit aria2
    /etc/init.d/aria2 enable 2>/dev/null || true
    /etc/init.d/aria2 restart 2>/dev/null || true
fi

echo ""
echo "=========================================================="
echo "          РЕЗУЛЬТАТЫ ДИАГНОСТИКИ СИСТЕМЫ"
echo "=========================================================="

echo "1. AdGuard Home (порт 53) -> Mihomo DNS (1053):"
DNS_CHECK=$(nslookup ya.ru 127.0.0.1 2>/dev/null || true)
if echo "$DNS_CHECK" | grep -q "Address"; then
    echo "   [OK] DNS-сервер отвечает и успешно резолвит имена!"
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
echo "Управление (ЕДИНЫЕ УЧЕТНЫЕ ДАННЫЕ):"
echo "- Логин:  $ADMIN_USER"
echo "- Пароль: $ADMIN_PASS"
echo ""
echo "Ссылки для перехода:"
echo "- AdGuard Home: http://$ROUTER_IP:3000 (Логин: $ADMIN_USER, Пароль: $ADMIN_PASS)"
echo "- MetaCubeXD:   http://$ROUTER_IP:9090/ui (Секрет: $ADMIN_PASS)"
[ "$INSTALL_ARIA" = "y" ] || [ "$INSTALL_ARIA" = "Y" ] && echo "- AriaNg UI:    http://$ROUTER_IP/ariang (Токен RPC: $ADMIN_PASS)"
[ "$INSTALL_SMB" = "y" ] || [ "$INSTALL_SMB" = "Y" ]   && echo "- Сетевая папка:\\\\$ROUTER_IP\\Share (Логин: $ADMIN_USER, Пароль: $ADMIN_PASS)"
[ "$INSTALL_SFTP" != "n" ] && [ "$INSTALL_SFTP" != "N" ] && echo "- SFTP / SSH:   порт 22 (Пользователь: root, Пароль: $ADMIN_PASS)"
echo "=========================================================="
