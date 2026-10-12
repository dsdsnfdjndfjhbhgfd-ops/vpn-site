# Сайт для продажи ключей VPN

Сайт в стиле Apple: главная страница с тарифами, регистрация по почте и паролю, личный кабинет. После оплаты подписки человек сам создаёт ключи (до `MAX_KEYS` штук, по одному на устройство) и получает ссылку `vless://` и QR-код. Когда подписка заканчивается, его ключи удаляются с сервера автоматически (проверка раз в 5 минут).

Сайт работает на том же сервере, что и VPN (`install-vpn.sh`), и правит тот же конфиг Xray, что и Telegram-бот. Ключи с сайта подписаны в Xray как `w<номер пользователя>_<имя>`, поэтому не путаются с ключами бота. Бот можно оставить: в его `/keys` ключи сайта видны как ключи админа.

Что внутри: Python (Flask), база SQLite в `/var/lib/vpn-site/site.db`, Caddy для HTTPS.

| Страница | Что там |
|---|---|
| `/` | главная: возможности, тарифы, как подключиться |
| `/register`, `/login` | регистрация и вход |
| `/account` | статус подписки, оплата, ключи с QR-кодами |
| `/admin` | для почт из `ADMIN_EMAILS`: все пользователи, «+30 дней», «Снять подписку», «Заблокировать» |

## Что понадобится

1. Сервер с уже установленным VPN (`bash install-vpn.sh`).
2. Домен (например, `vpn.example.com`), у которого A-запись указывает на IP сервера. Без домена не будет HTTPS, а ЮKassa работает только с HTTPS.

Порт 443 занят VPN, поэтому сайт открывается на порту **8443**: `https://vpn.example.com:8443`. Порт 80 нужен Caddy, чтобы получить сертификат.

## 1. Скопируйте файлы на сервер

С компьютера, из папки `site`:
```
ssh root@IP_СЕРВЕРА mkdir -p /opt/vpn-site
scp -r app.py requirements.txt static templates vpn-site.service Caddyfile root@IP_СЕРВЕРА:/opt/vpn-site/
```

## 2. Установите сайт

На сервере:
```
apt-get install -y python3-venv
cd /opt/vpn-site
python3 -m venv venv
venv/bin/pip install -r requirements.txt

cat > /etc/vpn-site.env <<E
SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
BASE_URL=https://vpn.example.com:8443
SITE_NAME=Tunnel
ADMIN_EMAILS=ваша@почта.ru
MAX_KEYS=3
PLANS=1m:30:199:1 месяц,3m:90:499:3 месяца,12m:365:1690:12 месяцев
PAYMENT_PROVIDER=test
E
chmod 600 /etc/vpn-site.env

cp vpn-site.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now vpn-site
systemctl status vpn-site
```
Замените `vpn.example.com` на свой домен. Все настройки с пояснениями есть в `vpn-site.env.example`.

## 3. Включите HTTPS (Caddy)

```
apt-get install -y caddy
sed -i 's/vpn.example.com/ВАШ_ДОМЕН/' /opt/vpn-site/Caddyfile
cp /opt/vpn-site/Caddyfile /etc/caddy/Caddyfile
systemctl restart caddy
ufw allow 80/tcp; ufw allow 8443/tcp   # если включён ufw
```
Если `apt-get install caddy` не находит пакет, поставьте его по инструкции с caddyserver.com/docs/install (раздел Debian, Ubuntu).

Откройте `https://ВАШ_ДОМЕН:8443`, зарегистрируйтесь с почтой из `ADMIN_EMAILS` и проверьте всё в тестовом режиме: кнопка «Оплатить (тест)» сразу продлевает подписку, деньги не списываются. Сверху сайта в этом режиме висит жёлтая плашка.

## 4. Настоящая оплата через ЮKassa

1. Зарегистрируйтесь на yookassa.ru и подключите магазин (нужен статус ИП или самозанятого).
2. В личном кабинете ЮKassa, раздел «Интеграция»:
   - «Ключи API»: скопируйте **shopId** и **секретный ключ**.
   - «HTTP-уведомления»: адрес `https://ВАШ_ДОМЕН:8443/pay/webhook`, событие `payment.succeeded` и `payment.canceled`.
