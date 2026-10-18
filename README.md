# Camping De Gouden Baguette 🏕️

Inschrijfsite voor de campingvakantie van 2027. Vrienden checken in met hun naam en een zelfgekozen kampcode van 4 cijfers (geen e-mail nodig), vullen een gastenkaart in (wie, hoe lang, hoe ver, Nederland of buitenland, kamperen of huisje, verblijf, wensen, weken) en zien op het prikbord wie er meegaat. Het volledige overzicht met alle antwoorden ziet alleen de organisatie, die daarvoor apart inlogt met e-mail (Organisatie-login onderaan de pagina).

- **Site:** `web/` — statisch, geen build-stap. Zonder ingevulde `config.js` draait hij in demo-modus (localStorage, jij bent dan de organisatie).
- **Backend:** Supabase — `supabase/migrations/` (0001 basis, 0002 inchecken met naam + kampcode). Vrienden hebben geen Supabase-account; alles loopt via `camping_*`-functies met een sessietoken.
- **Hosting:** GitHub Pages via `.github/workflows/pages.yml` bij elke push naar `main`.

## Lokaal draaien
    python3 -m http.server 5179 --directory web

## Supabase inrichten
Draait in het project "It's Growing"; alle tabellen en functies heten `camping_*`. Voor een ander project:
1. Voer de migraties in `supabase/migrations/` op volgorde uit (SQL editor of `supabase db push`).
2. **Authentication → URL Configuration → Redirect URLs:** voeg het GitHub Pages-adres toe (`https://lordpoppie.github.io/camping-2027/**`), plus `http://localhost:5179/**` voor lokaal testen. Alleen nodig voor de organisatie-login.
3. Vul `web/config.js` met de project-URL en de publishable key.
4. Maak jezelf organisator (je account moet al bestaan in Authentication → Users):

       insert into public.camping_organizers (user_id)
       select id from auth.users where email = 'jouw@adres.nl';

## Kampcode vergeten
Na 5 verkeerde pogingen staat een naam een kwartier op slot. Een nieuwe code zetten (als organisator, of in de SQL editor):

    select public.camping_admin_reset_pin('Toos', '1234');

In de SQL editor werkt dit niet (geen ingelogde organisator); gebruik daar:

    update public.camping_members set pin_hash = extensions.crypt('1234', extensions.gen_salt('bf')), failed_attempts = 0, locked_until = null
    where lower(btrim(name)) = lower('Toos');

## Wie ziet wat
| | ingelogde vriend | organisatie |
|---|---|---|
| Wie er meegaat of twijfelt (namen) | ✓ | ✓ |
| Eigen kaart | ✓ | ✓ |
| Kaarten van anderen | – | ✓ |

Iedereen met de link kan zich inschrijven met een nieuwe naam. Een bestaande kaart openen kan alleen met de bijbehorende kampcode.
