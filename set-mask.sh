#!/bin/bash
# Меняет маскировку VPN (REALITY) на основном сервере. Запуск от root:
#   bash <(curl -fsSL https://raw.githubusercontent.com/dsdsnfdjndfjhbhgfd-ops/vpn-site/main/set-mask.sh)         — выбрать сайт из белого списка
#   bash <(curl -fsSL https://raw.githubusercontent.com/dsdsnfdjndfjhbhgfd-ops/vpn-site/main/set-mask.sh) ya.ru   — под указанный сайт
#   bash <(curl -fsSL https://raw.githubusercontent.com/dsdsnfdjndfjhbhgfd-ops/vpn-site/main/set-mask.sh) self    — под адрес своего сайта
#
# Маскировка под сайт из белого списка: оператор видит, что телефон открывает, например,
# ya.ru, а тот, кто проверит сервер сам, получит ответ настоящего ya.ru (REALITY пересылает
# ему соединение). Сайт должен поддерживать TLS 1.3, HTTP/2 и X25519 — скрипт это проверяет.
# «self» — маскировка под адрес своего сайта (тот, что в BASE_URL) с его сертификатом.
# После смены ключи в кабинете обновляются сами; в приложениях их нужно скопировать заново.
set -euo pipefail

REPO=dsdsnfdjndfjhbhgfd-ops/vpn-site
RUN="bash <(curl -fsSL https://raw.githubusercontent.com/$REPO/main/set-mask.sh)"
XRAY_DIR=${XRAY_DIR:-/usr/local/etc/xray}
CONF=$XRAY_DIR/config.json
STATE=$XRAY_DIR/vpn-state
ENV_FILE=${ENV_FILE:-/etc/vpn-site.env}
XRAY=${XRAY:-/usr/local/bin/xray}
RESTART_CMD=${RESTART_CMD:-systemctl restart xray}

# Крупные российские сайты, которые входят в белые списки мобильного интернета.
# Порядок важен: берётся первый, который подходит технически.
CANDIDATES=${CANDIDATES:-"ya.ru vk.com dzen.ru rutube.ru max.ru www.ozon.ru www.avito.ru www.wildberries.ru"}

step() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mОшибка: %s\033[0m\n' "$*" >&2; exit 1; }

# Подходит ли сайт для REALITY: TLS 1.3, HTTP/2 (h2) и обмен ключами X25519.
# Проверка идёт отсюда, с основного сервера: именно он будет соединяться с сайтом.
check_site() {
  local d=$1 out
  # CHECK_TARGET=ip:порт — проверить по другому адресу (для тестов)
  out=$(timeout 10 openssl s_client -connect "${CHECK_TARGET:-$d:443}" -servername "$d" -tls1_3 -alpn h2 </dev/null 2>&1) || true
  grep -q 'TLSv1.3' <<<"$out" && grep -qi 'ALPN protocol: h2' <<<"$out" && grep -qi 'x25519' <<<"$out"
}

# Адрес своего сайта: из BASE_URL, иначе адрес входа в России или самого сервера на sslip.io
self_domain() {
  local host ip
  host=$(sed -n 's#^BASE_URL=https://\([^:/]*\).*#\1#p' "$ENV_FILE" 2>/dev/null | head -n1)
  if [ -n "$host" ]; then echo "$host"; return; fi
  ip=$(sed -n 's/^BRIDGE_IP=//p' "$STATE")
  [ -n "$ip" ] || ip=$(sed -n 's/^MAIN_IP=//p' "$STATE")
  [ -n "$ip" ] || ip=$(sed -n 's/^IP=//p' "$STATE")
  echo "${ip//./-}.sslip.io"
}

# Читает конфиг Xray из $1 и пишет в $2 с новой целью REALITY и именем сайта для клиентов
update_config() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, sys
src, dst, dest, name = sys.argv[1:]
c = json.load(open(src))
r = c["inbounds"][0]["streamSettings"]["realitySettings"]
r.pop("target", None)
r["dest"] = dest
r["serverNames"] = [name]
with open(dst, "w") as f:
    json.dump(c, f, indent=2)
PY
}

