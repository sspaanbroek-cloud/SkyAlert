-- Live ADS-B ingest and approach prediction (phase 1, step 4).
--
-- Flow: the `ingest-adsb` Edge Function asks adsb_fetch_areas() which boxes
-- to poll on OpenSky, stores state vectors with ingest_track_points(), then
-- calls compute_live_predictions() to (re)compute passes over every spot.
set search_path = public, extensions;

-------------------------------------------------------------------------------
-- Areas to poll. Same 1-degree grid as METAR, padded by the largest search
-- radius plus a lookahead distance, so approaching aircraft are seen early.
-- OpenSky charges 1 credit for a box up to 25 sq deg; area_sq_deg is returned
-- so the worker can report cost.
-------------------------------------------------------------------------------
create or replace function public.adsb_fetch_areas(lookahead_nm numeric default 80)
returns table (min_lat double precision, min_lon double precision,
               max_lat double precision, max_lon double precision,
               area_sq_deg double precision)
language sql stable security definer set search_path = ''
as $$
  with cells as (
    select floor(s.lat) as cell_lat, floor(s.lon) as cell_lon,
           (max(s.search_radius_nm) + lookahead_nm) / 60.0 as pad_lat
    from public.spot s
    group by 1, 2
  ), boxes as (
    select greatest(-90.0, cell_lat - pad_lat) as min_lat,
           greatest(-180.0, cell_lon - pad_lat / greatest(cos(radians(cell_lat + 0.5)), 0.2)) as min_lon,
           least(90.0, cell_lat + 1 + pad_lat) as max_lat,
           least(180.0, cell_lon + 1 + pad_lat / greatest(cos(radians(cell_lat + 0.5)), 0.2)) as max_lon
    from cells
  )
  select min_lat, min_lon, max_lat, max_lon, (max_lat - min_lat) * (max_lon - min_lon)
  from boxes
  order by 1, 2
$$;

