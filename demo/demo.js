// Демо-версия: аккаунт хранится только в этом браузере, оплаты и ключей нет.
(() => {
  const KEY = 'demo-email';
  const page = location.pathname.split('/').pop() || 'index.html';
  let email = null;
  try { email = localStorage.getItem(KEY); } catch (e) {}

  const go = p => { location.href = p; };
  const save = v => { try { localStorage.setItem(KEY, v); } catch (e) {} };

  if (page === 'account.html') {
    if (!email) return go('login.html');
    document.querySelectorAll('[data-demo-email]').forEach(el => { el.textContent = email; });
    document.title = 'Кабинет · ' + document.title.split('·').pop().trim();
  }

  // Навигация: показываем «Кабинет», если в демо уже вошли
  if (email && page !== 'account.html') {
    const links = document.querySelector('.nav-links');
    const login = links && links.querySelector('a[href="login.html"]');
    const reg = links && links.querySelector('a[href="register.html"]');
    if (login) { login.textContent = 'Кабинет'; login.href = 'account.html'; }
    if (reg) reg.remove();
  }

  const flash = (form, text) => {
    let el = form.querySelector('.flash');
    if (!el) { el = document.createElement('div'); el.className = 'flash'; form.prepend(el); }
    el.textContent = text;
  };

  document.querySelectorAll('form').forEach(form => form.addEventListener('submit', e => {
    e.preventDefault();
    const f = form.elements;
    if (form.querySelector('button.linklike') && form.textContent.includes('Выйти')) {
      try { localStorage.removeItem(KEY); } catch (err) {}
      return go('index.html');
    }
    if (f.email) {
      if (f.password2 && f.password.value !== f.password2.value) return flash(form, 'Пароли не совпадают.');
      save(f.email.value.trim().toLowerCase());
      return go('account.html');
    }
    alert('Это демо-версия: оплата и выдача ключей пока отключены.');
  }));
})();
