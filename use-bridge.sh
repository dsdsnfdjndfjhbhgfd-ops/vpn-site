#!/bin/bash
# Переключает основной сервер на работу через вход в России (см. bridge.sh):
#   телефон → российский сервер → этот сервер → интернет
#
# Запуск на ОСНОВНОМ сервере от root, после bridge.sh на российском:
#   bash <(curl -fsSL https://raw.githubusercontent.com/dsdsnfdjndfjhbhgfd-ops/vpn-site/main/use-bridge.sh) IP_РОССИЙСКОГО_СЕРВЕРА
#
# Что меняется:
#   • Xray принимает подключения только через российский сервер и получает от него
#     настоящий адрес телефона (PROXY protocol), поэтому правило «одно устройство» работает;
#   • маскировка VPN — под адрес российского сервера (1-2-3-4.sslip.io) с настоящим
#     сертификатом, который Caddy получает здесь же через пересылку порта 80;
#   • ключи в кабинете и адрес сайта — с адресом российского сервера.
set -euo pipefail

XRAY_DIR=${XRAY_DIR:-/usr/local/etc/xray}
CONF=$XRAY_DIR/config.json
STATE=$XRAY_DIR/vpn-state
CADDYFILE=${CADDYFILE:-/etc/caddy/Caddyfile}
ENV_FILE=${ENV_FILE:-/etc/vpn-site.env}
XRAY=${XRAY:-/usr/local/bin/xray}
CADDY=${CADDY:-caddy}

step() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mОшибка: %s\033[0m\n' "$*" >&2; exit 1; }

# Адреса сайта, которые уже есть в Caddyfile (строки вида «адрес {» или «адрес, адрес {»)
site_domains() {
  awk '/^[^{ \t#][^{]*\{[ \t]*$/ {sub(/[ \t]*\{[ \t]*$/, ""); gsub(/,/, " "); print}' "$CADDYFILE" \
    | tr ' ' '\n' | grep -v '^$' | sort -u
}

# Caddy: сайт отвечает и на адрес российского сервера; с российского сервера
# приходит настоящий адрес посетителя (PROXY protocol), остальные подключения — как раньше.
write_caddyfile() {
  local bridge_ip=$1 domains=$2
  cat > "$CADDYFILE" <<EOF
{
	https_port 8443
	servers :8443 {
		listener_wrappers {
			proxy_protocol {
				timeout 5s
				allow $bridge_ip/32
			}
			tls
		}
	}
}

$domains {
	reverse_proxy 127.0.0.1:8000
}
EOF
}

# Xray: только через российский сервер, маскировка под его адрес, сертификат берётся у Caddy.
update_xray_config() {
  local bridge_domain=$1
  python3 - "$CONF" "$bridge_domain" <<'PY'
import json, sys
path, domain = sys.argv[1], sys.argv[2]
c = json.load(open(path))
ib = c["inbounds"][0]
ss = ib.setdefault("streamSettings", {})
ss.setdefault("sockopt", {})["acceptProxyProtocol"] = True
r = ss["realitySettings"]
r.pop("target", None)
r["dest"] = "127.0.0.1:8443"
names = [n for n in r.get("serverNames", []) if n != domain]
r["serverNames"] = [domain] + names
c.setdefault("log", {})["loglevel"] = "warning"
json.dump(c, open(path, "w"), indent=2)
PY
}

update_state() {
  local bridge_ip=$1 bridge_domain=$2
  grep -q '^MAIN_IP=' "$STATE" || echo "MAIN_IP=$(sed -n 's/^IP=//p' "$STATE")" >> "$STATE"
  sed -i "s/^IP=.*/IP=$bridge_ip/; s/^SNI=.*/SNI=$bridge_domain/" "$STATE"
  if grep -q '^BRIDGE_IP=' "$STATE"; then
    sed -i "s/^BRIDGE_IP=.*/BRIDGE_IP=$bridge_ip/" "$STATE"
  else
    echo "BRIDGE_IP=$bridge_ip" >> "$STATE"
  fi
}

main() {
  local bridge_ip=${1:-}
  [ "$(id -u)" = 0 ] || die "запустите от root"
  [[ "$bridge_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "укажите IP российского сервера: bash use-bridge.sh 1.2.3.4"
  [ -f "$CONF" ] && [ -f "$STATE" ] || die "не найден VPN ($CONF): сначала установите его через install.sh"
  local bridge_domain="${bridge_ip//./-}.sslip.io"

  step "Проверяю, что российский сервер пересылает трафик сюда"
  timeout 10 bash -c "</dev/tcp/$bridge_ip/80" 2>/dev/null \
    || die "$bridge_ip:80 недоступен. Сначала запустите bridge.sh на российском сервере"
  echo "  $bridge_ip отвечает"

  step "Настраиваю сайт на адрес $bridge_domain"
  local domains
  domains=$( (site_domains; echo "$bridge_domain") | sort -u | paste -sd, - | sed 's/,/, /g')
  cp "$CADDYFILE" "$CADDYFILE.bak"
  write_caddyfile "$bridge_ip" "$domains"
  "$CADDY" validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1 \
    || { cp "$CADDYFILE.bak" "$CADDYFILE"; die "Caddy не принял настройки, вернул прежние"; }
  systemctl restart caddy

  echo "Жду сертификат для $bridge_domain (до 3 минут)…"
  local ok=0
  for _ in $(seq 36); do
    if curl -fsS -o /dev/null --max-time 5 --resolve "$bridge_domain:8443:127.0.0.1" "https://$bridge_domain:8443/"; then
      ok=1; break
    fi
    sleep 5
  done
  [ "$ok" = 1 ] || die "сертификат для $bridge_domain не получен. Журнал: journalctl -u caddy -n 30
Проверьте, что на российском сервере запущен bridge.sh и открыт порт 80. VPN пока не переключён"
  echo "  сертификат получен"

  step "Переключаю VPN на работу через $bridge_ip"
  cp "$CONF" "$CONF.bak"
  update_xray_config "$bridge_domain"
  "$XRAY" run -test -c "$CONF" >/dev/null || { cp "$CONF.bak" "$CONF"; die "Xray не принял настройки, вернул прежние"; }
  chown nobody:nogroup "$CONF" 2>/dev/null || true
  update_state "$bridge_ip" "$bridge_domain"
  sed -i "s#^BASE_URL=.*#BASE_URL=https://$bridge_domain:8443#" "$ENV_FILE"
  systemctl restart xray
  systemctl restart vpn-site

  step "Проверяю"
  sleep 2
  for s in xray vpn-site caddy; do
    systemctl is-active --quiet "$s" && echo "  $s: работает" || die "$s не запустился"
  done

  cat <<EOF

========================================================================
Готово: VPN работает через российский сервер $bridge_ip.

Сайт:   https://$bridge_domain:8443
Ключи:  в кабинете на сайте. Старые ключи в приложениях больше не работают:
        удалите их и скопируйте ключ из кабинета заново (адрес в нём теперь $bridge_ip).

Вернуть как было: cp $CONF.bak $CONF && cp $CADDYFILE.bak $CADDYFILE
        и в $STATE поставьте IP и SNI прежними, затем
        systemctl restart xray caddy vpn-site
========================================================================
EOF
}

# INSTALL_LIB=1 — только загрузить функции (для проверки), ничего не менять
if [ "${INSTALL_LIB:-}" != 1 ]; then
  main "$@"
fi
