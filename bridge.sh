#!/bin/bash
# Вход в VPN на сервере в России. Пересылает трафик на основной сервер за границей:
#   телефон → этот сервер (в России) → основной сервер → интернет
# Соединения внутри России операторы не режут, а между серверами блокировок нет.
#
# Запуск на российском сервере от root (чистая Ubuntu или Debian):
#   bash <(curl -fsSL https://raw.githubusercontent.com/dsdsnfdjndfjhbhgfd-ops/vpn-site/main/bridge.sh) IP_ОСНОВНОГО_СЕРВЕРА
# Потом на основном сервере: use-bridge.sh с IP этого сервера (команду скрипт напечатает в конце).
set -euo pipefail

REPO=dsdsnfdjndfjhbhgfd-ops/vpn-site
HAPROXY_CFG=${HAPROXY_CFG:-/etc/haproxy/haproxy.cfg}

step() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mОшибка: %s\033[0m\n' "$*" >&2; exit 1; }

# На свежем сервере Ubuntu сама ставит обновления и держит блокировку apt: ждём.
wait_apt() {
  local waited=0
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

is_public_ip() {
  [ -n "${1:-}" ] && python3 -c 'import ipaddress, sys; sys.exit(0 if ipaddress.ip_address(sys.argv[1]).is_global else 1)' "$1" 2>/dev/null
}

# Адрес, по которому к этому серверу подключаются снаружи (как в install.sh)
detect_ip() {
  local ip
  if [ -n "${SERVER_IP:-}" ]; then echo "$SERVER_IP"; return; fi
  ip=$(printf '%s' "${SSH_CONNECTION:-}" | awk '{print $3}')
  if is_public_ip "$ip"; then echo "$ip"; return; fi
  for ip in $(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1); do
    if is_public_ip "$ip"; then echo "$ip"; return; fi
  done
  curl -4 -fsS --max-time 10 https://api.ipify.org || curl -4 -fsS --max-time 10 https://ifconfig.me
}

# HAProxy пересылает соединения как есть, ничего не расшифровывая.
# Для VPN и сайта передаём настоящий адрес клиента (PROXY protocol): без него все
# клиенты выглядели бы как этот сервер, и правило «одно устройство» не работало бы.
write_haproxy_cfg() {
  local main=$1
  cat > "$HAPROXY_CFG" <<EOF
global
    log /dev/log local0 warning
    maxconn 20000
    user haproxy
    group haproxy
    daemon

defaults
    mode tcp
    log global
    option dontlognull
    timeout connect 10s
    timeout client 2h
    timeout server 2h

# VPN
frontend vpn
    bind :443
    default_backend vpn
backend vpn
    server main $main:443 send-proxy

# Сайт
frontend site
    bind :8443
    default_backend site
backend site
    server main $main:8443 send-proxy

# Порт 80: через него основной сервер получает сертификат на адрес этого сервера
frontend http
    bind :80
    default_backend http
backend http
    server main $main:80
EOF
}

main() {
  local main_ip=${1:-}
  [ "$(id -u)" = 0 ] || die "запустите от root"
  [ -n "$main_ip" ] || die "укажите IP основного сервера: bash bridge.sh 1.2.3.4"
  is_public_ip "$main_ip" || die "$main_ip не похож на внешний IP"
  command -v apt-get >/dev/null || die "нужна Ubuntu или Debian"

  local my_ip
  my_ip=$(detect_ip) || die "не удалось узнать IP этого сервера"
  is_public_ip "$my_ip" || die "у этого сервера нет своего внешнего IP ($my_ip): нужен VPS не за NAT"
  [ "$my_ip" != "$main_ip" ] || die "это и есть основной сервер; bridge.sh запускают на российском"
  echo "Этот сервер: $my_ip, основной сервер: $main_ip"

  step "Проверяю, что основной сервер доступен отсюда"
  timeout 10 bash -c "</dev/tcp/$main_ip/443" 2>/dev/null \
    || die "не удаётся подключиться к $main_ip:443. Проверьте, что на основном сервере работает VPN"
  echo "  $main_ip:443 доступен"

  step "Проверяю, что порты 80, 443 и 8443 свободны"
  local busy
  busy=$(ss -ltnp 2>/dev/null | awk '$4 ~ /:(80|443|8443)$/ && $0 !~ /haproxy/' || true)
  [ -z "$busy" ] || die "порты уже заняты другой программой:
$busy
Остановите её (например: systemctl disable --now nginx apache2) и запустите снова"

  step "Ставлю HAProxy"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q haproxy psmisc python3 curl

  step "Настраиваю пересылку на $main_ip"
  write_haproxy_cfg "$main_ip"
  haproxy -c -f "$HAPROXY_CFG" >/dev/null || die "HAProxy не принял настройки $HAPROXY_CFG"
  systemctl enable haproxy >/dev/null 2>&1
  systemctl restart haproxy

  step "Настраиваю сеть для скорости (BBR, буферы TCP)"
  cat > /etc/sysctl.d/99-vpn-bbr.conf <<'SYSCTL'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 131072 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_notsent_lowat=16384
SYSCTL
  sysctl --system >/dev/null 2>&1 || true

  if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    step "Открываю порты в ufw"
    for p in 22 80 443 8443; do ufw allow "$p/tcp" >/dev/null; done
  fi

  step "Проверяю"
  sleep 2
  systemctl is-active --quiet haproxy || die "HAProxy не запустился: journalctl -u haproxy -n 30"
  echo "  haproxy: работает"
  ss -ltn | awk '$4 ~ /:(80|443|8443)$/ {print "  слушает " $4}'

  cat <<EOF

========================================================================
Российский сервер готов: $my_ip пересылает трафик на $main_ip.

Последний шаг — на ОСНОВНОМ сервере ($main_ip) выполните:

  bash <(curl -fsSL https://raw.githubusercontent.com/$REPO/main/use-bridge.sh) $my_ip

После этого сайт будет по адресу https://${my_ip//./-}.sslip.io:8443,
а ключи в кабинете — с адресом этого сервера. Старые ключи в приложениях
нужно заменить: скопируйте их из кабинета заново.
========================================================================
EOF
}

# INSTALL_LIB=1 — только загрузить функции (для проверки), ничего не устанавливать
if [ "${INSTALL_LIB:-}" != 1 ]; then
  main "$@"
fi