-------------------------------------------------------------------------------
-- Store state vectors. points: JSON array of
--   {icao24, observed_at, callsign, lat, lon, altitude_ft, geo_altitude_ft,
--    on_ground, ground_speed_kt, heading_deg, vertical_rate_fpm, squawk, source}
-- Invalid rows are skipped (counted), duplicates ignored.
-------------------------------------------------------------------------------
create or replace function public.ingest_track_points(points jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  total    integer;
  inserted integer;
  valid    integer;
begin
  if jsonb_typeof(points) is distinct from 'array' then
    raise exception 'points must be a JSON array';
  end if;
  total := jsonb_array_length(points);

  with rows as (
    select * from jsonb_to_recordset(points) as x(
      icao24 text, observed_at timestamptz, callsign text, lat float8, lon float8,
      altitude_ft integer, geo_altitude_ft integer, on_ground boolean, ground_speed_kt numeric,
      heading_deg numeric, vertical_rate_fpm integer, squawk text, source text)
  ), ok as (
    select * from rows
    where icao24 ~ '^[0-9a-f]{6}$'
      and observed_at is not null
      and lat between -90 and 90 and lon between -180 and 180
      and (heading_deg is null or (heading_deg >= 0 and heading_deg < 360))
      and (ground_speed_kt is null or ground_speed_kt >= 0)
  ), ins as (
    insert into public.track_point (icao24, observed_at, callsign, geog, altitude_ft, geo_altitude_ft,
                                    on_ground, ground_speed_kt, heading_deg, vertical_rate_fpm, squawk, source)
    select icao24, observed_at, nullif(trim(callsign), ''),
           extensions.st_setsrid(extensions.st_makepoint(lon, lat), 4326)::extensions.geography,
           altitude_ft, geo_altitude_ft, coalesce(on_ground, false), ground_speed_kt, heading_deg,
           vertical_rate_fpm, squawk, coalesce(source, 'opensky')
    from ok
    on conflict (icao24, observed_at) do nothing
    returning 1
  )
  select (select count(*) from ok), (select count(*) from ins) into valid, inserted;

  return jsonb_build_object('received', total, 'inserted', inserted,
                            'duplicate', valid - inserted, 'invalid', total - valid);
end $$;

-------------------------------------------------------------------------------
-- Predict passes from live positions.
--
-- For each aircraft's latest position (no older than p_max_age_s), project a
-- straight line along its track at its ground speed for up to p_horizon_min,
-- in a local flat frame around each spot (fine at these ranges), and find the
-- closest point of approach (CPA). Keep it if:
--   * the CPA is ahead (aircraft approaching, not receding),
--   * CPA distance <= the spot's search radius,
--   * the aircraft will be at least min_elevation_deg above the horizon.
--
-- Altitude: GNSS (geo) altitude when available, else barometric. Vertical
-- rate is extrapolated for at most 5 minutes (climbs and descents level off).
-- Elevation angle includes Earth curvature with standard refraction.
--
-- Rows are upserted: a new result for the same spot + aircraft within 15 min
-- of an existing predicted CPA updates that row (same pass). Future passes
-- that are no longer predicted (aircraft turned away) are removed, except an
-- aircraft inside the radius in the last 2 minutes: that pass is happening.
-------------------------------------------------------------------------------
create or replace function public.compute_live_predictions(
  p_horizon_min integer default 20,
  p_max_age_s   integer default 120)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  c         record;
  run_at    timestamptz := clock_timestamp();
  earth_r   constant float8 := 6371000.0;
  refract_k constant float8 := 0.13;
  h_m       float8;
  el        float8;
  conf      float8;
  age_s     float8;
  cpa_at    timestamptz;
  existing  bigint;
  ins       integer := 0;
  upd       integer := 0;
  low       integer := 0;
  removed   integer := 0;
begin
  for c in
    with latest as (
      select distinct on (tp.icao24) tp.*
      from public.track_point tp
      where tp.observed_at > run_at - make_interval(secs => p_max_age_s)
      order by tp.icao24, tp.observed_at desc
    ), cand as (
      select s.id as spot_id, s.geog as spot_geog, s.elevation_ft as spot_elev_ft,
             s.search_radius_nm, s.min_elevation_deg,
             l.icao24, l.callsign, l.observed_at,
             coalesce(l.geo_altitude_ft, l.altitude_ft)::float8 as alt_ft,
             coalesce(l.vertical_rate_fpm, 0)::float8 as vr_fpm,
             l.ground_speed_kt::float8 * 1852.0 / 3600.0 as v_ms,
             radians(l.heading_deg::float8) as hdg,
             extensions.st_distance(s.geog, l.geog) as d0,
             coalesce(extensions.st_azimuth(s.geog, l.geog), 0) as az0
      from latest l
      join public.spot s
        on extensions.st_dwithin(s.geog, l.geog,
             (s.search_radius_nm::float8 + l.ground_speed_kt::float8 * p_horizon_min / 60.0) * 1852.0)
      where not l.on_ground
        and l.ground_speed_kt >= 30
        and l.heading_deg is not null
        and coalesce(l.geo_altitude_ft, l.altitude_ft) is not null
    ), frame as (   -- metres east (x) / north (y) of the spot
      select cand.*,
             d0 * sin(az0) as px, d0 * cos(az0) as py,
             v_ms * sin(hdg) as vx, v_ms * cos(hdg) as vy
      from cand
    ), tcpa as (
      select frame.*,
             least(-(px * vx + py * vy) / (vx * vx + vy * vy), p_horizon_min * 60.0) as t
      from frame
    ), cpa as (
      select tcpa.*, px + vx * t as cx, py + vy * t as cy
      from tcpa
      where t > 0
    )
    select cpa.*,
           sqrt(cx * cx + cy * cy) as dist_m,
           mod((degrees(atan2(cx, cy)) + 360.0)::numeric, 360) as az_deg,
           greatest(0.0, alt_ft + vr_fpm * least(t, 300.0) / 60.0) as alt_cpa_ft
    from cpa
    where sqrt(cx * cx + cy * cy) <= search_radius_nm::float8 * 1852.0
  loop
    h_m := (c.alt_cpa_ft - c.spot_elev_ft) * 0.3048
           - (c.dist_m * c.dist_m) * (1 - refract_k) / (2 * earth_r);
    el := degrees(atan2(h_m, greatest(c.dist_m, 1.0)));
    if el < c.min_elevation_deg then
      low := low + 1;
      continue;
    end if;

    -- Confidence: falls with lookahead time, data age and vertical manoeuvring.
    age_s := extract(epoch from run_at - c.observed_at);
    conf := (1.0 - 0.5 * c.t / (p_horizon_min * 60.0))
            * (1.0 - 0.2 * least(greatest(age_s, 0), p_max_age_s) / p_max_age_s)
            * case when abs(c.vr_fpm) > 500 then 0.85 else 1.0 end;

    cpa_at := c.observed_at + make_interval(secs => c.t);

    select p.id into existing
    from public.overflight_prediction p
    where p.spot_id = c.spot_id and p.basis = 'live_adsb' and p.icao24 = c.icao24
      and p.closest_approach_at between cpa_at - interval '15 minutes' and cpa_at + interval '15 minutes'
    order by abs(extract(epoch from p.closest_approach_at - cpa_at))
    limit 1;

    if existing is not null then
      update public.overflight_prediction set
        callsign = coalesce(c.callsign, callsign),
        closest_approach_at = cpa_at,
        closest_distance_nm = round((c.dist_m / 1852.0)::numeric, 2),
        closest_point = extensions.st_project(c.spot_geog, c.dist_m, radians(c.az_deg::float8)),
        altitude_ft = round(c.alt_cpa_ft)::integer,
        azimuth_deg = round(c.az_deg, 1) % 360,
        elevation_deg = round(el::numeric, 1),
        confidence = round(conf::numeric, 2),
        computed_at = run_at
      where id = existing;
      upd := upd + 1;
    else
      insert into public.overflight_prediction (
        spot_id, basis, icao24, callsign, pass_key, closest_approach_at, closest_distance_nm,
        closest_point, altitude_ft, azimuth_deg, elevation_deg, confidence, computed_at)
      values (
        c.spot_id, 'live_adsb', c.icao24, c.callsign,
        'adsb:' || c.icao24 || ':' || to_char(cpa_at at time zone 'UTC', 'YYYYMMDD"T"HH24MI"Z"'),
        cpa_at, round((c.dist_m / 1852.0)::numeric, 2),
        extensions.st_project(c.spot_geog, c.dist_m, radians(c.az_deg::float8)),
        round(c.alt_cpa_ft)::integer, round(c.az_deg, 1) % 360, round(el::numeric, 1),
        round(conf::numeric, 2), run_at)
      on conflict (spot_id, pass_key) do update set computed_at = excluded.computed_at;
      ins := ins + 1;
    end if;
  end loop;

  -- Drop future passes this run no longer predicts. Within 2 minutes of the
  -- CPA, keep the pass while the aircraft is still inside the search radius
  -- (or not seen this run): it is probably passing right now.
  delete from public.overflight_prediction p
  using public.spot s
  where p.spot_id = s.id
    and p.basis = 'live_adsb'
    and p.computed_at < run_at
    and p.closest_approach_at > run_at
    and (p.closest_approach_at > run_at + interval '2 minutes'
         or exists (
           select 1
           from (select tp.geog from public.track_point tp
                 where tp.icao24 = p.icao24
                   and tp.observed_at > run_at - make_interval(secs => p_max_age_s)
                 order by tp.observed_at desc limit 1) last_pos
           where not extensions.st_dwithin(last_pos.geog, s.geog, s.search_radius_nm::float8 * 1852.0)));
  get diagnostics removed = row_count;

  return jsonb_build_object('inserted', ins, 'updated', upd, 'removed', removed, 'too_low', low);
end $$;

create or replace function public.purge_live_predictions(keep interval default interval '2 days')
returns integer language plpgsql set search_path = ''
as $$
declare n integer;
begin
  delete from public.overflight_prediction
  where basis = 'live_adsb' and closest_approach_at < now() - keep;
  get diagnostics n = row_count;
  return n;
end $$;

-------------------------------------------------------------------------------
-- Privileges: worker only.
-------------------------------------------------------------------------------
revoke execute on function public.adsb_fetch_areas(numeric) from public, anon, authenticated;
revoke execute on function public.ingest_track_points(jsonb) from public, anon, authenticated;
revoke execute on function public.compute_live_predictions(integer, integer) from public, anon, authenticated;
revoke execute on function public.purge_live_predictions(interval) from public, anon, authenticated;
grant execute on function public.adsb_fetch_areas(numeric) to service_role;
grant execute on function public.ingest_track_points(jsonb) to service_role;
grant execute on function public.compute_live_predictions(integer, integer) to service_role;
grant execute on function public.purge_live_predictions(interval) to service_role;

-------------------------------------------------------------------------------
-- Schedules (skipped where pg_cron/pg_net are missing, as in *_schedules.sql).
-- Every minute: ~1,440 OpenSky credits per area per day. A free OpenSky
-- account allows about 4,000/day, so slow this down if spots span 3+ cells.
-------------------------------------------------------------------------------
do $outer$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron')
     or not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_cron/pg_net not installed: skipping ADS-B schedules';
    return;
  end if;

  perform cron.schedule('ingest-adsb', '* * * * *', $job$
    select net.http_post(
      url     := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
                 || '/functions/v1/ingest-adsb',
      headers := jsonb_build_object(
                   'Content-Type', 'application/json',
                   'x-ingest-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'ingest_secret')),
      body    := '{}'::jsonb,
      timeout_milliseconds := 50000)
  $job$);

  perform cron.schedule('purge-live-predictions', '41 3 * * *',
    $job$ select public.purge_live_predictions(interval '2 days') $job$);
end
$outer$;
