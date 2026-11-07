begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(19);

-- Lightning phrases from METAR remarks
select is(lightning_remark('KMIA 041853Z 09012G22KT 6SM TSRA BKN040CB 27/24 A2990 RMK AO2 OCNL LTGICCG DSNT NE TSB45'),
  'OCNL LTGICCG DSNT NE', 'frequency, type, distance, direction');
select is(lightning_remark('KDEN 041853Z 10SM SCT080 RMK AO2 LTG DSNT W-NW'), 'LTG DSNT W-NW', 'direction range');
select is(lightning_remark('KXYZ 041853Z 10SM FEW030 RMK AO2 FRQ LTGCG OHD AND VC'), 'FRQ LTGCG OHD AND VC', 'overhead and in the vicinity');
select is(lightning_remark('KSEA 041853Z 10SM BKN060 RMK AO2 SLP165'), null, 'no lightning');
select is(lightning_remark('KSEA 041853Z 10SM BKN060 RMK SALTGRASS'), null, 'LTG inside another word is ignored');

insert into auth.users (id) values ('11111111-1111-1111-1111-111111111111'), ('22222222-2222-2222-2222-222222222222');
insert into spot (id, user_id, name, geog, elevation_ft) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Kubota',
   'SRID=4326;POINT(-122.2712 47.5134)', 200);

-- nearby_weather carries the remark
insert into metar_observation (station, observed_at, raw_text, sky_clear_code)
values ('KBFI', now() - interval '5 minutes', 'KBFI 041853Z 10SM CLR RMK AO2 LTG DSNT SE', 'CLR');
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
select is((select lightning_remark from nearby_weather('aaaaaaaa-0000-0000-0000-000000000001') where station = 'KBFI'),
  'LTG DSNT SE', 'nearby_weather returns the lightning remark');
reset role;

-- A TAF for KSEA, relative to now:
--   BASE  -1h..+3h  BKN060
--   FM    +3h       OVC030 -RA
--   TEMPO +1h..+2h  TSRA BKN025CB
--   BECMG +6h..+8h  wind only (no cloud)
--   PROB  +20h      fog (outside a 12 h window)
select ingest_tafs(jsonb_build_array(jsonb_build_object(
  'station', jsonb_build_object('icao', 'KSEA', 'name', 'Seattle-Tacoma Intl', 'lat', 47.4502, 'lon', -122.3088, 'elevation_ft', 433),
  'issued_at', date_trunc('minute', now()) - interval '2 hours',
  'valid_from', date_trunc('minute', now()) - interval '1 hour',
  'valid_to', date_trunc('minute', now()) + interval '23 hours',
  'raw_text', 'TAF KSEA test',
  'periods', jsonb_build_array(
    jsonb_build_object('change_type', 'BASE', 'time_from', now() - interval '1 hour', 'time_to', now() + interval '3 hours',
      'visibility_sm', 6, 'visibility_is_min', true,
      'layers', jsonb_build_array(jsonb_build_object('cover', 'BKN', 'base_agl_ft', 6000, 'cloud_type', null))),
    jsonb_build_object('change_type', 'FM', 'time_from', now() + interval '3 hours',
      'visibility_sm', 5, 'wx_string', '-RA',
      'layers', jsonb_build_array(jsonb_build_object('cover', 'OVC', 'base_agl_ft', 3000, 'cloud_type', null))),
    jsonb_build_object('change_type', 'TEMPO', 'time_from', now() + interval '1 hour', 'time_to', now() + interval '2 hours',
      'visibility_sm', 3, 'wx_string', 'TSRA',
      'layers', jsonb_build_array(jsonb_build_object('cover', 'BKN', 'base_agl_ft', 2500, 'cloud_type', 'CB'))),
    jsonb_build_object('change_type', 'BECMG', 'time_from', now() + interval '6 hours', 'time_to', now() + interval '8 hours'),
    jsonb_build_object('change_type', 'PROB', 'probability', 30, 'time_from', now() + interval '20 hours', 'time_to', now() + interval '22 hours',
      'visibility_sm', 0.5, 'wx_string', 'FG',
      'layers', jsonb_build_array(jsonb_build_object('cover', 'VV', 'base_agl_ft', 200, 'cloud_type', null))))
)));

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
create temp table f as select * from nearby_forecast('aaaaaaaa-0000-0000-0000-000000000001');
select is((select array_agg(change_type order by seq) from f), array['BASE','FM','TEMPO','BECMG'], 'groups in the next 12 h, in order');
select is((select count(distinct station)::int from f), 1, 'one station');
select is((select min(station) from f), 'KSEA', 'nearest station with a TAF (KBFI has none)');
select is((select issued_age_min from f limit 1) between 119 and 121, true, 'issue age about 2 h');
select is((select cloud_summary from f where change_type = 'BASE'), 'Mostly cloudy with gaps at 6,000 ft above ground', 'base period wording');
select is((select cloud_summary from f where change_type = 'TEMPO'), 'Mostly cloudy with gaps at 2,500 ft above ground (thunderstorm clouds)',
  'TEMPO wording with CB');
select is((select thunder from f where change_type = 'TEMPO'), true, 'TSRA flagged as thunder');
select is((select thunder from f where change_type = 'FM'), false, 'rain is not thunder');
select is((select cloud_summary from f where change_type = 'BECMG'), null, 'wind-only BECMG: cloud unchanged');
select ok((select abs(extract(epoch from time_to - (now() + interval '3 hours'))) < 2 from f where change_type = 'BASE'),
  'base period ends at its own end time');
select ok((select abs(extract(epoch from time_to - (select valid_to from taf_forecast))) < 2 from f where change_type = 'FM'),
  'FM with no end runs to the end of the TAF');
select is((select count(*)::int from nearby_forecast('aaaaaaaa-0000-0000-0000-000000000001', 24) where change_type = 'PROB'), 1,
  'a 24 h window includes the later PROB30 fog');

set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
select is((select count(*)::int from nearby_forecast('aaaaaaaa-0000-0000-0000-000000000001')), 0, 'no forecast for someone else''s spot');

select * from finish(true);
rollback;
