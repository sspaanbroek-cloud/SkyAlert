begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(26);

insert into auth.users (id) values ('11111111-1111-1111-1111-111111111111');
insert into spot (id, user_id, name, geog, elevation_ft) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Kubota',
   'SRID=4326;POINT(-122.2712 47.5134)', 200);
insert into airport (icao, name, geog, elevation_ft) values
  ('KPDX', 'Portland Intl', 'SRID=4326;POINT(-122.5975 45.5887)', 31),
  ('KPAE', 'Paine Fld', 'SRID=4326;POINT(-122.282 47.906)', 607)
on conflict (icao) do nothing;

-- Synthetic NASR extract.
insert into nav_fix (ident, kind, geog, state_code) values
  ('SEA', 'navaid', 'SRID=4326;POINT(-122.3097 47.4354)', 'WA'),
  ('OLM', 'navaid', 'SRID=4326;POINT(-122.9027 46.9715)', 'WA'),
  ('OLM', 'fix',    'SRID=4326;POINT(-81.0 28.0)', 'FL'),          -- same ident far away
  ('BTG', 'navaid', 'SRID=4326;POINT(-122.5937 45.7477)', 'WA');
insert into nav_fix (ident, kind, icao_ident, geog) values ('BFI', 'airport', 'KBFI', 'SRID=4326;POINT(-122.302 47.53)');
insert into airway_fix (airway_id, seq, ident, geog) values
  ('J1', 10, 'SEA', 'SRID=4326;POINT(-122.3097 47.4354)'),
  ('J1', 20, 'OLM', 'SRID=4326;POINT(-122.9027 46.9715)'),
  ('J1', 30, 'BTG', 'SRID=4326;POINT(-122.5937 45.7477)');

-- Coordinates
select ok(abs(st_y(parse_coord_token('4730N12216W')::geometry) - 47.5) < 1e-9
          and abs(st_x(parse_coord_token('4730N12216W')::geometry) + 122.26667) < 1e-4, 'ddmm coordinates');
select ok(abs(st_x(parse_coord_token('47N122W')::geometry) + 122) < 1e-9, 'whole-degree coordinates');
select is(parse_coord_token('9930N12216W'), null, 'invalid latitude rejected');

-- Route resolution
create temp table r as select resolve_route('N0450F350 BTG J1 SEA DCT 4730N12216W HAWKZ7 ZZQQX KPAE', 'KPDX', 'KPAE') as j;
select is((select array_agg(p->>'ident' order by o) from r, jsonb_array_elements(j->'points') with ordinality as x(p, o)),
  array['KPDX','BTG','OLM','SEA','4730N12216W','KPAE'], 'route points in order, airway expanded backwards');
select is((select p->>'via' from r, jsonb_array_elements(j->'points') p where p->>'ident' = 'OLM'), 'J1', 'OLM came from J1');
select ok((select abs((p->>'lon')::float8 + 122.9027) < 1e-6 from r, jsonb_array_elements(j->'points') p where p->>'ident' = 'OLM'),
  'ambiguous ident resolved to the nearby OLM, not Florida');
select is((select j->'skipped' from r), '["HAWKZ7"]'::jsonb, 'STAR skipped and listed');
select is((select j->'unresolved' from r), '["ZZQQX"]'::jsonb, 'unknown token listed');
select is((select jsonb_array_length(resolve_route('KPDX..BTG.J1.SEA..KPAE', 'KPDX', 'KPAE')->'points')), 5,
  'FAA dotted format works');
select is((select array_agg(p->>'ident') from jsonb_array_elements(resolve_route('SEA J1 BTG', 'KBFI', 'KPDX')->'points') p),
  array['KBFI','SEA','OLM','BTG','KPDX'], 'forward airway, FAA-id airport from NASR');

-- Mid-route, SEA is the VOR even when flying to KSEA; at the ends it's the airport.
select is((select array_agg(p->>'ident') from jsonb_array_elements(resolve_route('BTG J1 SEA', 'KPDX', 'KSEA')->'points') p),
  array['KPDX','BTG','OLM','SEA','KSEA'], 'navaid SEA kept on a flight to KSEA');
