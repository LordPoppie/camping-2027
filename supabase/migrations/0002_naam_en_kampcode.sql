-- Inloggen op naam + zelfgekozen kampcode (4 cijfers) in plaats van e-mail.
-- Vrienden hebben geen Supabase-account: alles loopt via de functies hieronder, met een
-- sessietoken in de browser. De tabellen zelf zijn voor niemand direct leesbaar.
-- De organisatie logt nog wel in met e-mail (camping_organizers) voor het volledige overzicht.

drop trigger if exists camping_on_auth_user_email on auth.users;
drop function if exists public.camping_tg_profile();
drop table if exists public.camping_profiles;
drop table if exists public.camping_responses;
drop table if exists public.camping_guests;

-- ───────────────────────── Tabellen ─────────────────────────

create table public.camping_members (
  id              uuid primary key default gen_random_uuid(),
  name            text not null check (char_length(btrim(name)) between 1 and 40),
  pin_hash        text not null,
  failed_attempts int not null default 0,
  locked_until    timestamptz,
  created_at      timestamptz not null default now()
);
create unique index camping_members_name_key on public.camping_members (lower(btrim(name)));

create table public.camping_sessions (
  token_hash text primary key,
  member_id  uuid not null references public.camping_members on delete cascade,
  created_at timestamptz not null default now()
);

-- De gastenkaart. `names` en `going` staan los zodat de gastenlijst ze kan tonen zonder de rest.
create table public.camping_responses (
  member_id  uuid primary key references public.camping_members on delete cascade,
  data       jsonb not null default '{}'::jsonb check (jsonb_typeof(data) = 'object' and pg_column_size(data) < 32000),
  names      text[] not null default '{}' check (cardinality(names) <= 12),
  going      text check (going in ('ja', 'misschien', 'nee')),
  updated_at timestamptz not null default now()
);
create trigger camping_responses_touch before insert or update on public.camping_responses
  for each row execute function public.camping_tg_touch();

alter table public.camping_members   enable row level security;
alter table public.camping_sessions  enable row level security;
alter table public.camping_responses enable row level security;
revoke all on public.camping_members, public.camping_sessions, public.camping_responses from anon, authenticated;

-- ───────────────────────── Functies ─────────────────────────

create function public.camping_member_from_token(p_token text) returns uuid
language sql stable security definer set search_path = ''
as $$
  select member_id from public.camping_sessions
  where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex')
$$;

-- status: ok | unknown (naam bestaat nog niet, p_create = false) | wrong_pin | locked | bad_pin | bad_name
create function public.camping_login(p_name text, p_pin text, p_create boolean default false) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  m public.camping_members;
  v_token text;
begin
  if coalesce(p_pin, '') !~ '^[0-9]{4}$' then return jsonb_build_object('status', 'bad_pin'); end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 1 and 40 then return jsonb_build_object('status', 'bad_name'); end if;

  select * into m from public.camping_members where lower(btrim(name)) = lower(btrim(p_name)) for update;
  if not found then
    if not p_create then return jsonb_build_object('status', 'unknown'); end if;
    insert into public.camping_members (name, pin_hash)
    values (btrim(p_name), extensions.crypt(p_pin, extensions.gen_salt('bf')))
    returning * into m;
  else
    if m.locked_until is not null and m.locked_until > now() then
      return jsonb_build_object('status', 'locked');
    end if;
    if m.pin_hash <> extensions.crypt(p_pin, m.pin_hash) then
      update public.camping_members
      set failed_attempts = failed_attempts + 1,
          locked_until = case when failed_attempts + 1 >= 5 then now() + interval '15 minutes' end
      where id = m.id;
      return jsonb_build_object('status', 'wrong_pin');
    end if;
    update public.camping_members set failed_attempts = 0, locked_until = null where id = m.id;
  end if;

  v_token := encode(extensions.gen_random_bytes(24), 'hex');
  insert into public.camping_sessions (token_hash, member_id)
  values (encode(extensions.digest(v_token, 'sha256'), 'hex'), m.id);
  return jsonb_build_object('status', 'ok', 'token', v_token, 'member_id', m.id, 'name', m.name);
