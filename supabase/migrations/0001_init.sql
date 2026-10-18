-- Camping De Gouden Baguette: inschrijving voor de campingvakantie van 2027.
-- Iedereen die is ingelogd ziet wie er meegaat (guests). De ingevulde kaarten (responses)
-- en e-mailadressen (profiles) ziet alleen de organisatie (organizers) en de persoon zelf.

-- ───────────────────────── Tabellen ─────────────────────────

create table public.organizers (
  user_id    uuid primary key references auth.users on delete cascade,
  created_at timestamptz not null default now()
);

create table public.profiles (
  user_id    uuid primary key references auth.users on delete cascade,
  email      text not null,
  created_at timestamptz not null default now()
);

-- De volledige gastenkaart. `data` heeft dezelfde vorm als het formulier op de site.
create table public.responses (
  user_id    uuid primary key references auth.users on delete cascade default auth.uid(),
  data       jsonb not null default '{}'::jsonb check (jsonb_typeof(data) = 'object' and pg_column_size(data) < 32000),
  updated_at timestamptz not null default now()
);

-- Openbare gastenlijst: alleen namen en of ze meegaan.
create table public.guests (
  user_id    uuid primary key references auth.users on delete cascade default auth.uid(),
  names      text[] not null default '{}' check (cardinality(names) between 1 and 12),
  going      text not null check (going in ('ja', 'misschien', 'nee')),
  updated_at timestamptz not null default now()
);

-- ───────────────────────── Functies ─────────────────────────

create function public.is_organizer() returns boolean
language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.organizers where user_id = auth.uid()) $$;

create function public.tg_profile_from_user() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.email is not null then
    insert into public.profiles (user_id, email) values (new.id, new.email)
    on conflict (user_id) do update set email = excluded.email;
  end if;
  return new;
end $$;

create trigger on_auth_user_email
after insert or update of email on auth.users
for each row execute function public.tg_profile_from_user();

create function public.tg_touch() returns trigger
language plpgsql set search_path = ''
as $$ begin new.updated_at = now(); return new; end $$;

create trigger responses_touch before insert or update on public.responses for each row execute function public.tg_touch();
create trigger guests_touch    before insert or update on public.guests    for each row execute function public.tg_touch();

-- Bestaande accounts meenemen.
insert into public.profiles (user_id, email)
select id, email from auth.users where email is not null
on conflict (user_id) do nothing;

revoke execute on function public.tg_profile_from_user() from public, anon, authenticated;
revoke execute on function public.tg_touch()             from public, anon, authenticated;
revoke execute on function public.is_organizer()         from public, anon;
grant  execute on function public.is_organizer()         to authenticated;

-- ───────────────────────── Toegang ─────────────────────────

alter table public.organizers enable row level security;
alter table public.profiles   enable row level security;
alter table public.responses  enable row level security;
alter table public.guests     enable row level security;

create policy "zelf zien of organisatie" on public.organizers
  for select to authenticated using (user_id = auth.uid());

create policy "eigen adres of organisatie" on public.profiles
  for select to authenticated using (user_id = auth.uid() or public.is_organizer());

create policy "eigen kaart of organisatie" on public.responses
  for select to authenticated using (user_id = auth.uid() or public.is_organizer());
create policy "eigen kaart maken" on public.responses
  for insert to authenticated with check (user_id = auth.uid());
create policy "eigen kaart wijzigen" on public.responses
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "eigen kaart wissen" on public.responses
  for delete to authenticated using (user_id = auth.uid());

create policy "iedereen ziet wie meegaat" on public.guests
  for select to authenticated using (true);
create policy "eigen regel maken" on public.guests
  for insert to authenticated with check (user_id = auth.uid());
create policy "eigen regel wijzigen" on public.guests
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "eigen regel wissen" on public.guests
  for delete to authenticated using (user_id = auth.uid());

-- Live bijwerken van het prikbord.
alter publication supabase_realtime add table public.guests, public.responses;
