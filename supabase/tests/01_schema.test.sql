begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(12);

select is(
  (select count(*)::int from pg_tables where schemaname = 'public' and not rowsecurity),
  0, 'RLS enabled on every public table');

select ok(
  (select count(*)::int from pg_tables where schemaname = 'public') >= 13,
  'all core tables created (13 from phase 1, more added later)');

select is(
  (select count(*)::int from pg_indexes where schemaname = 'public' and indexdef ilike '%using gist%'),
  5, 'GiST indexes on all searched geography columns (airport, spot, route, waypoint, track)');

-- Cloud layer derivation: AGL -> MSL using station elevation, plain label, fractions.
insert into metar_observation (station, observed_at, raw_text, is_auto)
values ('KSEA', '2026-11-04 18:53Z', 'KSEA 041853Z 18008KT 10SM FEW020 BKN060 OVC250 12/08 A3001', true);
insert into cloud_layer (metar_id, seq, cover, base_agl_ft)
select id, s, c, h from metar_observation, (values (0,'FEW',2000),(1,'BKN',6000)) v(s,c,h)
where station = 'KSEA';

select is((select base_msl_ft from cloud_layer where cover = 'BKN'), 6433, 'BKN base MSL = 6000 AGL + 433 ft elevation');
select is((select plain_label from cloud_layer where cover = 'BKN'),
  'Mostly cloudy with gaps at 6,000 ft above ground', 'default plain label');
select is((select sky_fraction_max from cloud_layer where cover = 'FEW'), 0.25, 'FEW max fraction');
select is((select est_top_msl_ft from cloud_layer where cover = 'BKN'), null, 'cloud top left unknown');

update cloud_layer set base_agl_ft = 5500 where cover = 'BKN';
select is((select base_msl_ft from cloud_layer where cover = 'BKN'), 5933, 'MSL base recomputed on update');

select throws_ok(
  $$ insert into cloud_layer (metar_id, seq, cover, base_agl_ft, est_top_msl_ft)
     select id, 5, 'SCT', 3000, 9000 from metar_observation limit 1 $$,
  '23514', null, 'a cloud top requires a source');

-- Geography sanity: spot 5 nm north of KSEA is within 10 nm, not within 3 nm.
select ok(st_dwithin(a.geog, st_project(a.geog, nm_to_m(5), 0)::geography, nm_to_m(10)), 'within 10 nm')
from airport a where icao = 'KSEA';
select ok(not st_dwithin(a.geog, st_project(a.geog, nm_to_m(5), 0)::geography, nm_to_m(3)), 'not within 3 nm')
from airport a where icao = 'KSEA';

select is(round(degrees(st_azimuth(a.geog, st_project(a.geog, 9260, radians(90))::geography)))::int, 90,
  'azimuth to a point due east is 90 deg') from airport a where icao = 'KSEA';

select * from finish(true);
rollback;