end $$;

create function public.camping_logout(p_token text) returns void
language sql security definer set search_path = ''
as $$ delete from public.camping_sessions where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex') $$;

-- Wie ben ik, en mijn eigen kaart (null als het token niet geldig is).
create function public.camping_me(p_token text) returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object('member_id', m.id, 'name', m.name, 'data', r.data, 'updated_at', r.updated_at)
  from public.camping_members m
  left join public.camping_responses r on r.member_id = m.id
  where m.id = public.camping_member_from_token(p_token)
$$;

create function public.camping_save(p_token text, p_data jsonb, p_names text[], p_going text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_member uuid := public.camping_member_from_token(p_token);
begin
  if v_member is null then return jsonb_build_object('status', 'not_logged_in'); end if;
  insert into public.camping_responses (member_id, data, names, going)
  values (v_member, p_data, p_names, p_going)
  on conflict (member_id) do update set data = excluded.data, names = excluded.names, going = excluded.going;
  return jsonb_build_object('status', 'ok');
end $$;

-- Gastenlijst voor ingelogde vrienden: alleen namen van wie meegaat of twijfelt.
create function public.camping_guest_list(p_token text) returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('member_id', r.member_id, 'names', r.names, 'going', r.going, 'updated_at', r.updated_at) order by r.updated_at), '[]'::jsonb)
  from public.camping_responses r
  where public.camping_member_from_token(p_token) is not null
    and r.going in ('ja', 'misschien')
$$;

-- Volledig overzicht, alleen voor de organisatie (ingelogd met e-mail).
create function public.camping_admin_responses() returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('member_id', m.id, 'login_name', m.name, 'data', r.data, 'updated_at', r.updated_at) order by r.updated_at), '[]'::jsonb)
  from public.camping_responses r
  join public.camping_members m on m.id = r.member_id
  where public.camping_is_organizer()
$$;

-- Vergeten kampcode: de organisatie zet een nieuwe.
create function public.camping_admin_reset_pin(p_name text, p_pin text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.camping_is_organizer() then return jsonb_build_object('status', 'not_allowed'); end if;
  if coalesce(p_pin, '') !~ '^[0-9]{4}$' then return jsonb_build_object('status', 'bad_pin'); end if;
  update public.camping_members
  set pin_hash = extensions.crypt(p_pin, extensions.gen_salt('bf')), failed_attempts = 0, locked_until = null
  where lower(btrim(name)) = lower(btrim(p_name));
  if not found then return jsonb_build_object('status', 'unknown'); end if;
  delete from public.camping_sessions s using public.camping_members m
  where s.member_id = m.id and lower(btrim(m.name)) = lower(btrim(p_name));
  return jsonb_build_object('status', 'ok');
end $$;

revoke execute on function public.camping_member_from_token(text)               from public, anon, authenticated;
revoke execute on function public.camping_login(text, text, boolean)            from public;
revoke execute on function public.camping_logout(text)                          from public;
revoke execute on function public.camping_me(text)                              from public;
revoke execute on function public.camping_save(text, jsonb, text[], text)       from public;
revoke execute on function public.camping_guest_list(text)                      from public;
revoke execute on function public.camping_admin_responses()                     from public, anon;
revoke execute on function public.camping_admin_reset_pin(text, text)           from public, anon;
grant  execute on function public.camping_login(text, text, boolean)            to anon, authenticated;
grant  execute on function public.camping_logout(text)                          to anon, authenticated;
grant  execute on function public.camping_me(text)                              to anon, authenticated;
grant  execute on function public.camping_save(text, jsonb, text[], text)       to anon, authenticated;
grant  execute on function public.camping_guest_list(text)                      to anon, authenticated;
grant  execute on function public.camping_admin_responses()                     to authenticated;
grant  execute on function public.camping_admin_reset_pin(text, text)           to authenticated;
