begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(14);

insert into auth.users (id) values ('11111111-1111-1111-1111-111111111111');
insert into spot (id, user_id, name, geog, elevation_ft) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Kubota',
   'SRID=4326;POINT(-122.2712 47.5134)', 200);
update airport set elevation_ft = 20, geog = 'SRID=4326;POINT(-122.302 47.53)' where icao = 'KBFI';

select is((select cell_key from model_cloud_points()), '47.5,-122.3', 'one 0.1-degree cell');

-- Automated station reporting CLR (blind above 12,000 ft).
insert into metar_observation (station, observed_at, raw_text, is_auto, sky_clear_code)
values ('KBFI', now() - interval '5 minutes', 'KBFI AUTO CLR', true, 'CLR');

insert into overflight_prediction (id, spot_id, basis, icao24, callsign, pass_key, closest_approach_at, closest_distance_nm, altitude_ft)
overriding system value values
  (1, 'aaaaaaaa-0000-0000-0000-000000000001', 'live_adsb', 'a00001', 'HIGH1', 'k1', now() + interval '10 minutes', 1, 35000),
  (2, 'aaaaaaaa-0000-0000-0000-000000000001', 'live_adsb', 'a00002', 'MID2',  'k2', now() + interval '12 minutes', 1, 15000),
  (3, 'aaaaaaaa-0000-0000-0000-000000000001', 'live_adsb', 'a00003', 'LOW3',  'k3', now() + interval '14 minutes', 1, 8000);

-- No model data yet: caveat stays.
select refresh_visibility_assessments();
select is((select high_cloud_caveat from visibility_assessment where prediction_id = 1), true, 'without model data the caveat stays');

-- Model: 85% high, 40% mid for the coming hour.
select is((ingest_model_cloud(jsonb_build_array(jsonb_build_object(
  'cell_key', '47.5,-122.3', 'lat', 47.5, 'lon', -122.3, 'valid_at', date_trunc('hour', now() + interval '10 minutes'),
  'low', 0, 'mid', 40, 'high', 85, 'model', 'best_match'))))->>'upserted', '1', 'model cloud stored');

create temp table c1 as select refresh_visibility_assessments() as r;
select is((select rating from visibility_assessment where prediction_id = 1), 'partial', '85% high cloud: clear becomes partial');
select ok((select explanation like '%a lot of high cloud (85%) above about 20,000 ft%' from visibility_assessment where prediction_id = 1),
  'explained');
select ok((select explanation not like '%can''t see cloud above 12,000 ft%' from visibility_assessment where prediction_id = 1),
  'station caveat replaced by model information');
select is((select high_cloud_caveat::text || model_cloud_band || model_cloud_pct from visibility_assessment where prediction_id = 1),
  'falsehigh85', 'model fields stored, caveat cleared');
select is((select rating from visibility_assessment where prediction_id = 2), 'clear', '15,000 ft with 40% mid cloud: still clear');
select ok((select explanation like '%some cloud between 12,000 and 20,000 ft (40%)%' from visibility_assessment where prediction_id = 2),
  'mid band noted');
select is((select model_cloud_band from visibility_assessment where prediction_id = 3), null,
  '8,000 ft: below the sensor limit, model not used');

-- Clear high sky: reassuring sentence, still clear.
select ingest_model_cloud(jsonb_build_array(jsonb_build_object(
  'cell_key', '47.5,-122.3', 'lat', 47.5, 'lon', -122.3, 'valid_at', date_trunc('hour', now() + interval '10 minutes'),
  'low', 0, 'mid', 0, 'high', 10)));
select refresh_visibility_assessments();
select is((select rating from visibility_assessment where prediction_id = 1), 'clear', '10% high cloud: clear');
select ok((select explanation like '%little high cloud (10%)%' from visibility_assessment where prediction_id = 1), 'reassuring sentence');

-- Model never hides on its own; hidden from METAR is left alone.
insert into metar_observation (station, observed_at, raw_text) values ('KBFI', now(), 'KBFI OVC');
insert into cloud_layer (metar_id, seq, cover, base_agl_ft) select id, 0, 'OVC', 3000 from metar_observation where raw_text = 'KBFI OVC';
select refresh_visibility_assessments();
select is((select rating from visibility_assessment where prediction_id = 1), 'hidden', 'OVC below: hidden');
select is((select model_cloud_band from visibility_assessment where prediction_id = 1), null, 'model not applied to hidden');

select * from finish(true);
rollback;
