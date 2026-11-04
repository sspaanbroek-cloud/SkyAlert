-- Contract test: TS TAF parser -> ingest_tafs() -> rate_taf().
begin;
set search_path = public, extensions;
select plan(4);
select is((ingest_tafs(:'payload'::jsonb))->>'stored', '1', 'parsed TAF stored');
select is((select count(*)::int from taf_period), 2, 'both periods stored');
select is((select rating from rate_taf((select id from taf_forecast), now() + interval '1 hour', 33000)), 'partial',
  'base period BKN: partial');
select is((select rating from rate_taf((select id from taf_forecast), now() + interval '6 hours', 33000)), 'hidden',
  'FM period OVC: hidden');
select * from finish(true);
rollback;
