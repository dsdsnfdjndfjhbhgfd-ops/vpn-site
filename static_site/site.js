// Регистрация и вход для статической версии сайта (GitHub Pages) через Supabase.
// Оплата и ключи в этой версии выключены.
(() => {
  const SUPABASE_URL = 'https://dnwubeyihrorwzlfxfsn.supabase.co';
  // Публичный ключ: его можно показывать, доступ к данным ограничен функциями в базе
  const SUPABASE_KEY = 'sb_publishable_9tf6nz5mYhBXKOS-avDUlg_tl8gvtaI';
  const TOKEN = 'vpn-token';
  const ERRORS = {
    bad_credentials: 'Неверная почта или пароль.',
    email_taken: 'Аккаунт с этой почтой уже есть. Войдите.',
    weak_password: 'Пароль должен быть не короче 8 символов.',
    bad_email: 'Проверьте адрес почты.',
    too_many_attempts: 'Слишком много попыток. Подождите 10 минут.',
    blocked: 'Доступ к аккаунту закрыт.',
  };

  const store = {
    get() { try { return localStorage.getItem(TOKEN); } catch (e) { return null; } },
    set(v) { try { localStorage.setItem(TOKEN, v); } catch (e) {} },
    clear() { try { localStorage.removeItem(TOKEN); } catch (e) {} },
  };

  async function rpc(name, args) {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
      method: 'POST',
      headers: { apikey: SUPABASE_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify(args),
    });
    const data = await r.json().catch(() => null);
    if (!r.ok) throw new Error((data && data.message) || 'network');
    return data;
  }

  const page = location.pathname.split('/').pop() || 'index.html';
  const token = store.get();
  const go = p => { location.href = p; };

  function flash(form, text) {
    let el = form.querySelector('.flash');
    if (!el) { el = document.createElement('div'); el.className = 'flash'; form.prepend(el); }
    el.textContent = text;
  }

  // Навигация: если уже вошли, вместо «Войти / Регистрация» показываем «Кабинет»
  if (token && page !== 'account.html') {
    const links = document.querySelector('.nav-links');
    const login = links && links.querySelector('a[href="login.html"]');
    const reg = links && links.querySelector('a[href="register.html"]');
    if (login) { login.textContent = 'Кабинет'; login.href = 'account.html'; }
    if (reg) reg.remove();
  }

  if (page === 'account.html') {
    const main = document.querySelector('main');
    main.style.visibility = 'hidden';
    if (!token) return go('login.html');
    rpc('vpn_me', { p_token: token }).then(rows => {
      if (!rows || !rows.length) { store.clear(); return go('login.html'); }
      document.querySelectorAll('[data-email]').forEach(el => { el.textContent = rows[0].email; });
      main.style.visibility = '';
    }).catch(() => {
      main.style.visibility = '';
      document.querySelectorAll('[data-email]').forEach(el => { el.textContent = 'Нет связи с сервером'; });
    });
  }
  if ((page === 'login.html' || page === 'register.html') && token) go('account.html');

  document.querySelectorAll('form').forEach(form => form.addEventListener('submit', async e => {
    e.preventDefault();
    const f = form.elements;
    const btn = form.querySelector('button[type=submit]');
    if (btn && btn.textContent.includes('Выйти')) {
      if (token) await rpc('vpn_logout', { p_token: token }).catch(() => {});
      store.clear();
      return go('index.html');
    }
    if (!f.email) return;
    if (f.password2 && f.password.value !== f.password2.value) return flash(form, 'Пароли не совпадают.');
    if (btn) { btn.disabled = true; btn.classList.add('loading'); }
    try {
      const fn = f.password2 ? 'vpn_register' : 'vpn_login';
      const t = await rpc(fn, { p_email: f.email.value, p_password: f.password.value });
      store.set(t);
      go('account.html');
    } catch (err) {
      flash(form, ERRORS[err.message] || 'Не удалось связаться с сервером. Попробуйте ещё раз.');
      if (btn) { btn.disabled = false; btn.classList.remove('loading'); }
    }
  }));
})();
