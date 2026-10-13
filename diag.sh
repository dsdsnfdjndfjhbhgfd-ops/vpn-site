#!/bin/bash
# Диагностика VPN на российском сервере (входе): что происходит с пакетами от телефона.
#
# Запуск на российском сервере от root:
#   bash <(curl -fsSL https://raw.githubusercontent.com/dsdsnfdjndfjhbhgfd-ops/vpn-site/main/diag.sh)
# Скрипт 30 секунд записывает пакеты на портах VPN. В это время включите VPN на телефоне
# и открывайте сайты. Потом он покажет по каждому подключению, сколько данных прошло в каждую
# сторону, были ли повторные отправки и кто оборвал соединение, и скажет, что это значит.
set -euo pipefail

SECONDS_TO_CAPTURE=${SECONDS_TO_CAPTURE:-30}
PORTS=${DIAG_PORTS:-"443 2053 47443"}
HAPROXY_CFG=${HAPROXY_CFG:-/etc/haproxy/haproxy.cfg}
PCAP=${PCAP:-/tmp/vpn-diag.pcap}

die() { printf '\n\033[1;31mОшибка: %s\033[0m\n' "$*" >&2; exit 1; }

# Разбор записи: по каждому подключению — данные в обе стороны, повторы, обрывы, имя сайта (SNI)
analyze() {
  python3 - "$1" "${2:-}" <<'PY'
import struct, sys, collections

path, ports_arg = sys.argv[1], sys.argv[2]
server_ports = {int(p) for p in ports_arg.split()} if ports_arg else {443, 2053, 47443}

def packets(path):
    f = open(path, "rb")
    gh = f.read(24)
    if len(gh) < 24:
        return
    magic = struct.unpack("<I", gh[:4])[0]
    endian = "<" if magic in (0xa1b2c3d4, 0xa1b23c4d) else ">"
    nano = magic in (0xa1b23c4d, 0x4d3cb2a1)
    linktype = struct.unpack(endian + "I", gh[20:24])[0]
    while True:
        h = f.read(16)
        if len(h) < 16:
            return
        ts, tsf, incl, _ = struct.unpack(endian + "IIII", h)
        data = f.read(incl)
        t = ts + tsf / (1e9 if nano else 1e6)
        if linktype == 1:            # Ethernet
            if len(data) < 14: continue
            eth = struct.unpack("!H", data[12:14])[0]; off = 14
            if eth == 0x8100: eth = struct.unpack("!H", data[16:18])[0]; off = 18
        elif linktype == 113:        # Linux cooked (SLL)
            eth = struct.unpack("!H", data[14:16])[0]; off = 16
        elif linktype == 276:        # Linux cooked v2 (SLL2)
            eth = struct.unpack("!H", data[0:2])[0]; off = 20
        elif linktype in (0, 108):   # loopback (BSD)
            off = 4; eth = 0x0800
        else:
            continue
        if eth != 0x0800: continue
        ip = data[off:]
        if len(ip) < 20 or ip[9] != 6: continue
        ihl = (ip[0] & 15) * 4
        total = struct.unpack("!H", ip[2:4])[0]
        src = ".".join(map(str, ip[12:16])); dst = ".".join(map(str, ip[16:20]))
        tcp = ip[ihl:total] if total else ip[ihl:]
        if len(tcp) < 20: continue
        sport, dport, seq, ack = struct.unpack("!HHII", tcp[:12])
        doff = (tcp[12] >> 4) * 4
        flags = tcp[13]
        payload = tcp[doff:]
        # настоящая длина данных — из IP-заголовка: tcpdump пишет только начало пакета
        plen = (total - ihl - doff) if total else len(payload)
        yield t, src, sport, dst, dport, seq, flags, payload, plen

def sni_of(hello):
    try:
        if hello[0] != 0x16 or hello[5] != 1: return ""
        p = 5 + 4 + 2 + 32
        p += 1 + hello[p]
        p += 2 + struct.unpack("!H", hello[p:p+2])[0]
        p += 1 + hello[p]
        end = p + 2 + struct.unpack("!H", hello[p:p+2])[0]; p += 2
        while p + 4 <= end:
            et, el = struct.unpack("!HH", hello[p:p+4]); p += 4
            if et == 0:
                n = struct.unpack("!H", hello[p+3:p+5])[0]
                return hello[p+5:p+5+n].decode(errors="replace")
            p += el
    except Exception:
        pass
    return ""

flows = collections.OrderedDict()
for t, src, sport, dst, dport, seq, flags, payload, plen in packets(path):
    if dport in server_ports:
        key, up = (src, sport, dport), True
    elif sport in server_ports:
        key, up = (dst, dport, sport), False
    else:
        continue
    fl = flows.get(key)
    if fl is None:
        fl = flows[key] = dict(start=t, last=t, syn=False, up=0, down=0, up_pk=0, down_pk=0,
                               up_re=0, down_re=0, rst="", fin="", sni="", hello=False,
                               seen_up=set(), seen_down=set(), down_last_data=0, hbuf=b"")
    fl["last"] = t
    if flags & 0x02 and not flags & 0x10 and up: fl["syn"] = True
    if flags & 0x04: fl["rst"] = fl["rst"] or ("телефон" if up else "сервер")
    if flags & 0x01: fl["fin"] = fl["fin"] or ("телефон" if up else "сервер")
    if plen > 0:
        seen = fl["seen_up" if up else "seen_down"]
        k = (seq, plen)
        if k in seen:
            fl["up_re" if up else "down_re"] += 1
        else:
            seen.add(k)
            if up:
                fl["up"] += plen; fl["up_pk"] += 1
                # приветствие TLS бывает больше одного пакета: склеиваем начало и ищем имя сайта
                if not fl["sni"] and len(fl["hbuf"]) < 8192:
                    fl["hbuf"] += payload
                    if fl["hbuf"][:1] == b"\x16":
                        fl["hello"] = True; fl["sni"] = sni_of(fl["hbuf"])
            else:
                fl["down"] += plen; fl["down_pk"] += 1; fl["down_last_data"] = t

def verdict(fl):
    if fl["up"] == 0:
        return "НЕТ ДАННЫХ: соединение открыто, но телефон не прислал ни байта (первый пакет потерян по дороге)"
    if fl["down"] == 0:
        return "НЕТ ОТВЕТА: телефон прислал данные, сервер ничего не вернул"
    if fl["down_re"] >= 3 and fl["down"] < 64000:
        return "ЗАМОРОЗКА: сервер отправляет, а до телефона не доходит (повторы отправки)"
    if fl["up_re"] >= 3 and fl["up"] < 64000:
        return "ЗАМОРОЗКА: телефон отправляет, а до сервера не доходит (повторы отправки)"
    if fl["down"] >= 64000:
        return "РАБОТАЕТ: идут данные"
    return "короткое соединение"

if not flows:
    print("ИТОГ: за время записи ни одного подключения к портам VPN.")
    print("Значит, пакеты телефона до этого сервера не доходят вообще: адрес сервера")
    print("заблокирован или не входит в белый список оператора — либо в ключе другой адрес.")
    sys.exit(0)

by_ip = collections.Counter(k[0] for k in flows)
print("Подключения по адресам (телефон — тот, у кого их больше всего):")
for ipaddr, n in by_ip.most_common(8):
    print(f"  {ipaddr}: {n}")
phone = by_ip.most_common(1)[0][0]
mine = [(k, v) for k, v in flows.items() if k[0] == phone]
t0 = mine[0][1]["start"]
print(f"\nПодробно по адресу {phone} (первые 25):")
print("  время  порт  от телефона  к телефону  повторы(тел/серв)  обрыв     сайт в ключе   итог")
for (ipaddr, cport, sport), v in mine[:25]:
    rst = ("RST " + v["rst"]) if v["rst"] else (("FIN " + v["fin"]) if v["fin"] else "-")
    print(f"  {v['start']-t0:5.1f}  {sport:<5} {v['up']:>9} Б  {v['down']:>9} Б  {v['up_re']:>4}/{v['down_re']:<4}       "
          f"{rst:<12} {v['sni'] or '-':<14} {verdict(v)}")

kinds = collections.Counter(verdict(v).split(":")[0] for _, v in mine)
print("\nСводка:", ", ".join(f"{k} — {n}" for k, n in kinds.most_common()))
total = len(mine)
works, nodata = kinds.get("РАБОТАЕТ", 0), kinds.get("НЕТ ДАННЫХ", 0)
frozen = kinds.get("ЗАМОРОЗКА", 0)
noreply = kinds.get("НЕТ ОТВЕТА", 0)
if frozen >= 1:
    print("ИТОГ: соединения замирают после первых килобайт — это «заморозка» оператора:")
    print("данные отправляются, но до получателя не доходят.")
elif nodata >= max(2, total / 3):
    if works:
        print("ИТОГ: первые соединения проходят, а дальше телефон открывает соединения, но их первый")
        print("пакет (приветствие TLS) до сервера не доходит. Оператор распознаёт VPN и режет новые")
        print("соединения по содержимому первого пакета.")
    else:
        print("ИТОГ: телефон открывает соединения, но их первый пакет (приветствие TLS) до сервера")
        print("не доходит. Оператор отбрасывает его по содержимому.")
elif noreply >= max(2, total / 3):
    print("ИТОГ: данные от телефона доходят, но основной сервер не отвечает — проблема на основном")
    print("сервере или между серверами.")
elif works:
    print("ИТОГ: данные через этот сервер идут. Если на телефоне не работает, причина дальше —")
    print("на основном сервере или в настройках приложения.")
else:
    print("ИТОГ: только короткие соединения, картина неясна; пришлите этот вывод целиком.")
PY
}

