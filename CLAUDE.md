# Firstbox app

Internal software for Firstbox (custom rigid boxes, mono cartons, printing). Owner: Raj Wadhwa, who is not a programmer:
explain changes in plain words, never ask him to run commands, and test before pushing.

## What it does
- **Costings**: manufacturing cost vs quoted price per order, worked out from saved rates (paper, mill board, printing, lamination, foiling, spot UV, die cutting, accessories, making).
- **Job cards**: internal instructions per order, with a master sheet and one sheet per team (designer, printing, fabrication, die, box making). PDF download.
- **Stock & procurement**: materials list; each job card takes its materials out of stock automatically (and puts them back when deleted); "To buy" list.
- **Settings ⚙**: Rate list, Price history, Team & access.

## Where things are
- `web/firstbox.html` — **the whole page** (UI + logic, plain JS, no framework). Edit this file for almost every change.
  It is the same page that first ran inside Claude as an artifact, and still runs there unchanged.
- `web/firstbox-cloud.js` — makes the page work outside Claude: provides `window.claude.use('db' | 'user' | 'downloads')`
  on top of Supabase, plus the sign-in screen. Collections `team` and `requests` are mapped onto the `members` table.
- `web/index.html` — generated from `web/firstbox.html` by `python3 tools/make-index.py` (adds the script tags). Regenerate after editing; CI also regenerates it.
- `web/config.js` — Supabase project URL and publishable key (public by design; access is enforced by the database rules).
- `supabase/setup.sql` — tables `docs` (col, id, data jsonb) and `members` (role: owner / inventory / jobcards / pending / removed), row-level security, realtime. Re-runnable.
- `electron/` — the Mac/Windows app shell. Loads the online page (`electron/app-config.json` → `uiUrl`) when reachable, else the built-in `web/` copy. Saves PDFs to `Documents/Firstbox/Job cards/<job card no.>/`.
- `.github/workflows/build.yml` — push to `main` publishes the page (GitHub Pages, when the repo is public); push a tag `vX.Y.Z` builds the Mac (.dmg) and Windows (.exe) installers into a GitHub release.

## Roles (enforced in `supabase/setup.sql`, mirrored in the page's `ROLES`)
- owner: everything. The first account ever created becomes the owner (Raj, signs in with his email).
- Team logins are created by the owner on ⚙ › Team & access (username + password, shown once with "Copy for WhatsApp").
  Behind the scenes a username is the Supabase login `<username>@firstbox.local`; SQL functions `create_member`,
  `set_member_password`, `delete_member` (owner only) in `supabase/team-logins.sql`. Self sign-up is switched off in Supabase.
- inventory: reads job cards/stock, writes stock + stockLog only.
- jobcards: reads/writes job cards, stock, stockLog. Cannot delete job cards.
- Costings (`jobs`), `rates`, `rateHistory`, `config`: owner only. `shared/lists` (paper names, lamination divisors): owner writes, staff read.

## Data model notes
- Everything the page stores is a JSON document at `collection/id` (e.g. `jobcards/CO-102`, `stock/<id>`, `config/defaults`).
- Job card numbers: series CO (complete order) / JW (job work); CO starts at 102.
- Calculation rules Raj gave (keep them): paper sheet cost = L × W (in) × GSM ÷ 1,550,000 × ₹/kg, 5 % wastage;
  mill board GSM = thickness × 660 grey / 680 white / 700 black; lamination kg = ΣL×W×sheets ÷ 1552 ÷ divisor (80 normal, 45 thermal, 30 velvet/anti-scratch), + 60 % labour;
  varnish L×W÷8 paise/sheet, hybrid ÷3.5; foil/emboss block ₹2000 + ₹0.70/up, min ₹4000; spot UV ₹1.50 / ₹3 crystal per sheet + ₹1000 positive;
  die ₹1500 each + cutting ₹1200 first 1000 sheets, ₹800 per further 1000 (on all printed sheets); magnets 2 per box if W > 170 mm else 1.

## Making a change
1. Edit `web/firstbox.html` (and `firstbox-cloud.js` only for data/login behaviour).
2. `python3 tools/make-index.py`
3. Test in a browser with a fake Supabase (see `tools/` notes) or against the real project.
4. Commit and push to `main` → page updates online for everyone.
5. While the repo is private, every change needs new installers: bump `version` in `package.json`, push to `main`,
   then run the workflow with publish ticked: `gh workflow run build.yml --ref main -f publish=true`
   (pushing tags from Claude sessions may be refused). The release appears under Releases.
6. Database rule changes: update `supabase/setup.sql` and give Raj the SQL to paste into Supabase › SQL Editor.
