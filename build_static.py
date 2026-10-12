#!/usr/bin/env python3
"""Собирает статическую версию сайта для GitHub Pages в папку _site (режим предзапуска).

Страницы рендерятся теми же шаблонами, что и настоящий сайт, с выключенными
оплатой и ключами. Регистрация и вход идут в Supabase (static_site/site.js,
функции vpn_register / vpn_login / vpn_me / vpn_logout в supabase/vpn_accounts.sql).
Запуск: python3 build_static.py
"""
import os
import re
import shutil
import sys
import tempfile

OUT = sys.argv[1] if len(sys.argv) > 1 else "_site"
os.environ.update(SECRET_KEY="static", SWEEPER="0", PAYMENT_PROVIDER="test",
                  PAYMENTS_ENABLED="0", KEYS_ENABLED="0",
                  DATA_DIR=tempfile.mkdtemp())
import app as site  # noqa: E402

PLACEHOLDER_EMAIL = "user@example.com"
PAGES = {"/": "index.html", "/register": "register.html", "/login": "login.html",
         "/account": "account.html"}


def fix(html: str) -> str:
    html = html.replace("/static/style.css", "style.css").replace("/static/app.js", "app.js")
    for path, name in sorted(PAGES.items(), key=lambda x: -len(x[0])):
        html = re.sub(rf'(href|action)="{re.escape(path)}(#[^"]*)?"',
                      lambda m: f'{m.group(1)}="{name}{m.group(2) or ""}"', html)
    # Формы обрабатывает site.js
    html = re.sub(r'action="/[^"]*"', 'action="#"', html)
    html = html.replace('<form method="post">', '<form method="post" action="#">')
    html = html.replace(PLACEHOLDER_EMAIL, '<span data-email>' + PLACEHOLDER_EMAIL + '</span>')
    return html.replace("</body>", '<script src="site.js"></script>\n</body>')


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(OUT)
    c = site.app.test_client()
    for path in ("/", "/register", "/login"):
        r = c.get(path)
        assert r.status_code == 200, path
        open(os.path.join(OUT, PAGES[path]), "w").write(fix(r.get_data(as_text=True)))
    # Кабинет: тот же шаблон, что видит новый пользователь без подписки
    c.get("/register")
    with c.session_transaction() as s:
        token = s["csrf"]
    c.post("/register", data={"csrf": token, "email": PLACEHOLDER_EMAIL,
                              "password": "static-pass", "password2": "static-pass"})
    r = c.get("/account")
    assert r.status_code == 200 and PLACEHOLDER_EMAIL in r.get_data(as_text=True)
    open(os.path.join(OUT, "account.html"), "w").write(fix(r.get_data(as_text=True)))
    shutil.copy("static/style.css", OUT)
    shutil.copy("static/app.js", OUT)
    shutil.copy("static_site/site.js", OUT)
    print("site built in", OUT)


if __name__ == "__main__":
    main()