3. Допишите в `/etc/vpn-site.env`:
   ```
   PAYMENT_PROVIDER=yookassa
   YOOKASSA_SHOP_ID=ваш_shopId
   YOOKASSA_SECRET_KEY=ваш_секретный_ключ
   ```
4. `systemctl restart vpn-site`

Человек нажимает «Оплатить», уходит на страницу ЮKassa (карта, СБП, SberPay), возвращается в кабинет, и подписка продлевается. Сайт не доверяет содержимому уведомления: он сам спрашивает у ЮKassa статус платежа. Если уведомление задержалось, статус проверяется ещё и при открытии кабинета.

Если ЮKassa требует чеки по 54-ФЗ (обычно да, если вы не самозанятый с «Мой налог»), в запрос создания платежа (функция `pay` в `app.py`) нужно добавить поле `receipt` с почтой покупателя. Напишите, и я добавлю.

Начните с тестового магазина ЮKassa (тестовые ключи из кабинета): оплата проходит тестовыми картами, деньги не списываются.

## Режим предзапуска

Чтобы открыть регистрацию, пока оплата и ключи не готовы, допишите в `/etc/vpn-site.env`:
```
PAYMENTS_ENABLED=0
KEYS_ENABLED=0
```
и выполните `systemctl restart vpn-site`. Люди регистрируются и входят в кабинет, вместо кнопок оплаты видят «Скоро», а сверху висит плашка о скором запуске. Когда будете готовы, поставьте `1` и перезапустите сайт: зарегистрированные аккаунты сохранятся.

## Полезное

- Логи: `journalctl -u vpn-site -f`
- Обновить сайт: скопируйте новые файлы в `/opt/vpn-site` и выполните `systemctl restart vpn-site`.
- Резервная копия пользователей и платежей: файл `/var/lib/vpn-site/site.db`.
- Цены и сроки меняются в `PLANS`, после правки: `systemctl restart vpn-site`.
- При каждом изменении ключей Xray перезапускается, и у всех подключённых связь прерывается на секунду (так же работает бот).
- Восстановить пароль пользователю пока можно только вручную. Письма с подтверждением почты сайт не отправляет.

## Автоматическая выкладка из GitHub

В репозитории есть GitHub Actions (`.github/workflows/deploy.yml`): после каждого push в `main` сайт сам копируется на сервер и перезапускается.

1. Один раз сделайте шаги 2 и 3 выше (файл `/etc/vpn-site.env` и Caddy).
2. Создайте ключ для выкладки на своём компьютере: `ssh-keygen -t ed25519 -f deploy_key -N ""`, затем добавьте его на сервер: `ssh-copy-id -i deploy_key.pub root@IP_СЕРВЕРА`.
3. В репозитории на GitHub: Settings → Secrets and variables → Actions → New repository secret:
   - `SSH_HOST`: IP сервера
   - `SSH_KEY`: содержимое файла `deploy_key` целиком
4. Вкладка Actions → Deploy → Run workflow. Дальше выкладка идёт сама при каждом изменении.

## Сайт на GitHub Pages (предзапуск)

Сейчас сайт работает на GitHub Pages: https://dsdsnfdjndfjhbhgfd-ops.github.io/vpn-site/

Это статическая копия из тех же шаблонов (её собирает `build_static.py`), оплата и ключи в ней выключены. Регистрация и вход настоящие: аккаунты хранятся в Supabase, в проекте `dnwubeyihrorwzlfxfsn`, в схеме `vpn` (таблица `vpn.users`, пароли зашифрованы bcrypt). Структура базы и функции лежат в `supabase/vpn_accounts.sql`. Браузер обращается к базе только через функции `vpn_register`, `vpn_login`, `vpn_me` и `vpn_logout`, а прочитать таблицы напрямую не может.

Посмотреть зарегистрированных: Supabase → SQL Editor → `select id, email, created_at from vpn.users order by id desc;`

Workflow `.github/workflows/pages.yml` пересобирает сайт после каждого push в `main`.

Когда включите оплату и ключи на VPN-сервере, аккаунты из Supabase нужно будет перенести в базу сервера.
