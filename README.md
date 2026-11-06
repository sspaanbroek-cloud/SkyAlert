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
    …_adsb.sql         ingest_track_points(), compute_live_predictions(), ADS-B schedule
    …_visibility.sql   rate_sky(), assess_visibility(), refresh_visibility_assessments()
    …_recurring.sql    sightings, recurring-flight detection, 'recurring' predictions
    …_taf.sql          TAF storage, rate_conditions(), rate_taf(), forecast-aware assess_visibility()
    …_model_cloud.sql  high_cloud_estimate, apply_model_cloud(), model-cloud schedule
    …_alerts.sql       push_subscription, spot alert settings, queue/claim/complete alerts
    …_routes.sql       nav_fix/airway_fix (NASR), resolve_route(), ingest_flight_plans(), plan predictions
  functions/
    _shared/metar.ts   METAR parser (sky from raw text, numbers from AWC JSON)
    _shared/awc.ts     Aviation Weather Center client
    _shared/taf.ts     TAF parser (AWC JSON change groups)
    _shared/opensky.ts OpenSky client (OAuth2 client credentials) + state-vector parser
    ingest-metar/      Edge Function: fetch around every spot, store
    _shared/openmeteo.ts Open-Meteo client (hourly low/mid/high cloud cover)
    ingest-adsb/       Edge Function: poll OpenSky, store positions, predict passes
    _shared/notify.ts  notification wording
    _shared/flightplan.ts the source-neutral flight-plan record
    ingest-model-cloud/ Edge Function: model cloud per spot cell, re-rate passes
    send-alerts/       Edge Function: queue, claim and deliver alerts by Web Push
  seed.sql           dev data (aircraft types, two Seattle airports)
  tests/             pgTAP tests (`supabase test db`)
db-test/             run migrations + tests on plain local Postgres, no Docker
tools/nasr/          FAA NASR CSV -> nav_fix/airway_fix converter and loader
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

## Live ADS-B (OpenSky)

`ingest-adsb` runs every minute from pg_cron. Each run:

1. `adsb_fetch_areas()` returns one box per 1° grid cell holding spots,
   padded by the largest search radius plus 80 nm of lookahead (about 8 to 10
   minutes' warning for an airliner at cruise). Each box stays under 25 sq deg,
   which OpenSky charges at 1 credit.
2. `/states/all` is fetched per box. Positions are stored in `track_point`
   (altitudes m to ft, speed m/s to kt, vertical rate to ft/min).
3. `compute_live_predictions()` takes each aircraft's latest position (under
   2 minutes old) and projects it in a straight line along its track for up
   to 20 minutes. A pass is kept when the closest approach is ahead, within
   the spot's search radius, and at least the spot's minimum elevation angle.
   - Altitude: GNSS altitude when reported, else barometric. Vertical rate is
     extrapolated for at most 5 minutes.
   - Elevation angle includes Earth curvature with standard refraction.
   - Confidence (0 to 1) falls with lookahead time, report age and climbing
     or descending.
   - The same pass is updated each minute, not duplicated. A future pass the
     aircraft no longer heads for is removed, but not while the aircraft is
     inside the radius within 2 minutes of its closest approach.
   - Past passes are kept 2 days; track points 2 hours.

Straight-line projection doesn't know about turns, so treat passes more than
a few minutes out as "likely", which is what the confidence label shows.
OpenSky state vectors carry no aircraft type, so `aircraft_type` stays empty
for live passes.

**Credit budget.** OpenSky gives a free account about 4,000 credits a day
(anonymous about 400). One area polled every minute uses about 1,440 a day,
so a free account covers two areas (spots in two different 1° cells) at
this rate. For more areas, or anonymous use, slow the schedule:

```sql
select cron.alter_job((select jobid from cron.job where jobname = 'ingest-adsb'), schedule := '*/3 * * * *');
```

The function's JSON response reports `credits_used`, `credits_remaining`
and whether OpenSky rate-limited the run.

Setup: create an API client in your OpenSky account (Account page, API
client), then:

```bash
supabase functions deploy ingest-adsb
```

```bash
supabase secrets set OPENSKY_CLIENT_ID=... OPENSKY_CLIENT_SECRET=...
```

