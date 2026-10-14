#!/bin/bash
# Проверяет и чинит сайт. Запуск от root на ЛЮБОМ из серверов — основном или российском:
#   bash <(curl -fsSL https://raw.githubusercontent.com/dsdsnfdjndfjhbhgfd-ops/vpn-site/main/fix.sh)
#
# Основной сервер: программа сайта, Caddy (HTTPS), Xray и проход через российский вход.
# Российский сервер: HAProxy и связь с основным.
# Что можно починить само (перезапуск, возврат сломанных настроек) — чинит, остальное объясняет.
set -uo pipefail

REPO=dsdsnfdjndfjhbhgfd-ops/vpn-site
BRANCH=${BRANCH:-main}
XRAY_DIR=${XRAY_DIR:-/usr/local/etc/xray}
CONF=$XRAY_DIR/config.json
STATE=$XRAY_DIR/vpn-state
CADDYFILE=${CADDYFILE:-/etc/caddy/Caddyfile}
ENV_FILE=${ENV_FILE:-/etc/vpn-site.env}
SITE_DIR=${SITE_DIR:-/opt/vpn-site}
HAPROXY_CFG=${HAPROXY_CFG:-/etc/haproxy/haproxy.cfg}
XRAY=${XRAY:-/usr/local/bin/xray}
CADDY=${CADDY:-caddy}

FIXED=()
PROBLEMS=()

step() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
good() { printf '  \033[32mOK\033[0m  %s\n' "$*"; }
bad() { printf '  \033[31mНЕТ\033[0m %s\n' "$*"; }
fixed() { printf '  \033[33mИСПРАВЛЕНО\033[0m %s\n' "$*"; FIXED+=("$*"); }
problem() { PROBLEMS+=("$*"); }

active() { systemctl is-active --quiet "$1"; }

# Код ответа по HTTPS: $1 — имя сайта, $2 — порт, $3 — к какому адресу подключаться
https_code() {
  curl -sS -o /dev/null -w '%{http_code}' --max-time 15 --noproxy '*' \
    --resolve "$1:$2:$3" "https://$1:$2/" 2>/tmp/fix-curl.err
}
curl_error() { sed 's/^curl: ([0-9]*) //' /tmp/fix-curl.err | head -n1; }

tcp_open() { timeout 8 bash -c "</dev/tcp/$1/$2" 2>/dev/null; }

# Загрузка файла оформления сайта (≈40 КБ) через адрес $3: на нём видно «замирание» связи
# (фильтр пропускает первые 16–20 КБ соединения, а дальше данные не идут). Печатает «получено всего».
fetch_css() {
  local h got total
  h=$(mktemp)
  got=$(curl -sS -D "$h" -o /dev/null -w '%{size_download}' --max-time 15 --noproxy '*' \
          --resolve "$1:$2:$3" "https://$1:$2/static/style.css" 2>/dev/null) || true
  total=$(tr -d '\r' < "$h" | awk -F': *' 'tolower($1)=="content-length"{v=$2} END{print v}')
  rm -f "$h"
  echo "${got:-0} ${total:-0}"
}
TUNNEL_RUN="bash <(curl -fsSL https://raw.githubusercontent.com/$REPO/main/tunnel.sh)"

set_state_del() { sed -i "/^$1=/d" "$STATE"; }

# ---------- основной сервер ----------

site_host() { sed -n 's#^BASE_URL=https://\([^:/]*\).*#\1#p' "$ENV_FILE" 2>/dev/null | head -n1; }
site_port() {
  local p
  p=$(sed -n 's#^BASE_URL=https://[^:/]*:\([0-9]*\).*#\1#p' "$ENV_FILE" 2>/dev/null | head -n1)
  echo "${p:-443}"
}

