#!/usr/bin/env python3
"""Сайт для продажи доступа к VPN (Xray, VLESS + Reality).

Человек регистрируется, оплачивает подписку и создаёт себе ключи.
Работает на том же сервере, что и VPN (install-vpn.sh), и правит тот же
config.json Xray, что и Telegram-бот. Ключи с сайта хранятся в Xray с email
"w<id пользователя>_<имя>", поэтому не пересекаются с ключами бота.
Когда подписка заканчивается, ключи пользователя удаляются автоматически.
Настройки берутся из переменных окружения (/etc/vpn-site.env).
"""
import base64
import fcntl
import grp
import hashlib
import io
import ipaddress
import json
import logging
import os
import pwd
import re
import secrets
import shutil
import sqlite3
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid as uuidlib
from contextlib import contextmanager
from datetime import datetime, timezone
from functools import wraps
from urllib.parse import quote, urlsplit

import qrcode
import qrcode.image.svg
from flask import (Flask, abort, flash, g, redirect, render_template, request,
                   session, url_for)
from werkzeug.middleware.proxy_fix import ProxyFix
from werkzeug.security import check_password_hash, generate_password_hash

CONF = os.getenv("XRAY_CONF", "/usr/local/etc/xray/config.json")
STATE = os.getenv("XRAY_STATE", "/usr/local/etc/xray/vpn-state")
XRAY_BIN = os.getenv("XRAY_BIN", "/usr/local/bin/xray")
RESTART_CMD = os.getenv("XRAY_RESTART_CMD", "systemctl restart xray").split()
DATA_DIR = os.getenv("DATA_DIR", "/var/lib/vpn-site")
DB = os.path.join(DATA_DIR, "site.db")
SITE_NAME = os.getenv("SITE_NAME", "Tunnel")
# Значок перед названием в приложениях (Hiddify, v2RayTun): «⚡ Tunnel · iphone»
KEY_EMOJI = os.getenv("KEY_EMOJI", "⚡")
BASE_URL = os.getenv("BASE_URL", "http://localhost:8000").rstrip("/")
MAX_KEYS = int(os.getenv("MAX_KEYS", "1"))
# Один ключ — одно устройство. Раз в SHARE_CHECK_SEC сайт спрашивает у Xray, с каких IP
# сейчас работает каждый ключ. Если ключ дольше SHARE_MINUTES минут подряд работает
# из двух разных сетей, это нарушение: в первый раз ключ отключается на BAN_MINUTES минут,
# во второй удаляется, и создать новый человек уже не может (вернуть доступ можно в /admin).
DEVICE_LIMIT = os.getenv("DEVICE_LIMIT", "1") == "1"
SHARE_MINUTES = int(os.getenv("SHARE_MINUTES", "6"))
BAN_MINUTES = int(os.getenv("BAN_MINUTES", "15"))
SHARE_CHECK_SEC = int(os.getenv("SHARE_CHECK_SEC", "30"))
# Адрес API Xray; сайт сам включает его в конфиге, если API ещё нет
XRAY_API = os.getenv("XRAY_API", "127.0.0.1:10085")
# Вход Trojan внутри сайта (его добавляет trojan.sh): пускает по тем же ключам, что и VLESS
TROJAN_TAG = "trojan-ws"
# test — кнопка «оплатить» сразу продлевает подписку (для проверки);
# yookassa — настоящая оплата через ЮKassa
PAYMENT = os.getenv("PAYMENT_PROVIDER", "test").strip().lower()
# Предзапуск: регистрация работает, а оплату и ключи можно временно выключить
PAYMENTS_ENABLED = os.getenv("PAYMENTS_ENABLED", "1") == "1"
KEYS_ENABLED = os.getenv("KEYS_ENABLED", "1") == "1"
YK_SHOP = os.getenv("YOOKASSA_SHOP_ID", "")
YK_SECRET = os.getenv("YOOKASSA_SECRET_KEY", "")
ADMIN_EMAILS = {e.strip().lower() for e in os.getenv("ADMIN_EMAILS", "").split(",") if e.strip()}
NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,20}$")
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def parse_plans(spec: str) -> dict:
    """"1m:30:199:1 месяц,..." → {код: {days, price, title}}"""
    plans = {}
    for item in spec.split(","):
        code, days, price, title = (p.strip() for p in item.split(":", 3))
        plans[code] = {"code": code, "days": int(days), "price": int(price), "title": title}
    return plans


PLANS = parse_plans(os.getenv(
    "PLANS", "1m:30:199:1 месяц,3m:90:499:3 месяца,12m:365:1690:12 месяцев"))

app = Flask(__name__)
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_port=1)
app.config.update(
    SECRET_KEY=os.environ["SECRET_KEY"],
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
    SESSION_COOKIE_SECURE=BASE_URL.startswith("https://"),
    PERMANENT_SESSION_LIFETIME=30 * 86400,
)
log = logging.getLogger("vpn-site")


