#!/usr/bin/env python3
"""Собирает статическую демо-версию сайта (без оплаты и ключей) в папку _site.

Страницы рендерятся теми же шаблонами, что и настоящий сайт. Регистрация и вход
в демо работают только в браузере (demo/demo.js), сервер не нужен.
Запуск: python3 build_demo.py
"""
import os
import re
import shutil
import sys
import tempfile

OUT = sys.argv[1] if len(sys.argv) > 1 else "_site"
os.environ.update(SECRET_KEY="demo", DEMO="1", SWEEPER="0", PAYMENT_PROVIDER="test",
                  DATA_DIR=tempfile.mkdtemp())
import app as site  # noqa: E402

DEMO_EMAIL = "demo@example.com"
PAGES = {"/": "index.html", "/register": "register.html", "/login": "login.html",
         "/account": "account.html"}


def fix(html: str) -> str:
    html = html.replace("/static/style.css", "style.css")
    for path, name in sorted(PAGES.items(), key=lambda x: -len(x[0])):
        html = re.sub(rf'(href|action)="{re.escape(path)}(#[^"]*)?"',
                      lambda m: f'{m.group(1)}="{name}{m.group(2) or ""}"', html)
    # Формы в демо обрабатывает demo.js
    html = re.sub(r'action="/[^"]*"', 'action="#"', html)
    html = html.replace('<form method="post">', '<form method="post" action="#">')
    html = html.replace(DEMO_EMAIL, '<span data-demo-email>' + DEMO_EMAIL + '</span>')
    return html.replace("</body>", '<script src="demo.js"></script>\n</body>')


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
    c.post("/register", data={"csrf": token, "email": DEMO_EMAIL,
                              "password": "demo-pass", "password2": "demo-pass"})
    r = c.get("/account")
    assert r.status_code == 200 and DEMO_EMAIL in r.get_data(as_text=True)
    open(os.path.join(OUT, "account.html"), "w").write(fix(r.get_data(as_text=True)))
    shutil.copy("static/style.css", OUT)
    shutil.copy("demo/demo.js", OUT)
    print("demo built in", OUT)


if __name__ == "__main__":
    main()