main() {
  [ "$(id -u)" = 0 ] || die "запустите от root"
  if ! command -v tcpdump >/dev/null; then
    echo "Ставлю tcpdump…"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q tcpdump >/dev/null 2>&1 || die "не удалось поставить tcpdump"
  fi
  # Основной сервер исключаем: нужны только подключения телефонов
  local main_ip filter p
  main_ip=$(awk '/^backend vpn/{f=1} f && $1=="server"{split($3,a,":"); print a[1]; exit}' "$HAPROXY_CFG" 2>/dev/null || true)
  filter="tcp and ("
  for p in $PORTS; do filter="$filter port $p or"; done
  filter="${filter% or})"
  [ -z "$main_ip" ] || filter="$filter and not host $main_ip"

  echo
  echo "Сейчас включите VPN на телефоне и $SECONDS_TO_CAPTURE секунд открывайте сайты (YouTube, любые)."
  echo "Записываю пакеты…"
  rm -f "$PCAP"
  timeout "$SECONDS_TO_CAPTURE" tcpdump -nn -i any -s 2000 -w "$PCAP" "$filter" 2>/dev/null || true
  [ -s "$PCAP" ] || die "запись пустая: tcpdump не смог записать пакеты"
  echo "Готово, разбираю…"
  echo
  analyze "$PCAP" "$PORTS"
  echo
  echo "Сырая запись: $PCAP"
}

# INSTALL_LIB=1 — только загрузить функции (для проверки)
if [ "${INSTALL_LIB:-}" != 1 ]; then
  main "$@"
fi
