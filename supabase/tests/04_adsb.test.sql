begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(24);

insert into auth.users (id) values ('11111111-1111-1111-1111-111111111111');
insert into spot (id, user_id, name, geog, elevation_ft, search_radius_nm, min_elevation_deg) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Kubota',
   'SRID=4326;POINT(-122.2712 47.5134)', 200, 10, 20);

-- Build an OpenSky-style point `nm` away from the spot on bearing `brg`.
create function pg_temp.pt(icao text, brg float8, nm float8, hdg float8, kt float8, alt int,
                           age_s int default 10, ground boolean default false, vr int default 0)
returns jsonb language sql as $$
  select jsonb_build_object(
    'icao24', icao, 'observed_at', now() - make_interval(secs => age_s), 'callsign', upper(icao) || '  ',
    'lat', st_y(p::geometry), 'lon', st_x(p::geometry),
    'altitude_ft', alt - 200, 'geo_altitude_ft', alt, 'on_ground', ground,
    'ground_speed_kt', kt, 'heading_deg', hdg, 'vertical_rate_fpm', vr, 'squawk', '1200', 'source', 'opensky')
  from (select st_project(s.geog, brg_m, radians(brg)) as p
        from spot s, (select nm * 1852.0 as brg_m) d) q
$$;

-- Privileges
set local role authenticated;
select throws_ok($$ select ingest_track_points('[]') $$, '42501', null, 'users cannot ingest ADS-B');
select throws_ok($$ select compute_live_predictions() $$, '42501', null, 'users cannot run predictions');
reset role;

select is((select count(*)::int from adsb_fetch_areas()), 1, 'one ADS-B box for one spot');
select ok((select area_sq_deg <= 25 from adsb_fetch_areas()), 'box costs 1 OpenSky credit (<= 25 sq deg)');

create temp table r1 as select ingest_track_points(jsonb_build_array(
  pg_temp.pt('a00001', 180, 30, 0, 450, 10000),    -- A: 30 nm S, northbound, will pass overhead
  pg_temp.pt('a00002', 170.5, 30.4, 0, 450, 35000), -- B: passes ~5 nm E at 35,000 ft
  pg_temp.pt('a00003', 170.5, 30.4, 0, 450, 3000),  -- C: same track at 3,000 ft: too low in the sky
  pg_temp.pt('a00004', 0, 10, 0, 450, 35000),       -- D: north of spot, northbound: receding
  pg_temp.pt('a00005', 180, 3, 0, 10, 400, 10, true), -- E: on the ground
  pg_temp.pt('a00006', 180, 30, 0, 450, 35000, 300),-- F: report 5 min old
  pg_temp.pt('a00007', 157, 32.5, 0, 450, 35000),   -- G: passes ~12.7 nm E, outside radius
  '{"icao24": "XYZ", "observed_at": "2026-01-01T00:00:00Z", "lat": 0, "lon": 0}'::jsonb
)) as r;
select is((select r->>'inserted' from r1), '7', '7 valid points stored');
select is((select r->>'invalid' from r1), '1', 'malformed point skipped');
select is((select callsign from track_point where icao24 = 'a00001'), 'A00001', 'callsign trimmed');
select is((select (ingest_track_points(jsonb_build_array(pg_temp.pt('a00005', 180, 3, 0, 10, 400, 10, true))))->>'duplicate'),
  '1', 're-sent point is a duplicate');

create temp table c1 as select compute_live_predictions() as r;
select is((select r->>'inserted' from c1), '2', 'two passes predicted (A, B)');
select is((select r->>'too_low' from c1), '1', 'C rejected as too low in the sky');
select is((select array_agg(icao24 order by icao24) from overflight_prediction), array['a00001','a00002'], 'A and B');

select ok((select closest_distance_nm < 0.1 and elevation_deg > 85 from overflight_prediction where icao24 = 'a00001'),
  'A passes overhead');
select ok((select abs(extract(epoch from closest_approach_at - (now() - interval '10 seconds')) - 240) < 5
           from overflight_prediction where icao24 = 'a00001'), 'A arrives in about 4 min (30 nm at 450 kt)');
select ok((select abs(closest_distance_nm - 5) < 0.2 from overflight_prediction where icao24 = 'a00002'),
  'B closest approach about 5 nm');
select ok((select abs(azimuth_deg - 90) < 2 from overflight_prediction where icao24 = 'a00002'), 'B: look east');
select ok((select abs(elevation_deg - 48.8) < 1 from overflight_prediction where icao24 = 'a00002'),
  'B is about 49 deg up (35,000 ft, 5 nm, spot at 200 ft)');
select is((select altitude_ft from overflight_prediction where icao24 = 'a00002'), 35000, 'geo altitude used');
select ok((select confidence between 0.7 and 1 from overflight_prediction where icao24 = 'a00002'), 'confidence in range');

-- A moves on 2 minutes: the same pass is updated, not duplicated.
select ingest_track_points(jsonb_build_array(pg_temp.pt('a00001', 180, 15, 0, 450, 10000, 0)));
create temp table c2 as select compute_live_predictions() as r;
select is((select count(*)::int from overflight_prediction where icao24 = 'a00001'), 1, 'still one row for A');
select ok((select abs(extract(epoch from closest_approach_at - now()) - 120) < 5
           from overflight_prediction where icao24 = 'a00001'), 'A now 2 min out');

-- A turns east (no longer heading for the spot): its future pass is removed.
select ingest_track_points(jsonb_build_array(
  jsonb_set(pg_temp.pt('a00001', 180, 15, 90, 450, 10000, 0), '{observed_at}', to_jsonb(now() + interval '1 second'))));
create temp table c3 as select compute_live_predictions() as r;
select is((select count(*)::int from overflight_prediction where icao24 = 'a00001'), 0, 'turned-away pass removed');

-- H is 1 nm out and about to pass overhead...
select ingest_track_points(jsonb_build_array(pg_temp.pt('a00008', 180, 1, 0, 450, 10000, 0)));
create temp table c4 as select compute_live_predictions() as r;
select is((select count(*)::int from overflight_prediction where icao24 = 'a00008'), 1, 'H predicted');
-- ...then its next report is just past the spot. The pass must not vanish.
select ingest_track_points(jsonb_build_array(
  jsonb_set(pg_temp.pt('a00008', 0, 0.3, 0, 450, 10000, 0), '{observed_at}', to_jsonb(now() + interval '2 seconds'))));
create temp table c5 as select compute_live_predictions() as r;
select is((select count(*)::int from overflight_prediction where icao24 = 'a00008'), 1, 'pass kept while overhead');

-- Past passes are kept as history until purged.
update overflight_prediction set closest_approach_at = now() - interval '3 days' where icao24 = 'a00002';
select is(purge_live_predictions(), 1, 'old live predictions purged');

select * from finish(true);
rollback;
