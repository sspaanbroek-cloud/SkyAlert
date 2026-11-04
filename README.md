# Overflight

Predicts when aircraft will pass over a photographer's shooting spot and says,
in plain language, whether they'll be visible or hidden by cloud.

Stack: Supabase (Postgres + PostGIS, Auth, auto REST API). Front end: TBD.

## Layout

```
supabase/
  config.toml        Supabase CLI project config
  migrations/        schema, in order
    …_extensions.sql   PostGIS + pgcrypto in the `extensions` schema
    …_core_schema.sql  tables, indexes, cloud-layer trigger
    …_auth_rls.sql     row-level security + grants
  seed.sql           dev data (aircraft types, two Seattle airports)
  tests/             pgTAP tests (`supabase test db`)
db-test/             run migrations + tests on plain local Postgres, no Docker
```

## Running

With Docker:

```bash
supabase start        # local stack, applies migrations + seed
supabase test db      # pgTAP tests
```

Without Docker (needs Postgres 16+, PostGIS 3, pgTAP installed locally):

```bash
./db-test/run.sh
```

Deploy to a hosted project: `supabase link --project-ref <ref>` then `supabase db push`.

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

## Status

Phase 1, step 1 (schema + auth) done. Next: shooting-spot UI, then METAR ingest.
`taf_forecast` and `high_cloud_estimate` are deferred to phase 2.