OpenSky's API-client download is a `credentials.json` with `clientId` and
`clientSecret`; those are the two values. Never commit that file
(`credentials*.json` is git-ignored). It uses the same `INGEST_SECRET` and
Vault secrets as the METAR job.

## Visibility rating (clear / partial / hidden)

`refresh_visibility_assessments()` re-rates every pass from 5 minutes ago
onwards. Both workers call it: `ingest-adsb` after new positions,
`ingest-metar` after new weather.

Per pass:

1. Take the latest report (up to 2 hours old) from up to 3 stations within
   40 nm of the spot. The line of sight from the spot crosses low and mid
   cloud close to the spot, so the spot is the reference point.
2. `rate_sky()` compares each station's cloud bases (MSL = AGL + field
   elevation) with the aircraft's altitude. METAR cover is cumulative, so the
   largest cover among layers below the aircraft decides:

   | Below the aircraft | Rating |
   |---|---|
   | nothing, or cloud only above it | clear |
   | FEW (a few wisps) | clear |
   | SCT, BKN | partial (seen through gaps) |
   | OVC, VV | hidden |

   Visibility under 1 mile makes it hidden; under 3 miles turns clear into
   partial. Cloud tops are never assumed. Automated stations (AUTO, or
   CLR/NCD) can't see above 12,000 ft, so passes above that get
   `high_cloud_caveat` and say so.
3. Station ratings are blended, weighted by 1/distance² (distance floored at
   3 nm) and by report age (full weight to 60 min, 0.3 at 120 min). The
   sentence comes from the strongest station that agrees with the result; if
   others disagree, the explanation says conditions may be patchy.

Explanations give cloud heights above sea level, rounded to 100 ft, so they
compare directly with the aircraft's altitude. The app shows them as, for
example:

> **Partly visible** · ASA123, 33,000 ft, passes at 7:42 pm.
> Mostly cloudy at about 6,400 ft, so the aircraft will be above the clouds
> and visible only through gaps.

The thresholds live in `rate_sky()`. Note: the brief listed BKN under
"hidden" but its own example treats BKN as visible through gaps; this
follows the example.

## Recurring flights

Every 5 minutes `record_sightings()` logs each completed live pass (with a
callsign) in `flight_sighting` (kept 60 days). Nightly,
`detect_recurring_flights()` looks at the last 28 days per spot and callsign:

- local time of day comes from the spot's `time_zone` and is averaged on a
  circle, so 23:55 and 00:05 average to midnight;
- a flight is recurring when it was seen on at least 3 different days with a
  time spread (circular standard deviation) of 30 minutes or less;
- `days_of_week` lists the weekdays it was actually seen on, so a daily flight
  fills in as more days are observed.

Hourly, `refresh_recurring_predictions()` writes `basis = 'recurring'` passes
for the next 36 hours (flights seen in the last 14 days only), using the
flight's typical time, altitude, direction and distance. Confidence grows with
the number of days seen and a tighter time spread, capped at 0.8. When live
tracking picks the same callsign up within 45 minutes, the live pass replaces
the usual one. These passes get visibility ratings like any other, from the
TAF when they're more than an hour out (below).

## TAF forecasts

`ingest-metar` also fetches current TAFs for the same areas and stores them
with `ingest_tafs()` (`taf_forecast` + one `taf_period` per change group).
A TAF failure never blocks the METAR ingest.

For a pass more than 60 minutes out, `assess_visibility()` rates the TAFs
valid at the pass time from up to 3 stations within 40 nm (same blending as
METARs). `rate_taf()` builds the prevailing conditions at that time: BASE and
FM groups reset everything, BECMG groups that have started change only what
they mention. If a TEMPO or PROB group covering the pass is worse, a clear
rating becomes partial and the explanation adds "At times, though: ...".
Explanations start with "Forecast:". With no TAF in range, current METARs
are used and the explanation says conditions may change
(`weather_basis = 'metar_persistence'`). The cloud rules themselves live in
one place, `rate_conditions()`, shared by METARs and TAFs.

## High cloud (Open-Meteo)

Ground stations can't see cloud above 12,000 ft. Every hour
`ingest-model-cloud` fetches Open-Meteo's hourly cloud cover (HRRR/GFS
"best match") for each spot, rounded to a 0.1° cell, in one request per 100
cells, and stores it in `high_cloud_estimate` (kept to 6 hours in the past).

