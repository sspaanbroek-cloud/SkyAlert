begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(24);

-- Payload in exactly the shape the ingest-metar Edge Function sends.
create temp table payload as select $json$[
  {"station": {"icao": "KBFI", "name": "Seattle/Boeing Fld", "lat": 47.53, "lon": -122.302, "elevation_ft": 20},
   "observed_at": "2026-11-04T18:53:00Z",
   "raw_text": "KBFI 041853Z 17006KT 10SM FEW025 BKN060 OVC090 12/08 A3001 RMK AO2",
   "report_type": "METAR", "is_auto": false, "visibility_sm": 10, "visibility_is_min": true,
   "flight_category": "VFR", "wind_dir_deg": 170, "wind_variable": false, "wind_speed_kt": 6,
   "wind_gust_kt": null, "temp_c": 12, "dewpoint_c": 8, "altimeter_hpa": 1016.3, "wx_string": null,
   "sky_clear_code": null,
   "layers": [{"cover": "FEW", "base_agl_ft": 2500, "cloud_type": null},
              {"cover": "BKN", "base_agl_ft": 6000, "cloud_type": null},
              {"cover": "OVC", "base_agl_ft": 9000, "cloud_type": null}]},
  {"station": {"icao": "KRNT", "name": "Renton Muni", "lat": 47.493, "lon": -122.216, "elevation_ft": 30},
   "observed_at": "2026-11-04T18:53:00Z",
   "raw_text": "KRNT 041853Z AUTO 00000KT 10SM CLR 11/07 A3002 RMK AO2",
   "report_type": "METAR", "is_auto": true, "visibility_sm": 10, "visibility_is_min": true,
   "flight_category": "VFR", "wind_dir_deg": 0, "wind_variable": false, "wind_speed_kt": 0,
   "wind_gust_kt": null, "temp_c": 11, "dewpoint_c": 7, "altimeter_hpa": 1016.6, "wx_string": null,
   "sky_clear_code": "CLR", "layers": []},
  {"station": {"icao": "KPAE", "name": "Everett/Paine Fld", "lat": 47.906, "lon": -122.282, "elevation_ft": 607},
   "observed_at": "2026-11-04T18:53:00Z",
   "raw_text": "KPAE 041853Z AUTO 20010KT 10SM SCT035CB 10/06 A3000",
   "report_type": "METAR", "is_auto": true, "visibility_sm": 10, "visibility_is_min": true,
   "flight_category": "VFR", "wind_dir_deg": 200, "wind_variable": false, "wind_speed_kt": 10,
   "wind_gust_kt": null, "temp_c": 10, "dewpoint_c": 6, "altimeter_hpa": 1015.9, "wx_string": null,
   "sky_clear_code": null,
   "layers": [{"cover": "SCT", "base_agl_ft": 3500, "cloud_type": "CB"}]},
  {"station": {"icao": "KBAD", "name": "Broken", "lat": 47.0, "lon": -122.0, "elevation_ft": 10},
   "observed_at": "2026-11-04T18:53:00Z", "raw_text": "KBAD 041853Z ...",
   "layers": [{"cover": "XXX", "base_agl_ft": 1000, "cloud_type": null}]}
]$json$::jsonb as j;

-- Privileges: only the ingest worker may write.
set local role authenticated;
select throws_ok($$ select ingest_metars('[]'::jsonb) $$, '42501', null, 'signed-in users cannot run ingest');
select throws_ok($$ select * from metar_fetch_areas() $$, '42501', null, 'signed-in users cannot list fetch areas');
reset role;
grant select on payload to service_role;
set local role service_role;

create temp table result1 as select ingest_metars((select j from payload)) as r;
select is((select (r->>'stored')::int from result1), 3, '3 good reports stored');
select is((select jsonb_array_length(r->'rejected') from result1), 1, 'bad report rejected, not fatal');
select is((select r->'rejected'->0->>'station' from result1), 'KBAD', 'rejection names the station');
select is((select count(*)::int from metar_observation where station = 'KBAD'), 0, 'nothing kept from the bad report');

