-- Recurring flights (phase 2, part 1).
--
-- Completed live passes are logged as sightings. A daily job finds callsigns
-- seen over the same spot at about the same local time on several days, and
-- an hourly job turns those into 'recurring' predictions for the next 36 h,
-- so photographers can plan ahead without paid flight-plan data.
set search_path = public, extensions;

-------------------------------------------------------------------------------
-- Spot time zone: "usual time" only means something in local time.
-------------------------------------------------------------------------------
alter table public.spot add column time_zone text not null default 'UTC';

create or replace function public.spot_check_time_zone()
returns trigger language plpgsql set search_path = ''
as $$
begin
  perform now() at time zone new.time_zone;   -- raises 22023 for an unknown zone
  return new;
end $$;

create trigger spot_check_time_zone before insert or update of time_zone on public.spot
  for each row execute function public.spot_check_time_zone();

grant update (time_zone) on public.spot to authenticated;

-------------------------------------------------------------------------------
-- Sightings: one row per completed live pass, kept 60 days.
-------------------------------------------------------------------------------
create table public.flight_sighting (
  id                   bigint generated always as identity primary key,
  spot_id              uuid not null references public.spot (id) on delete cascade,
  prediction_id        bigint unique,          -- the live prediction it came from (no FK: those are purged)
  callsign             text not null,
  icao24               text,
  passed_at            timestamptz not null,
  closest_distance_nm  numeric(6,2),
  altitude_ft          integer,
  azimuth_deg          numeric(4,1),
  elevation_deg        numeric(4,1)
);
create index flight_sighting_spot_callsign_idx on public.flight_sighting (spot_id, callsign, passed_at);
create index flight_sighting_passed_idx on public.flight_sighting (passed_at);

alter table public.flight_sighting enable row level security;
create policy "own spots" on public.flight_sighting for select to authenticated
  using (exists (select 1 from public.spot s where s.id = flight_sighting.spot_id and s.user_id = (select auth.uid())));

-------------------------------------------------------------------------------
-- recurring_flight becomes per spot (a flight is "regular" over a place).
-- origin/destination stay for when filed plans arrive (phase 2, part 5).
-------------------------------------------------------------------------------
alter table public.recurring_flight
  drop constraint recurring_flight_callsign_origin_destination_key,
  add column spot_id uuid not null references public.spot (id) on delete cascade,
  add column time_spread_min integer,           -- circular std dev of the local time
  add column typical_altitude_ft integer,
  add column typical_distance_nm numeric(6,2),
  add column typical_azimuth_deg numeric(4,1),
  add column typical_elevation_deg numeric(4,1),
  add column distinct_days integer not null default 0,
  add column computed_at timestamptz not null default now(),
  add constraint recurring_flight_spot_callsign_key unique (spot_id, callsign);

drop policy "signed-in read" on public.recurring_flight;
create policy "own spots" on public.recurring_flight for select to authenticated
  using (exists (select 1 from public.spot s where s.id = recurring_flight.spot_id and s.user_id = (select auth.uid())));

-------------------------------------------------------------------------------
-- Predictions from recurring flights.
-------------------------------------------------------------------------------
alter table public.overflight_prediction
  drop constraint overflight_prediction_basis_check,
  add constraint overflight_prediction_basis_check check (basis in ('filed_plan', 'live_adsb', 'recurring')),
  add column recurring_flight_id bigint references public.recurring_flight (id) on delete cascade,
  add constraint overflight_prediction_recurring_check check (basis <> 'recurring' or recurring_flight_id is not null);
create index prediction_recurring_idx on public.overflight_prediction (recurring_flight_id);

-- When live tracking picks the flight up, the live pass replaces the "usual" one.
create or replace function public.live_replaces_recurring()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.basis = 'live_adsb' and new.callsign is not null then
    delete from public.overflight_prediction p
    where p.spot_id = new.spot_id and p.basis = 'recurring' and p.callsign = new.callsign
      and p.closest_approach_at between new.closest_approach_at - interval '45 minutes'
                                    and new.closest_approach_at + interval '45 minutes';
  end if;
  return null;
end $$;

create trigger live_replaces_recurring after insert or update of callsign on public.overflight_prediction
  for each row when (new.basis = 'live_adsb') execute function public.live_replaces_recurring();

