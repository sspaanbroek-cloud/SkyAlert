-- Scheduled jobs (pg_cron + pg_net, both available on Supabase).
--
-- The METAR job calls the `ingest-metar` Edge Function. It reads two Vault
-- secrets at run time, so nothing sensitive lives in this file:
--   project_url    e.g. https://abcd1234.supabase.co  (local: http://host.docker.internal:54321)
--   ingest_secret  same value as the function's INGEST_SECRET env var
-- See README "Scheduled ingest" for the setup commands.
--
-- On a plain Postgres without pg_cron/pg_net (db-test/run.sh) this is skipped.

do $outer$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron')
     or not exists (select 1 from pg_available_extensions where name = 'pg_net') then
    raise notice 'pg_cron/pg_net not available: skipping job schedules';
    return;
  end if;

  create extension if not exists pg_cron;
  create extension if not exists pg_net with schema extensions;

  -- METARs are issued around :50-:59 each hour, with SPECIs any time.
  perform cron.schedule('ingest-metar', '*/10 * * * *', $job$
    select net.http_post(
      url     := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
                 || '/functions/v1/ingest-metar',
      headers := jsonb_build_object(
                   'Content-Type', 'application/json',
                   'x-ingest-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'ingest_secret')),
      body    := '{}'::jsonb,
      timeout_milliseconds := 55000)
  $job$);

  perform cron.schedule('purge-metar', '17 3 * * *',
    $job$ select public.purge_metar_observations(interval '3 days') $job$);
  perform cron.schedule('purge-track-points', '*/15 * * * *',
    $job$ select public.purge_track_points(interval '2 hours') $job$);
end
$outer$;
