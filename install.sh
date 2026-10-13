#!/bin/bash
# Установка VPN (Xray, VLESS Reality) и сайта на чистый сервер Ubuntu или Debian.
#
# Запуск на сервере от root:
#   bash <(curl -fsSL https://raw.githubusercontent.com/dsdsnfdjndfjhbhgfd-ops/vpn-site/main/install.sh) ПОЧТА_АДМИНА [ДОМЕН]
#
# Без домена сайт получит бесплатный адрес вида 1-2-3-4.sslip.io.
# Повторный запуск безопасен: ключи Reality и выданные ключи сохраняются, обновляется только сайт.
set -euo pipefail

REPO=dsdsnfdjndfjhbhgfd-ops/vpn-site
BRANCH=${BRANCH:-main}
SNI=${SNI:-www.microsoft.com}          # под какой сайт маскируется VPN
XRAY_DIR=${XRAY_DIR:-/usr/local/etc/xray}
CONF=$XRAY_DIR/config.json
STATE=$XRAY_DIR/vpn-state
SITE_DIR=/opt/vpn-site
ENV_FILE=/etc/vpn-site.env

# На свежем сервере Ubuntu сама ставит обновления (unattended-upgrades) и держит
# блокировку apt. Ждём, пока она закончит, а не падаем.
wait_apt() {
  local waited=0
  # Смотрим только на файлы блокировки. По имени процесса нельзя: служба
  # unattended-upgrade-shutdown висит всегда и тоже называется «unattended-upgr».
  while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
    [ "$waited" = 0 ] && echo "Система ставит обновления, жду, пока закончит (обычно 5–15 минут)…"
    sleep 10; waited=$((waited + 10))
    if [ "$waited" -ge 1800 ]; then
      die "apt занят больше 30 минут, перезагрузите сервер (reboot) и запустите снова"
    fi
  done
  return 0
}

apt-get() { wait_apt; command apt-get -o DPkg::Lock::Timeout=600 "$@"; }

step() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mОшибка: %s\033[0m\n' "$*" >&2; exit 1; }

# Ключи Reality. Новые версии Xray пишут «PrivateKey» и «Password (PublicKey)»,
# старые — «Private key» и «Public key».
make_keys() {
  local out
  out=$("$1" x25519)
  PRIV=$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /^private ?key/ {print $2; exit}')
  PBK=$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /public ?key|password/ {print $2; exit}')
  [ -n "$PRIV" ] && [ -n "$PBK" ] || die "не удалось создать ключи Reality: $out"
  SID=$(openssl rand -hex 8)
}

# Конфиг Xray: VLESS Reality на 443, API и учёт адресов для правила «одно устройство».
write_config() {
  cat > "$CONF" <<EOF
{
  "log": {"loglevel": "warning"},
  "api": {"tag": "api", "listen": "127.0.0.1:10085", "services": ["HandlerService", "StatsService"]},
  "stats": {},
  "policy": {"levels": {"0": {"statsUserOnline": true}}},
  "inbounds": [{
    "tag": "vless-in",
    "listen": "0.0.0.0",
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$TEST_ID", "email": "test", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "$SNI:443",
        "serverNames": ["$SNI"],
        "privateKey": "$PRIV",
        "shortIds": ["$SID"]
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
  }],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}
  ],
  "routing": {"rules": [{"type": "field", "ip": ["geoip:private"], "outboundTag": "block"}]}
}
EOF
  cat > "$STATE" <<EOF
IP=$IP
PORT=443
SNI=$SNI
PBK=$PBK
SID=$SID
PRIVATE_KEY=$PRIV
TEST_ID=$TEST_ID
EOF
  chmod 600 "$CONF" "$STATE"
  chown nobody:nogroup "$CONF" 2>/dev/null || true
}

