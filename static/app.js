// Интерактив сайта: анимации, демо-телефон, подсветка карточек, формы.
(() => {
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const finePointer = matchMedia('(pointer: fine)').matches;

  // ---------- уведомление внизу экрана ----------
  let toastEl, toastTimer;
  function toast(text) {
    if (!toastEl) {
      toastEl = document.createElement('div');
      toastEl.className = 'toast';
      toastEl.setAttribute('role', 'status');
      document.body.append(toastEl);
    }
    toastEl.textContent = text;
    requestAnimationFrame(() => toastEl.classList.add('show'));
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toastEl.classList.remove('show'), 2200);
  }

  // ---------- счётчики ----------
  function countUp(el) {
    const to = Number(el.dataset.count);
    if (!Number.isFinite(to) || reduce) return;
    const t0 = performance.now(), dur = 1400;
    const step = now => {
      const k = Math.min(1, (now - t0) / dur);
      el.textContent = Math.round(to * (1 - Math.pow(1 - k, 3)));
      if (k < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }

  // ---------- появление при прокрутке ----------
  const io = new IntersectionObserver(es => es.forEach(e => {
    if (!e.isIntersecting) return;
    e.target.classList.add('shown');
    $$('[data-count]', e.target).forEach(countUp);
    io.unobserve(e.target);
  }), { threshold: 0.12, rootMargin: '0px 0px -40px 0px' });
  $$('.reveal').forEach(el => {
    const sibs = [...el.parentElement.children].filter(c => c.classList.contains('reveal'));
    el.style.setProperty('--d', Math.min(sibs.indexOf(el), 6) * 90 + 'ms');
    io.observe(el);
  });

  // ---------- навигация ----------
  const nav = $('.nav'), bar = $('.progress'), burger = $('.burger');
  const onScroll = () => {
    const y = scrollY, h = document.documentElement.scrollHeight - innerHeight;
    nav && nav.classList.toggle('scrolled', y > 10);
    if (bar) bar.style.transform = `scaleX(${h > 0 ? Math.min(1, y / h) : 0})`;
  };
  addEventListener('scroll', onScroll, { passive: true });
  onScroll();
  const closeMenu = () => { nav.classList.remove('open'); burger.setAttribute('aria-expanded', 'false'); };
  if (burger) {
    burger.addEventListener('click', () => burger.setAttribute('aria-expanded', nav.classList.toggle('open')));
    $$('.nav-links a').forEach(a => a.addEventListener('click', closeMenu));
    addEventListener('keydown', e => { if (e.key === 'Escape') closeMenu(); });
  }
  // Ссылки на разделы этой же страницы прокручивают, а не перезагружают её
  $$('a[href*="#"]').forEach(a => {
    const sec = a.hash.length > 1 && document.getElementById(a.hash.slice(1));
    if (!sec) return;
    a.addEventListener('click', e => {
      e.preventDefault();
      sec.scrollIntoView({ behavior: reduce ? 'auto' : 'smooth' });
      history.replaceState(null, '', a.hash);
    });
  });
  // Подсветка пункта меню текущего раздела
  const links = new Map();
  $$('.nav-links a').forEach(a => {
    const sec = a.hash.length > 1 && document.getElementById(a.hash.slice(1));
    if (sec) links.set(sec, a);
  });
  if (links.size) {
    const so = new IntersectionObserver(es => es.forEach(e => {
      if (!e.isIntersecting) return;
      links.forEach(a => a.classList.remove('active'));
      links.get(e.target).classList.add('active');
    }), { rootMargin: '-45% 0px -50% 0px' });
    links.forEach((_, sec) => so.observe(sec));
  }

  // ---------- подсветка карточек под курсором ----------
  if (finePointer) {
    $$('.spot').forEach(el => el.addEventListener('pointermove', e => {
      const r = el.getBoundingClientRect();
      el.style.setProperty('--mx', `${e.clientX - r.left}px`);
      el.style.setProperty('--my', `${e.clientY - r.top}px`);
    }));
  }

  // ---------- волна при нажатии на кнопку ----------
  document.addEventListener('pointerdown', e => {
    const b = e.target.closest('.btn');
    if (!b || b.disabled || reduce) return;
    const r = b.getBoundingClientRect(), d = Math.max(r.width, r.height) * 2;
    const s = document.createElement('span');
    s.className = 'ripple';
    s.style.cssText = `width:${d}px;height:${d}px;left:${e.clientX - r.left - d / 2}px;top:${e.clientY - r.top - d / 2}px`;
    b.append(s);
    s.addEventListener('animationend', () => s.remove());
  });

  // ---------- наклон телефона за курсором ----------
  const tilt = $('[data-tilt]');
  if (tilt && finePointer && !reduce) {
    const device = $('.device', tilt), area = tilt.closest('section') || tilt;
    area.addEventListener('pointermove', e => {
      const r = tilt.getBoundingClientRect();
      const x = (e.clientX - r.left) / r.width - 0.5, y = (e.clientY - r.top) / r.height - 0.5;
      device.style.setProperty('--ry', `${(x * 16).toFixed(2)}deg`);
      device.style.setProperty('--rx', `${(-y * 12).toFixed(2)}deg`);
    });
    area.addEventListener('pointerleave', () => {
      device.style.setProperty('--ry', '0deg');
      device.style.setProperty('--rx', '0deg');
    });
  }

  // ---------- демо-телефон: кнопка включения ----------
  const vpn = $('[data-vpn]');
  if (vpn) {
    const part = k => vpn.querySelector(`[data-vpn-${k}]`);
    const power = $('.power', vpn);
    let state = 'off', started = 0, tick = 0, pending = 0;
    const speeds = [];
    const pad = n => String(n).padStart(2, '0');
    const set = (s, title, sub) => {
      state = s; vpn.dataset.state = s;
      part('state').textContent = title;
      part('sub').textContent = sub;
    };
    const update = () => {
      const t = Math.floor((Date.now() - started) / 1000);
      part('timer').textContent = `${pad(Math.floor(t / 3600))}:${pad(Math.floor(t / 60) % 60)}:${pad(t % 60)}`;
      const speed = Math.round(860 + Math.random() * 110);
      part('ping').textContent = Math.round(9 + Math.random() * 7);
      part('speed').textContent = speed;
      speeds.push(speed);
      if (speeds.length > 24) speeds.shift();
      part('spark').setAttribute('points',
        speeds.map((v, i) => `${(i / 23 * 100).toFixed(1)},${(28 - (v - 840) / 150 * 26).toFixed(1)}`).join(' '));
    };
    const connect = () => {
      set('connecting', 'Подключение…', 'Устанавливаем защищённый канал');
      pending = setTimeout(() => {
        set('on', 'Подключено', 'Защищённое соединение');
        part('ip').textContent = 'IP скрыт';
        started = Date.now();
        speeds.length = 0;
        update();
        tick = setInterval(update, 1000);
      }, 1500);
    };
    const disconnect = () => {
      clearTimeout(pending); clearInterval(tick);
      set('off', 'Не подключено', 'Нажмите, чтобы подключиться');
      part('ip').textContent = 'IP открыт';
      part('timer').textContent = '00:00:00';
      part('ping').textContent = part('speed').textContent = '—';
      part('spark').setAttribute('points', '');
    };
    power.addEventListener('click', () => (state === 'off' ? connect() : disconnect()));
    // Включаем сами, когда телефон впервые появился на экране
    const auto = new IntersectionObserver(es => {
      if (!es[0].isIntersecting) return;
      auto.disconnect();
      setTimeout(() => { if (state === 'off') connect(); }, 900);
    }, { threshold: 0.5 });
    auto.observe(vpn);
  }

  // ---------- сеть точек на первом экране ----------
  const cv = $('.hero-net');
  if (cv && !reduce && cv.getContext) {
    const ctx = cv.getContext('2d');
    const mouse = { x: -1e4, y: -1e4 };
    let w = 0, h = 0, dots = [], raf = 0, visible = true;
    const resize = () => {
      const dpr = Math.min(devicePixelRatio || 1, 2);
      w = cv.clientWidth; h = cv.clientHeight;
      cv.width = w * dpr; cv.height = h * dpr;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      const n = Math.min(70, Math.round(w * h / 16000));
      dots = Array.from({ length: n }, () => ({
        x: Math.random() * w, y: Math.random() * h,
        vx: (Math.random() - 0.5) * 0.3, vy: (Math.random() - 0.5) * 0.3,
      }));
    };
    const frame = () => {
      ctx.clearRect(0, 0, w, h);
      for (const d of dots) {
        d.x += d.vx; d.y += d.vy;
        if (d.x < 0 || d.x > w) d.vx *= -1;
        if (d.y < 0 || d.y > h) d.vy *= -1;
      }
      for (let i = 0; i < dots.length; i++) {
        const a = dots[i];
        for (let j = i + 1; j < dots.length; j++) {
          const b = dots[j], dist = Math.hypot(a.x - b.x, a.y - b.y);
          if (dist < 130) {
            ctx.strokeStyle = `rgba(140,160,255,${(1 - dist / 130) * 0.22})`;
            ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y); ctx.stroke();
          }
        }
        const md = Math.hypot(a.x - mouse.x, a.y - mouse.y);
        if (md < 180) {
          ctx.strokeStyle = `rgba(190,140,255,${(1 - md / 180) * 0.5})`;
          ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.lineTo(mouse.x, mouse.y); ctx.stroke();
        }
        ctx.fillStyle = 'rgba(170,185,255,0.7)';
        ctx.beginPath(); ctx.arc(a.x, a.y, 1.4, 0, Math.PI * 2); ctx.fill();
      }
      raf = requestAnimationFrame(frame);
    };
    const run = () => { cancelAnimationFrame(raf); if (visible && !document.hidden) raf = requestAnimationFrame(frame); };
    resize();
    addEventListener('resize', () => { resize(); });
    const hero = cv.parentElement;
    hero.addEventListener('pointermove', e => {
      const r = cv.getBoundingClientRect();
      mouse.x = e.clientX - r.left; mouse.y = e.clientY - r.top;
    });
    hero.addEventListener('pointerleave', () => { mouse.x = mouse.y = -1e4; });
    new IntersectionObserver(es => { visible = es[0].isIntersecting; run(); }).observe(hero);
    document.addEventListener('visibilitychange', run);
  }

  // ---------- вопросы: открыт только один ----------
  $$('.faq details').forEach(d => d.addEventListener('toggle', () => {
    if (d.open) $$('.faq details').forEach(o => { if (o !== d) o.open = false; });
  }));

  // ---------- кабинет: копирование и увеличение QR ----------
  $$('[data-copy]').forEach(b => b.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(b.dataset.copy);
      toast('Ключ скопирован. Вставьте его в приложение.');
    } catch (e) {
      toast('Не удалось скопировать. Выделите ссылку вручную.');
    }
  }));
  $$('img[data-zoom]').forEach(img => img.addEventListener('click', () => {
    const box = document.createElement('div');
    box.className = 'lightbox';
    box.innerHTML = `<img src="${img.src}" alt="${img.alt}">`;
    const close = () => { box.classList.remove('show'); setTimeout(() => box.remove(), 300); removeEventListener('keydown', esc); };
    const esc = e => { if (e.key === 'Escape') close(); };
    box.addEventListener('click', close);
    addEventListener('keydown', esc);
    document.body.append(box);
    requestAnimationFrame(() => box.classList.add('show'));
  }));

  // ---------- формы ----------
  const eyeOpen = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M2.5 12S6 5 12 5s9.5 7 9.5 7-3.5 7-9.5 7-9.5-7-9.5-7Z"/><circle cx="12" cy="12" r="3"/></svg>';
  const eyeOff = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M3 3l18 18M10.6 5.1A10.4 10.4 0 0 1 12 5c6 0 9.5 7 9.5 7a17 17 0 0 1-3 3.9M6.6 6.6A16.6 16.6 0 0 0 2.5 12S6 19 12 19a9.6 9.6 0 0 0 5.4-1.6M9.9 9.9a3 3 0 0 0 4.2 4.2"/></svg>';
  $$('.field input[type=password]').forEach(input => {
    const field = input.parentElement;
    const b = document.createElement('button');
    b.type = 'button'; b.className = 'eye'; b.innerHTML = eyeOpen;
    b.setAttribute('aria-label', 'Показать пароль');
    b.addEventListener('click', () => {
      const show = input.type === 'password';
      input.type = show ? 'text' : 'password';
      b.innerHTML = show ? eyeOff : eyeOpen;
      b.setAttribute('aria-label', show ? 'Скрыть пароль' : 'Показать пароль');
      input.focus();
    });
    field.classList.add('has-eye');
    field.append(b);
  });

  const meter = $('.meter'), pw = $('#password'), pw2 = $('#password2');
  if (meter && pw) {
    const labels = ['', 'Слабый пароль', 'Средний пароль', 'Хороший пароль', 'Надёжный пароль'];
    pw.addEventListener('input', () => {
      const v = pw.value;
      let s = 0;
      if (v.length >= 8) s++;
      if (v.length >= 12) s++;
      if (/[a-zа-яё]/.test(v) && /[A-ZА-ЯЁ]/.test(v)) s++;
      if (/\d/.test(v) && /[^\wа-яё]/i.test(v)) s++;
      if (v && v.length < 8) s = 1;
      meter.dataset.score = v ? Math.max(1, s) : 0;
      $('.meter-label', meter).textContent = v ? labels[Math.max(1, s)] : '';
    });
  }
  if (pw && pw2) {
    const check = () => {
      const f = pw2.parentElement;
      f.classList.toggle('ok', !!pw2.value && pw2.value === pw.value);
      f.classList.toggle('bad', !!pw2.value && pw2.value !== pw.value && pw2.value.length >= pw.value.length);
    };
    pw.addEventListener('input', check);
    pw2.addEventListener('input', check);
  }

  // Индикатор загрузки на кнопке, если форма уходит на сервер обычным способом
  document.addEventListener('submit', e => {
    const btn = e.target.querySelector('button[type=submit]:not(.linklike)');
    if (btn) setTimeout(() => { if (!e.defaultPrevented) btn.classList.add('loading'); });
  });
  addEventListener('pageshow', () => $$('.btn.loading').forEach(b => b.classList.remove('loading')));
})();
