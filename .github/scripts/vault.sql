-- Store (or update) the two Vault secrets the scheduled jobs read.
-- Run by the "Deploy backend" workflow:
--   psql "$SUPABASE_DB_URL" -v project_url=... -v ingest_secret=... -f vault.sql
\set ON_ERROR_STOP on
select vault.update_secret(id, :'project_url') from vault.secrets where name = 'project_url';
select vault.create_secret(:'project_url', 'project_url')
where not exists (select 1 from vault.secrets where name = 'project_url');
select vault.update_secret(id, :'ingest_secret') from vault.secrets where name = 'ingest_secret';
select vault.create_secret(:'ingest_secret', 'ingest_secret')
where not exists (select 1 from vault.secrets where name = 'ingest_secret');
select count(*) as scheduled_jobs from cron.job;