-------------------------------------------------------------------------------
-- record_sightings(): log live passes whose closest approach is over.
-------------------------------------------------------------------------------
create or replace function public.record_sightings()
returns integer language plpgsql security definer set search_path = ''
as $$
declare n integer;
begin
  insert into public.flight_sighting (spot_id, prediction_id, callsign, icao24, passed_at,
                                      closest_distance_nm, altitude_ft, azimuth_deg, elevation_deg)
  select p.spot_id, p.id, p.callsign, p.icao24, p.closest_approach_at,
         p.closest_distance_nm, p.altitude_ft, p.azimuth_deg, p.elevation_deg
  from public.overflight_prediction p
  where p.basis = 'live_adsb'
    and p.callsign is not null
    and p.closest_approach_at < now() - interval '2 minutes'
    and p.closest_approach_at > now() - interval '2 days'
  on conflict (prediction_id) do nothing;
  get diagnostics n = row_count;

  delete from public.flight_sighting where passed_at < now() - interval '60 days';
  return n;
end $$;

-------------------------------------------------------------------------------
-- detect_recurring_flights(): per spot and callsign over the last p_days.
--
-- Local time of day is averaged on a circle (so 23:50 and 00:10 average to
-- midnight, not noon). A flight is recurring when it was seen on at least
-- p_min_days different days with a time spread (circular std dev) of at most
-- p_max_spread_min. days_of_week lists the ISO weekdays it was actually seen
-- on, so it fills in as more days are observed.
-------------------------------------------------------------------------------
create or replace function public.detect_recurring_flights(
  p_days           integer default 28,
  p_min_days       integer default 3,
  p_max_spread_min integer default 30)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  upserted integer;
  removed  integer;
begin
  with local as (
    select f.spot_id, f.callsign, f.passed_at, f.altitude_ft, f.closest_distance_nm,
           f.azimuth_deg, f.elevation_deg,
           (f.passed_at at time zone s.time_zone) as local_ts,
           s.time_zone
    from public.flight_sighting f
    join public.spot s on s.id = f.spot_id
    where f.passed_at > now() - make_interval(days => p_days)
  ), angles as (
    select local.*,
           2 * pi() * extract(epoch from local_ts::time) / 86400.0 as theta,
           extract(isodow from local_ts)::smallint as dow,
           local_ts::date as local_day
    from local
  ), stats as (
    select spot_id, callsign, min(time_zone) as time_zone,
           count(*) as n,
           count(distinct local_day) as days,
           atan2(avg(sin(theta)), avg(cos(theta))) as mean_theta,
           sqrt(power(avg(sin(theta)), 2) + power(avg(cos(theta)), 2)) as r,
           array_agg(distinct dow order by dow) as dows,
           min(passed_at) as first_seen, max(passed_at) as last_seen,
           round(avg(altitude_ft))::integer as alt,
           round(avg(closest_distance_nm), 2) as dist,
           -- circular mean of azimuth as well
           mod((degrees(atan2(avg(sin(radians(azimuth_deg::float8))), avg(cos(radians(azimuth_deg::float8))))) + 360)::numeric, 360) as az,
           round(avg(elevation_deg), 1) as el
    from angles
    group by spot_id, callsign
  ), qualified as (
    select stats.*,
           -- circular standard deviation, in minutes
           round(sqrt(-2 * ln(greatest(r, 1e-9))) * 1440 / (2 * pi()))::integer as spread_min,
           -- mean angle -> minutes after midnight, rounded to the minute
           (time '00:00' + make_interval(mins => (round(
              mod((mean_theta + 2 * pi())::numeric, (2 * pi())::numeric) / (2 * pi())::numeric * 1440)::integer % 1440))) as typical
    from stats
    where days >= p_min_days
  ), up as (
    insert into public.recurring_flight as rf (
      spot_id, callsign, typical_local_time, time_zone, days_of_week, observation_count, distinct_days,
      first_seen_at, last_seen_at, time_spread_min, typical_altitude_ft, typical_distance_nm,
      typical_azimuth_deg, typical_elevation_deg, computed_at)
    select spot_id, callsign, typical, time_zone, dows, n, days,
           first_seen, last_seen, spread_min, alt, dist, round(az, 1) % 360, el, now()
    from qualified
    where spread_min <= p_max_spread_min
    on conflict (spot_id, callsign) do update set
      typical_local_time = excluded.typical_local_time, time_zone = excluded.time_zone,
      days_of_week = excluded.days_of_week, observation_count = excluded.observation_count,
      distinct_days = excluded.distinct_days, first_seen_at = excluded.first_seen_at,
      last_seen_at = excluded.last_seen_at, time_spread_min = excluded.time_spread_min,
      typical_altitude_ft = excluded.typical_altitude_ft, typical_distance_nm = excluded.typical_distance_nm,
      typical_azimuth_deg = excluded.typical_azimuth_deg, typical_elevation_deg = excluded.typical_elevation_deg,
      computed_at = excluded.computed_at
    returning 1
  )
  select count(*) into upserted from up;

  -- Flights that no longer qualify (stopped flying, schedule changed).
  delete from public.recurring_flight where computed_at < now();  -- not refreshed by this run
  get diagnostics removed = row_count;

  return jsonb_build_object('recurring', upserted, 'removed', removed);