select is((select array_agg(p->>'ident') from jsonb_array_elements(resolve_route('PDX BTG J1 OLM', 'KPDX', 'KOLM')->'points') p),
  array['KPDX','BTG','OLM'], 'leading FAA airport id (PDX) dropped; KOLM unknown so no end point');

-- Plan ingest
create temp table ing as select ingest_flight_plans(jsonb_build_array(
  jsonb_build_object('source', 'test', 'source_ref', 'p1', 'callsign', 'asa123', 'origin', 'KPDX', 'destination', 'KPAE',
                     'aircraft_type', 'B738', 'rules', 'IFR', 'filed_cruise_ft', 35000, 'filed_speed_kt', 420,
                     'filed_etd', date_trunc('minute', now()) + interval '1 hour',
                     'route_string', 'N0450F350 BTG J1 SEA DCT 4730N12216W HAWKZ7 KPAE'),
  jsonb_build_object('source', 'test', 'source_ref', 'p2', 'callsign', 'NOWHERE', 'origin', 'XXXX', 'destination', 'YYYY',
                     'filed_etd', now(), 'route_string', 'ZZQQX')
)) as r;
select is((select r->>'stored' from ing), '2', 'both plans stored');
select is((select route_status from flight_plan where source_ref = 'p1'), 'resolved', 'p1 resolved (STAR skipped is noted, not unresolved)');
select ok((select route_note like '%HAWKZ7%' from flight_plan where source_ref = 'p1'), 'note lists the skipped STAR');
select is((select route_status from flight_plan where source_ref = 'p2'), 'failed', 'p2 cannot be resolved');
select is((select callsign from flight_plan where source_ref = 'p1'), 'ASA123', 'callsign upper-cased');
select ok((select route_total_nm between 140 and 160 from flight_plan where source_ref = 'p1'), 'route length about 150 nm');
select is((select count(*)::int from route_waypoint w join flight_plan f on f.id = w.flight_plan_id where f.source_ref = 'p1'), 6,
  'six waypoints');
select is((select string_agg(altitude_ft::text, ',' order by seq) from route_waypoint w join flight_plan f on f.id = w.flight_plan_id where f.source_ref = 'p1'),
  '31,2894,21458,9714,8360,607', 'climb 300 ft/nm, 3-degree descent; a 150 nm hop never reaches FL350');

-- Plan predictions
create temp table cp as select compute_plan_predictions() as r;
select is((select r->>'upserted' from cp), '1', 'one plan pass over the spot');
select ok((select closest_distance_nm < 1.5 from overflight_prediction where basis = 'filed_plan'), 'passes about a mile away');
select ok((select altitude_ft between 6000 and 11000 from overflight_prediction where basis = 'filed_plan'),
  'descending into Paine Field: about 8,000 ft over the spot');
select ok((select closest_approach_at between (select filed_etd from flight_plan where source_ref = 'p1') + interval '30 minutes'
                                          and (select filed_etd from flight_plan where source_ref = 'p1') + interval '50 minutes'
           from overflight_prediction where basis = 'filed_plan'), 'ETA about 40 min after departure');

-- Live tracking picks the flight up: plan pass replaced and not re-created.
insert into overflight_prediction (spot_id, basis, icao24, callsign, pass_key, closest_approach_at, closest_distance_nm, altitude_ft)
select spot_id, 'live_adsb', 'a1b2c3', 'ASA123', 'adsb:x', closest_approach_at + interval '4 minutes', 0.8, 8000
from overflight_prediction where basis = 'filed_plan';
select is((select count(*)::int from overflight_prediction where basis = 'filed_plan'), 0, 'live pass replaced the plan pass');
select compute_plan_predictions();
select is((select count(*)::int from overflight_prediction where basis = 'filed_plan'), 0, 'not re-created while live has it');

select * from finish(true);
rollback;