After each assessment, `apply_model_cloud()` refines the rating using the
forecast hour nearest the pass:

- aircraft at or above ~19,700 ft (6 km): the high band;
- aircraft between the station's 12,000 ft limit and 19,700 ft: the mid band,
  only when the rating came from an automated station;
- 70% or more: clear becomes partial ("may be dimmed or hidden at times");
  30 to 69%: a note; under 30%: "little high cloud", replacing the
  automated-station caveat.

The model never makes a pass hidden on its own, and hidden/unknown ratings
are left alone.

**Licence:** Open-Meteo's free API is for non-commercial use (CC BY 4.0,
attribution required). For commercial use, buy an API key and set it:

```bash
supabase secrets set OPEN_METEO_API_KEY=...
```

Requests then go to `customer-api.open-meteo.com`. Deploy with
`supabase functions deploy ingest-model-cloud`.

## Push alerts (Web Push)

- Each device turns notifications on from the home page; its subscription is
  saved with `save_push_subscription()` (a shared browser belongs to whoever
  subscribed on it last).
- Spots have alert settings: on/off, which ratings ("clear view only" or
  "clear or partly visible") and minutes ahead (default 10).
- `send-alerts` runs every minute:
  1. `queue_alerts()` queues an automatic alert for each live (or, later,
     filed-plan) pass in the next hour that meets the spot's rating with
     confidence of at least 0.5. Usual-flight passes are never alerted
     automatically: they aren't confirmed.
  2. `claim_due_alerts()` re-checks each due automatic alert and skips it if
     the pass is over or the rating has dropped; manual reminders always go.
  3. Each claimed alert goes to every device the user subscribed. Endpoints
     the push service reports gone (404/410) are deleted; 10 failures in a
     row also remove a subscription.
- "Remind me" on any pass (including usual flights hours ahead) sets a manual
  reminder at the spot's lead time. When live tracking takes over a usual
  flight, its reminders move to the live pass, keeping the same lead time.
- Notification text, for example: **ASA123 overhead in 6 min** /
  "Clear view · 33,000 ft · look NE, 62° up · at 7:42 pm" / "Kubota Garden".
  Tapping it opens that spot.
- iPhone/iPad: web push works only after "Add to Home Screen" (iOS 16.4+);
  the app says so. The manifest and icons for that are in `web/static`.

Setup:

```bash
npx web-push generate-vapid-keys
```

```bash
supabase secrets set VAPID_PUBLIC_KEY=... VAPID_PRIVATE_KEY=... VAPID_SUBJECT=mailto:you@example.com
```

```bash
supabase functions deploy send-alerts
```

Put the same public key in `web/.env.local` as `VITE_VAPID_PUBLIC_KEY`.

## Routes and filed flight plans

