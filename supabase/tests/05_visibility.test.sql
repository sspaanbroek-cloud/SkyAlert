begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(26);

-- Spot at Kubota Garden (200 ft). Stations: KBFI 1.6 nm, KRNT 2.5 nm, KPAE 23 nm.
insert into auth.users (id) values ('11111111-1111-1111-1111-111111111111'), ('22222222-2222-2222-2222-222222222222');
insert into spot (id, user_id, name, geog, elevation_ft) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Kubota',
   'SRID=4326;POINT(-122.2712 47.5134)', 200);
insert into airport (icao, name, geog, elevation_ft) values
  ('KRNT', 'Renton', 'SRID=4326;POINT(-122.216 47.493)', 30),
  ('KPAE', 'Paine', 'SRID=4326;POINT(-122.282 47.906)', 607),
  ('KSEA', 'Sea-Tac', 'SRID=4326;POINT(-122.3088 47.4502)', 433)
on conflict (icao) do update set geog = excluded.geog, elevation_ft = excluded.elevation_ft;
update airport set elevation_ft = 20, geog = 'SRID=4326;POINT(-122.302 47.53)' where icao = 'KBFI';

-- metar(station, minutes ago, layers "COVER:agl_ft[:CB]", auto, clear code, vis)
create function pg_temp.metar(st text, ago int, layers text[], auto boolean default false,
                              clr text default null, vis numeric default 10, wx text default null)
returns bigint language plpgsql as $$
declare mid bigint; i int := 0; l text;
begin
  delete from metar_observation where station = st;
  insert into metar_observation (station, observed_at, raw_text, is_auto, sky_clear_code, visibility_sm, wx_string)
  values (st, now() - make_interval(mins => ago), st || ' test', auto, clr, vis, wx) returning id into mid;
  foreach l in array layers loop
    insert into cloud_layer (metar_id, seq, cover, base_agl_ft, cloud_type)
    values (mid, i, split_part(l, ':', 1), split_part(l, ':', 2)::int, nullif(split_part(l, ':', 3), ''));
    i := i + 1;
  end loop;
  return mid;
end $$;

-- rate_sky: single-station rules
select pg_temp.metar('KBFI', 10, array['BKN:6000']);
select is((select rating from rate_sky((select id from metar_observation where station='KBFI'), 33000)), 'partial',
  'BKN below aircraft: partial');
select is((select explanation from rate_sky((select id from metar_observation where station='KBFI'), 33000)),
  'Mostly cloudy at about 6,000 ft, so the aircraft will be above the clouds and visible only through gaps.',
  'BKN sentence uses MSL height (6,000 AGL + 20 ft field)');
select is((select clear_margin_ft from rate_sky((select id from metar_observation where station='KBFI'), 33000)), -26980,
  'margin: base 6,020 MSL minus 33,000');
select is((select rating from rate_sky((select id from metar_observation where station='KBFI'), 5000)), 'clear',
  'same cloud above a low aircraft: clear');
select is((select explanation from rate_sky((select id from metar_observation where station='KBFI'), 5000)),
  'The lowest cloud, mostly cloudy with gaps at about 6,000 ft, is above the aircraft, so it will fly below the clouds in clear view.',
  'below-the-clouds sentence');
select is((select clear_margin_ft from rate_sky((select id from metar_observation where station='KBFI'), 5000)), 1020,
  'positive margin when cloud is above');

select pg_temp.metar('KBFI', 10, array['FEW:2500','SCT:5000','OVC:9000']);
select is((select rating from rate_sky((select id from metar_observation where station='KBFI'), 35000)), 'hidden',
  'OVC anywhere below decides: hidden');
select is((select limiting_cover from rate_sky((select id from metar_observation where station='KBFI'), 35000)), 'OVC',
  'limiting cover OVC');
select is((select rating from rate_sky((select id from metar_observation where station='KBFI'), 7000)), 'partial',
  'aircraft between SCT and OVC: partial');

select pg_temp.metar('KBFI', 10, array['FEW:3000']);
select is((select rating from rate_sky((select id from metar_observation where station='KBFI'), 20000)), 'clear',
  'FEW below: clear');

select pg_temp.metar('KBFI', 10, array[]::text[], true, 'CLR');
select is((select rating from rate_sky((select id from metar_observation where station='KBFI'), 35000)), 'clear', 'CLR: clear');
select is((select high_cloud_caveat from rate_sky((select id from metar_observation where station='KBFI'), 35000)), true,
  'CLR + aircraft above 12,000 ft: high-cloud caveat');
select ok((select explanation like '%can''t see cloud above 12,000 ft%' from rate_sky((select id from metar_observation where station='KBFI'), 35000)),
  'caveat explained');
select is((select high_cloud_caveat from rate_sky((select id from metar_observation where station='KBFI'), 8000)), false,
  'no caveat for an aircraft below 12,000 ft');

select pg_temp.metar('KBFI', 10, array['SCT:3000'], false, null, 0.5, 'FG');
select is((select rating from rate_sky((select id from metar_observation where station='KBFI'), 30000)), 'hidden',
  'visibility under 1 mile: hidden');
select pg_temp.metar('KBFI', 10, array[]::text[], false, 'SKC', 2, 'HZ');
select is((select rating from rate_sky((select id from metar_observation where station='KBFI'), 30000)), 'partial',
  'haze under 3 miles turns clear into partial');
select pg_temp.metar('KBFI', 10, array[]::text[]);
select is((select rating from rate_sky((select id from metar_observation where station='KBFI'), 30000)), 'unknown',
  'sky not reported: unknown');

-- assess_visibility: blending and storage
insert into overflight_prediction (id, spot_id, basis, icao24, callsign, pass_key, closest_approach_at, closest_distance_nm, altitude_ft)
overriding system value values
  (1, 'aaaaaaaa-0000-0000-0000-000000000001', 'live_adsb', 'a00001', 'ASA123', 'k1', now() + interval '6 min', 1.2, 33000),
  (2, 'aaaaaaaa-0000-0000-0000-000000000001', 'live_adsb', 'a00002', null, 'k2', now() + interval '8 min', 2.0, null);

delete from metar_observation;
select pg_temp.metar('KBFI', 10, array['BKN:6000']);
select pg_temp.metar('KRNT', 20, array['BKN:5500']);
select pg_temp.metar('KPAE', 15, array[]::text[], true, 'CLR');
select is(assess_visibility(1), 'partial', 'two near stations BKN, far one clear: partial');
select is((select metar_station from visibility_assessment where prediction_id = 1), 'KBFI', 'nearest agreeing station explains');
select is((select stations_used from visibility_assessment where prediction_id = 1), array['KBFI','KRNT','KPAE'], 'stations used');
select ok((select explanation like '%Other nearby reports differ (KPAE looks clear)%' from visibility_assessment where prediction_id = 1),
  'disagreement mentioned');
select is((select obs_age_min from visibility_assessment where prediction_id = 1), 10, 'observation age kept');

select is(assess_visibility(2), 'unknown', 'no altitude: unknown');

-- Weather improves: refresh re-rates current passes in place.
select pg_temp.metar('KBFI', 0, array['FEW:4000']);
select pg_temp.metar('KRNT', 0, array['SCT:25000']);
select is((select refresh_visibility_assessments()->>'clear'), '1', 'refresh re-rates');
select is((select rating from visibility_assessment where prediction_id = 1), 'clear', 'pass now clear');

-- RLS: only the spot owner sees the assessment.
set local role authenticated;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
select is((select count(*)::int from visibility_assessment), 0, 'other users see no assessments');

select * from finish(true);
rollback;
