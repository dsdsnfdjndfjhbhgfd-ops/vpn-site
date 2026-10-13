#!/bin/bash
# Меняет маскировку VPN (REALITY) на основном сервере.
#
#   bash set-mask.sh            — выбрать подходящий сайт из белого списка автоматически
#   bash set-mask.sh ya.ru      — маскироваться под указанный сайт
#   bash set-mask.sh self       — вернуть маскировку под свой адрес (*.sslip.io со своим сертификатом)
#
# Маскировка под сайт из белого списка: оператор видит, что телефон открывает, например,
# ya.ru, а тот, кто проверит сервер сам, получит ответ настоящего ya.ru (REALITY пересылает
# ему соединение). Сайт должен поддерживать TLS 1.3, HTTP/2 и X25519 — скрипт это проверяет.
# После смены ключи в кабинете обновляются сами; в приложениях их нужно скопировать заново.
set -euo pipefail

XRAY_DIR=${XRAY_DIR:-/usr/local/etc/xray}
CONF=$XRAY_DIR/config.json
STATE=$XRAY_DIR/vpn-state
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

# Адрес для маскировки «под себя»: адрес входа в России, если он есть, иначе свой
self_domain() {
  local ip
  ip=$(sed -n 's/^BRIDGE_IP=//p' "$STATE")
  [ -n "$ip" ] || ip=$(sed -n 's/^MAIN_IP=//p' "$STATE")
  [ -n "$ip" ] || ip=$(sed -n 's/^IP=//p' "$STATE")
  echo "${ip//./-}.sslip.io"
}

# Пишет в конфиг Xray новую цель REALITY и имя сайта для клиентов
update_config() {
  local dest=$1 name=$2
  python3 - "$CONF" "$dest" "$name" <<'PY'
import json, sys
path, dest, name = sys.argv[1:]
c = json.load(open(path))
r = c["inbounds"][0]["streamSettings"]["realitySettings"]
r.pop("target", None)
r["dest"] = dest
r["serverNames"] = [name]
json.dump(c, open(path, "w"), indent=2)
PY
}

update_state() {
  local name=$1
  if grep -q '^SNI=' "$STATE"; then
    sed -i "s/^SNI=.*/SNI=$name/" "$STATE"
  else
    echo "SNI=$name" >> "$STATE"
  fi
}

main() {
  local arg=${1:-} name dest
  [ "$(id -u)" = 0 ] || die "запустите от root"
  [ -f "$CONF" ] && [ -f "$STATE" ] || die "не найден VPN ($CONF): сначала установите его через install.sh"
  command -v openssl >/dev/null || { apt-get install -y -q openssl >/dev/null 2>&1 || die "нужен openssl"; }

  if [ "$arg" = self ]; then
    name=$(self_domain)
    dest=127.0.0.1:8443
    step "Возвращаю маскировку под свой адрес $name"
    curl -fsS -o /dev/null --max-time 10 --resolve "$name:8443:127.0.0.1" "https://$name:8443/" \
      || die "сайт https://$name:8443 не отвечает с сертификатом; маскировка «под себя» без него не работает"
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
  fi

  step "Меняю маскировку на $name"
  cp "$CONF" "$CONF.mask.bak"
  cp "$STATE" "$STATE.mask.bak"
  update_config "$dest" "$name"
  if ! "$XRAY" run -test -c "$CONF" >/dev/null 2>&1; then
    cp "$CONF.mask.bak" "$CONF"
    die "Xray не принял настройки, вернул прежние"
  fi
  chown nobody:nogroup "$CONF" 2>/dev/null || true
  update_state "$name"
  $RESTART_CMD
  sleep 1
  systemctl is-active --quiet xray 2>/dev/null || [ -n "${SKIP_ACTIVE_CHECK:-}" ] \
    || { cp "$CONF.mask.bak" "$CONF"; cp "$STATE.mask.bak" "$STATE"; $RESTART_CMD; die "Xray не запустился, вернул прежние настройки"; }

  cat <<EOF

========================================================================
Готово: VPN маскируется под $name.

Ключи в кабинете на сайте уже обновились (в них sni=$name).
В приложении удалите старый ключ и скопируйте его из кабинета заново.

Попробовать другой сайт:   bash set-mask.sh vk.com
Вернуть маскировку «под себя»:   bash set-mask.sh self
========================================================================
EOF
}

# INSTALL_LIB=1 — только загрузить функции (для проверки), ничего не менять
if [ "${INSTALL_LIB:-}" != 1 ]; then
  main "$@"
fi
