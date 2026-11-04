# SkyAlert

Predicts when aircraft will pass over a photographer's shooting spot and says,
in plain language, whether they'll be visible or hidden by cloud.

Stack: Supabase (Postgres + PostGIS, Auth, auto REST API) and a SvelteKit 3 /
Svelte 5 single-page app in `web/`.

## Layout

```
supabase/
  config.toml        Supabase CLI project config
  migrations/        schema, in order
    …_extensions.sql   PostGIS + pgcrypto in the `extensions` schema
    …_core_schema.sql  tables, indexes, cloud-layer trigger
    …_auth_rls.sql     row-level security + grants
    …_metar_ingest.sql ingest_metars(), sky_summary(), nearby_weather()
    …_schedules.sql    pg_cron jobs (METAR every 10 min, purges)
  functions/
    _shared/metar.ts   METAR parser (sky from raw text, numbers from AWC JSON)
    _shared/awc.ts     Aviation Weather Center client
    ingest-metar/      Edge Function: fetch around every spot, store
  seed.sql           dev data (aircraft types, two Seattle airports)
  tests/             pgTAP tests (`supabase test db`)
db-test/             run migrations + tests on plain local Postgres, no Docker
web/                 SvelteKit app (static SPA, talks to Supabase directly)
  src/lib/           supabase client, auth state, spot data layer, geo helpers
  src/lib/components SpotMap (Leaflet), SpotForm
  src/routes/        /login, / (spot list), /spots/new, /spots/[id]
  tests/             Playwright end-to-end tests (Supabase mocked in the browser)
```

## Running

With Docker:

```bash
supabase start        # local stack, applies migrations + seed
supabase test db      # pgTAP tests
```

Without Docker (needs Postgres 16+, PostGIS 3, pgTAP installed locally; if
Deno is installed it also runs a contract test that pushes TypeScript parser
output through the SQL ingest):

```bash
./db-test/run.sh
```

Edge Function tests (Deno, no network needed):

```bash
deno test supabase/functions
```

Web app:

```bash
cd web
cp .env.example .env.local   # fill in URL + anon key from `supabase status`
npm install
npm run dev                  # http://localhost:5173
npm test                     # unit tests (vitest)
npm run test:e2e             # Playwright, phone viewport, no backend needed
npm run build                # static site in web/build (SPA fallback: 200.html)
```

The build is plain static files; any static host works if it serves
`200.html` for unknown paths (Netlify does this automatically; for
Vercel/Cloudflare Pages add a rewrite to `/200.html`).

Deploy the database to a hosted project: `supabase link --project-ref <ref>` then `supabase db push`.

## Data model notes

- All positions are `geography(…, 4326)` with GiST indexes. Distances in the DB
  are metres; use `nm_to_m()` / `m_to_nm()`. `airport` and `spot` also expose
  generated `lat` / `lon` columns for the front end.
- Write a point through the REST API as EWKT: `"geog": "SRID=4326;POINT(lon lat)"`
  (longitude first).
- `cloud_cover` holds the plain-language meaning of FEW/SCT/BKN/OVC/VV.
  A trigger on `cloud_layer` always sets `base_msl_ft = base_agl_ft + station
  elevation`, copies the sky fractions, and writes a default `plain_label` if
  ingest doesn't supply one. `est_top_msl_ft` stays null unless a source
  (`pirep` / `model` / `satellite`) is recorded with it.
- `metar_observation.is_auto` and `sky_clear_code` (e.g. `CLR`) let the
  visibility logic set `high_cloud_caveat`: automated "clear" only means clear
  below about 12,000 ft.
- `overflight_prediction` rows are upserted on `(spot_id, pass_key)` as new
  data arrives. `basis = 'live_adsb'` requires `icao24`; `'filed_plan'`
  requires `flight_plan_id`.
- `visibility_assessment.clear_margin_ft` = lowest relevant cloud base (MSL)
  minus aircraft altitude: positive means the base is above the aircraft.
