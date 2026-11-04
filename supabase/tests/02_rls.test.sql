begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(13);

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'a@example.com'),
  ('22222222-2222-2222-2222-222222222222', 'b@example.com');

-- User A
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

select lives_ok(
  $$ insert into spot (name, geog, elevation_ft) values ('Kubota Garden', 'SRID=4326;POINT(-122.2712 47.5134)', 200) $$,
  'user can create a spot (user_id defaults to auth.uid())');
select is((select user_id::text from spot), '11111111-1111-1111-1111-111111111111', 'spot owned by caller');
select is((select search_radius_nm from spot), 10.0, 'default radius 10 nm');
select ok((select abs(lat - 47.5134) < 1e-6 from spot), 'lat generated column');
select throws_ok(
  $$ update spot set user_id = '22222222-2222-2222-2222-222222222222' $$,
  '42501', null, 'cannot reassign spot ownership');
select throws_ok(
  $$ insert into spot (user_id, name, geog) values ('22222222-2222-2222-2222-222222222222', 'x', 'SRID=4326;POINT(0 0)') $$,
  '42501', null, 'cannot create a spot for someone else');
select is((select count(*)::int from airport), 2, 'signed-in user reads airports');
select throws_ok($$ insert into airport (icao, geog, elevation_ft) values ('KXXX', 'SRID=4326;POINT(0 0)', 0) $$,
  '42501', null, 'signed-in user cannot write shared data');

-- Worker creates a prediction for A's spot.
reset role;
insert into track_point (icao24, observed_at, callsign, geog, altitude_ft)
values ('a1b2c3', now(), 'ASA123', 'SRID=4326;POINT(-122.28 47.52)', 33000);
insert into overflight_prediction (spot_id, basis, icao24, callsign, pass_key, closest_approach_at, closest_distance_nm, altitude_ft)
select id, 'live_adsb', 'a1b2c3', 'ASA123', 'adsb:a1b2c3:test', now() + interval '5 min', 0.8, 33000 from spot;
do $$ begin
  perform set_config('test.spot_id', (select id::text from public.spot), true);
  perform set_config('test.pred_id', (select id::text from public.overflight_prediction), true);
end $$;

-- User B
set local role authenticated;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
select is((select count(*)::int from spot), 0, 'other user cannot see the spot');
select is((select count(*)::int from overflight_prediction), 0, 'other user cannot see its predictions');
select throws_ok(
  $$ insert into alert (spot_id, prediction_id, notify_at)
     values (current_setting('test.spot_id')::uuid, current_setting('test.pred_id')::bigint, now()) $$,
  '42501', null, 'other user cannot set an alert on a pass they do not own');

-- Back to A: alert on own prediction works.
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
reset role; set local role authenticated;
select lives_ok(
  $$ insert into alert (spot_id, prediction_id, notify_at)
     select spot_id, id, closest_approach_at - interval '10 min' from overflight_prediction $$,
  'owner can set an alert on own prediction');

-- anon sees nothing
set local role anon;
select throws_ok($$ select * from airport $$, '42501', null, 'anon has no table access');

select * from finish(true);
rollback;
