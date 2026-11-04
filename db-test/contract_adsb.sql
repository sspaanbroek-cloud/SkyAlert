-- Contract test: OpenSky state vector -> TS parser -> ingest_track_points()
-- -> compute_live_predictions(). Run by run.sh with -v payload=<json>.
begin;
set search_path = public, extensions;
select plan(5);
insert into auth.users (id) values ('11111111-1111-1111-1111-111111111111');
insert into spot (user_id, name, geog, elevation_ft) values
  ('11111111-1111-1111-1111-111111111111', 'Kubota', 'SRID=4326;POINT(-122.2712 47.5134)', 200);
select is((ingest_track_points(:'payload'::jsonb))->>'inserted', '1', 'parsed state vector stored');
select is((select altitude_ft from track_point where icao24 = 'c0ffee'), 35000, '10,668 m baro = 35,000 ft');
select is((compute_live_predictions())->>'inserted', '1', 'pass predicted');
select is((select callsign from overflight_prediction), 'SKA101', 'callsign carried through');
select ok((select closest_distance_nm < 0.2 and elevation_deg > 80 and abs(extract(epoch from closest_approach_at - now()) - 120) < 10
           from overflight_prediction), 'overhead in about 2 min (15 nm at 450 kt)');
select * from finish(true);
rollback;
