-- Camping De Gouden Baguette: inschrijving voor de campingvakantie van 2027.
-- Alles heeft het voorvoegsel camping_, zodat het naast andere apps in hetzelfde Supabase-project kan staan.
-- Iedereen die is ingelogd ziet wie er meegaat (camping_guests). De ingevulde kaarten (camping_responses)
-- en e-mailadressen (camping_profiles) ziet alleen de organisatie (camping_organizers) en de persoon zelf.

-- ───────────────────────── Tabellen ─────────────────────────

create table public.camping_organizers (
  user_id    uuid primary key references auth.users on delete cascade,
  created_at timestamptz not null default now()
);

create table public.camping_profiles (
  user_id    uuid primary key references auth.users on delete cascade,
  email      text not null,
  created_at timestamptz not null default now()
);

-- De volledige gastenkaart. `data` heeft dezelfde vorm als het formulier op de site.
create table public.camping_responses (
  user_id    uuid primary key references auth.users on delete cascade default auth.uid(),
  data       jsonb not null default '{}'::jsonb check (jsonb_typeof(data) = 'object' and pg_column_size(data) < 32000),
  updated_at timestamptz not null default now()
);

-- Openbare gastenlijst: alleen namen en of ze meegaan.
create table public.camping_guests (
  user_id    uuid primary key references auth.users on delete cascade default auth.uid(),
  names      text[] not null default '{}' check (cardinality(names) between 1 and 12),
  going      text not null check (going in ('ja', 'misschien', 'nee')),
  updated_at timestamptz not null default now()
);

-- ───────────────────────── Functies ─────────────────────────

create function public.camping_is_organizer() returns boolean
language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.camping_organizers where user_id = auth.uid()) $$;

create function public.camping_tg_profile() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.email is not null then
    insert into public.camping_profiles (user_id, email) values (new.id, new.email)
    on conflict (user_id) do update set email = excluded.email;
  end if;
  return new;
end $$;

create trigger camping_on_auth_user_email
after insert or update of email on auth.users
for each row execute function public.camping_tg_profile();

create function public.camping_tg_touch() returns trigger
language plpgsql set search_path = ''
as $$ begin new.updated_at = now(); return new; end $$;

create trigger camping_responses_touch before insert or update on public.camping_responses for each row execute function public.camping_tg_touch();
create trigger camping_guests_touch    before insert or update on public.camping_guests    for each row execute function public.camping_tg_touch();

-- Bestaande accounts meenemen.
insert into public.camping_profiles (user_id, email)
select id, email from auth.users where email is not null
on conflict (user_id) do nothing;

revoke execute on function public.camping_tg_profile() from public, anon, authenticated;
revoke execute on function public.camping_tg_touch()             from public, anon, authenticated;
revoke execute on function public.camping_is_organizer()         from public, anon;
grant  execute on function public.camping_is_organizer()         to authenticated;

-- ───────────────────────── Toegang ─────────────────────────

alter table public.camping_organizers enable row level security;
alter table public.camping_profiles   enable row level security;
alter table public.camping_responses  enable row level security;
alter table public.camping_guests     enable row level security;

create policy "zelf zien of organisatie" on public.camping_organizers
  for select to authenticated using (user_id = auth.uid());

create policy "eigen adres of organisatie" on public.camping_profiles
  for select to authenticated using (user_id = auth.uid() or public.camping_is_organizer());

create policy "eigen kaart of organisatie" on public.camping_responses
  for select to authenticated using (user_id = auth.uid() or public.camping_is_organizer());
create policy "eigen kaart maken" on public.camping_responses
  for insert to authenticated with check (user_id = auth.uid());
create policy "eigen kaart wijzigen" on public.camping_responses
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "eigen kaart wissen" on public.camping_responses
  for delete to authenticated using (user_id = auth.uid());

create policy "iedereen ziet wie meegaat" on public.camping_guests
  for select to authenticated using (true);
create policy "eigen regel maken" on public.camping_guests
  for insert to authenticated with check (user_id = auth.uid());
create policy "eigen regel wijzigen" on public.camping_guests
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "eigen regel wissen" on public.camping_guests
  for delete to authenticated using (user_id = auth.uid());

-- Live bijwerken van het prikbord.
alter publication supabase_realtime add table public.camping_guests, public.camping_responses;
