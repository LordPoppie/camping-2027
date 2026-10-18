# Camping De Gouden Baguette 🏕️

Inschrijfsite voor de campingvakantie van 2027. Vrienden loggen in met hun e-mail (link of 6-cijferige code), vullen een gastenkaart in (wie, hoe lang, hoe ver, Nederland of buitenland, kamperen of huisje, verblijf, wensen, weken) en zien op het prikbord wie er meegaat. Het volledige overzicht met alle antwoorden en e-mailadressen ziet alleen de organisatie.

- **Site:** `web/` — statisch, geen build-stap. Zonder ingevulde `config.js` draait hij in demo-modus (localStorage, jij bent dan de organisatie).
- **Backend:** Supabase — `supabase/migrations/0001_init.sql` (tabellen, toegangsregels, live bijwerken).
- **Hosting:** GitHub Pages via `.github/workflows/pages.yml` bij elke push naar `main`.

## Lokaal draaien
    python3 -m http.server 5179 --directory web

## Supabase inrichten
1. Draait nu in het project "It's Growing" (alle tabellen heten `camping_*`). Voor een ander project: voer `supabase/migrations/0001_init.sql` uit, via de SQL editor of `supabase db push`.
2. **Authentication → URL Configuration:** zet de *Site URL* op het GitHub Pages-adres (bv. `https://lordpoppie.github.io/camping-2027/`) en voeg dat adres ook toe aan *Redirect URLs*. Voeg `http://localhost:5179/` toe om lokaal te testen.
3. De inlogmail bevat alleen een link. Een eigen mailtekst met 6-cijferige code kan pas met een eigen SMTP-server (Authentication → SMTP Settings) of een betaald plan; zet dan `{{ .Token }}` in de Magic Link-template en `SHOW_CODE` in `web/index.html` op `true`.
4. Vul `web/config.js` met de project-URL en de publishable key (Project Settings → API Keys).
5. Log één keer zelf in op de site en maak jezelf organisator:

       insert into public.camping_organizers (user_id)
       select id from auth.users where email = 'jouw@adres.nl';

## Wie ziet wat
| | ingelogde vriend | organisatie |
|---|---|---|
| Wie er meegaat (namen) | ✓ | ✓ |
| Eigen kaart | ✓ | ✓ |
| Kaarten van anderen | – | ✓ |
| E-mailadressen | alleen eigen | ✓ |

Iedereen met de link kan een account aanmaken. Wil je dat niet, zet dan in Supabase *Allow new users to sign up* uit en nodig mensen uit via Authentication → Users → Invite.