# SNI — имя сайта в ключах; MASK — что выбрано здесь (use-bridge.sh по нему не сбрасывает маскировку)
set_state() {
  local key=$1 value=$2
  if grep -q "^$key=" "$STATE"; then
    sed -i "s|^$key=.*|$key=$value|" "$STATE"
  else
    echo "$key=$value" >> "$STATE"
  fi
}

restore() {
  cp "$CONF.mask.bak" "$CONF.restore.tmp" && mv -f "$CONF.restore.tmp" "$CONF"
  cp "$STATE.mask.bak" "$STATE"
}

main() {
  local arg=${1:-} name dest mask
  [ "$(id -u)" = 0 ] || die "запустите от root"
  [ -f "$CONF" ] && [ -f "$STATE" ] || die "не найден VPN ($CONF): сначала установите его через install.sh"
  command -v openssl >/dev/null || { apt-get install -y -q openssl >/dev/null 2>&1 || die "нужен openssl"; }

  if [ "$arg" = self ]; then
    name=$(self_domain)
    dest=127.0.0.1:8443
    mask=self
    step "Маскирую под адрес своего сайта $name"
    curl -fsS -o /dev/null --max-time 10 --resolve "$name:8443:127.0.0.1" "https://$name:8443/" \
      || die "сайт https://$name:8443 не отвечает с действующим сертификатом, а без него эта маскировка не работает"
  else
    local list=$arg
    [ -n "$list" ] || list=$CANDIDATES
    step "Ищу сайт для маскировки"
    name=""
    for d in $list; do
      d=${d#https://}; d=${d%%/*}
      if check_site "$d"; then
        echo "  $d: подходит"
        name=$d
        break
      fi
      echo "  $d: не подходит (нет TLS 1.3, HTTP/2 или X25519, или недоступен отсюда)"
    done
    [ -n "$name" ] || die "ни один сайт не подошёл: $list"
    dest=$name:443
    mask=$name
  fi

  step "Меняю маскировку на $name"
  # Тот же замок, что у сайта (conf_lock в app.py): пока он у нас, сайт не правит конфиг
  exec 9>"$CONF.lock"
  flock 9
  cp "$CONF" "$CONF.mask.bak"
  cp "$STATE" "$STATE.mask.bak"
  # Новый конфиг сначала проверяем во временном файле; рабочий не трогаем, пока он не годен.
  # Расширение .json обязательно: по нему Xray понимает формат файла.
  local tmp
  tmp=$(mktemp --suffix=.json "$XRAY_DIR/mask.XXXXXX")
  update_config "$CONF" "$tmp" "$dest" "$name"
  if ! "$XRAY" run -test -c "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    die "Xray не принял новые настройки, ничего не изменено"
  fi
  chmod 600 "$tmp"
  chown nobody:nogroup "$tmp" 2>/dev/null || true

  # Дальше меняем два файла; если прервут на середине — возвращаем оба
  trap 'restore; exit 1' INT TERM HUP
  set_state SNI "$name"
  set_state MASK "$mask"
  mv -f "$tmp" "$CONF"
  $RESTART_CMD || true   # если не запустится, проверка ниже вернёт прежние настройки
  sleep 1
  if ! systemctl is-active --quiet xray 2>/dev/null && [ -z "${SKIP_ACTIVE_CHECK:-}" ]; then
    restore
    $RESTART_CMD || true
    die "Xray не запустился с новыми настройками, вернул прежние"
  fi
  trap - INT TERM HUP

  cat <<EOF

========================================================================
Готово: VPN маскируется под $name.

Ключи в кабинете на сайте уже обновились (в них sni=$name).
В приложении удалите старый ключ и скопируйте его из кабинета заново.

Попробовать другой сайт:
  $RUN vk.com
Маскировка под адрес своего сайта:
  $RUN self
========================================================================
EOF
}

# INSTALL_LIB=1 — только загрузить функции (для проверки), ничего не менять
if [ "${INSTALL_LIB:-}" != 1 ]; then
  main "$@"
fi
