-- Core schema for SkyAlert.
-- All positions are geography(…, 4326) (lon/lat WGS84, distances in metres).
-- Altitudes are feet. Distances shown to users are nautical miles.
set search_path = public, extensions;

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------
create or replace function public.nm_to_m(nm numeric)
returns double precision language sql immutable parallel safe
set search_path = ''
as $$ select nm * 1852.0 $$;

create or replace function public.m_to_nm(m double precision)
returns double precision language sql immutable parallel safe
set search_path = ''
as $$ select m / 1852.0 $$;

create or replace function public.set_updated_at()
returns trigger language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end $$;

-------------------------------------------------------------------------------
-- Reference data
-------------------------------------------------------------------------------

-- Airports / weather stations. Rows are upserted by the METAR ingest from the
-- station metadata AWC returns, so every metar_observation has an elevation.
create table public.airport (
  icao          text primary key check (icao ~ '^[A-Z0-9]{3,4}$'),
  name          text,
  geog          geography(Point, 4326) not null,
  lat           double precision generated always as (st_y(geog::geometry)) stored,
  lon           double precision generated always as (st_x(geog::geometry)) stored,
  elevation_ft  integer not null,
  has_metar     boolean not null default true,
  updated_at    timestamptz not null default now()
);
create index airport_geog_gix on public.airport using gist (geog);

create table public.aircraft_type (
  icao_type          text primary key check (icao_type ~ '^[A-Z0-9]{2,4}$'),
  manufacturer       text,
  model              text not null,
  typical_cruise_ft  integer check (typical_cruise_ft between 0 and 60000)
);

-- METAR sky-cover codes and their plain-language meaning.
-- Fractions are of the sky covered by that layer.
create table public.cloud_cover (
  code              text primary key,
  plain_label       text not null,          -- "Mostly cloudy"
  sky_fraction_min  numeric(3,2) not null check (sky_fraction_min between 0 and 1),
  sky_fraction_max  numeric(3,2) not null check (sky_fraction_max between 0 and 1),
  is_solid          boolean not null,       -- BKN/OVC/VV: treat as hiding the aircraft
  check (sky_fraction_min <= sky_fraction_max)
);

insert into public.cloud_cover (code, plain_label, sky_fraction_min, sky_fraction_max, is_solid) values
  ('FEW', 'A few wisps',               0.10, 0.25, false),
  ('SCT', 'Scattered clouds',          0.30, 0.50, false),
  ('BKN', 'Mostly cloudy with gaps',   0.60, 0.90, true),
  ('OVC', 'Solid overcast',            1.00, 1.00, true),
  ('VV',  'Sky obscured (fog, haze or precipitation)', 1.00, 1.00, true);

-------------------------------------------------------------------------------
-- User data
-------------------------------------------------------------------------------

