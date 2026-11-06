begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(16);

insert into auth.users (id, email, phone, phone_confirmed_at) values
  ('11111111-1111-1111-1111-111111111111', 'a@example.com', '14155550101', now()),   -- verified phone
  ('22222222-2222-2222-2222-222222222222', 'b@example.com', '14155550102', null),    -- unverified
  ('33333333-3333-3333-3333-333333333333', 'c@example.com', null, null);             -- push only

-- Consent is required to switch texts on.
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
select throws_ok($$ insert into notification_pref (sms_enabled) values (true) $$, '23514', null, 'texts need a consent time');
select lives_ok($$ insert into notification_pref (sms_enabled, sms_consent_at, sms_consent_text)
                   values (true, now(), 'I agree to receive SkyAlert alert texts') $$, 'user turns texts on with consent');
select throws_ok($$ update notification_pref set sms_opted_out_at = null $$, '42501', null, 'users cannot clear a STOP themselves');
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
select is((select count(*)::int from notification_pref), 0, 'other users cannot see it');
select lives_ok($$ insert into notification_pref (sms_enabled, sms_consent_at, sms_consent_text) values (true, now(), 'x') $$,
  'B turns texts on (but has no verified number)');
reset role;

create temp table ch as select * from alert_channels(array[
  '11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222','33333333-3333-3333-3333-333333333333']::uuid[]);
select is((select sms_to from ch where user_id = '11111111-1111-1111-1111-111111111111'), '+14155550101', 'A: text to verified number, with +');
select is((select sms_blocked_reason from ch where user_id = '22222222-2222-2222-2222-222222222222'), 'no verified phone number', 'B: unverified number not used');
select is((select coalesce(sms_to, 'none') || '/' || push_enabled::text from ch where user_id = '33333333-3333-3333-3333-333333333333'),
  'none/true', 'C: push only by default');

-- Daily cap.
select record_deliveries((select jsonb_agg(jsonb_build_object('user_id', '11111111-1111-1111-1111-111111111111', 'channel', 'sms', 'ok', true))
                          from generate_series(1, 3)));
select is((select sms_blocked_reason from alert_channels(array['11111111-1111-1111-1111-111111111111']::uuid[], 3)),
  'daily text limit reached', 'cap of 3 reached after 3 texts');
select is((select sms_to from alert_channels(array['11111111-1111-1111-1111-111111111111']::uuid[], 4)), '+14155550101', 'under a cap of 4');

-- STOP, then re-consent.
select mark_sms_opted_out(array['11111111-1111-1111-1111-111111111111']::uuid[]);
select is((select sms_blocked_reason from alert_channels(array['11111111-1111-1111-1111-111111111111']::uuid[])), 'replied STOP', 'STOP blocks texts');
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
update notification_pref set sms_consent_at = now() + interval '1 second', sms_enabled = true;
reset role;
select is((select sms_opted_out_at from notification_pref where user_id = '11111111-1111-1111-1111-111111111111'), null,
  'a fresh consent clears the STOP');

-- Queueing: a text-only user (no push device) gets alerts queued.
insert into spot (id, user_id, name, geog, elevation_ft, alerts_enabled) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'A spot', 'SRID=4326;POINT(-122.27 47.51)', 200, true),
  ('aaaaaaaa-0000-0000-0000-000000000003', '33333333-3333-3333-3333-333333333333', 'C spot', 'SRID=4326;POINT(-122.27 47.51)', 200, true);
insert into overflight_prediction (id, spot_id, basis, icao24, callsign, pass_key, closest_approach_at, closest_distance_nm, altitude_ft, confidence)
overriding system value values
  (1, 'aaaaaaaa-0000-0000-0000-000000000001', 'live_adsb', 'a00001', 'ASA1', 'k1', now() + interval '8 minutes', 1, 33000, 0.9),
  (3, 'aaaaaaaa-0000-0000-0000-000000000003', 'live_adsb', 'a00003', 'ASA3', 'k3', now() + interval '8 minutes', 1, 33000, 0.9);
insert into visibility_assessment (prediction_id, rating, explanation) values (1, 'clear', 'x'), (3, 'clear', 'x');
select is(queue_alerts(), 1, 'queued for the text user; not for C (no push device, no texts)');
select is((select user_id::text from alert), '11111111-1111-1111-1111-111111111111', 'the text user');

-- Privileges
set local role authenticated;
select throws_ok($$ select * from alert_channels(array[auth.uid()]) $$, '42501', null, 'users cannot read channels');
select throws_ok($$ select record_deliveries('[]') $$, '42501', null, 'users cannot write deliveries');

select * from finish(true);
rollback;
