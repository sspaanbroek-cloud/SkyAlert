begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(11);

-- The harness loads db-test/airports_sample.csv with .github/scripts/load-airports.sh first.
select is((select count(*)::int from airport_directory), 9, 'airports loaded; heliports and closed fields left out');
select is((select name from airport_directory where ident = 'KSEA'), 'Seattle–Tacoma International Airport', 'names kept as published');

insert into auth.users (id) values ('11111111-1111-1111-1111-111111111111');
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

select is((select ident from find_airport('KSEA') limit 1), 'KSEA', 'ICAO code');
select is((select ident || ' ' || matched from find_airport('sea') limit 1), 'KSEA iata', 'IATA code, any case');
select is((select ident from find_airport('LHR') limit 1), 'EGLL', 'IATA for a non-US airport');
select is((select ident from find_airport('0S9') limit 1), 'K0S9', 'US FAA id finds the airport');
select is((select code from find_airport('0S9') limit 1), '0S9', 'shown by the code pilots use (no ICAO code: GPS code)');
select ok((select abs(lat - 47.449) < 0.01 and abs(lon + 122.309) < 0.01 and elevation_ft = 433 from find_airport('KSEA') limit 1),
  'position and elevation');
select is((select count(*)::int from find_airport('ZZZZ')), 0, 'unknown code: nothing');
select is((select count(*)::int from find_airport(' ')), 0, 'blank: nothing');
reset role;

-- Reloading replaces rather than duplicates (the loader deletes and re-inserts in one transaction).
select is((select count(distinct ident)::int from airport_directory), (select count(*)::int from airport_directory), 'one row per airport');

select * from finish(true);
rollback;