end $$;

-------------------------------------------------------------------------------
-- refresh_recurring_predictions(): 'recurring' passes for the next p_hours.
--
-- Skips a slot when live tracking already has that callsign within 45 min.
-- Confidence: more distinct days and a tighter time spread raise it; capped
-- at 0.8 because "usually" is never as sure as an aircraft on radar.
-------------------------------------------------------------------------------
create or replace function public.refresh_recurring_predictions(p_hours integer default 36)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  run_at   timestamptz := now();
  upserted integer;
  removed  integer;
begin
  with slots as (
    select rf.*, s.geog as spot_geog,
           ((d.day::date + rf.typical_local_time) at time zone rf.time_zone) as at
    from public.recurring_flight rf
    join public.spot s on s.id = rf.spot_id
    cross join lateral generate_series(
      (run_at at time zone rf.time_zone)::date - 1,
      (run_at at time zone rf.time_zone)::date + ceil(p_hours / 24.0)::integer,
      interval '1 day') as d(day)
    where extract(isodow from d.day)::smallint = any (rf.days_of_week)
      and rf.last_seen_at > run_at - interval '14 days'
  ), wanted as (
    select * from slots
    where at > run_at and at <= run_at + make_interval(hours => p_hours)
      and not exists (
        select 1 from public.overflight_prediction lp
        where lp.spot_id = slots.spot_id and lp.basis = 'live_adsb' and lp.callsign = slots.callsign
          and lp.closest_approach_at between slots.at - interval '45 minutes' and slots.at + interval '45 minutes')
  ), up as (
    insert into public.overflight_prediction as p (
      spot_id, basis, recurring_flight_id, callsign, pass_key, closest_approach_at, closest_distance_nm,
      closest_point, altitude_ft, azimuth_deg, elevation_deg, confidence, computed_at)
    select w.spot_id, 'recurring', w.id, w.callsign,
           'recurring:' || w.id || ':' || to_char(w.at at time zone w.time_zone, 'YYYY-MM-DD'),
           w.at, coalesce(w.typical_distance_nm, 0),
           case when w.typical_azimuth_deg is not null
                then extensions.st_project(w.spot_geog, coalesce(w.typical_distance_nm, 0)::float8 * 1852.0,
                                           radians(w.typical_azimuth_deg::float8)) end,
           w.typical_altitude_ft, w.typical_azimuth_deg, w.typical_elevation_deg,
           round(least(0.8, (0.3 + 0.05 * w.distinct_days)
                 * (1.0 - least(coalesce(w.time_spread_min, 30), 30) / 60.0))::numeric, 2),
           run_at
    from wanted w
    on conflict (spot_id, pass_key) do update set
      closest_approach_at = excluded.closest_approach_at, closest_distance_nm = excluded.closest_distance_nm,
      closest_point = excluded.closest_point, altitude_ft = excluded.altitude_ft,
      azimuth_deg = excluded.azimuth_deg, elevation_deg = excluded.elevation_deg,
      confidence = excluded.confidence, computed_at = excluded.computed_at
    returning 1
  )
  select count(*) into upserted from up;

  delete from public.overflight_prediction
  where basis = 'recurring' and computed_at < run_at and closest_approach_at > run_at;
  get diagnostics removed = row_count;

  return jsonb_build_object('upserted', upserted, 'removed', removed);
end $$;

-------------------------------------------------------------------------------
-- Privileges and schedules
-------------------------------------------------------------------------------
revoke execute on function public.record_sightings() from public, anon, authenticated;
revoke execute on function public.detect_recurring_flights(integer, integer, integer) from public, anon, authenticated;
revoke execute on function public.refresh_recurring_predictions(integer) from public, anon, authenticated;
grant execute on function public.record_sightings() to service_role;
grant execute on function public.detect_recurring_flights(integer, integer, integer) to service_role;
grant execute on function public.refresh_recurring_predictions(integer) to service_role;

do $outer$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not installed: skipping recurring-flight schedules';
    return;
  end if;
  perform cron.schedule('record-sightings', '*/5 * * * *', $job$ select public.record_sightings() $job$);
  perform cron.schedule('detect-recurring', '23 4 * * *', $job$
    select public.detect_recurring_flights();
    select public.refresh_recurring_predictions();
    select public.refresh_visibility_assessments();
  $job$);
  perform cron.schedule('refresh-recurring', '7 * * * *', $job$
    select public.refresh_recurring_predictions();
    select public.refresh_visibility_assessments();
  $job$);
end
$outer$;
