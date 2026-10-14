#!/bin/bash
# Второй способ подключения к VPN — Trojan, спрятанный внутри сайта. Запуск на ОСНОВНОМ сервере от root:
#   bash <(curl -fsSL https://raw.githubusercontent.com/dsdsnfdjndfjhbhgfd-ops/vpn-site/main/trojan.sh)       — включить
#   bash <(curl -fsSL https://raw.githubusercontent.com/dsdsnfdjndfjhbhgfd-ops/vpn-site/main/trojan.sh) off   — выключить
#
# Как это устроено: телефон подключается к сайту — тот же адрес, порт 8443 и настоящий
# сертификат, — а VPN отвечает только по секретному пути. Для оператора это обычное
# посещение сайта по HTTPS; кто откроет адрес сам, увидит сайт.
# Основной ключ (VLESS) продолжает работать; в кабинете у каждого ключа появляется второй —
# Trojan, с тем же правилом «одно устройство». Российский сервер настраивать не нужно:
# порт сайта он уже пересылает.
set -euo pipefail

REPO=dsdsnfdjndfjhbhgfd-ops/vpn-site
BRANCH=${BRANCH:-main}
RUN="bash <(curl -fsSL https://raw.githubusercontent.com/$REPO/main/trojan.sh)"
XRAY_DIR=${XRAY_DIR:-/usr/local/etc/xray}
CONF=$XRAY_DIR/config.json
STATE=$XRAY_DIR/vpn-state
CADDYFILE=${CADDYFILE:-/etc/caddy/Caddyfile}
ENV_FILE=${ENV_FILE:-/etc/vpn-site.env}
SITE_DIR=${SITE_DIR:-/opt/vpn-site}
XRAY=${XRAY:-/usr/local/bin/xray}
CADDY=${CADDY:-caddy}
RESTART_CMD=${RESTART_CMD:-systemctl restart xray}
CADDY_RELOAD_CMD=${CADDY_RELOAD_CMD:-systemctl reload caddy}
SELFTEST_URL=${SELFTEST_URL:-https://www.gstatic.com/generate_204}
# Внутренний порт Trojan: Xray слушает его только на 127.0.0.1, снаружи он закрыт.
# Тот же порт прописан в use-bridge.sh и install.sh.
TROJAN_PORT=10443
TAG=trojan-ws

step() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mОшибка: %s\033[0m\n' "$*" >&2; exit 1; }

set_state() {
  local key=$1 value=$2
  if grep -q "^$key=" "$STATE"; then
    sed -i "s|^$key=.*|$key=$value|" "$STATE"
  else
    echo "$key=$value" >> "$STATE"
  fi
}

# Адрес сайта из BASE_URL: имя и порт
site_host() { sed -n 's#^BASE_URL=https://\([^:/]*\).*#\1#p' "$ENV_FILE" 2>/dev/null | head -n1; }
site_port() {
  local p
  p=$(sed -n 's#^BASE_URL=https://[^:/]*:\([0-9]*\).*#\1#p' "$ENV_FILE" 2>/dev/null | head -n1)
  echo "${p:-443}"
}

# Xray: вход Trojan на 127.0.0.1 с теми же ключами, что у VLESS (пароль — id ключа).
# Без пути ($3 пуст) — убирает вход Trojan.
update_xray_config() {
  python3 - "$1" "$2" "${3:-}" "$TROJAN_PORT" "$TAG" <<'PY'
import json, sys
src, dst, path, port, tag = sys.argv[1:]
c = json.load(open(src))
c["inbounds"] = [i for i in c["inbounds"] if i.get("tag") != tag]
if path:
    main = c["inbounds"][0]
    ib = {
        "tag": tag, "listen": "127.0.0.1", "port": int(port), "protocol": "trojan",
        "settings": {"clients": [{"password": u["id"], "email": u["email"]}
                                 for u in main["settings"]["clients"]]},
        "streamSettings": {"network": "ws", "wsSettings": {"path": path}},
    }
    if main.get("sniffing"):
        ib["sniffing"] = main["sniffing"]
    c["inbounds"].append(ib)
with open(dst, "w") as f:
    json.dump(c, f, indent=2)
PY
}

# Caddy: запросы по секретному пути — в Xray, остальное — сайт, как раньше.
# Без пути ($3 пуст) — убирает эту строку.
update_caddyfile() {
  python3 - "$1" "$2" "${3:-}" "$TROJAN_PORT" <<'PY'
import re, sys
src, dst, path, port = sys.argv[1:]
out, sites = [], 0
for line in open(src).read().splitlines(keepends=True):
    if re.match(r"\s*reverse_proxy\s+/\S+\s+127\.0\.0\.1:%s\s*$" % port, line):
        continue  # прежний путь Trojan
    m = re.match(r"(\s*)reverse_proxy\s+127\.0\.0\.1:8000\s*$", line)
    if m:
        sites += 1
        if path:
            out.append(f"{m.group(1)}reverse_proxy {path} 127.0.0.1:{port}\n")
    out.append(line)
if not sites:
    sys.exit("в Caddyfile нет строки «reverse_proxy 127.0.0.1:8000»")
open(dst, "w").write("".join(out))
PY
}

# Ключ для проверки: служебный «test», иначе первый попавшийся
probe_password() {
  python3 - "$CONF" <<'PY'
import json, sys
cl = json.load(open(sys.argv[1]))["inbounds"][0]["settings"]["clients"]
cl = sorted(cl, key=lambda c: c.get("email") != "test")
print(cl[0]["id"] if cl else "")
PY
}

# Проверка как с телефона: Xray-клиент → $1:$2 (TLS с именем сайта) → Trojan → интернет
selftest() {
  local addr=$1 port=$2 host=$3 path=$4 password=$5 dir sp pid code
  dir=$(mktemp -d)
  sp=$((20000 + RANDOM % 20000))
  cat > "$dir/client.json" <<EOF
{"log": {"loglevel": "none"},
 "inbounds": [{"listen": "127.0.0.1", "port": $sp, "protocol": "socks"}],
 "outbounds": [{"protocol": "trojan",
   "settings": {"servers": [{"address": "$addr", "port": $port, "password": "$password"}]},
   "streamSettings": {"network": "ws", "wsSettings": {"path": "$path", "host": "$host"},
     "security": "tls", "tlsSettings": {"serverName": "$host", "fingerprint": "chrome", "alpn": ["http/1.1"]}}}]}
EOF
  "$XRAY" run -c "$dir/client.json" >/dev/null 2>&1 &
  pid=$!
  sleep 1
  # --noproxy '': идти именно через проверяемый VPN, даже если в окружении задан NO_PROXY
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 --retry 3 --retry-connrefused --noproxy '' \
           --socks5-hostname "127.0.0.1:$sp" "$SELFTEST_URL" 2>/dev/null) || true
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$dir/client.json"
  rmdir "$dir"
  [ "$code" = "${SELFTEST_CODE:-204}" ]
}

restore() {
  cat "$CONF.trojan.bak" > "$CONF"
  cat "$CADDYFILE.trojan.bak" > "$CADDYFILE"
  cat "$STATE.trojan.bak" > "$STATE"
  $RESTART_CMD || true
  # если Caddy к этому моменту остановлен, перечитать настройки он не сможет — тогда запускаем
  $CADDY_RELOAD_CMD || systemctl restart caddy || true
}

# Новый код сайта: он добавляет и удаляет ключи сразу в обоих входах и показывает ключ Trojan
update_site() {
  [ -d "$SITE_DIR/venv" ] || die "не найден сайт в $SITE_DIR: сначала установите его через install.sh"
  curl -fsSL --max-time 120 "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" \
    | tar -xz --strip-components=1 -C "$SITE_DIR" || die "не удалось скачать сайт с GitHub"
  "$SITE_DIR/venv/bin/pip" install -q -r "$SITE_DIR/requirements.txt"
  systemctl restart vpn-site
}

# Меняет конфиги Xray и Caddy (путь пуст — убирает Trojan), проверяет и применяет
apply() {
  local path=$1 tmp ctmp err
  # Тот же замок, что у сайта (conf_lock в app.py): пока он у нас, сайт не правит конфиг
  exec 9>"$CONF.lock"
  flock 9
  cp "$CONF" "$CONF.trojan.bak"
  cp "$CADDYFILE" "$CADDYFILE.trojan.bak"
  cp "$STATE" "$STATE.trojan.bak"
  # Расширение .json обязательно: по нему Xray понимает формат файла
  tmp=$(mktemp --suffix=.json "$XRAY_DIR/trojan.XXXXXX")
  ctmp=$(mktemp "$CADDYFILE.XXXXXX")
  update_xray_config "$CONF" "$tmp" "$path"
  if ! err=$(update_caddyfile "$CADDYFILE" "$ctmp" "$path" 2>&1); then
    rm -f "$tmp" "$ctmp"
    die "$err. Ничего не изменено"
  fi
  if ! err=$("$XRAY" run -test -c "$tmp" 2>&1); then
    rm -f "$tmp" "$ctmp"
    die "Xray не принял настройки, ничего не изменено:
$(printf '%s\n' "$err" | tail -3)"
  fi
  if ! err=$("$CADDY" validate --config "$ctmp" --adapter caddyfile 2>&1); then
    rm -f "$tmp" "$ctmp"
    die "Caddy не принял настройки, ничего не изменено:
$(printf '%s\n' "$err" | grep -iE 'error' | tail -3)"
  fi
  chmod 600 "$tmp"
  chown nobody:nogroup "$tmp" 2>/dev/null || true

  # Дальше меняем три файла; если прервут на середине — возвращаем все
  trap 'restore; exit 1' INT TERM HUP
  mv -f "$tmp" "$CONF"
  cat "$ctmp" > "$CADDYFILE"
  rm -f "$ctmp"
  if [ -n "$path" ]; then
    set_state TROJAN_PATH "$path"
  else
    sed -i '/^TROJAN_PATH=/d' "$STATE"
  fi
  $RESTART_CMD || true   # если не запустится, проверка ниже вернёт прежние настройки
  $CADDY_RELOAD_CMD || true
  sleep 2
  if [ -z "${SKIP_ACTIVE_CHECK:-}" ]; then
    local s
    for s in xray caddy; do
      if ! systemctl is-active --quiet "$s"; then
        restore
        die "$s не запустился с новыми настройками, вернул прежние"
      fi
    done
  fi
  trap - INT TERM HUP
}

main() {
  local arg=${1:-} host port ip path password
  [ "$(id -u)" = 0 ] || die "запустите от root"
  [ -f "$CONF" ] && [ -f "$STATE" ] || die "не найден VPN ($CONF): сначала установите его через install.sh"
  [ -f "$CADDYFILE" ] || die "не найден $CADDYFILE: сначала установите сайт через install.sh"

  if [ "$arg" = off ]; then
    step "Выключаю Trojan"
    apply ""
    cat <<EOF

========================================================================
Trojan выключен, ключи Trojan больше не работают. Основной ключ работает как раньше.
Включить снова:
  $RUN
========================================================================
EOF
    return
  fi

  host=$(site_host)
  port=$(site_port)
  [ -n "$host" ] || die "в $ENV_FILE нет адреса сайта (BASE_URL=https://…)"
  ip=$(sed -n 's/^IP=//p' "$STATE")
  # Путь — секрет: без него на этом адресе только сайт. При повторном запуске оставляем прежний,
  # чтобы ключи в приложениях не пришлось менять.
  path=$(sed -n 's/^TROJAN_PATH=//p' "$STATE")
  [ -n "$path" ] || path="/$(openssl rand -hex 8)"

  step "Проверяю сайт https://$host:$port"
  curl -fsS -o /dev/null --max-time 10 --resolve "$host:$port:127.0.0.1" "https://$host:$port/" \
    || die "сайт не отвечает с действующим сертификатом, а Trojan работает через него.
Журнал: journalctl -u caddy -n 30"
  echo "  сайт работает"

  if [ -z "${SKIP_SITE_UPDATE:-}" ]; then
    step "Обновляю сайт"
    update_site
    echo "  готово"
  fi

  step "Включаю Trojan"
  apply "$path"
  echo "  Xray и Caddy работают"

  step "Проверяю Trojan"
  password=$(probe_password)
  [ -n "$password" ] || die "в Xray нет ни одного ключа, проверить нечем"
  if ! selftest 127.0.0.1 "$port" "$host" "$path" "$password"; then
    restore
    die "Trojan не заработал, вернул прежние настройки. Журнал: journalctl -u xray -n 30"
  fi
  echo "  на этом сервере: работает"
  local chain="через вход $ip: работает"
  if [ -n "$ip" ] && ! selftest "$ip" "$port" "$host" "$path" "$password"; then
    chain="через вход $ip: НЕ работает — проверьте, что на российском сервере пересылается порт $port"
  fi
  echo "  $chain"

  cat <<EOF

========================================================================
Готово: Trojan включён.

В кабинете на сайте у каждого ключа появился «Запасной ключ: Trojan».
Скопируйте его, добавьте в приложение (v2RayTun или Hiddify) и подключитесь
именно к нему. Основной ключ тоже остаётся.

Для оператора это выглядит как посещение сайта https://$host:$port
(тот же адрес и настоящий сертификат).

Выключить Trojan:
  $RUN off
========================================================================
EOF
}

# INSTALL_LIB=1 — только загрузить функции (для проверки), ничего не менять
if [ "${INSTALL_LIB:-}" != 1 ]; then
  main "$@"
fi