**Reference data (FAA NASR, every 28 days).** Download the CSV edition of the
28-day NASR subscription from the FAA
(https://www.faa.gov/air_traffic/flight_info/aeronav/aero_data/NASR_Subscription/),
unzip it, then:

```bash
deno run --allow-read --allow-write tools/nasr/convert.ts path/to/CSV_Data nasr-out 2026-10-30
```

```bash
DATABASE_URL='postgresql://...' tools/nasr/load.sh nasr-out
```

`convert.ts` reads `FIX_BASE.csv`, `NAV_BASE.csv`, `APT_BASE.csv` and
`AWY_BASE.csv` (the `AIRWAY_STRING` column lists each airway's fixes in
order). If FAA renames a column it stops and lists the columns it found.
`load.sh` replaces the previous cycle in one transaction. Those column names
follow FAA's documented CSV layout but haven't been checked against a live
download yet (it's blocked from the build sandbox); the first real run will
tell.

**Route resolution.** `resolve_route(route, origin, destination)` returns the
route's points:

- tokens split on spaces or dots (`KSEA..SEA.J70.LKV..KSFO` works);
- `DCT`, speed/level groups (`N0450F350`) and `/...` suffixes dropped;
- airways expanded between their entry and exit fixes, either direction;
- coordinates `4730N12216W`, `47N122W` and with seconds;
- an identifier with several candidates (OLM in Washington and Florida)
  resolves to the one nearest the previous point;
- SIDs/STARs (`SUMMA1`, `HAWKZ7`) can't be expanded without procedure data,
  so they're skipped and listed in the plan's `route_note`;
- an airport's 3-letter FAA id (SEA for KSEA) is treated as the airport only
  at the very start or end of the route and not right after an airway; mid-route
  it's the VOR.

**Ingest.** A plan source produces `FlightPlanInput` records
(`supabase/functions/_shared/flightplan.ts`) and calls
`ingest_flight_plans()`. That resolves the route, stores `route_geog` and the
waypoints, and estimates each waypoint's time and altitude: off the ground 15
minutes after the filed departure, the filed speed (420 kt if none), climbing
about 300 ft per nm, descending on a 3° path (318 ft per nm), never above the
filed cruise level. A plan's `route_status` is `resolved`, `partial` (some
tokens unknown) or `failed`.

**Predictions.** Every 10 minutes `compute_plan_predictions()` finds plans
departing from 6 hours ago to 12 hours ahead whose route passes within a
spot's radius, interpolates time and altitude at the closest point, and writes
`basis = 'filed_plan'` passes (confidence at most 0.5, lower further ahead).
When live tracking picks the flight up, the live pass replaces the plan pass
(alerts carried over) and the plan pass isn't re-created.

**Plan source: still to choose.** No adapter is wired up yet. FAA SWIM (SFDPS)
is free but needs approval and an always-on JMS consumer; FlightAware AeroAPI
is paid and immediate (its route endpoint also returns decoded fixes, which
could skip NASR resolution). Either only needs to emit `FlightPlanInput`.

## Text messages (SMS)

Two features share one Twilio account:

- **Sign in with a texted code** (Supabase phone auth). Enable it in Supabase:
  Authentication > Sign In / Providers > Phone, SMS provider Twilio, with the
  Account SID, Auth Token and Messaging Service SID. The login page's
  "Phone (text a code)" tab then works; email + password stays available.
- **Text alerts.** The number is the person's verified Supabase phone (from
  phone sign-in, or added from the home page with a texted code). People
  switch texts on with a consent box (`notification_pref`, consent time and
  wording stored). `send-alerts` sends each alert by push and/or text:
  plain-ASCII, at most 160 characters, "SkyAlert:" first and "Reply STOP to
  opt out." last; at most `SMS_DAILY_CAP` (default 20) texts per person per
  24 hours (`alert_delivery`). A Twilio 21610 error (the number replied STOP)
  pauses texts for that person until they tick the box again. Twilio's
  Messaging Service handles STOP/HELP replies itself.

Set `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_MESSAGING_SERVICE_SID`
(and optionally `SMS_DAILY_CAP`) as GitHub secrets and run Deploy backend.
Without them, texts are skipped and noted on each alert; push still works.
US carriers require A2P 10DLC (or toll-free) registration of the sender
before they deliver app texts reliably.

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
- Each spot's page also shows "Coming overhead": predicted passes from 2
  minutes ago onwards, with time, altitude, distance, where to look (compass
  direction and angle above the horizon) and confidence. It refreshes every
  30 seconds while the page is visible. Each pass carries its rating badge
  (Clear view / Partly visible / Hidden by cloud / Visibility unknown), the
  explanation, and which station's report it's based on and how old it is.
- Spots have a time zone (defaults to the browser's). Pass times show the
  day when it isn't today ("passes tomorrow at 7:10 am"), in that zone.
- "Regulars over this spot" lists recurring flights: usual time, days,
  altitude and direction, and how often they've been seen.
- `#lib/...` imports need the file extension (`#lib/geo.ts`): SvelteKit 3 uses
  Node subpath imports instead of the old `$lib` alias.

## Status

Phase 1 done: schema + auth, shooting spots, METAR ingest, live ADS-B
predictions, and the clear / partial / hidden rating per pass.

Phase 2: recurring flights, TAF forecasts, high cloud from Open-Meteo, web
push alerts, and NASR route resolution with the filed-plan pipeline are done.
Remaining: a flight-plan source adapter (FAA SWIM or FlightAware AeroAPI, to
be chosen).
`taf_forecast` and `high_cloud_estimate` are deferred to phase 2.