select is((select elevation_ft from airport where icao = 'KBFI'), 20, 'airport elevation refreshed from station metadata');
select is((select name from airport where icao = 'KRNT'), 'Renton Muni', 'new station added to airport table');
select is((select count(*)::int from cloud_layer c join metar_observation m on m.id = c.metar_id where m.station = 'KBFI'),
  3, 'three KBFI layers');
select is((select base_msl_ft from cloud_layer c join metar_observation m on m.id = c.metar_id
           where m.station = 'KBFI' and c.cover = 'BKN'), 6020, 'BKN060 at a 20 ft field is 6,020 ft MSL');
select is((select plain_label from cloud_layer c join metar_observation m on m.id = c.metar_id where m.station = 'KPAE'),
  'Scattered clouds at 3,500 ft above ground (thunderstorm clouds)', 'CB noted in the label');
select is((select sky_clear_code from metar_observation where station = 'KRNT'), 'CLR', 'CLR kept');

-- Idempotent re-run, then a correction.
create temp table result2 as select ingest_metars((select j from payload)) as r;
select is((select (r->>'unchanged')::int from result2), 3, 'identical re-send changes nothing');
select is((select count(*)::int from cloud_layer), 4, 'no duplicate layers');

select ingest_metars(jsonb_build_array(jsonb_set(jsonb_set((select j->0 from payload),
  '{raw_text}', '"KBFI 041853Z COR 17006KT 10SM OVC040 12/08 A3001"'),
  '{layers}', '[{"cover": "OVC", "base_agl_ft": 4000, "cloud_type": null}]')));
select is((select count(*)::int from cloud_layer c join metar_observation m on m.id = c.metar_id where m.station = 'KBFI'),
  1, 'correction replaces the layers');
select is((select count(*)::int from metar_observation where station = 'KBFI'), 1, 'still one KBFI observation');

-- Plain-language summaries.
select is(sky_summary((select id from metar_observation where station = 'KRNT')),
  'No cloud below 12,000 ft (automated sensor; it can''t see higher)', 'CLR summary carries the 12,000 ft limit');
select is(sky_summary((select id from metar_observation where station = 'KPAE')),
  'Scattered clouds at 3,500 ft above ground (thunderstorm clouds). Automated station: it can''t see cloud above 12,000 ft',
  'automated station with gaps gets the high-cloud warning');
select is(sky_summary((select id from metar_observation where station = 'KBFI')),
  'Solid overcast at 4,000 ft above ground', 'overcast summary');

reset role;
-- Fetch areas: one box per grid cell, padded by radius + margin.
insert into auth.users (id) values ('11111111-1111-1111-1111-111111111111');
insert into spot (user_id, name, geog, elevation_ft) values
  ('11111111-1111-1111-1111-111111111111', 'Kubota', 'SRID=4326;POINT(-122.2712 47.5134)', 200),
  ('11111111-1111-1111-1111-111111111111', 'Seward Park', 'SRID=4326;POINT(-122.2530 47.5500)', 30);
set local role service_role;
select is((select count(*)::int from metar_fetch_areas()), 1, 'two spots in one cell share a fetch box');
select ok((select min_lat < 46.4 and max_lat > 48.6 and min_lon < -123.9 and max_lon > -121.1 from metar_fetch_areas()),
  'box padded by about 40 nm');

-- Nearby weather, as the spot owner.
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
select is((select array_agg(station order by distance_nm) from nearby_weather((select id from spot where name = 'Kubota'))),
  array['KBFI','KRNT','KPAE'], 'stations nearest first (KBFI 1.6 nm, KRNT 2.5 nm, KPAE 23 nm)');
select is((select jsonb_array_length(layers) from nearby_weather((select id from spot where name = 'Kubota')) where station = 'KBFI'),
  1, 'layers returned as JSON');

-- Another user gets nothing for this spot.
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
select is((select count(*)::int from nearby_weather((select id from spot limit 1))), 0,
  'no weather for someone else''s spot');

select * from finish(true);
rollback;
