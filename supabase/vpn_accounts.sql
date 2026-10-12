-- Аккаунты для статической версии сайта (GitHub Pages) в Supabase.
-- Уже применено к проекту dnwubeyihrorwzlfxfsn (миграция vpn_site_accounts).
-- Таблицы лежат в схеме vpn, она закрыта для API; сайт работает только через функции vpn_*.
create schema if not exists vpn;
revoke all on schema vpn from public, anon, authenticated;

create table vpn.users (
  id bigint generated always as identity primary key,
  email text not null unique check (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' and length(email) <= 200),
  pw_hash text not null,
  created_at timestamptz not null default now(),
  paid_until timestamptz,
  blocked boolean not null default false
);
create table vpn.sessions (
  token text primary key,
  user_id bigint not null references vpn.users(id) on delete cascade,
  expires_at timestamptz not null
);
create index on vpn.sessions(user_id);
create table vpn.attempts (
  key text not null,
  at timestamptz not null default now()
);
create index on vpn.attempts(key, at);
alter table vpn.users enable row level security;
alter table vpn.sessions enable row level security;
alter table vpn.attempts enable row level security;

-- Не больше lim попыток за 10 минут на ключ (почта или "reg")
create or replace function vpn.throttle(k text, lim int default 10)
returns void language plpgsql security definer set search_path = '' as $$
begin
  delete from vpn.attempts where at < now() - interval '1 hour';
  if (select count(*) from vpn.attempts where key = k and at > now() - interval '10 minutes') >= lim then
    raise exception 'too_many_attempts';
  end if;
  insert into vpn.attempts(key) values (k);
end $$;

create or replace function vpn.new_session(uid bigint)
returns text language plpgsql security definer set search_path = '' as $$
declare t text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  delete from vpn.sessions where expires_at < now();
  insert into vpn.sessions(token, user_id, expires_at) values (t, uid, now() + interval '30 days');
  return t;
end $$;

create or replace function public.vpn_register(p_email text, p_password text)
returns text language plpgsql security definer set search_path = '' as $$
declare e text := lower(trim(p_email)); uid bigint;
begin
  perform vpn.throttle('reg', 30);
  if length(coalesce(p_password, '')) < 8 or length(p_password) > 200 then
    raise exception 'weak_password';
  end if;
  if e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(e) > 200 then
    raise exception 'bad_email';
  end if;
  begin
    insert into vpn.users(email, pw_hash)
    values (e, extensions.crypt(p_password, extensions.gen_salt('bf', 10)))
    returning id into uid;
  exception when unique_violation then
    raise exception 'email_taken';
  end;
  return vpn.new_session(uid);
end $$;

create or replace function public.vpn_login(p_email text, p_password text)
returns text language plpgsql security definer set search_path = '' as $$
declare e text := lower(trim(p_email)); u vpn.users;
begin
  perform vpn.throttle('login:' || e);
  select * into u from vpn.users where email = e;
  if u.id is null or u.pw_hash <> extensions.crypt(coalesce(p_password, ''), u.pw_hash) then
    raise exception 'bad_credentials';
  end if;
  if u.blocked then raise exception 'blocked'; end if;
  return vpn.new_session(u.id);
end $$;

create or replace function public.vpn_me(p_token text)
returns table(email text, created_at timestamptz, paid_until timestamptz)
language sql security definer set search_path = '' as $$
  select u.email, u.created_at, u.paid_until
  from vpn.sessions s join vpn.users u on u.id = s.user_id
  where s.token = p_token and s.expires_at > now() and not u.blocked;
$$;

create or replace function public.vpn_logout(p_token text)
returns void language sql security definer set search_path = '' as $$
  delete from vpn.sessions where token = p_token;
$$;

revoke all on function vpn.throttle(text, int), vpn.new_session(bigint) from public, anon, authenticated;
revoke all on function public.vpn_register(text, text), public.vpn_login(text, text),
  public.vpn_me(text), public.vpn_logout(text) from public;
grant execute on function public.vpn_register(text, text), public.vpn_login(text, text),
  public.vpn_me(text), public.vpn_logout(text) to anon, authenticated;