# Caddy пробуем поставить по очереди: из репозитория системы, из репозитория Caddy
# (dl.cloudsmith.io часто недоступен с серверов в России) и готовым файлом с GitHub.
install_caddy() {
  command -v caddy >/dev/null && return 0
  echo "Пробую из репозитория системы…"
  apt-get install -y -q caddy && return 0
  echo "Пробую из репозитория Caddy…"
  if curl -1sLf --max-time 30 https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
       | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
     && curl -1sLf --max-time 30 https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
       > /etc/apt/sources.list.d/caddy-stable.list \
     && apt-get update -q && apt-get install -y -q caddy; then
    return 0
  fi
  rm -f /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -q || true
  echo "Скачиваю Caddy с GitHub…"
  local arch ver
  arch=$(dpkg --print-architecture)
  ver=$(curl -fsSL --max-time 30 -o /dev/null -w '%{url_effective}' \
          https://github.com/caddyserver/caddy/releases/latest | sed -n 's#.*/tag/v##p') || true
  [ -n "$ver" ] || ver=2.10.2
  curl -fsSL --max-time 300 \
      "https://github.com/caddyserver/caddy/releases/download/v$ver/caddy_${ver}_linux_${arch}.tar.gz" \
    | tar -xz -C /usr/bin caddy || die "не удалось скачать Caddy"
  chmod +x /usr/bin/caddy
  getent group caddy >/dev/null || groupadd --system caddy
  id caddy >/dev/null 2>&1 || useradd --system --gid caddy --create-home --home-dir /var/lib/caddy \
    --shell /usr/sbin/nologin caddy
  mkdir -p /etc/caddy
  cat > /etc/systemd/system/caddy.service <<'UNIT'
[Unit]
Description=Caddy
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
}

main() {
  local admin=${1:-} domain=${2:-}
  [ "$(id -u)" = 0 ] || die "запустите от root"
  [ -n "$admin" ] || die "укажите почту админа: bash install.sh you@example.com"
  command -v apt-get >/dev/null || die "нужна Ubuntu или Debian"

  step "Ставлю пакеты"
  export DEBIAN_FRONTEND=noninteractive
  # Хвост неудачной прошлой установки: недоступный репозиторий Caddy ломает apt-get update
  command -v caddy >/dev/null || rm -f /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -q
  apt-get install -y -q curl unzip openssl python3 python3-venv ca-certificates gnupg \
    debian-keyring debian-archive-keyring apt-transport-https

  IP=$(curl -4 -fsS --max-time 10 https://api.ipify.org || curl -4 -fsS --max-time 10 https://ifconfig.me) \
    || die "не удалось узнать IP сервера"
  [ -n "$domain" ] || domain="${IP//./-}.sslip.io"
  echo "IP сервера: $IP, адрес сайта: $domain"

  step "Ставлю Xray"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  if [ -f "$STATE" ] && grep -q '^PBK=' "$STATE"; then
    echo "Xray уже настроен: оставляю его ключи и выданные ключи как есть"
    TEST_ID=$(sed -n 's/^TEST_ID=//p' "$STATE")
    PBK=$(sed -n 's/^PBK=//p' "$STATE"); SID=$(sed -n 's/^SID=//p' "$STATE")
    SNI=$(sed -n 's/^SNI=//p' "$STATE")
  else
    make_keys /usr/local/bin/xray
    TEST_ID=$(cat /proc/sys/kernel/random/uuid)
    write_config
  fi
  /usr/local/bin/xray run -test -c "$CONF" >/dev/null || die "Xray не принял конфиг $CONF"
  systemctl enable xray >/dev/null 2>&1
  systemctl restart xray

  step "Включаю BBR (быстрее на плохих сетях)"
  printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/99-vpn-bbr.conf
  sysctl --system >/dev/null 2>&1 || true

  step "Ставлю сайт"
  mkdir -p "$SITE_DIR"
  curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" \
    | tar -xz --strip-components=1 -C "$SITE_DIR"
  [ -d "$SITE_DIR/venv" ] || python3 -m venv "$SITE_DIR/venv"
  "$SITE_DIR/venv/bin/pip" install -q --upgrade pip
  "$SITE_DIR/venv/bin/pip" install -q -r "$SITE_DIR/requirements.txt"
  if [ ! -f "$ENV_FILE" ]; then
    cat > "$ENV_FILE" <<EOF
SECRET_KEY=$(openssl rand -hex 32)
BASE_URL=https://$domain:8443
SITE_NAME=Tunnel
ADMIN_EMAILS=$admin
MAX_KEYS=1
PLANS=1m:30:199:1 месяц,3m:90:499:3 месяца,12m:365:1690:12 месяцев
# Оплата пока выключена: подписку выдаёт админ в /admin кнопкой «+30 дней».
# Когда подключите ЮKassa: PAYMENT_PROVIDER=yookassa, ключи магазина и PAYMENTS_ENABLED=1.
PAYMENT_PROVIDER=test
PAYMENTS_ENABLED=0
KEYS_ENABLED=1
EOF
    chmod 600 "$ENV_FILE"
  fi
  cp "$SITE_DIR/vpn-site.service" /etc/systemd/system/vpn-site.service
  systemctl daemon-reload
  systemctl enable vpn-site >/dev/null 2>&1
  systemctl restart vpn-site

  step "Ставлю Caddy (HTTPS для сайта)"
  install_caddy
  # Порт 443 занят VPN, поэтому сайт на 8443. Порт 80 нужен для получения сертификата.
  mkdir -p /etc/caddy
  printf '{\n\thttps_port 8443\n}\n\n%s {\n\treverse_proxy 127.0.0.1:8000\n}\n' "$domain" > /etc/caddy/Caddyfile
  systemctl enable caddy >/dev/null 2>&1
  systemctl restart caddy

  if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    step "Открываю порты в ufw"
    for p in 22 80 443 8443; do ufw allow "$p/tcp" >/dev/null; done
  fi

  step "Проверяю"
  sleep 3
  local ok=1
  for s in xray vpn-site caddy; do
    if systemctl is-active --quiet "$s"; then echo "  $s: работает"; else echo "  $s: НЕ РАБОТАЕТ"; ok=0; fi
  done
  curl -fsS -o /dev/null http://127.0.0.1:8000/ && echo "  сайт отвечает" || { echo "  сайт не отвечает"; ok=0; }

  local link="vless://$TEST_ID@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PBK&sid=$SID&type=tcp#Tunnel-test"
  cat <<EOF

========================================================================
Готово.

Сайт:  https://$domain:8443
       (сертификат выдаётся в первые минуты; если сайт не открылся сразу,
        подождите 1–2 минуты)

Что сделать дальше:
  1. Откройте сайт и зарегистрируйтесь с почтой $admin.
  2. Откройте https://$domain:8443/admin и нажмите себе «+30 дней».
  3. В кабинете создайте ключ и добавьте его в приложение.

Проверочный ключ, чтобы сразу проверить VPN (вставьте в v2RayTun или Hiddify):
$link

Журнал сайта:  journalctl -u vpn-site -f
Настройки:     $ENV_FILE  (после правки: systemctl restart vpn-site)
========================================================================
EOF
  [ "$ok" = 1 ] || die "часть сервисов не запустилась, пришлите вывод выше"
}

# INSTALL_LIB=1 — только загрузить функции (для проверки), ничего не устанавливать
if [ "${INSTALL_LIB:-}" != 1 ]; then
  main "$@"
fi
