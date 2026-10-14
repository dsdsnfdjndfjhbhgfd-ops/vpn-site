#!/bin/bash
# Обратный туннель между серверами: основной сервер сам подключается к российскому.
#
# Зачем: фильтр на стороне российского сервера «замораживает» соединения, которые российский
# сервер открывает к зарубежному: после ~16–20 КБ данные перестают идти. Из-за этого сайт
# через российский вход не догружается, а VPN подключается, но не работает. Соединения,
# которые открываются из-за границы в Россию, так не режутся — поэтому туннель открывает
# основной сервер (по SSH), а российский пересылает в него подключения телефонов.
#
# 1) На ОСНОВНОМ сервере:
#      bash <(curl -fsSL https://raw.githubusercontent.com/dsdsnfdjndfjhbhgfd-ops/vpn-site/main/tunnel.sh)
#    В конце он напечатает команду для российского сервера.
# 2) На РОССИЙСКОМ сервере — эту команду (вида  … tunnel.sh ru 'ssh-ed25519 AAAA…').
#
# Если туннель пропадёт, российский сервер сам вернётся к прямой пересылке, как раньше.
set -euo pipefail

REPO=dsdsnfdjndfjhbhgfd-ops/vpn-site
RUN="bash <(curl -fsSL https://raw.githubusercontent.com/$REPO/main/tunnel.sh)"
XRAY_DIR=${XRAY_DIR:-/usr/local/etc/xray}
CONF=$XRAY_DIR/config.json
STATE=$XRAY_DIR/vpn-state
CADDYFILE=${CADDYFILE:-/etc/caddy/Caddyfile}
ENV_FILE=${ENV_FILE:-/etc/vpn-site.env}
HAPROXY_CFG=${HAPROXY_CFG:-/etc/haproxy/haproxy.cfg}
CADDY=${CADDY:-caddy}
SSH=${SSH:-ssh}
SSHD=${SSHD:-sshd}
KEY=${TUNNEL_KEY:-/root/.ssh/vpn_tunnel}
UNIT=${TUNNEL_UNIT:-/etc/systemd/system/vpn-tunnel.service}
TUNNEL_USER=${TUNNEL_USER:-vpntunnel}
SSH_PORT=${TUNNEL_SSH_PORT:-22}
# порт на основном сервере : порт туннеля на российском (там он слушает только 127.0.0.1)
TUNNEL_PORTS=${TUNNEL_PORTS:-"443:20443 8443:20843 80:20080"}
SSHD_DROPIN=${SSHD_DROPIN:-/etc/ssh/sshd_config.d/vpn-tunnel.conf}

step() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mОшибка: %s\033[0m\n' "$*" >&2; exit 1; }

# Загрузка файла оформления сайта (≈40 КБ — больше порога «заморозки») через адрес $3.
# Печатает «получено всего» в байтах.
fetch_css() {
  local h got total
  h=$(mktemp)
  got=$(curl -sS -D "$h" -o /dev/null -w '%{size_download}' --max-time 15 --noproxy '*' \
          --resolve "$1:$2:$3" "https://$1:$2/static/style.css" 2>/dev/null) || true
  total=$(tr -d '\r' < "$h" | awk -F': *' 'tolower($1)=="content-length"{v=$2} END{print v}')
  rm -f "$h"
  echo "${got:-0} ${total:-0}"
}

# Человеческий вывод проверки; код возврата 0 — пришло целиком
report_css() {
  local got=$1 total=$2 what=$3
  if [ "${total:-0}" -gt 0 ] && [ "$got" -ge "$total" ]; then
    echo "  $what: пришло целиком ($((total / 1024)) КБ) — работает"
    return 0
  elif [ "${total:-0}" -gt 0 ]; then
    echo "  $what: пришло $((got / 1024)) КБ из $((total / 1024)) КБ — соединение замирает"
  else
    echo "  $what: сайт не ответил"
  fi
  return 1
}

tcp_open() { timeout 5 bash -c "</dev/tcp/$1/$2" 2>/dev/null; }

# ---------- основной сервер ----------

site_host() { sed -n 's#^BASE_URL=https://\([^:/]*\).*#\1#p' "$ENV_FILE" 2>/dev/null | head -n1; }
site_port() {
  local p
  p=$(sed -n 's#^BASE_URL=https://[^:/]*:\([0-9]*\).*#\1#p' "$ENV_FILE" 2>/dev/null | head -n1)
  echo "${p:-443}"
}

# Caddy: подключения из туннеля приходят с 127.0.0.1 и несут настоящий адрес посетителя
# (PROXY protocol) — их надо принимать так же, как с российского сервера. Заодно сжатие
# страниц: так сайт меньше весит и быстрее открывается на медленном интернете.
update_caddyfile() {
  python3 - "$1" "$2" <<'PY'
import re, sys
src, dst = sys.argv[1:]
lines = open(src).read().splitlines(keepends=True)
out, depth, site, has_encode = [], 0, False, False
for line in lines:
    s = line.strip()
    m = re.match(r"(\s*)allow\s+(.*)$", line.rstrip("\n"))
    if m and "127.0.0.1/32" not in m.group(2).split():
        line = f"{m.group(1)}allow {m.group(2)} 127.0.0.1/32\n"
    if depth == 0 and s.endswith("{") and s != "{":
        site, has_encode = True, False
    if site and depth == 1 and s.startswith("encode"):
        has_encode = True
    if site and depth == 1 and s.startswith("reverse_proxy") and not has_encode:
        out.append(re.match(r"\s*", line).group(0) + "encode zstd gzip\n")
        has_encode = True
    out.append(line)
    depth += s.count("{") - s.count("}")
    if depth == 0:
        site = False
open(dst, "w").write("".join(out))
PY
}

write_unit() {
  local bridge=$1 fwd="" p ssh_bin
  for p in $TUNNEL_PORTS; do fwd="$fwd -R 127.0.0.1:${p#*:}:127.0.0.1:${p%%:*}"; done
  ssh_bin=$(command -v "$SSH")
  cat > "$UNIT" <<EOF
[Unit]
Description=Обратный туннель к российскому серверу $bridge (вход VPN и сайта)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
ExecStart=$ssh_bin -N -T -i $KEY -p $SSH_PORT -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KEY.known_hosts$fwd $TUNNEL_USER@$bridge
Restart=always
RestartSec=15
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
}

main_side() {
  [ -f "$CONF" ] && [ -f "$STATE" ] || die "это не основной сервер: не найден VPN ($CONF)"
  local bridge host port got total
  bridge=$(sed -n 's/^BRIDGE_IP=//p' "$STATE")
  [ -n "$bridge" ] || die "VPN работает без российского сервера (в $STATE нет BRIDGE_IP): туннель не нужен"
  host=$(site_host); port=$(site_port)
  [ -n "$host" ] || die "в $ENV_FILE нет адреса сайта (BASE_URL=https://…)"
  command -v "$SSH" >/dev/null || { apt-get install -y -q openssh-client >/dev/null 2>&1 || die "нужен ssh"; }

  step "Проверяю, замирает ли связь через российский сервер $bridge"
  read -r got total <<<"$(fetch_css "$host" "$port" 127.0.0.1)"
  report_css "$got" "$total" "напрямую на этом сервере" || die "сайт не открывается даже на этом сервере — сначала почините его (fix.sh)"
  read -r got total <<<"$(fetch_css "$host" "$port" "$bridge")"
  report_css "$got" "$total" "через $bridge" || true

  step "Ключ для туннеля"
  mkdir -p "$(dirname "$KEY")"
  chmod 700 "$(dirname "$KEY")"
  if [ ! -f "$KEY" ]; then
    ssh-keygen -q -t ed25519 -N "" -C "vpn-tunnel@$(hostname)" -f "$KEY"
    echo "  создан $KEY"
  else
    echo "  уже есть $KEY"
  fi

  step "Caddy: принимаю подключения из туннеля"
  local tmp err
  tmp=$(mktemp "$CADDYFILE.XXXXXX")
  update_caddyfile "$CADDYFILE" "$tmp"
  if cmp -s "$tmp" "$CADDYFILE"; then
    rm -f "$tmp"
    echo "  уже настроено"
  else
    if ! err=$("$CADDY" validate --config "$tmp" --adapter caddyfile 2>&1); then
      rm -f "$tmp"
      die "Caddy не принял настройки, ничего не изменено:
$(printf '%s\n' "$err" | grep -iE 'error' | tail -3)"
    fi
    cp "$CADDYFILE" "$CADDYFILE.tunnel.bak"
    cat "$tmp" > "$CADDYFILE"
    rm -f "$tmp"
    systemctl reload caddy || systemctl restart caddy
    sleep 2
    read -r got total <<<"$(fetch_css "$host" "$port" 127.0.0.1)"
    if ! report_css "$got" "$total" "сайт после изменения"; then
      cat "$CADDYFILE.tunnel.bak" > "$CADDYFILE"
      systemctl reload caddy || systemctl restart caddy
      die "сайт перестал открываться, вернул прежние настройки Caddy"
    fi
  fi

  step "Служба туннеля (vpn-tunnel)"
  write_unit "$bridge"
  systemctl daemon-reload
  systemctl enable vpn-tunnel >/dev/null 2>&1
  systemctl restart vpn-tunnel
  echo "  запущена; подключится, как только российский сервер её пустит"

  cat <<EOF

========================================================================
Осталось одно действие на РОССИЙСКОМ сервере ($bridge).
Зайдите на него и выполните эту команду целиком (одной строкой):

$RUN ru '$(cat "$KEY.pub")'

========================================================================
EOF
}

# ---------- российский сервер ----------

detect_ip() {
  local ip
  if [ -n "${SERVER_IP:-}" ]; then echo "$SERVER_IP"; return; fi
  ip=$(printf '%s' "${SSH_CONNECTION:-}" | awk '{print $3}')
  if [ -n "$ip" ] && [[ ! "$ip" =~ ^(10|127|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\. ]]; then echo "$ip"; return; fi
  ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}

# HAProxy: каждый «server main IP:порт» → сначала туннель, прямой путь — запасной.
update_haproxy() {
  python3 - "$1" "$2" "$TUNNEL_PORTS" <<'PY'
import re, sys
src, dst, spec = sys.argv[1:]
ports = dict(p.split(":") for p in spec.split())
out, in_backend, tunneled = [], False, set()
lines = open(src).read().splitlines(keepends=True)
for line in lines:
    s = line.strip()
    if re.match(r"(global|defaults|frontend|backend|listen)\b", s):
        in_backend = s.startswith("backend")
    m = re.match(r"(\s*)server\s+(\S+)\s+(\S+):(\d+)(.*)$", line.rstrip("\n"))
    if in_backend and m:
        ind, name, ip, port, rest = m.groups()
        if name == "tun" or " backup" in rest:
            out.append(line)
            continue
        if port in ports:
            out.append(f"{ind}server tun 127.0.0.1:{ports[port]}{rest} check inter 10s fall 2 rise 1\n")
            out.append(f"{ind}server {name} {ip}:{port}{rest} backup\n")
            continue
    out.append(line)
open(dst, "w").write("".join(out))
PY
}

# Пользователь только для туннеля: без пароля и командной строки, ключ разрешает лишь
# открыть на этом сервере порты туннеля на 127.0.0.1
setup_user() {
  local pub=$1 home akf listen="" p
  id "$TUNNEL_USER" >/dev/null 2>&1 \
    || useradd --system --create-home --home-dir "/var/lib/$TUNNEL_USER" --shell /usr/sbin/nologin "$TUNNEL_USER"
  # «*» — пароля нет, но учётная запись не «заблокирована»: иначе sshd без PAM не пустит и по ключу
  usermod -p '*' "$TUNNEL_USER"
  home=$(getent passwd "$TUNNEL_USER" | cut -d: -f6)
  # где sshd ищет ключи этого пользователя (обычно ~/.ssh/authorized_keys)
  akf=$("$SSHD" -T -C "user=$TUNNEL_USER,host=localhost,addr=127.0.0.1" 2>/dev/null \
          | awk '$1=="authorizedkeysfile"{print $2; exit}')
  akf=${akf:-.ssh/authorized_keys}
  akf=${akf//%h/$home}; akf=${akf//%u/$TUNNEL_USER}; akf=${akf//%%/%}
  [[ "$akf" = /* ]] || akf="$home/$akf"
  for p in $TUNNEL_PORTS; do listen="$listen,permitlisten=\"127.0.0.1:${p#*:}\""; done
  mkdir -p "$(dirname "$akf")"
  # permitopen на закрытый порт: ключ не даёт ходить с этого сервера куда-либо ещё
  printf 'restrict,port-forwarding%s,permitopen="127.0.0.1:9",command="/bin/false" %s\n' "$listen" "$pub" > "$akf"
  if [[ "$akf" = "$home"/* ]]; then
    chown -R "$TUNNEL_USER:" "$(dirname "$akf")"
    chmod 700 "$(dirname "$akf")"
  fi
  chmod 600 "$akf"
  # через туннель идут все подключения телефонов: обычного лимита в 1024 открытых файла мало
  if [ -d /etc/security/limits.d ]; then
    printf '%s - nofile 65536\n' "$TUNNEL_USER" > /etc/security/limits.d/vpn-tunnel.conf
  fi
  echo "  пользователь $TUNNEL_USER, ключ в $akf"
}

# Проверка настроек SSH: туннель должен быть разрешён. Ничего опасного не меняем —
# только добавляем проверку «жив ли собеседник», чтобы оборванный туннель освобождал порты.
check_sshd() {
  local main_ip=$1 t fwd users
  t=$("$SSHD" -T -C "user=$TUNNEL_USER,host=$main_ip,addr=$main_ip" 2>&1) \
    || die "не удалось прочитать настройки SSH: $(printf '%s' "$t" | tail -1)"
  fwd=$(awk '$1=="allowtcpforwarding"{print $2}' <<<"$t")
  case "$fwd" in yes|all|remote) ;; *) die "в настройках SSH запрещены туннели (AllowTcpForwarding $fwd)" ;; esac
  [ "$(awk '$1=="disableforwarding"{print $2}' <<<"$t")" != yes ] || die "в настройках SSH запрещены туннели (DisableForwarding yes)"
  [ "$(awk '$1=="pubkeyauthentication"{print $2}' <<<"$t")" != no ] || die "в настройках SSH выключен вход по ключам (PubkeyAuthentication no)"
  users=$(awk '$1=="allowusers"{print $2}' <<<"$t")
  if [ -n "$users" ] && ! grep -qx "$TUNNEL_USER" <<<"$users"; then
    die "в настройках SSH вход разрешён только пользователям: $(echo $users). Добавьте $TUNNEL_USER в AllowUsers"
  fi
  local port
  port=$(awk '$1=="port"{print $2; exit}' <<<"$t")
  if [ -n "$port" ] && [ "$port" != "$SSH_PORT" ]; then
    echo "  SSH здесь на порту $port: на основном сервере запустите туннель с TUNNEL_SSH_PORT=$port"
  fi
  if [ -d "$(dirname "$SSHD_DROPIN")" ]; then
    # только для пользователя туннеля: ваши собственные SSH-сессии это не затрагивает
    printf '# vpn-tunnel: оборванный туннель закрывается за минуту и освобождает свои порты\nMatch User %s\n    ClientAliveInterval 20\n    ClientAliveCountMax 3\nMatch all\n' "$TUNNEL_USER" > "$SSHD_DROPIN"
    if "$SSHD" -t 2>/dev/null; then
      systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    else
      rm -f "$SSHD_DROPIN"
    fi
  fi
}

ru_side() {
  local pub=$1 main_ip my_ip host site_bind site_port site_addr got total tmp err first_port
  [ -f "$HAPROXY_CFG" ] && grep -q '^backend site' "$HAPROXY_CFG" \
    || die "это не российский сервер: не найден HAProxy с пересылкой ($HAPROXY_CFG). Сначала bridge.sh"
  local re='^ssh-ed25519 [A-Za-z0-9+/=]+( [A-Za-z0-9@._-]*)?$'
  [[ "$pub" =~ $re ]] \
    || die "ключ не похож на ключ туннеля (ssh-ed25519 …). Скопируйте команду с основного сервера целиком"
  main_ip=$(awk '/^backend site/{f=1} f && $1=="server" && $0 !~ / backup/ && $2!="tun"{split($3,a,":"); print a[1]; exit}' "$HAPROXY_CFG")
  [ -n "$main_ip" ] || main_ip=$(awk '/^backend site/{f=1} f && $1=="server" && / backup/{split($3,a,":"); print a[1]; exit}' "$HAPROXY_CFG")
  site_bind=$(awk '/^frontend site/{f=1} f && $1=="bind"{print $2; exit}' "$HAPROXY_CFG")
  site_port=${site_bind##*:}; site_port=${site_port:-8443}
  site_addr=${site_bind%:*}
  [ -n "$site_addr" ] && [ "$site_addr" != "*" ] && [ "$site_addr" != "$site_bind" ] || site_addr=127.0.0.1
  my_ip=$(detect_ip)
  host="${my_ip//./-}.sslip.io"
  echo "Этот сервер: $my_ip, основной: $main_ip"

  step "Проверяю связь с основным сервером сейчас"
  read -r got total <<<"$(fetch_css "$host" "$site_port" "$site_addr")"
  report_css "$got" "$total" "сайт через этот сервер" || true

  step "Пользователь для туннеля"
  check_sshd "$main_ip"
  setup_user "$pub"
  if command -v fail2ban-client >/dev/null; then
    # основной сервер подключается каждые 15 секунд, пока его не пустили: не банить его
    fail2ban-client set sshd unbanip "$main_ip" >/dev/null 2>&1 || true
    fail2ban-client set sshd addignoreip "$main_ip" >/dev/null 2>&1 || true
    mkdir -p /etc/fail2ban/jail.d
    printf '[sshd]\nignoreip = 127.0.0.1/8 ::1 %s\n' "$main_ip" > /etc/fail2ban/jail.d/vpn-tunnel.local
  fi

  step "HAProxy: пересылка через туннель (прямой путь — запасной)"
  tmp=$(mktemp "$HAPROXY_CFG.XXXXXX")
  update_haproxy "$HAPROXY_CFG" "$tmp"
  if cmp -s "$tmp" "$HAPROXY_CFG"; then
    rm -f "$tmp"
    echo "  уже настроено"
  else
    if ! err=$(haproxy -c -f "$tmp" 2>&1); then
      rm -f "$tmp"
      die "HAProxy не принял настройки, ничего не изменено:
$(printf '%s\n' "$err" | grep -iE 'alert|error' | head -3)"
    fi
    cp "$HAPROXY_CFG" "$HAPROXY_CFG.tunnel.bak"
    cat "$tmp" > "$HAPROXY_CFG"
    rm -f "$tmp"
    systemctl reload haproxy || systemctl restart haproxy
    echo "  готово (прежние настройки: $HAPROXY_CFG.tunnel.bak)"
  fi

  step "Жду, когда основной сервер подключит туннель (до 2 минут)"
  # ssh открывает все порты туннеля разом (ExitOnForwardFailure), так что хватает первого
  first_port=${TUNNEL_PORTS%% *}
  first_port=${first_port#*:}
  local i up=0
  for i in $(seq 24); do
    if tcp_open 127.0.0.1 "$first_port"; then up=1; break; fi
    sleep 5
  done
  if [ "$up" != 1 ]; then
    cat <<EOF

========================================================================
Туннель пока не подключился. Пока его нет, всё работает как раньше (напрямую).
На ОСНОВНОМ сервере посмотрите, что пишет служба туннеля:
  journalctl -u vpn-tunnel -n 20 --no-pager
и пришлите вывод.
========================================================================
EOF
    exit 1
  fi
  echo "  туннель подключён"
  # HAProxy проверяет туннель раз в 10 секунд — даём ему заметить
  sleep 12

  step "Проверяю связь через туннель"
  local ok=0
  read -r got total <<<"$(fetch_css "$host" "$site_port" "$site_addr")"
  report_css "$got" "$total" "сайт через этот сервер" && ok=1

  echo
  echo "========================================================================"
  if [ "$ok" = 1 ]; then
    echo "Готово: сайт и VPN идут через туннель, связь больше не замирает."
    echo "Откройте сайт на телефоне и подключите VPN заново."
  else
    echo "Туннель подключён, но связь всё равно замирает. Значит, режется и такой путь —"
    echo "нужен российский сервер у другого хостинга. Пришлите этот вывод."
  fi
  echo "========================================================================"
}

main() {
  [ "$(id -u)" = 0 ] || die "запустите от root"
  if [ "${1:-}" = ru ]; then
    shift
    ru_side "$*"
  else
    main_side
  fi
}

# INSTALL_LIB=1 — только загрузить функции (для проверки)
if [ "${INSTALL_LIB:-}" != 1 ]; then
  main "$@"
fi
