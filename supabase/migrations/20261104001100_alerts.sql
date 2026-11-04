-- Web push alerts (phase 2, part 4).
--
-- * push_subscription: one row per browser/device that allowed notifications.
-- * spot alert settings: automatic alerts for live passes that meet a rating.
-- * alert: queued notifications. Automatic ones come from queue_alerts();
--   "Remind me" ones are inserted by the user (manual = true).
-- * claim_due_alerts() hands due alerts to the `send-alerts` Edge Function,
--   re-checking the rating for automatic alerts at send time.
set search_path = public, extensions;

-------------------------------------------------------------------------------
-- Subscriptions
-------------------------------------------------------------------------------
create table public.push_subscription (
  id               bigint generated always as identity primary key,
  user_id          uuid not null default auth.uid() references auth.users (id) on delete cascade,
  endpoint         text not null unique check (endpoint ~ '^https://'),
  p256dh           text not null,
  auth             text not null,
  user_agent       text,
  created_at       timestamptz not null default now(),
  last_success_at  timestamptz,
  failure_count    integer not null default 0
);
create index push_subscription_user_idx on public.push_subscription (user_id);

alter table public.push_subscription enable row level security;
create policy "owner select" on public.push_subscription for select to authenticated
  using (user_id = (select auth.uid()));
create policy "owner insert" on public.push_subscription for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy "owner delete" on public.push_subscription for delete to authenticated
  using (user_id = (select auth.uid()));
-- Re-subscribing the same browser refreshes its keys (upsert on endpoint).
create policy "owner update" on public.push_subscription for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
revoke update on public.push_subscription from authenticated;
grant update (p256dh, auth, user_agent) on public.push_subscription to authenticated;
revoke all on public.push_subscription from anon;

-------------------------------------------------------------------------------
-- Spot alert settings
-------------------------------------------------------------------------------
alter table public.spot
  add column alerts_enabled boolean not null default false,
  add column alerts_min_rating text not null default 'clear' check (alerts_min_rating in ('clear', 'partial')),
  add column alerts_lead_min smallint not null default 10 check (alerts_lead_min between 1 and 120);
grant update (alerts_enabled, alerts_min_rating, alerts_lead_min) on public.spot to authenticated;

-------------------------------------------------------------------------------
-- Alert status
-------------------------------------------------------------------------------
alter table public.alert
  add column manual boolean not null default false,
  add column status text not null default 'pending' check (status in ('pending', 'sent', 'skipped', 'failed')),
  add column status_detail text;

-- Users create reminders with only these columns; status is the worker's.
revoke insert on public.alert from authenticated;
grant insert (spot_id, prediction_id, notify_at, min_rating, manual) on public.alert to authenticated;

-------------------------------------------------------------------------------
-- When live tracking replaces a "usual" pass, move its pending alerts over,
-- keeping the same lead time before the pass.
-------------------------------------------------------------------------------
create or replace function public.live_replaces_recurring()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.basis = 'live_adsb' and new.callsign is not null then
    update public.alert a
    set prediction_id = new.id,
        notify_at = new.closest_approach_at - (p.closest_approach_at - a.notify_at)
    from public.overflight_prediction p
    where a.prediction_id = p.id
      and a.status = 'pending'
      and p.spot_id = new.spot_id and p.basis = 'recurring' and p.callsign = new.callsign
      and p.closest_approach_at between new.closest_approach_at - interval '45 minutes'
                                    and new.closest_approach_at + interval '45 minutes'
      and not exists (select 1 from public.alert x where x.user_id = a.user_id and x.prediction_id = new.id);

    delete from public.overflight_prediction p
    where p.spot_id = new.spot_id and p.basis = 'recurring' and p.callsign = new.callsign
      and p.closest_approach_at between new.closest_approach_at - interval '45 minutes'
                                    and new.closest_approach_at + interval '45 minutes';
  end if;
  return null;
end $$;

-------------------------------------------------------------------------------
-- queue_alerts(): automatic alerts for live (and, later, filed-plan) passes
-- in the next hour that meet the spot's rating, with confidence >= 0.5.
-------------------------------------------------------------------------------
create or replace function public.queue_alerts()
returns integer language plpgsql security definer set search_path = ''
as $$
declare n integer;
begin
  insert into public.alert (user_id, spot_id, prediction_id, notify_at, min_rating, manual)
  select s.user_id, s.id, p.id,
         greatest(now(), p.closest_approach_at - make_interval(mins => s.alerts_lead_min)),
         s.alerts_min_rating, false
  from public.overflight_prediction p
  join public.spot s on s.id = p.spot_id
  join public.visibility_assessment va on va.prediction_id = p.id
  where s.alerts_enabled
    and p.basis in ('live_adsb', 'filed_plan')
    and p.closest_approach_at > now() + interval '1 minute'
    and p.closest_approach_at <= now() + interval '60 minutes'
    and coalesce(p.confidence, 0) >= 0.5
    and (va.rating = 'clear' or (s.alerts_min_rating = 'partial' and va.rating = 'partial'))
    and exists (select 1 from public.push_subscription ps where ps.user_id = s.user_id)
  on conflict (user_id, prediction_id) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-------------------------------------------------------------------------------