create table public.spot (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name               text not null check (length(name) between 1 and 100),
  geog               geography(Point, 4326) not null,
  lat                double precision generated always as (st_y(geog::geometry)) stored,
  lon                double precision generated always as (st_x(geog::geometry)) stored,
  elevation_ft       integer not null default 0 check (elevation_ft between -1500 and 30000),
  search_radius_nm   numeric(5,1) not null default 10 check (search_radius_nm > 0 and search_radius_nm <= 100),
  min_elevation_deg  numeric(4,1) not null default 20 check (min_elevation_deg between 0 and 90),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index spot_geog_gix on public.spot using gist (geog);
create index spot_user_idx on public.spot (user_id);
create trigger spot_set_updated_at before update on public.spot
  for each row execute function public.set_updated_at();

-------------------------------------------------------------------------------
-- Flights
-------------------------------------------------------------------------------

-- Filed flight plans (phase 2 ingest; table exists now so predictions can FK it).
create table public.flight_plan (
  id               bigint generated always as identity primary key,
  source           text not null,                 -- 'faa_swim' | 'aeroapi' | …
  source_ref       text not null,                 -- id in the source system
  callsign         text not null,
  origin           text,                          -- ICAO; not FK, may be outside airport table
  destination      text,
  aircraft_type    text,                          -- ICAO type designator; not FK for the same reason
  rules            text check (rules in ('IFR', 'VFR', 'Y', 'Z')),
  filed_cruise_ft  integer check (filed_cruise_ft between 0 and 60000),
  filed_etd        timestamptz,
  route_string     text,
  route_geog       geography(LineString, 4326),   -- null until route resolution succeeds
  status           text not null default 'filed'
                   check (status in ('filed', 'active', 'completed', 'cancelled', 'unknown')),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (source, source_ref)
);
create index flight_plan_route_gix on public.flight_plan using gist (route_geog);
create index flight_plan_etd_idx on public.flight_plan (filed_etd);
create index flight_plan_callsign_idx on public.flight_plan (callsign);
create trigger flight_plan_set_updated_at before update on public.flight_plan
  for each row execute function public.set_updated_at();

create table public.route_waypoint (
  flight_plan_id  bigint not null references public.flight_plan (id) on delete cascade,
  seq             integer not null check (seq >= 0),
  fix_name        text,
  geog            geography(Point, 4326) not null,
  altitude_ft     integer,
  eta             timestamptz,
  primary key (flight_plan_id, seq)
);
create index route_waypoint_geog_gix on public.route_waypoint using gist (geog);

-- Live ADS-B positions. Short retention (see purge_track_points()).
-- altitude_ft is barometric (pressure) altitude as broadcast; geo_altitude_ft is GNSS.
create table public.track_point (
  icao24             text not null check (icao24 ~ '^[0-9a-f]{6}$'),
  observed_at        timestamptz not null,
  callsign           text,
  geog               geography(Point, 4326) not null,
  altitude_ft        integer,
  geo_altitude_ft    integer,
  on_ground          boolean not null default false,
  ground_speed_kt    numeric(5,1) check (ground_speed_kt >= 0),
  heading_deg        numeric(4,1) check (heading_deg >= 0 and heading_deg < 360),
  vertical_rate_fpm  integer,
  squawk             text,
  source             text not null default 'opensky',
  received_at        timestamptz not null default now(),
  primary key (icao24, observed_at)
);
create index track_point_geog_gix on public.track_point using gist (geog);
create index track_point_observed_idx on public.track_point (observed_at);

create or replace function public.purge_track_points(keep interval default interval '2 hours')
returns integer language plpgsql
set search_path = ''
as $$
declare n integer;
begin
  delete from public.track_point where observed_at < now() - keep;
  get diagnostics n = row_count;
  return n;
end $$;

-- Derived: flights seen repeatedly (phase 2).
create table public.recurring_flight (
  id                  bigint generated always as identity primary key,
  callsign            text not null,
  origin              text,
  destination         text,
  typical_local_time  time,
  time_zone           text,                         -- IANA zone typical_local_time is in
  days_of_week        smallint[] not null default '{}'
                      check (days_of_week <@ array[1,2,3,4,5,6,7]::smallint[]),  -- ISO: 1 = Monday
  observation_count   integer not null default 0 check (observation_count >= 0),
  first_seen_at       timestamptz,
  last_seen_at        timestamptz,
  unique nulls not distinct (callsign, origin, destination)
);

-------------------------------------------------------------------------------
-- Weather
-------------------------------------------------------------------------------

create table public.metar_observation (
  id              bigint generated always as identity primary key,
  station         text not null references public.airport (icao) on update cascade,
  observed_at     timestamptz not null,
  raw_text        text not null,                  -- always kept, it is the source of truth
  report_type     text not null default 'METAR' check (report_type in ('METAR', 'SPECI')),
  is_auto         boolean not null default false, -- AUTO: no human augmentation
  visibility_sm   numeric(5,2) check (visibility_sm >= 0),
  visibility_is_min boolean not null default false, -- reported as "10+" / "P6SM"
  flight_category text check (flight_category in ('VFR', 'MVFR', 'IFR', 'LIFR')),
  wind_dir_deg    smallint check (wind_dir_deg between 0 and 360),  -- null when variable/calm
  wind_variable   boolean not null default false,
  wind_speed_kt   smallint check (wind_speed_kt >= 0),
  wind_gust_kt    smallint check (wind_gust_kt >= 0),
  temp_c          numeric(4,1),
  dewpoint_c      numeric(4,1),
  altimeter_hpa   numeric(6,1),
  wx_string       text,                           -- present weather, e.g. "-RA BR"
  sky_clear_code  text check (sky_clear_code in ('CLR', 'SKC', 'NSC', 'NCD', 'CAVOK')),
  source          text not null default 'awc',
  fetched_at      timestamptz not null default now(),
  unique (station, observed_at)                   -- corrections overwrite via upsert
);
create index metar_station_time_idx on public.metar_observation (station, observed_at desc);
create index metar_observed_idx on public.metar_observation (observed_at);

-- One row per reported cloud layer, lowest first (seq 0).
create table public.cloud_layer (
  id                bigint generated always as identity primary key,
  metar_id          bigint not null references public.metar_observation (id) on delete cascade,
  seq               smallint not null check (seq >= 0),
  cover             text not null references public.cloud_cover (code),
  cloud_type        text check (cloud_type in ('CB', 'TCU')),
  base_agl_ft       integer not null check (base_agl_ft >= 0),
  base_msl_ft       integer not null,               -- base_agl_ft + station elevation (set by trigger)
  est_top_msl_ft    integer,                        -- null unless PIREP/model supplies it; never assume
  est_top_source    text check (est_top_source in ('pirep', 'model', 'satellite')),
  plain_label       text not null,                  -- "Mostly cloudy with gaps at 6,000 ft above ground"
  sky_fraction_min  numeric(3,2) not null,
  sky_fraction_max  numeric(3,2) not null,
  unique (metar_id, seq),
  check (est_top_msl_ft is null or est_top_msl_ft > base_msl_ft),
  check ((est_top_msl_ft is null) = (est_top_source is null))
);

-- Fill MSL base, fractions and a default plain label from the station and cover code.
-- Ingest may supply its own plain_label; base_msl_ft is always recomputed so it
-- can never drift from the station elevation.
create or replace function public.cloud_layer_derive()
returns trigger language plpgsql
set search_path = ''
as $$
declare
  elev integer;
  cc   public.cloud_cover;
begin
  select a.elevation_ft into elev
  from public.metar_observation m join public.airport a on a.icao = m.station
  where m.id = new.metar_id;

  select * into cc from public.cloud_cover where code = new.cover;

  new.base_msl_ft      := new.base_agl_ft + elev;
  new.sky_fraction_min := cc.sky_fraction_min;
  new.sky_fraction_max := cc.sky_fraction_max;
  if new.plain_label is null then
    new.plain_label := cc.plain_label || ' at '
      || to_char(new.base_agl_ft, 'FM999,999') || ' ft above ground'
      || case new.cloud_type when 'CB' then ' (thunderstorm clouds)'
                             when 'TCU' then ' (towering cumulus)' else '' end;
  end if;
  return new;
end $$;

create trigger cloud_layer_derive before insert or update on public.cloud_layer
  for each row execute function public.cloud_layer_derive();

-------------------------------------------------------------------------------
-- Predictions
-------------------------------------------------------------------------------

-- A predicted pass of one aircraft/flight over one spot. Recomputed (upserted
-- on spot_id + pass_key) whenever new plan or ADS-B data arrives.
create table public.overflight_prediction (
  id                   bigint generated always as identity primary key,
  spot_id              uuid not null references public.spot (id) on delete cascade,
  basis                text not null check (basis in ('filed_plan', 'live_adsb')),
  flight_plan_id       bigint references public.flight_plan (id) on delete cascade,
  icao24               text check (icao24 ~ '^[0-9a-f]{6}$'),
  callsign             text,
  aircraft_type        text,
  pass_key             text not null,   -- stable id for this pass, e.g. 'adsb:a1b2c3:2026-11-04T19:40Z'
  closest_approach_at  timestamptz not null,
  closest_distance_nm  numeric(6,2) not null check (closest_distance_nm >= 0),
  closest_point        geography(Point, 4326),
  altitude_ft          integer,
  azimuth_deg          numeric(4,1) check (azimuth_deg >= 0 and azimuth_deg < 360),  -- camera bearing, true north
  elevation_deg        numeric(4,1) check (elevation_deg between -90 and 90),
  confidence           numeric(3,2) check (confidence between 0 and 1),
  computed_at          timestamptz not null default now(),
  unique (spot_id, pass_key),
  check (basis <> 'filed_plan' or flight_plan_id is not null),
  check (basis <> 'live_adsb'  or icao24 is not null)
);
create index prediction_spot_time_idx on public.overflight_prediction (spot_id, closest_approach_at);
create index prediction_time_idx on public.overflight_prediction (closest_approach_at);
create index prediction_flight_plan_idx on public.overflight_prediction (flight_plan_id);

-- Visibility verdict for a prediction (one current row per prediction).
create table public.visibility_assessment (
  prediction_id        bigint primary key references public.overflight_prediction (id) on delete cascade,
  metar_station        text references public.airport (icao),   -- primary (nearest) station
  metar_observation_id bigint references public.metar_observation (id) on delete set null,
  stations_used        text[] not null default '{}',             -- all stations blended for the spot
  obs_age_min          integer check (obs_age_min >= 0),
  -- Lowest relevant cloud base (MSL) minus aircraft altitude.
  -- Positive: cloud base is that far above the aircraft (clear view under it).
  -- Negative: aircraft is above that base. Null: no cloud layers reported.
  clear_margin_ft      integer,
  limiting_cover       text references public.cloud_cover (code),
  rating               text not null check (rating in ('clear', 'partial', 'hidden', 'unknown')),
  explanation          text not null,
  high_cloud_caveat    boolean not null default false,  -- ASOS-only: cirrus above ~12,000 ft undetectable
  computed_at          timestamptz not null default now()
);

-------------------------------------------------------------------------------
-- Alerts
-------------------------------------------------------------------------------

create table public.alert (
  id             bigint generated always as identity primary key,
  user_id        uuid not null default auth.uid() references auth.users (id) on delete cascade,
  spot_id        uuid not null references public.spot (id) on delete cascade,
  prediction_id  bigint not null references public.overflight_prediction (id) on delete cascade,
  notify_at      timestamptz not null,
  min_rating     text not null default 'partial' check (min_rating in ('clear', 'partial')),
  sent_at        timestamptz,
  created_at     timestamptz not null default now(),
  unique (user_id, prediction_id)
);
create index alert_pending_idx on public.alert (notify_at) where sent_at is null;
create index alert_spot_idx on public.alert (spot_id);
create index alert_prediction_idx on public.alert (prediction_id);
