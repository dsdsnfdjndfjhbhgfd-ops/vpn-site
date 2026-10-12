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
import io
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
from urllib.parse import quote

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
BASE_URL = os.getenv("BASE_URL", "http://localhost:8000").rstrip("/")
MAX_KEYS = int(os.getenv("MAX_KEYS", "3"))
# test — кнопка «оплатить» сразу продлевает подписку (для проверки);
# yookassa — настоящая оплата через ЮKassa
PAYMENT = os.getenv("PAYMENT_PROVIDER", "test").strip().lower()
# Статическая демо-версия для GitHub Pages (собирается build_demo.py)
DEMO = os.getenv("DEMO") == "1"
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
  blocked INTEGER NOT NULL DEFAULT 0
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


def save_conf_and_restart(conf: dict) -> None:
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(CONF))
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
    subprocess.run(RESTART_CMD, check=True)


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
    """Раз в 5 минут убирает ключи у тех, чья подписка кончилась или кто заблокирован."""
    while True:
        try:
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
        except Exception:
            log.exception("sweep failed")
        time.sleep(300)


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


@app.context_processor
def inject():
    return {"csrf_token": csrf_token, "site_name": SITE_NAME, "plans": PLANS.values(),
            "me": current_user(), "payment_mode": PAYMENT, "demo": DEMO, "max_keys": MAX_KEYS,
            "year": datetime.now().year}


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
    if is_active(user):
        for k in user_keys(user["id"]):
            link = make_link(k["id"], f"{SITE_NAME}-{k['name']}")
            keys.append({**k, "link": link, "qr": qr_svg(link)})
    payments = con.execute("SELECT * FROM payments WHERE user_id=? AND status='succeeded' "
                           "ORDER BY created_at DESC LIMIT 10", (user["id"],)).fetchall()
    return render_template("account.html", user=user, active=is_active(user),
                           keys=keys, payments=payments)


@app.post("/keys")
@login_required
def key_create():
    if not is_active(g.user):
        flash("Сначала оформите подписку.")
        return redirect(url_for("account") + "#plans")
    name = request.form.get("name", "").strip() or "device"
    if not NAME_RE.match(name):
        flash("Имя ключа: латиница, цифры, «-» или «_», до 20 символов.")
        return redirect(url_for("account"))
    email = prefix(g.user["id"]) + name
    with conf_lock():
        conf = load_conf()
        mine = [c for c in clients(conf) if c["email"].startswith(prefix(g.user["id"]))]
        if len(mine) >= MAX_KEYS:
            flash(f"Можно не больше {MAX_KEYS} ключей. Удалите ненужный.")
            return redirect(url_for("account"))
        if any(c["email"] == email for c in mine):
            flash("Ключ с таким именем уже есть.")
            return redirect(url_for("account"))
        clients(conf).append({"id": str(uuidlib.uuid4()), "email": email,
                              "flow": "xtls-rprx-vision"})
        try:
            save_conf_and_restart(conf)
        except subprocess.CalledProcessError:
            log.exception("xray config failed")
            flash("Не удалось создать ключ. Попробуйте позже.")
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
    if PAYMENT != "test":
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
        if act in ("block", "stop"):
            remove_user_keys({uid})
        return redirect(url_for("admin"))
    users = con.execute("SELECT * FROM users ORDER BY id DESC LIMIT 500").fetchall()
    counts: dict = {}
    for c in clients(load_conf()):
        if m := re.match(r"^w(\d+)_", c["email"]):
            counts[int(m.group(1))] = counts.get(int(m.group(1)), 0) + 1
    income = con.execute("SELECT COALESCE(SUM(amount), 0) FROM payments "
                         "WHERE status='succeeded'").fetchone()[0]
    return render_template("admin.html", users=users, counts=counts, income=income,
                           now=now())


logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
if os.getenv("SWEEPER", "1") == "1":
    threading.Thread(target=sweep_expired, daemon=True).start()

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8000, debug=False)
