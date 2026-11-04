begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(24);

insert into auth.users (id) values ('11111111-1111-1111-1111-111111111111'), ('22222222-2222-2222-2222-222222222222');
insert into spot (id, user_id, name, geog, elevation_ft, alerts_enabled, alerts_min_rating, alerts_lead_min) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Kubota',
   'SRID=4326;POINT(-122.2712 47.5134)', 200, true, 'clear', 10);

-- A user subscribes a browser.
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
select lives_ok($$ insert into push_subscription (endpoint, p256dh, auth, user_agent)
                   values ('https://push.example/abc', 'pkey', 'akey', 'test') $$, 'user saves a subscription');
select throws_ok($$ insert into push_subscription (endpoint, p256dh, auth) values ('http://insecure/x', 'p', 'a') $$,
  '23514', null, 'endpoint must be https');
select throws_ok($$ update spot set alerts_lead_min = 500 $$, '23514', null, 'lead time capped at 120 min');
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
select is((select count(*)::int from push_subscription), 0, 'other users cannot see it');
reset role;

-- Passes with ratings.
insert into overflight_prediction (id, spot_id, basis, icao24, callsign, pass_key, closest_approach_at, closest_distance_nm, altitude_ft, confidence)
overriding system value values
  (1, 'aaaaaaaa-0000-0000-0000-000000000001', 'live_adsb', 'a00001', 'CLEAR1', 'k1', now() + interval '8 minutes', 1, 33000, 0.9),
  (2, 'aaaaaaaa-0000-0000-0000-000000000001', 'live_adsb', 'a00002', 'PART2', 'k2', now() + interval '20 minutes', 1, 33000, 0.8),
  (3, 'aaaaaaaa-0000-0000-0000-000000000001', 'live_adsb', 'a00003', 'UNSURE3', 'k3', now() + interval '9 minutes', 1, 33000, 0.3),
  (4, 'aaaaaaaa-0000-0000-0000-000000000001', 'live_adsb', 'a00004', 'FAR4', 'k4', now() + interval '3 hours', 1, 33000, 0.9);
insert into visibility_assessment (prediction_id, rating, explanation) values
  (1, 'clear', 'x'), (2, 'partial', 'x'), (3, 'clear', 'x'), (4, 'clear', 'x');

select is(queue_alerts(), 1, 'only the clear, confident pass in the next hour is queued');
select ok((select abs(extract(epoch from notify_at - now())) < 5 from alert where prediction_id = 1),
  'pass 8 min out with a 10 min lead: notify now');
select is(queue_alerts(), 0, 'not queued twice');

update spot set alerts_min_rating = 'partial';
select is(queue_alerts(), 1, 'partial pass queued once the spot accepts partial');
select ok((select abs(extract(epoch from notify_at - (now() + interval '10 minutes'))) < 5 from alert where prediction_id = 2),
  'pass 20 min out: notify 10 min before');

-- Claim: only due ones.
create temp table c1 as select * from claim_due_alerts();
select is((select array_agg(callsign) from c1), array['CLEAR1'], 'only the due alert is claimed');
select is((select spot_name || '/' || rating from c1), 'Kubota/clear', 'claim carries what the notification needs');
select is((select status from alert where prediction_id = 1), 'sent', 'marked sent');
select is((select count(*)::int from claim_due_alerts()), 0, 'not claimed twice');

-- Rating drops before an automatic alert is due: skipped.
update alert set notify_at = now() where prediction_id = 2;
update spot set alerts_min_rating = 'clear';
update alert set min_rating = 'clear' where prediction_id = 2;
select is((select count(*)::int from claim_due_alerts()), 0, 'partial pass under a clear-only alert is not sent');
select is((select status || ': ' || status_detail from alert where prediction_id = 2), 'skipped: rating dropped to partial', 'skip reason');

-- Manual reminder on a "usual" pass, then live tracking takes over.
insert into recurring_flight (id, spot_id, callsign, typical_local_time, time_zone, days_of_week, observation_count)
overriding system value values (7, 'aaaaaaaa-0000-0000-0000-000000000001', 'USUAL7', '19:40', 'UTC', '{1,2,3,4,5,6,7}', 5);
insert into overflight_prediction (id, spot_id, basis, recurring_flight_id, callsign, pass_key, closest_approach_at, closest_distance_nm, altitude_ft, confidence)
overriding system value values (10, 'aaaaaaaa-0000-0000-0000-000000000001', 'recurring', 7, 'USUAL7', 'r1', now() + interval '2 hours', 1.5, 33000, 0.6);

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
select lives_ok($$ insert into alert (spot_id, prediction_id, notify_at, manual)
                   values ('aaaaaaaa-0000-0000-0000-000000000001', 10, now() + interval '105 minutes', true) $$,
  'user sets a reminder 15 min before a usual pass');
select throws_ok($$ insert into alert (spot_id, prediction_id, notify_at, status)
                    values ('aaaaaaaa-0000-0000-0000-000000000001', 4, now(), 'sent') $$,
  '42501', null, 'users cannot set alert status');
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
select throws_ok($$ insert into alert (spot_id, prediction_id, notify_at, manual)
                    values ('aaaaaaaa-0000-0000-0000-000000000001', 10, now(), true) $$,
  '42501', null, 'nobody else can set reminders on your passes');
reset role;

insert into overflight_prediction (id, spot_id, basis, icao24, callsign, pass_key, closest_approach_at, closest_distance_nm, altitude_ft, confidence)
overriding system value values (11, 'aaaaaaaa-0000-0000-0000-000000000001', 'live_adsb', 'a00011', 'USUAL7', 'live-usual', now() + interval '2 hours 6 minutes', 1.1, 33000, 0.7);
select is((select prediction_id from alert where manual), 11::bigint, 'reminder moved to the live pass');
select ok((select abs(extract(epoch from notify_at - (now() + interval '111 minutes'))) < 5 from alert where manual),
  'still 15 min before the (now later) pass');

-- Delivery results: a gone endpoint is removed.
select complete_alerts(jsonb_build_array(jsonb_build_object(
  'alert_id', (select id from alert where prediction_id = 1), 'delivered', 0, 'failed', 1,
  'gone', jsonb_build_array('https://push.example/abc'), 'detail', '410 Gone')));
select is((select status from alert where prediction_id = 1) || '/' || (select count(*)::text from push_subscription),
  'failed/0', 'undeliverable alert marked failed; expired subscription removed');

-- Shared browser: user B subscribes on the same endpoint; it becomes theirs.
insert into push_subscription (user_id, endpoint, p256dh, auth) values ('11111111-1111-1111-1111-111111111111', 'https://push.example/shared', 'p', 'a');
set local role authenticated;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
select lives_ok($$ select save_push_subscription('https://push.example/shared', 'p2', 'a2', 'Firefox') $$, 'save via RPC');
select is((select p256dh from push_subscription where endpoint = 'https://push.example/shared'), 'p2', 'endpoint now belongs to B, new keys');
select remove_push_subscription('https://push.example/shared');
select is((select count(*)::int from push_subscription), 0, 'B removes it');
reset role;

select * from finish(true);
rollback;