- `track_point.altitude_ft` is barometric altitude as broadcast;
  `geo_altitude_ft` is GNSS. `purge_track_points(interval)` trims old rows
  (to be scheduled with the ADS-B worker).

## Auth and access

- Supabase Auth (email sign-up enabled in `config.toml`).
- `spot` and `alert`: owner-only via RLS. `user_id` defaults to `auth.uid()`
  and cannot be changed after insert. Users can't set `alert.sent_at`.
- `overflight_prediction` / `visibility_assessment`: read-only, only for the
  caller's own spots.
- Airports, weather, flights and ADS-B data: readable by any signed-in user,
  written only by ingest workers using the `service_role` key.
- `anon` has no table access.

## Scheduled ingest (METAR)

`ingest-metar` runs every 10 minutes from pg_cron. Each run:

1. `metar_fetch_areas()` returns one bounding box per 1° grid cell that holds a
   spot, padded by the largest search radius there plus 30 nm.
2. Each box is fetched from `aviationweather.gov/api/data/metar` (2 hours of
   history, so SPECIs between hourly reports are caught).
3. Reports are parsed. Cloud layers come from the raw text (it's the source
   of truth and the only place CB/TCU appear); remarks and TEMPO/BECMG trend
   groups are ignored, and layers with unknown height (`BKN///`) are dropped.
4. `ingest_metars()` stores them: station upserted into `airport` (elevation
   converted from metres), observation upserted, cloud layers replaced, MSL
   bases and plain labels filled by trigger. Identical re-sends are no-ops;
   corrections replace the old report. A bad report is rejected on its own.

The function returns a JSON summary (areas, fetched, stored, unchanged,
rejections, fetch errors). Observations older than 3 days are purged nightly.

One-time setup on a hosted project:

```bash
supabase functions deploy ingest-metar
supabase secrets set INGEST_SECRET="$(openssl rand -hex 32)"
```

Then in the SQL editor (use the same secret value):

```sql
select vault.create_secret('https://<project-ref>.supabase.co', 'project_url');
select vault.create_secret('<the INGEST_SECRET value>', 'ingest_secret');
```

Run it by hand to check:

```bash
curl -X POST -H "x-ingest-secret: <secret>" https://<project-ref>.supabase.co/functions/v1/ingest-metar
```

Locally, use `http://host.docker.internal:54321` as `project_url` and run
`supabase functions serve --env-file supabase/functions/.env` with
`INGEST_SECRET=...` in that file.

Plain-language sky text (`sky_summary()`), examples:

- `A few wisps at 2,500 ft above ground, then mostly cloudy with gaps at 6,000 ft above ground`
- `Scattered clouds at 3,500 ft above ground (thunderstorm clouds). Automated station: it can't see cloud above 12,000 ft`
- `No cloud below 12,000 ft (automated sensor; it can't see higher)` (for `AUTO … CLR`)

## Web app notes

- Sign-in is email + password via Supabase Auth. If email confirmation is on
  (the default on hosted projects), sign-up shows "check your email".
- The spot form: tap the map, drag the pin, "Use my location", or type
  `lat, lon`. Ground elevation is looked up from the Open-Meteo elevation API
  (free, no key) and can be overridden for rooftops; a typed value is never
  overwritten when the pin moves.
- The map uses OpenStreetMap tiles by default. OSM's tile policy doesn't allow
  heavy production use, so set `VITE_MAP_TILE_URL` to a provider (MapTiler,
  Stadia, etc.) before launch.
- Each spot's page shows "Sky near this spot": the latest report from the 3
  nearest stations (`nearby_weather()`), with distance and direction, the
  plain-language summary, report age (flagged when over 90 minutes), and the
  raw METAR.
- `#lib/...` imports need the file extension (`#lib/geo.ts`): SvelteKit 3 uses
  Node subpath imports instead of the old `$lib` alias.

## Status

Phase 1 steps 1 (schema + auth), 2 (store a shooting spot) and 3 (METAR
ingest) done. Next: step 4, live ADS-B ingest and approach detection.
`taf_forecast` and `high_cloud_estimate` are deferred to phase 2.
