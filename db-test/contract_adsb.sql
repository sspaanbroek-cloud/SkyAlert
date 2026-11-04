-- Contract test: OpenSky state vector -> TS parser -> ingest_track_points()
-- -> compute_live_predictions(). Run by run.sh with -v payload=<json>.
begin;
set search_path = public, extensions;
select plan(7);
insert into auth.users (id) values ('11111111-1111-1111-1111-111111111111');
insert into spot (user_id, name, geog, elevation_ft) values
  ('11111111-1111-1111-1111-111111111111', 'Kubota', 'SRID=4326;POINT(-122.2712 47.5134)', 200);
select is((ingest_track_points(:'payload'::jsonb))->>'inserted', '1', 'parsed state vector stored');
select is((select altitude_ft from track_point where icao24 = 'c0ffee'), 35000, '10,668 m baro = 35,000 ft');
select is((compute_live_predictions())->>'inserted', '1', 'pass predicted');
select is((select callsign from overflight_prediction), 'SKA101', 'callsign carried through');
select ok((select closest_distance_nm < 0.2 and elevation_deg > 80 and abs(extract(epoch from closest_approach_at - now()) - 120) < 10
           from overflight_prediction), 'overhead in about 2 min (15 nm at 450 kt)');
-- Weather at Boeing Field, 1.6 nm away: BKN at 6,000 ft -> partly visible.
select ingest_metars(jsonb_build_array(jsonb_build_object(
  'station', jsonb_build_object('icao', 'KBFI', 'name', 'Boeing Fld', 'lat', 47.53, 'lon', -122.302, 'elevation_ft', 20),
  'observed_at', now() - interval '12 minutes', 'raw_text', 'KBFI 041853Z 17006KT 10SM BKN060 12/08 A3001',
  'is_auto', false, 'visibility_sm', 10, 'sky_clear_code', null,
  'layers', jsonb_build_array(jsonb_build_object('cover', 'BKN', 'base_agl_ft', 6000, 'cloud_type', null)))));
select is((refresh_visibility_assessments())->>'partial', '1', 'pass rated partial');
select is((select explanation from visibility_assessment),
  'Mostly cloudy at about 6,000 ft, so the aircraft will be above the clouds and visible only through gaps.',
  'plain-language explanation');
select * from finish(true);
rollback;
