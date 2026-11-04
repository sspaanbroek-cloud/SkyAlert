begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(17);

insert into auth.users (id) values ('11111111-1111-1111-1111-111111111111');
insert into spot (id, user_id, name, geog, elevation_ft) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Kubota',
   'SRID=4326;POINT(-122.2712 47.5134)', 200);

-- A TAF for KSEA (433 ft), issued an hour ago, valid 24 h, built relative to now:
--   BASE  BKN060
--   FM +3h  OVC030 (worse)
--   BECMG +6h..+8h  SCT040 (cloud only; visibility carries over)
--   TEMPO +1h..+2.5h  4SM -SHRA BKN025
create temp table taf as select jsonb_build_array(jsonb_build_object(
  'station', jsonb_build_object('icao', 'KSEA', 'name', 'Seattle-Tacoma Intl', 'lat', 47.4502, 'lon', -122.3088, 'elevation_ft', 433),
  'issued_at', date_trunc('minute', now()) - interval '1 hour',
  'valid_from', date_trunc('minute', now()) - interval '1 hour',
  'valid_to', date_trunc('minute', now()) + interval '23 hours',
  'raw_text', 'TAF KSEA ... test',
  'periods', jsonb_build_array(
    jsonb_build_object('change_type', 'BASE', 'time_from', now() - interval '1 hour', 'time_to', now() + interval '3 hours',
                       'visibility_sm', 6, 'visibility_is_min', true,
                       'layers', jsonb_build_array(jsonb_build_object('cover', 'BKN', 'base_agl_ft', 6000, 'cloud_type', null))),
    jsonb_build_object('change_type', 'FM', 'time_from', now() + interval '3 hours', 'time_to', now() + interval '23 hours',
                       'visibility_sm', 6, 'visibility_is_min', true,
                       'layers', jsonb_build_array(jsonb_build_object('cover', 'OVC', 'base_agl_ft', 3000, 'cloud_type', null))),
    jsonb_build_object('change_type', 'BECMG', 'time_from', now() + interval '6 hours', 'time_to', now() + interval '8 hours',
                       'layers', jsonb_build_array(jsonb_build_object('cover', 'SCT', 'base_agl_ft', 4000, 'cloud_type', null))),
    jsonb_build_object('change_type', 'TEMPO', 'time_from', now() + interval '1 hour', 'time_to', now() + interval '150 minutes',
                       'visibility_sm', 4, 'wx_string', '-SHRA',
                       'layers', jsonb_build_array(jsonb_build_object('cover', 'OVC', 'base_agl_ft', 2500, 'cloud_type', null))))
)) as j;
grant select on taf to service_role;

set local role authenticated;
select throws_ok($$ select ingest_tafs('[]') $$, '42501', null, 'users cannot ingest TAFs');
reset role;
set local role service_role;
select is((ingest_tafs((select j from taf)))->>'stored', '1', 'TAF stored');
select is((ingest_tafs((select j from taf)))->>'unchanged', '1', 'identical re-send is a no-op');
reset role;
select is((select count(*)::int from taf_period), 4, 'four periods');
select is((select layers from taf_period where change_type = 'BECMG')->0->>'cover', 'SCT', 'BECMG cloud stored');

-- rate_taf at different times, for an aircraft at 33,000 ft.
create temp table t as select id from taf_forecast;
select is((select rating from rate_taf((select id from t), now() + interval '30 minutes', 33000)), 'partial',
  'base period: BKN -> partial');
select is((select explanation from rate_taf((select id from t), now() + interval '30 minutes', 33000)),
  'Mostly cloudy at about 6,400 ft, so the aircraft will be above the clouds and visible only through gaps.',
  'base sentence, MSL height (6,000 + 433)');
select is((select rating from rate_taf((select id from t), now() + interval '4 hours', 33000)), 'hidden', 'FM: OVC -> hidden');
select is((select rating from rate_taf((select id from t), now() + interval '9 hours', 33000)), 'partial',
  'after BECMG: SCT -> partial');
select ok((select explanation like 'Scattered clouds at about 4,400 ft%' from rate_taf((select id from t), now() + interval '9 hours', 33000)),
  'BECMG cloud used, visibility carried over');
select is((select rating from rate_taf((select id from t), now() + interval '4 hours', 2000)), 'clear',
  'low aircraft under the OVC: clear');
select is((select rating from rate_taf((select id from t), now() + interval '90 minutes', 5000)), 'partial',
  'aircraft at 5,000 ft: clear under BKN 6,400, but TEMPO OVC at 2,900 makes it partial');
select ok((select explanation like '%At times, though: solid overcast at about 2,900 ft%' from rate_taf((select id from t), now() + interval '90 minutes', 5000)),
  'TEMPO explained');

-- assess_visibility picks the TAF for later passes and the METAR for soon ones.
insert into metar_observation (station, observed_at, raw_text, is_auto, sky_clear_code)
values ('KSEA', now() - interval '10 minutes', 'KSEA test', false, 'SKC');
insert into overflight_prediction (id, spot_id, basis, icao24, callsign, pass_key, closest_approach_at, closest_distance_nm, altitude_ft)
overriding system value values
  (101, 'aaaaaaaa-0000-0000-0000-000000000001', 'live_adsb', 'a00001', 'SOON1', 's1', now() + interval '10 minutes', 1, 33000),
  (102, 'aaaaaaaa-0000-0000-0000-000000000001', 'live_adsb', 'a00002', 'LATER2', 's2', now() + interval '4 hours', 1, 33000),
  (103, 'aaaaaaaa-0000-0000-0000-000000000001', 'live_adsb', 'a00003', 'BEYOND3', 's3', now() + interval '30 hours', 1, 33000);
select assess_visibility(101), assess_visibility(102), assess_visibility(103);
select is((select rating || '/' || weather_basis from visibility_assessment where prediction_id = 101),
  'clear/metar', 'soon: current METAR (clear sky)');
select is((select rating || '/' || weather_basis from visibility_assessment where prediction_id = 102),
  'hidden/taf', 'in 4 h: forecast overcast');
select ok((select explanation like 'Forecast: Solid overcast%' from visibility_assessment where prediction_id = 102), 'forecast sentence');
select is((select rating || '/' || weather_basis from visibility_assessment where prediction_id = 103),
  'clear/metar_persistence', 'beyond the TAF: current conditions, flagged');

select * from finish(true);
rollback;