app_code() { curl -sS -o /dev/null -w '%{http_code}' --max-time 10 --noproxy '*' http://127.0.0.1:8000/ 2>/dev/null; }

reinstall_site() {
  echo "  Скачиваю код сайта заново…"
  local tmp
  tmp=$(mktemp -d)
  if curl -fsSL --max-time 120 "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" \
       | tar -xz --strip-components=1 -C "$tmp"; then
    cp -a "$tmp"/. "$SITE_DIR"/
    "$SITE_DIR/venv/bin/pip" install -q -r "$SITE_DIR/requirements.txt" || true
  else
    echo "  не удалось скачать код с GitHub"
  fi
  rm -rf "$tmp"
  systemctl restart vpn-site
  sleep 4
}

check_app() {
  step "Программа сайта (vpn-site)"
  local code
  code=$(app_code)
  if [ "$code" = 200 ]; then good "отвечает"; return; fi
  bad "не отвечает (код ${code:-нет}), перезапускаю"
  systemctl restart vpn-site
  sleep 4
  code=$(app_code)
  if [ "$code" = 200 ]; then fixed "программа сайта перезапущена"; return; fi
  echo "  Журнал:"
  journalctl -u vpn-site -n 12 --no-pager 2>/dev/null | sed 's/^/    /'
  reinstall_site
  code=$(app_code)
  if [ "$code" = 200 ]; then fixed "код сайта переустановлен"; return; fi
  bad "программа сайта не запускается"
  problem "программа сайта не запускается: пришлите вывод команды  journalctl -u vpn-site -n 40 --no-pager"
}

caddy_valid() { "$CADDY" validate --config "$1" --adapter caddyfile >/dev/null 2>&1; }

check_caddy() {
  step "Caddy (HTTPS для сайта)"
  if ! caddy_valid "$CADDYFILE"; then
    bad "настройки Caddy ($CADDYFILE) с ошибкой"
    local b bridge
    bridge=$(sed -n 's/^BRIDGE_IP=//p' "$STATE" 2>/dev/null)
    # самая свежая исправная копия; при работе через российский сервер — только с приёмом
    # PROXY protocol (Caddyfile.bak от use-bridge.sh — это настройки ещё до российского сервера)
    for b in $(ls -t "$CADDYFILE.trojan.bak" "$CADDYFILE.tunnel.bak" "$CADDYFILE.bak" 2>/dev/null); do
      [ -z "$bridge" ] || grep -q "allow .*$bridge/32" "$b" || continue
      if caddy_valid "$b"; then
        cp "$CADDYFILE" "$CADDYFILE.broken"
        cat "$b" > "$CADDYFILE"
        # без строки Trojan в Caddy ключи Trojan не работают — убираем их из кабинета
        grep -q 10443 "$CADDYFILE" || set_state_del TROJAN_PATH
        fixed "настройки Caddy возвращены из $b (сломанные сохранены в $CADDYFILE.broken)"
        systemctl restart caddy
        sleep 3
        break
      fi
    done
    caddy_valid "$CADDYFILE" || problem "настройки Caddy ($CADDYFILE) с ошибкой, подходящей резервной копии нет: пришлите вывод команды  caddy validate --config $CADDYFILE"
  fi
  if ! active caddy; then
    bad "Caddy не работает, запускаю"
    systemctl restart caddy
    sleep 3
    if active caddy; then fixed "Caddy запущен"; else
      bad "Caddy не запускается. Журнал:"
      journalctl -u caddy -n 12 --no-pager 2>/dev/null | sed 's/^/    /'
      problem "Caddy не запускается: пришлите вывод команды  journalctl -u caddy -n 40 --no-pager"
      return
    fi
  else
    good "работает"
  fi

  local host port code
  host=$(site_host); port=$(site_port)
  [ -n "$host" ] || { problem "в $ENV_FILE нет BASE_URL=https://…"; return; }
  code=$(https_code "$host" "$port" 127.0.0.1)
  if [ "$code" = 200 ]; then
    good "https://$host:$port отвечает на этом сервере"
  else
    bad "https://$host:$port на этом сервере: ${code:-нет ответа} $(curl_error)"
    systemctl restart caddy
    sleep 5
    code=$(https_code "$host" "$port" 127.0.0.1)
    if [ "$code" = 200 ]; then fixed "Caddy перезапущен, сайт отвечает"; else
      echo "  Журнал Caddy:"
      journalctl -u caddy -n 15 --no-pager 2>/dev/null | grep -iE 'error|certificate|obtain' | tail -8 | sed 's/^/    /'
      problem "Caddy не отдаёт сайт https://$host:$port (${code:-нет ответа} $(curl_error))"
    fi
  fi
}

check_xray() {
  step "VPN (Xray)"
  if active xray; then good "работает"; return; fi
  bad "Xray не работает"
  if ! "$XRAY" run -test -c "$CONF" >/dev/null 2>&1 && [ -f "$CONF.trojan.bak" ] \
     && "$XRAY" run -test -c "$CONF.trojan.bak" >/dev/null 2>&1; then
    cp "$CONF" "$CONF.broken"
    cat "$CONF.trojan.bak" > "$CONF"
    set_state_del TROJAN_PATH
    fixed "настройки Xray возвращены (сломанные сохранены в $CONF.broken)"
  fi
  systemctl restart xray
  sleep 2
  if active xray; then fixed "Xray запущен"; else
    "$XRAY" run -test -c "$CONF" 2>&1 | tail -3 | sed 's/^/    /'
    problem "Xray не запускается: пришлите вывод команды  journalctl -u xray -n 40 --no-pager"
  fi
}

check_bridge_from_main() {
  local host port bridge code got total
  bridge=$(sed -n 's/^BRIDGE_IP=//p' "$STATE" 2>/dev/null)
  [ -n "$bridge" ] || return
  host=$(site_host); port=$(site_port)
  if [ -f /etc/systemd/system/vpn-tunnel.service ]; then
    step "Обратный туннель к $bridge (vpn-tunnel)"
    if active vpn-tunnel; then good "служба работает"; else
      bad "служба не работает, запускаю"
      systemctl restart vpn-tunnel
      sleep 5
      if active vpn-tunnel; then fixed "туннель запущен"; else
        journalctl -u vpn-tunnel -n 8 --no-pager 2>/dev/null | sed 's/^/    /'
        problem "туннель не запускается: пришлите вывод команды  journalctl -u vpn-tunnel -n 30 --no-pager"
      fi
    fi
  fi
  step "Сайт через российский вход $bridge"
  code=$(https_code "$host" "$port" "$bridge")
  if [ "$code" = 200 ]; then
    good "https://$host:$port через $bridge отвечает"
    read -r got total <<<"$(fetch_css "$host" "$port" "$bridge")"
    if [ "${total:-0}" -gt 0 ] && [ "$got" -ge "$total" ]; then
      good "большие файлы через $bridge приходят целиком"
    else
      bad "файл оформления через $bridge: пришло $((got / 1024)) КБ из $((total / 1024)) КБ — связь замирает"
      if [ -f /etc/systemd/system/vpn-tunnel.service ]; then
        problem "связь через российский сервер замирает (фильтр режет соединения к зарубежному серверу). Туннель установлен — на российском сервере выполните эту же команду"
      else
        problem "связь через российский сервер замирает: фильтр режет соединения от него к зарубежному серверу после 16–20 КБ, поэтому сайт не догружается, а VPN не работает. Включите обратный туннель:  $TUNNEL_RUN"
      fi
    fi
  elif tcp_open "$bridge" "$port"; then
    bad "порт $port на $bridge открыт, но сайт не отвечает (${code:-нет ответа} $(curl_error))"
    problem "российский сервер $bridge не пропускает сайт: запустите эту же команду на нём"
  else
    bad "$bridge:$port не отвечает"
    problem "российский сервер $bridge недоступен или на нём не работает HAProxy: запустите эту же команду на нём, а если не получается зайти — проверьте у хостинга, включён ли сервер"
  fi
}

main_server() {
  echo "Это основной сервер (VPN и сайт)."
  check_app
  check_caddy
  check_xray
  check_bridge_from_main
}

# ---------- российский сервер ----------

detect_ip() {
  local ip
  if [ -n "${SERVER_IP:-}" ]; then echo "$SERVER_IP"; return; fi
  ip=$(printf '%s' "${SSH_CONNECTION:-}" | awk '{print $3}')
  if [ -n "$ip" ] && [[ ! "$ip" =~ ^(10|127|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\. ]]; then echo "$ip"; return; fi
  ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}

bridge_server() {
  echo "Это российский сервер (вход)."
  local main_ip my_ip host site_bind site_addr site_port targets tunnel_ports got total
  # куда пересылает HAProxy: «server main 1.2.3.4:443 …» в каждом backend
  # (с туннелем tunnel.sh: «server tun 127.0.0.1:…», а прямой путь — запасной)
  targets=$(awk '/^backend /{f=1} f && $1=="server" && $2!="tun"{print $3}' "$HAPROXY_CFG" | sort -u)
  tunnel_ports=$(awk '/^backend /{f=1} f && $1=="server" && $2=="tun"{print $3}' "$HAPROXY_CFG" | sort -u)
  main_ip=$(awk '/^backend site/{f=1} f && $1=="server" && $2!="tun"{split($3,a,":"); print a[1]; exit}' "$HAPROXY_CFG")
  # порт сайта на этом сервере: «bind :8443» в frontend site
  site_bind=$(awk '/^frontend site/{f=1} f && $1=="bind"{print $2; exit}' "$HAPROXY_CFG")
  site_port=${site_bind##*:}
  site_port=${site_port:-8443}
  site_addr=${site_bind%:*}
  [ -n "$site_addr" ] && [ "$site_addr" != "*" ] && [ "$site_addr" != "$site_bind" ] || site_addr=127.0.0.1
  my_ip=$(detect_ip)
  host="${my_ip//./-}.sslip.io"

  step "HAProxy (пересылка на основной сервер $main_ip)"
  if ! haproxy -c -f "$HAPROXY_CFG" >/dev/null 2>&1; then
    bad "настройки HAProxy с ошибкой:"
    haproxy -c -f "$HAPROXY_CFG" 2>&1 | grep -iE 'alert|error' | head -5 | sed 's/^/    /'
    problem "настройки HAProxy с ошибкой: запустите заново bridge.sh $main_ip"
  fi
  if active haproxy; then good "работает"; else
    bad "HAProxy не работает, запускаю"
    systemctl enable haproxy >/dev/null 2>&1
    systemctl restart haproxy
    sleep 2
    if active haproxy; then fixed "HAProxy запущен"; else
      journalctl -u haproxy -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
      problem "HAProxy не запускается: пришлите вывод команды  journalctl -u haproxy -n 40 --no-pager"
    fi
  fi

  step "Связь с основным сервером $main_ip"
  local t
  for t in $targets; do
    if tcp_open "${t%:*}" "${t##*:}"; then good "$t доступен"; else
      bad "$t не отвечает"
      problem "основной сервер не отвечает на $t: запустите эту же команду на нём; если не получается зайти — проверьте у хостинга, включён ли он"
    fi
  done

  if [ -n "$tunnel_ports" ]; then
    step "Обратный туннель от основного сервера"
    local tp
    tp=$(head -n1 <<<"$tunnel_ports")
    tp=${tp##*:}
    # ssh открывает все порты туннеля разом, так что хватает первого
    if tcp_open 127.0.0.1 "$tp"; then good "подключён"; else
      bad "не подключён — пока работает прямой путь"
      problem "туннель не подключён: на основном сервере $main_ip выполните эту же команду"
    fi
  fi

  step "Сайт через этот сервер"
  local code
  code=$(https_code "$host" "$site_port" "$site_addr")
  if [ "$code" = 200 ]; then
    good "https://$host:$site_port отвечает"
    read -r got total <<<"$(fetch_css "$host" "$site_port" "$site_addr")"
    if [ "${total:-0}" -gt 0 ] && [ "$got" -ge "$total" ]; then
      good "большие файлы приходят целиком"
    else
      bad "файл оформления: пришло $((got / 1024)) КБ из $((total / 1024)) КБ — связь с основным сервером замирает"
      problem "связь отсюда с основным сервером замирает (фильтр режет соединения к зарубежному серверу после 16–20 КБ). Нужен обратный туннель: на ОСНОВНОМ сервере выполните  $TUNNEL_RUN  — он напечатает команду для этого сервера"
    fi
  else
    bad "https://$host:$site_port: ${code:-нет ответа} $(curl_error)"
    problem "сайт через этот сервер не открывается: запустите эту же команду на основном сервере $main_ip"
  fi
}

main() {
  [ "$(id -u)" = 0 ] || { echo "Запустите от root"; exit 1; }
  if [ -f "$CONF" ] && [ -f "$STATE" ]; then
    main_server
  elif [ -f "$HAPROXY_CFG" ] && grep -q '^backend site' "$HAPROXY_CFG"; then
    bridge_server
  else
    echo "Не нашёл ни VPN (основной сервер), ни HAProxy (российский сервер). Это точно нужный сервер?"
    exit 1
  fi

  echo
  echo "========================================================================"
  if [ ${#FIXED[@]} -gt 0 ]; then
    echo "Исправлено:"
    printf '  • %s\n' "${FIXED[@]}"
  fi
  if [ ${#PROBLEMS[@]} -gt 0 ]; then
    echo "Осталось:"
    printf '  • %s\n' "${PROBLEMS[@]}"
  else
    echo "На этом сервере всё работает."
    echo "Если сайт всё равно не открывается на телефоне — откройте его через другой интернет"
    echo "(Wi-Fi вместо мобильного или наоборот). Открывается там — значит, ваш оператор"
    echo "не пускает к адресу сервера, а сам сайт в порядке."
  fi
  echo "========================================================================"
}

# INSTALL_LIB=1 — только загрузить функции (для проверки)
if [ "${INSTALL_LIB:-}" != 1 ]; then
  main "$@"
fi