-- claim_due_alerts(): mark due alerts sent (or skipped) and return what to send.
-- Skipped: the pass is already over, or (automatic alerts only) the rating
-- has dropped below the spot's minimum since the alert was queued.
-------------------------------------------------------------------------------
create or replace function public.claim_due_alerts(p_limit integer default 100)
returns table (
  alert_id bigint, user_id uuid, spot_id uuid, spot_name text, time_zone text,
  prediction_id bigint, basis text, callsign text, icao24 text,
  closest_approach_at timestamptz, closest_distance_nm numeric, altitude_ft integer,
  azimuth_deg numeric, elevation_deg numeric, rating text, manual boolean)
language plpgsql security definer set search_path = ''
as $$
begin
  -- Over already, or gone (prediction deleted cascades the alert away).
  update public.alert a set status = 'skipped', status_detail = 'pass already over'
  from public.overflight_prediction p
  where a.prediction_id = p.id and a.status = 'pending' and a.notify_at <= now()
    and p.closest_approach_at < now() - interval '1 minute';

  update public.alert a set status = 'skipped', status_detail = 'rating dropped to ' || coalesce(va.rating, 'unknown')
  from public.overflight_prediction p
  left join public.visibility_assessment va on va.prediction_id = p.id
  where a.prediction_id = p.id and a.status = 'pending' and a.notify_at <= now() and not a.manual
    and not (coalesce(va.rating, 'unknown') = 'clear' or (a.min_rating = 'partial' and va.rating = 'partial'));

  return query
  with due as (
    select a.id from public.alert a
    where a.status = 'pending' and a.notify_at <= now()
    order by a.notify_at
    limit p_limit
    for update skip locked
  ), marked as (
    update public.alert a set status = 'sent', sent_at = now()
    from due where a.id = due.id
    returning a.*
  )
  select m.id, m.user_id, s.id, s.name, s.time_zone,
         p.id, p.basis, p.callsign, p.icao24,
         p.closest_approach_at, p.closest_distance_nm, p.altitude_ft,
         p.azimuth_deg, p.elevation_deg, coalesce(va.rating, 'unknown'), m.manual
  from marked m
  join public.overflight_prediction p on p.id = m.prediction_id
  join public.spot s on s.id = m.spot_id
  left join public.visibility_assessment va on va.prediction_id = p.id;
end $$;

-- Record delivery results from the worker.
--   results: [{alert_id, delivered (count), failed (count), gone: [endpoint...], detail}]
create or replace function public.complete_alerts(results jsonb)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  update public.alert a
  set status = case when (r->>'delivered')::int > 0 then 'sent' else 'failed' end,
      status_detail = r->>'detail'
  from jsonb_array_elements(results) r
  where a.id = (r->>'alert_id')::bigint;

  delete from public.push_subscription
  where endpoint in (select jsonb_array_elements_text(r->'gone') from jsonb_array_elements(results) r);
end $$;

create or replace function public.mark_push_results(ok_endpoints text[], failed_endpoints text[])
returns void language sql security definer set search_path = ''
as $$
  update public.push_subscription set last_success_at = now(), failure_count = 0 where endpoint = any (ok_endpoints);
  update public.push_subscription set failure_count = failure_count + 1 where endpoint = any (failed_endpoints);
  delete from public.push_subscription where failure_count >= 10;
$$;

revoke execute on function public.queue_alerts() from public, anon, authenticated;
revoke execute on function public.claim_due_alerts(integer) from public, anon, authenticated;
revoke execute on function public.complete_alerts(jsonb) from public, anon, authenticated;
revoke execute on function public.mark_push_results(text[], text[]) from public, anon, authenticated;
grant execute on function public.queue_alerts() to service_role;
grant execute on function public.claim_due_alerts(integer) to service_role;
grant execute on function public.complete_alerts(jsonb) to service_role;
grant execute on function public.mark_push_results(text[], text[]) to service_role;

do $outer$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron')
     or not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_cron/pg_net not installed: skipping alert schedule';
    return;
  end if;
  perform cron.schedule('send-alerts', '* * * * *', $job$
    select net.http_post(
      url     := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
                 || '/functions/v1/send-alerts',
      headers := jsonb_build_object(
                   'Content-Type', 'application/json',
                   'x-ingest-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'ingest_secret')),
      body    := '{}'::jsonb,
      timeout_milliseconds := 50000)
  $job$);
  perform cron.schedule('purge-alerts', '51 3 * * *',
    $job$ delete from public.alert where status <> 'pending' and created_at < now() - interval '30 days' $job$);
end
$outer$;

-------------------------------------------------------------------------------
-- Save / remove this browser's subscription. A browser endpoint belongs to
-- whoever subscribed on it last (shared devices, signing in as someone else).
-------------------------------------------------------------------------------
create or replace function public.save_push_subscription(
  p_endpoint text, p_p256dh text, p_auth text, p_user_agent text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  insert into public.push_subscription (user_id, endpoint, p256dh, auth, user_agent)
  values (uid, p_endpoint, p_p256dh, p_auth, left(p_user_agent, 300))
  on conflict (endpoint) do update set
    user_id = uid, p256dh = excluded.p256dh, auth = excluded.auth,
    user_agent = excluded.user_agent, failure_count = 0;
end $$;

create or replace function public.remove_push_subscription(p_endpoint text)
returns void language sql security definer set search_path = ''
as $$ delete from public.push_subscription where endpoint = p_endpoint and user_id = auth.uid() $$;

revoke execute on function public.save_push_subscription(text, text, text, text) from public, anon;
revoke execute on function public.remove_push_subscription(text) from public, anon;
grant execute on function public.save_push_subscription(text, text, text, text) to authenticated;
grant execute on function public.remove_push_subscription(text) to authenticated;
