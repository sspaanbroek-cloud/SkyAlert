begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(20);

insert into auth.users (id) values ('11111111-1111-1111-1111-111111111111'), ('22222222-2222-2222-2222-222222222222');
insert into spot (id, user_id, name, geog, elevation_ft, time_zone) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Kubota',
   'SRID=4326;POINT(-122.2712 47.5134)', 200, 'America/Los_Angeles');

select throws_ok($$ update spot set time_zone = 'Mars/Olympus_Mons' $$, '22023', null, 'unknown time zone rejected');

-- A sighting at local time `t` on the local day `days_ago` days back.
create function pg_temp.seen(cs text, days_ago int, t time, alt int default 33000, az numeric default 40)
returns void language sql as $$
  insert into flight_sighting (spot_id, callsign, icao24, passed_at, closest_distance_nm, altitude_ft, azimuth_deg, elevation_deg)
  select 'aaaaaaaa-0000-0000-0000-000000000001', cs, 'a1b2c3',
         (((now() at time zone 'America/Los_Angeles')::date - days_ago) + t) at time zone 'America/Los_Angeles',
         1.5, alt, az, 70
$$;

-- DAILY1: seen 7 days running at 19:35-19:45 local.
select pg_temp.seen('DAILY1', d, time '19:40' + make_interval(mins => (array[-5,2,0,-2,5,1,-1])[d])) from generate_series(1, 7) d;
-- WKDY2: the weekdays among the last 14 days, 07:10 local.
select pg_temp.seen('WKDY2', d, time '07:10')
from generate_series(1, 14) d
where extract(isodow from (now() at time zone 'America/Los_Angeles')::date - d) between 1 and 5;
-- MIDN3: around midnight on 4 days.
select pg_temp.seen('MIDN3', 1, '23:55'), pg_temp.seen('MIDN3', 2, '00:05'),
       pg_temp.seen('MIDN3', 3, '23:58'), pg_temp.seen('MIDN3', 4, '00:02');
-- RAND4: irregular times. TWO5: only two days. OLD6: seen 40 days ago.
select pg_temp.seen('RAND4', 1, '08:00'), pg_temp.seen('RAND4', 2, '14:00'), pg_temp.seen('RAND4', 3, '21:30');
select pg_temp.seen('TWO5', 1, '12:00'), pg_temp.seen('TWO5', 2, '12:01');
select pg_temp.seen('OLD6', d, '10:00') from generate_series(40, 44) d;

select is(detect_recurring_flights()->>'recurring', '3', 'three regular flights found');
select is((select array_agg(callsign order by callsign) from recurring_flight), array['DAILY1','MIDN3','WKDY2'],
  'irregular, two-day and old flights left out');
select is((select typical_local_time from recurring_flight where callsign = 'DAILY1'), time '19:40', 'DAILY1 usually 19:40');
select ok((select time_spread_min between 2 and 5 from recurring_flight where callsign = 'DAILY1'), 'small time spread');
select is((select days_of_week from recurring_flight where callsign = 'DAILY1'), array[1,2,3,4,5,6,7]::smallint[], 'every day');
select is((select days_of_week from recurring_flight where callsign = 'WKDY2'), array[1,2,3,4,5]::smallint[], 'weekdays only');
select ok((select typical_local_time >= '23:55' or typical_local_time <= '00:05' from recurring_flight where callsign = 'MIDN3'),
  'midnight flight averages to about midnight, not noon');
select is((select observation_count from recurring_flight where callsign = 'DAILY1'), 7, 'observation count');

-- Predictions for the next 36 h.
select ok((refresh_recurring_predictions()->>'upserted')::int >= 2, 'recurring predictions generated');
select ok((select bool_and((closest_approach_at at time zone 'America/Los_Angeles')::time = '19:40')
           from overflight_prediction where callsign = 'DAILY1'), 'DAILY1 slots at 19:40 local');
select ok((select coalesce(bool_and(extract(isodow from closest_approach_at at time zone 'America/Los_Angeles') between 1 and 5), true)
           from overflight_prediction where callsign = 'WKDY2'), 'WKDY2 only on weekdays (none in a weekend window)');
select ok((select bool_and(closest_approach_at > now() and closest_approach_at <= now() + interval '36 hours')
           from overflight_prediction where basis = 'recurring'), 'all within the next 36 h');
select ok((select bool_and(confidence <= 0.8 and altitude_ft = 33000 and azimuth_deg = 40)
           from overflight_prediction where basis = 'recurring'), 'typical altitude/direction, capped confidence');
select is(refresh_recurring_predictions()->>'removed', '0', 'refresh is stable');

-- Live tracking picks DAILY1 up: the "usual" pass gives way.
insert into overflight_prediction (spot_id, basis, icao24, callsign, pass_key, closest_approach_at, closest_distance_nm, altitude_ft)
select spot_id, 'live_adsb', 'a1b2c3', 'DAILY1', 'adsb:test', closest_approach_at + interval '6 minutes', 1.1, 33000
from overflight_prediction where callsign = 'DAILY1' order by closest_approach_at limit 1;
select is((select count(*)::int from overflight_prediction r, overflight_prediction l
           where l.pass_key = 'adsb:test' and r.basis = 'recurring' and r.callsign = 'DAILY1'
             and r.closest_approach_at between l.closest_approach_at - interval '45 minutes' and l.closest_approach_at + interval '45 minutes'),
  0, 'live pass replaced the recurring one');
select is((select count(*)::int from overflight_prediction where pass_key = 'adsb:test'), 1, 'live pass kept');

-- Sightings come from completed live passes, once.
insert into overflight_prediction (spot_id, basis, icao24, callsign, pass_key, closest_approach_at, closest_distance_nm, altitude_ft)
values ('aaaaaaaa-0000-0000-0000-000000000001', 'live_adsb', 'b00001', 'DONE7', 'adsb:done', now() - interval '5 minutes', 0.5, 9000),
       ('aaaaaaaa-0000-0000-0000-000000000001', 'live_adsb', 'b00002', 'SOON8', 'adsb:soon', now() + interval '5 minutes', 0.5, 9000);
select is(record_sightings(), 1, 'one completed pass recorded');
select is(record_sightings(), 0, 'not recorded twice');

-- RLS: other users see nothing.
set local role authenticated;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
select is((select count(*)::int from recurring_flight) + (select count(*)::int from flight_sighting), 0,
  'other users see no recurring flights or sightings');

select * from finish(true);
rollback;