# ---------- база ----------

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY,
  email TEXT UNIQUE NOT NULL,
  pw_hash TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  paid_until INTEGER NOT NULL DEFAULT 0,
  blocked INTEGER NOT NULL DEFAULT 0,
  strikes INTEGER NOT NULL DEFAULT 0,  -- сколько раз ключом пользовались на двух устройствах
  revoked INTEGER NOT NULL DEFAULT 0   -- 1: ключ удалён за нарушение, новый создать нельзя
);
CREATE TABLE IF NOT EXISTS payments (
  id TEXT PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id),
  plan TEXT NOT NULL,
  amount INTEGER NOT NULL,
  days INTEGER NOT NULL,
  status TEXT NOT NULL,
  provider TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  applied INTEGER NOT NULL DEFAULT 0
);
-- Ключи, временно отключённые за работу на двух устройствах
CREATE TABLE IF NOT EXISTS key_bans (
  email TEXT PRIMARY KEY,           -- имя ключа в Xray, например w12_iphone
  user_id INTEGER NOT NULL REFERENCES users(id),
  client TEXT NOT NULL,             -- запись ключа из конфига Xray: вернём её как была
  until INTEGER NOT NULL
);
"""


def connect() -> sqlite3.Connection:
    os.makedirs(DATA_DIR, exist_ok=True)
    con = sqlite3.connect(DB, timeout=10)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA journal_mode=WAL")
    return con


def db() -> sqlite3.Connection:
    if "db" not in g:
        g.db = connect()
    return g.db


@app.teardown_appcontext
def close_db(_exc):
    con = g.pop("db", None)
    if con is not None:
        con.close()


with connect() as _con:
    _con.executescript(SCHEMA)
    # Базы, созданные до появления этих колонок
    _cols = {r["name"] for r in _con.execute("PRAGMA table_info(users)")}
    for _col in ("strikes", "revoked"):
        if _col not in _cols:
            _con.execute(f"ALTER TABLE users ADD COLUMN {_col} INTEGER NOT NULL DEFAULT 0")
    # Секрет ссылки-подписки (/sub/<sub_token>); создаётся при первом заходе в кабинет
    if "sub_token" not in _cols:
        _con.execute("ALTER TABLE users ADD COLUMN sub_token TEXT")
    _con.execute("CREATE UNIQUE INDEX IF NOT EXISTS users_sub_token ON users(sub_token)")


def now() -> int:
    return int(time.time())


def is_active(user) -> bool:
    return bool(user) and not user["blocked"] and user["paid_until"] > now()


def apply_payment(con: sqlite3.Connection, pid: str) -> bool:
    """Продлевает подписку по оплаченному платежу ровно один раз."""
    with con:
        cur = con.execute("UPDATE payments SET status='succeeded', applied=1 "
                          "WHERE id=? AND applied=0", (pid,))
        if cur.rowcount == 0:
            return False
        p = con.execute("SELECT user_id, days FROM payments WHERE id=?", (pid,)).fetchone()
        con.execute("UPDATE users SET paid_until = MAX(paid_until, ?) + ? WHERE id=?",
                    (now(), p["days"] * 86400, p["user_id"]))
    log.info("payment %s applied", pid)
    return True


# ---------- конфиг Xray (так же, как в боте) ----------

@contextmanager
def conf_lock():
    """Сайт может работать в нескольких процессах: правим конфиг по очереди."""
    with open(CONF + ".lock", "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def read_state() -> dict:
    state = {}
    with open(STATE) as f:
        for line in f:
            if "=" in line:
                k, v = line.strip().split("=", 1)
                state[k] = v
    return state


def load_conf() -> dict:
    with open(CONF) as f:
        return json.load(f)


def clients(conf: dict) -> list:
    return conf["inbounds"][0]["settings"]["clients"]


def trojan_inbound(conf: dict) -> dict | None:
    return next((ib for ib in conf.get("inbounds", []) if ib.get("tag") == TROJAN_TAG), None)


def trojan_client(client: dict) -> dict:
    """Ключ Trojan: пароль — id ключа, имя то же, поэтому учёт устройств общий."""
    return {"password": client["id"], "email": client["email"]}


def save_conf(conf: dict) -> None:
    """Проверяет конфиг через xray -test и записывает его. Xray не перезапускает."""
    # Trojan всегда пускает ровно те ключи, что есть в VLESS: удаление и выдача — в одном месте
    if (tj := trojan_inbound(conf)) is not None:
        tj.setdefault("settings", {})["clients"] = [trojan_client(c) for c in clients(conf)]
    # Расширение .json обязательно: по нему Xray понимает формат файла
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(CONF), suffix=".json")
    with os.fdopen(fd, "w") as f:
        json.dump(conf, f, indent=2, ensure_ascii=False)
    try:
        subprocess.run([XRAY_BIN, "run", "-test", "-c", tmp], check=True, capture_output=True)
    except subprocess.CalledProcessError:
        os.unlink(tmp)
        raise
    os.chmod(tmp, 0o600)
    try:
        os.chown(tmp, pwd.getpwnam("nobody").pw_uid, grp.getgrnam("nogroup").gr_gid)
    except (KeyError, PermissionError):
        pass
    if os.path.exists(CONF):
        shutil.copy2(CONF, CONF + ".bak")
    os.replace(tmp, CONF)


def save_conf_and_restart(conf: dict) -> None:
    """Перезапуск рвёт на секунду связь у всех, зато сразу отключает удалённые ключи."""
    save_conf(conf)
    subprocess.run(RESTART_CMD, check=True)


def api_addr(conf: dict) -> str | None:
    """Адрес API Xray из конфига: поле api.listen или отдельный вход с тегом API."""
    api = conf.get("api") or {}
    if api.get("listen"):
        return api["listen"]
    for ib in conf.get("inbounds", []):
        if api.get("tag") and ib.get("tag") == api["tag"]:
            return f"{ib.get('listen') or '127.0.0.1'}:{ib['port']}"
    return None


def xray_api(conf: dict, cmd: str, *args: str) -> str:
    addr = api_addr(conf)
    if not addr:
        raise RuntimeError("в конфиге Xray нет API")
    r = subprocess.run([XRAY_BIN, "api", cmd, f"--server={addr}", *args],
                       capture_output=True, text=True, timeout=15)
    if r.returncode:
        raise RuntimeError((r.stderr or r.stdout).strip())
    return r.stdout


def add_client(client: dict, limit: int | None = None) -> str:
    """Добавляет ключ в конфиг и в работающий Xray через API, без перезапуска.
    Если API недоступно, перезапускает Xray, как раньше.
    С limit проверяет, что у человека ещё нет столько ключей. Возвращает ok, exists или limit."""
    with conf_lock():
        conf = load_conf()
        if any(c["email"] == client["email"] for c in clients(conf)):
            return "exists"
        owner = re.match(r"^w\d+_", client["email"]).group(0)
        if limit is not None and sum(c["email"].startswith(owner) for c in clients(conf)) >= limit:
            return "limit"
        clients(conf).append(client)
        save_conf(conf)
        ib = conf["inbounds"][0]
        add = [{"tag": ib["tag"], "protocol": ib["protocol"], "port": ib["port"],
                "settings": {"clients": [client], "decryption": "none"}}]
        if (tj := trojan_inbound(conf)) is not None:
            add.append({"tag": tj["tag"], "protocol": tj["protocol"], "port": tj["port"],
                        "settings": {"clients": [trojan_client(client)]}})
        try:
            with tempfile.NamedTemporaryFile("w", suffix=".json") as f:
                json.dump({"inbounds": add}, f)
                f.flush()
                out = xray_api(conf, "adu", f.name)
            if f"Added {len(add)} user" not in out:
                raise RuntimeError(out.strip())
        except (RuntimeError, KeyError, subprocess.TimeoutExpired) as e:
            log.warning("xray api adu failed (%s), restarting xray", e)
            subprocess.run(RESTART_CMD, check=True)
    return "ok"


def prefix(uid: int) -> str:
    return f"w{uid}_"


def user_keys(uid: int) -> list:
    p = prefix(uid)
    return [{"id": c["id"], "email": c["email"], "name": c["email"][len(p):]}
            for c in clients(load_conf()) if c["email"].startswith(p)]


def make_link(cid: str, label: str) -> str:
    s = read_state()
    return (f"vless://{cid}@{s['IP']}:{s['PORT']}?encryption=none&flow=xtls-rprx-vision"
            f"&security=reality&sni={s['SNI']}&fp=chrome&pbk={s['PBK']}&sid={s['SID']}"
            f"&type=tcp#{quote(label)}")


def make_trojan_link(cid: str, label: str) -> str | None:
    """Запасной ключ: Trojan внутри сайта. Снаружи это обычный HTTPS к сайту — тот же адрес,
    порт и настоящий сертификат; VPN отвечает только по секретному пути."""
    s = read_state()
    site = urlsplit(BASE_URL)
    if not s.get("TROJAN_PATH") or site.scheme != "https" or not site.hostname:
        return None
    host = site.hostname
    return (f"trojan://{cid}@{s['IP']}:{site.port or 443}?security=tls&sni={host}&fp=chrome"
            f"&alpn=http%2F1.1&type=ws&host={host}&path={quote(s['TROJAN_PATH'], safe='')}"
            f"#{quote(label)}")


def profile_title() -> str:
    return f"{KEY_EMOJI} {SITE_NAME}".strip()


def key_label(name: str) -> str:
    """Как ключ называется в приложении: «⚡ Tunnel · iphone»."""
    return f"{profile_title()} · {name}"


def key_link(k: dict) -> tuple[str, bool]:
    """Ссылка ключа. Если включён Trojan (trojan.sh), выдаём только его: он идёт внутри
    сайта и проходит там, где VLESS режут. Без Trojan — VLESS, как раньше."""
    trojan = make_trojan_link(k["id"], key_label(k["name"]))
    return (trojan or make_link(k["id"], key_label(k["name"]))), bool(trojan)


def sub_token(con: sqlite3.Connection, user) -> str:
    if user["sub_token"]:
        return user["sub_token"]
    with con:
        con.execute("UPDATE users SET sub_token=? WHERE id=? AND sub_token IS NULL",
                    (secrets.token_urlsafe(18), user["id"]))
    return con.execute("SELECT sub_token FROM users WHERE id=?", (user["id"],)).fetchone()[0]


def qr_svg(text: str) -> str:
    img = qrcode.make(text, image_factory=qrcode.image.svg.SvgPathImage, box_size=8, border=2)
    buf = io.BytesIO()
    img.save(buf)
    return "data:image/svg+xml;base64," + base64.b64encode(buf.getvalue()).decode()


def remove_user_keys(uids: set) -> int:
    """Удаляет из Xray все ключи этих пользователей; возвращает число удалённых."""
    if not uids:
        return 0
    prefixes = tuple(prefix(u) for u in uids)
    with conf_lock():
        conf = load_conf()
        before = len(clients(conf))
        conf["inbounds"][0]["settings"]["clients"] = [
            c for c in clients(conf) if not c["email"].startswith(prefixes)]
        removed = before - len(clients(conf))
        if removed:
            save_conf_and_restart(conf)
    return removed


def sweep_expired() -> None:
    """Убирает ключи у тех, чья подписка кончилась или кто заблокирован."""
    con = connect()
    rows = con.execute("SELECT id FROM users WHERE paid_until <= ? OR blocked=1",
                       (now(),)).fetchall()
    con.close()
    expired = {r["id"] for r in rows}
    have = {int(m.group(1)) for c in clients(load_conf())
            if (m := re.match(r"^w(\d+)_", c["email"]))}
    n = remove_user_keys(expired & have)
    if n:
        log.info("removed %d keys of expired users", n)


# ---------- один ключ — одно устройство ----------

def ensure_xray_api() -> bool:
    """Включает в Xray API и учёт адресов, с которых работают ключи (нужен свежий Xray, проверено на 26.3).
    Конфиг правится и Xray перезапускается только один раз, при первом запуске."""
    with conf_lock():
        conf = load_conf()
        changed = False
        ib = conf["inbounds"][0]
        if not ib.get("tag"):
            ib["tag"] = "vless-in"
            changed = True
        api = conf.setdefault("api", {})
        if not api:
            api.update(tag="api", listen=XRAY_API)
            changed = True
        services = api.setdefault("services", [])
        for name in ("HandlerService", "StatsService"):
            if name not in services:
                services.append(name)
                changed = True
        if not api_addr(conf):
            api["listen"] = XRAY_API
            changed = True
        if "stats" not in conf:
            conf["stats"] = {}
            changed = True
        level = conf.setdefault("policy", {}).setdefault("levels", {}).setdefault("0", {})
        if not level.get("statsUserOnline"):
            level["statsUserOnline"] = True
            changed = True
        if changed:
            log.info("enabling xray api and online stats")
            save_conf_and_restart(conf)
            time.sleep(2)
    try:
        online_ips("w0_check")
        return True
    except RuntimeError as e:
        log.error("xray api is not working, device limit is off: %s", e)
        return False


def online_ips(email: str) -> dict:
    """IP, с которых ключ сейчас подключён: {ip: когда появился}."""
    try:
        out = xray_api(load_conf(), "statsonlineiplist", "-email", email)
    except RuntimeError as e:
        if "not found" in str(e):
            return {}
        raise
    return json.loads(out).get("ips") or {}


def network_of(ip: str) -> str:
    """Адреса из одной подсети /24 (IPv6: /64) считаем одним устройством: так мобильный
    интернет, который иногда меняет адрес внутри своей сети, не даёт ложных срабатываний."""
    addr = ipaddress.ip_address(ip)
    return str(ipaddress.ip_network(f"{ip}/{24 if addr.version == 4 else 64}", strict=False))


_shared_since: dict = {}


def check_sharing() -> None:
    t = now()
    for c in clients(load_conf()):
        email = c["email"]
        if not re.match(r"^w\d+_", email):
            continue  # ключи бота не трогаем
        nets = {network_of(ip) for ip in online_ips(email)}
        if len(nets) < 2:
            _shared_since.pop(email, None)
            continue
        since = _shared_since.setdefault(email, t)
        if t - since >= SHARE_MINUTES * 60:
            _shared_since.pop(email, None)
            punish(email, nets)


def punish(email: str, nets: set) -> None:
    uid = int(re.match(r"^w(\d+)_", email).group(1))
    con = connect()
    try:
        user = con.execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone()
        if user is None:
            return
        if user["strikes"] == 0:
            with conf_lock():
                conf = load_conf()
                client = next((c for c in clients(conf) if c["email"] == email), None)
                if client is None:
                    return
                conf["inbounds"][0]["settings"]["clients"] = [
                    c for c in clients(conf) if c["email"] != email]
                save_conf_and_restart(conf)
            with con:
                con.execute("INSERT OR REPLACE INTO key_bans (email, user_id, client, until) "
                            "VALUES (?, ?, ?, ?)",
                            (email, uid, json.dumps(client), now() + BAN_MINUTES * 60))
                con.execute("UPDATE users SET strikes=1 WHERE id=?", (uid,))
            log.warning("key %s used from %s: disabled for %d min", email, sorted(nets), BAN_MINUTES)
        else:
            remove_user_keys({uid})
            with con:
                con.execute("UPDATE users SET strikes=strikes+1, revoked=1 WHERE id=?", (uid,))
                con.execute("DELETE FROM key_bans WHERE user_id=?", (uid,))
            log.warning("key %s used from %s again: keys removed, access revoked",
                        email, sorted(nets))
    finally:
        con.close()


def lift_bans(uid: int | None = None) -> None:
    """Возвращает ключи, у которых кончился срок отключения (или все ключи человека)."""
    con = connect()
    try:
        if uid is None:
            rows = con.execute("SELECT * FROM key_bans WHERE until <= ?", (now(),)).fetchall()
        else:
            rows = con.execute("SELECT * FROM key_bans WHERE user_id=?", (uid,)).fetchall()
        for r in rows:
            user = con.execute("SELECT * FROM users WHERE id=?", (r["user_id"],)).fetchone()
            if user and is_active(user) and not user["blocked"] and not user["revoked"]:
                add_client(json.loads(r["client"]))
                log.info("key %s is back", r["email"])
            with con:
                con.execute("DELETE FROM key_bans WHERE email=?", (r["email"],))
    finally:
        con.close()


def background() -> None:
    """Фоновая работа. Сайт запущен в нескольких процессах, а работать должен только один:
    кто первым взял блокировку, тот и следит."""
    lock = open(os.path.join(DATA_DIR, "background.lock"), "w")
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError:
            time.sleep(60)
    api_ready, api_retry, last_sweep = False, 0.0, 0.0
    while True:
        try:
            if time.time() - last_sweep >= 300:
                last_sweep = time.time()
                sweep_expired()
            lift_bans()
            if DEVICE_LIMIT and not api_ready and time.time() >= api_retry:
                api_ready = ensure_xray_api()
                api_retry = time.time() + 3600
            if DEVICE_LIMIT and api_ready:
                check_sharing()
        except Exception:
            log.exception("background task failed")
        time.sleep(SHARE_CHECK_SEC)


# ---------- ЮKassa ----------

def yk_request(method: str, path: str, body: dict | None = None, idem: str | None = None) -> dict:
    req = urllib.request.Request(f"https://api.yookassa.ru/v3{path}", method=method)
    token = base64.b64encode(f"{YK_SHOP}:{YK_SECRET}".encode()).decode()
    req.add_header("Authorization", f"Basic {token}")
    req.add_header("Content-Type", "application/json")
    if idem:
        req.add_header("Idempotence-Key", idem)
    data = json.dumps(body).encode() if body is not None else None
    with urllib.request.urlopen(req, data=data, timeout=15) as r:
        return json.load(r)


def refresh_payment(con: sqlite3.Connection, pid: str) -> None:
    """Спрашивает у ЮKassa статус платежа (данным из вебхука не доверяем)."""
    if PAYMENT != "yookassa":
        return
    try:
        p = yk_request("GET", f"/payments/{pid}")
    except (urllib.error.URLError, ValueError):
        log.exception("yookassa status check failed for %s", pid)
        return
    if p.get("status") == "succeeded" and p.get("paid"):
        apply_payment(con, pid)
    elif p.get("status") == "canceled":
        with con:
            con.execute("UPDATE payments SET status='canceled' WHERE id=? AND applied=0", (pid,))


# ---------- вход, CSRF, ограничение попыток ----------

def current_user():
    uid = session.get("uid")
    if not uid:
        return None
    return db().execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone()


def login_required(view):
    @wraps(view)
    def wrapped(*a, **kw):
        user = current_user()
        if user is None:
            return redirect(url_for("login", next=request.path))
        if user["blocked"]:
            session.clear()
            flash("Доступ к аккаунту закрыт.")
            return redirect(url_for("login"))
        g.user = user
        return view(*a, **kw)
    return wrapped


def csrf_token() -> str:
    if "csrf" not in session:
        session["csrf"] = secrets.token_urlsafe(32)
    return session["csrf"]


@app.before_request
def check_csrf():
    if request.method == "POST" and request.endpoint != "webhook":
        token = session.get("csrf")
        if not token or not secrets.compare_digest(request.form.get("csrf", ""), token):
            abort(400)


_attempts: dict = {}
_attempts_lock = threading.Lock()


def too_many_attempts(key: str, limit: int = 10, window: int = 600) -> bool:
    with _attempts_lock:
        t = now()
        hits = [x for x in _attempts.get(key, []) if t - x < window]
        hits.append(t)
        _attempts[key] = hits
        return len(hits) > limit


def asset(name: str) -> str:
    """Ссылка на файл из static с версией по содержимому, чтобы браузер не брал старый из кэша."""
    with open(os.path.join(app.static_folder, name), "rb") as f:
        ver = hashlib.md5(f.read()).hexdigest()[:8]
    return url_for("static", filename=name, v=ver)


@app.context_processor
def inject():
    return {"csrf_token": csrf_token, "asset": asset, "site_name": SITE_NAME, "plans": PLANS.values(),
            "me": current_user(), "payment_mode": PAYMENT,
            "payments_on": PAYMENTS_ENABLED, "keys_on": KEYS_ENABLED, "max_keys": MAX_KEYS,
            "device_limit": DEVICE_LIMIT, "ban_minutes": BAN_MINUTES,
            "year": datetime.now().year}


@app.template_filter("plural")
def plural(n: int, one: str, few: str, many: str) -> str:
    """1 устройство, 2 устройства, 5 устройств"""
    n = abs(int(n))
    if n % 10 == 1 and n % 100 != 11:
        return one
    if 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14:
        return few
    return many


@app.template_filter("date")
def fmt_date(ts: int) -> str:
    months = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля",
              "августа", "сентября", "октября", "ноября", "декабря"]
    d = datetime.fromtimestamp(ts, timezone.utc).astimezone()
    return f"{d.day} {months[d.month - 1]} {d.year}"


# ---------- страницы ----------

@app.get("/")
def index():
    return render_template("index.html")


@app.route("/register", methods=["GET", "POST"])
def register():
    if request.method == "POST":
        email = request.form.get("email", "").strip().lower()
        pw = request.form.get("password", "")
        if too_many_attempts("reg:" + (request.remote_addr or "")):
            flash("Слишком много попыток. Попробуйте позже.")
        elif not EMAIL_RE.match(email) or len(email) > 200:
            flash("Проверьте адрес почты.")
        elif len(pw) < 8:
            flash("Пароль должен быть не короче 8 символов.")
        elif pw != request.form.get("password2", ""):
            flash("Пароли не совпадают.")
        else:
            try:
                with db() as con:
                    cur = con.execute(
                        "INSERT INTO users (email, pw_hash, created_at) VALUES (?, ?, ?)",
                        (email, generate_password_hash(pw), now()))
            except sqlite3.IntegrityError:
                flash("Аккаунт с этой почтой уже есть. Войдите.")
                return render_template("auth.html", mode="register", email=email)
            session.clear()
            session.permanent = True
            session["uid"] = cur.lastrowid
            return redirect(url_for("account"))
        return render_template("auth.html", mode="register", email=email)
    return render_template("auth.html", mode="register")


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        email = request.form.get("email", "").strip().lower()
        if too_many_attempts("login:" + (request.remote_addr or "")):
            flash("Слишком много попыток. Подождите 10 минут.")
            return render_template("auth.html", mode="login", email=email)
        user = db().execute("SELECT * FROM users WHERE email=?", (email,)).fetchone()
        if not user or not check_password_hash(user["pw_hash"], request.form.get("password", "")):
            flash("Неверная почта или пароль.")
            return render_template("auth.html", mode="login", email=email)
        if user["blocked"]:
            flash("Доступ к аккаунту закрыт.")
            return render_template("auth.html", mode="login", email=email)
        session.clear()
        session.permanent = True
        session["uid"] = user["id"]
        nxt = request.args.get("next", "")
        return redirect(nxt if nxt.startswith("/") and not nxt.startswith("//") else url_for("account"))
    return render_template("auth.html", mode="login")


@app.post("/logout")
def logout():
    session.clear()
    return redirect(url_for("index"))


@app.get("/account")
@login_required
def account():
    con = db()
    # Вернулись со страницы оплаты: проверим платежи, не дожидаясь вебхука
    for p in con.execute("SELECT id FROM payments WHERE user_id=? AND status='pending' "
                         "AND created_at > ?", (g.user["id"], now() - 86400)).fetchall():
        refresh_payment(con, p["id"])
    user = con.execute("SELECT * FROM users WHERE id=?", (g.user["id"],)).fetchone()
    keys = []
    if is_active(user) and KEYS_ENABLED:
        for k in user_keys(user["id"]):
            link, trojan = key_link(k)
            keys.append({**k, "link": link, "qr": qr_svg(link), "trojan": trojan})
    payments = con.execute("SELECT * FROM payments WHERE user_id=? AND status='succeeded' "
                           "ORDER BY created_at DESC LIMIT 10", (user["id"],)).fetchall()
    bans = [{"name": b["email"][len(prefix(user["id"])):],
             "minutes": max(1, -(-(b["until"] - now()) // 60))}
            for b in con.execute("SELECT * FROM key_bans WHERE user_id=?", (user["id"],))]
    sub_url = f"{BASE_URL}/sub/{sub_token(con, user)}" if KEYS_ENABLED else None
    return render_template("account.html", user=user, active=is_active(user),
                           keys=keys, payments=payments, bans=bans, sub_url=sub_url,
                           profile_title=profile_title())


@app.get("/sub/<token>")
def subscription(token):
    """Ссылка-подписка для Hiddify и v2RayTun: приложение само забирает отсюда ключи,
    название и срок подписки и обновляет их. Ключи — только пока подписка активна."""
    if len(token) < 16:
        abort(404)
    user = db().execute("SELECT * FROM users WHERE sub_token=?", (token,)).fetchone() or abort(404)
    links = []
    if KEYS_ENABLED and is_active(user) and not user["blocked"] and not user["revoked"]:
        links = [key_link(k)[0] for k in user_keys(user["id"])]
    title = profile_title()
    resp = app.response_class(base64.b64encode("\n".join(links).encode()).decode(),
                              mimetype="text/plain")
    resp.headers["profile-title"] = "base64:" + base64.b64encode(title.encode()).decode()
    # срок подписки: приложения показывают, сколько дней осталось
    resp.headers["subscription-userinfo"] = (f"upload=0; download=0; total=0; "
                                             f"expire={user['paid_until']}")
    resp.headers["profile-update-interval"] = "6"
    resp.headers["profile-web-page-url"] = f"{BASE_URL}/account"
    resp.headers["Content-Disposition"] = f"attachment; filename*=UTF-8''{quote(title)}"
    resp.headers["Cache-Control"] = "no-store"
    return resp


@app.post("/keys")
@login_required
def key_create():
    if not KEYS_ENABLED:
        flash("Выдача ключей скоро откроется.")
        return redirect(url_for("account"))
    if g.user["revoked"]:
        flash("Доступ закрыт: ключ использовался на нескольких устройствах одновременно.")
        return redirect(url_for("account"))
    if not is_active(g.user):
        flash("Сначала оформите подписку.")
        return redirect(url_for("account") + "#plans")
    banned = db().execute("SELECT COUNT(*) FROM key_bans WHERE user_id=?",
                          (g.user["id"],)).fetchone()[0]
    if banned:
        flash("Ключ временно отключён. Новый можно будет создать, когда он снова заработает.")
        return redirect(url_for("account"))
    name = request.form.get("name", "").strip() or "device"
    if not NAME_RE.match(name):
        flash("Имя ключа: латиница, цифры, «-» или «_», до 20 символов.")
        return redirect(url_for("account"))
    client = {"id": str(uuidlib.uuid4()), "email": prefix(g.user["id"]) + name,
              "flow": "xtls-rprx-vision"}
    try:
        res = add_client(client, limit=MAX_KEYS)
    except subprocess.CalledProcessError:
        log.exception("xray config failed")
        flash("Не удалось создать ключ. Попробуйте позже.")
        return redirect(url_for("account"))
    if res == "limit":
        flash("Можно создать только один ключ. Чтобы подключить другое устройство, "
              "удалите старый ключ." if MAX_KEYS == 1 else
              f"Можно не больше {MAX_KEYS} ключей. Удалите ненужный.")
        return redirect(url_for("account"))
    if res == "exists":
        flash("Ключ с таким именем уже есть.")
        return redirect(url_for("account"))
    flash(f"Ключ «{name}» готов.")
    return redirect(url_for("account") + "#keys")


@app.post("/keys/<name>/delete")
@login_required
def key_delete(name):
    email = prefix(g.user["id"]) + name
    with conf_lock():
        conf = load_conf()
        left = [c for c in clients(conf) if c["email"] != email]
        if len(left) != len(clients(conf)):
            conf["inbounds"][0]["settings"]["clients"] = left
            save_conf_and_restart(conf)
            flash(f"Ключ «{name}» удалён.")
    return redirect(url_for("account") + "#keys")


# ---------- оплата ----------

@app.post("/pay/<code>")
@login_required
def pay(code):
    plan = PLANS.get(code) or abort(404)
    if g.user["revoked"]:
        flash("Доступ закрыт: ключ использовался на нескольких устройствах одновременно.")
        return redirect(url_for("account"))
    if not PAYMENTS_ENABLED:
        flash("Оплата скоро откроется.")
        return redirect(url_for("account"))
    if PAYMENT == "yookassa":
        idem = str(uuidlib.uuid4())
        try:
            p = yk_request("POST", "/payments", {
                "amount": {"value": f"{plan['price']}.00", "currency": "RUB"},
                "capture": True,
                "confirmation": {"type": "redirect", "return_url": f"{BASE_URL}/account"},
                "description": f"{SITE_NAME}: подписка на {plan['title']}",
                "metadata": {"user_id": g.user["id"], "plan": code},
            }, idem=idem)
        except (urllib.error.URLError, ValueError):
            log.exception("yookassa create failed")
            flash("Платёжная система не отвечает. Попробуйте ещё раз.")
            return redirect(url_for("account"))
        pid, url = p["id"], p["confirmation"]["confirmation_url"]
    else:
        pid, url = "test-" + secrets.token_hex(8), None
    with db() as con:
        con.execute("INSERT INTO payments (id, user_id, plan, amount, days, status, provider, "
                    "created_at) VALUES (?, ?, ?, ?, ?, 'pending', ?, ?)",
                    (pid, g.user["id"], code, plan["price"], plan["days"], PAYMENT, now()))
    return redirect(url or url_for("pay_test", pid=pid))


@app.route("/pay/test/<pid>", methods=["GET", "POST"])
@login_required
def pay_test(pid):
    if PAYMENT != "test" or not PAYMENTS_ENABLED:
        abort(404)
    p = db().execute("SELECT * FROM payments WHERE id=? AND user_id=?",
                     (pid, g.user["id"])).fetchone() or abort(404)
    if request.method == "POST":
        apply_payment(db(), pid)
        flash("Подписка оформлена (тестовая оплата).")
        return redirect(url_for("account"))
    return render_template("pay_test.html", p=p, plan=PLANS.get(p["plan"]))


@app.post("/pay/webhook")
def webhook():
    """Уведомление ЮKassa. Статус перепроверяем запросом к API."""
    try:
        pid = request.get_json(force=True)["object"]["id"]
    except (TypeError, KeyError, ValueError):
        abort(400)
    con = db()
    if con.execute("SELECT 1 FROM payments WHERE id=?", (pid,)).fetchone():
        refresh_payment(con, pid)
    return "", 200


# ---------- админка ----------

@app.route("/admin", methods=["GET", "POST"])
@login_required
def admin():
    if g.user["email"] not in ADMIN_EMAILS:
        abort(404)
    con = db()
    if request.method == "POST":
        uid = int(request.form["uid"])
        act = request.form["action"]
        with con:
            if act == "block":
                con.execute("UPDATE users SET blocked=1 WHERE id=?", (uid,))
            elif act == "unblock":
                con.execute("UPDATE users SET blocked=0 WHERE id=?", (uid,))
            elif act == "add30":
                con.execute("UPDATE users SET paid_until = MAX(paid_until, ?) + ? WHERE id=?",
                            (now(), 30 * 86400, uid))
            elif act == "stop":
                con.execute("UPDATE users SET paid_until=0 WHERE id=?", (uid,))
            elif act == "pardon":
                con.execute("UPDATE users SET strikes=0, revoked=0 WHERE id=?", (uid,))
        if act in ("block", "stop") and KEYS_ENABLED:
            remove_user_keys({uid})
        if act == "pardon" and KEYS_ENABLED:
            lift_bans(uid)
        return redirect(url_for("admin"))
    users = con.execute("SELECT * FROM users ORDER BY id DESC LIMIT 500").fetchall()
    counts: dict = {}
    for c in (clients(load_conf()) if KEYS_ENABLED else []):
        if m := re.match(r"^w(\d+)_", c["email"]):
            counts[int(m.group(1))] = counts.get(int(m.group(1)), 0) + 1
    income = con.execute("SELECT COALESCE(SUM(amount), 0) FROM payments "
                         "WHERE status='succeeded'").fetchone()[0]
    return render_template("admin.html", users=users, counts=counts, income=income,
                           now=now())


logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
if os.getenv("SWEEPER", "1") == "1" and KEYS_ENABLED:
    threading.Thread(target=background, daemon=True).start()

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8000, debug=False)
