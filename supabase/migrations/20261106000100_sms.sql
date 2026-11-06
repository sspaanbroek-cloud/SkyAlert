-- Text-message (SMS) alerts.
--
-- The phone number used is the one on the person's Supabase account, which
-- Supabase verifies with a texted code (phone sign-in, or adding a phone to an
-- email account). Texts go only to people who switched them on and gave
-- consent, never to a number that replied STOP, and at most p_daily_cap a day.
set search_path = public, extensions;

create table public.notification_pref (
  user_id          uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  push_enabled     boolean not null default true,
  sms_enabled      boolean not null default false,
  sms_consent_at   timestamptz,          -- when they ticked the consent box
  sms_consent_text text,                 -- exactly what they agreed to
  sms_opted_out_at timestamptz,          -- they replied STOP (set by the worker)
  updated_at       timestamptz not null default now(),
  check (not sms_enabled or sms_consent_at is not null)
);

alter table public.notification_pref enable row level security;
create policy "owner select" on public.notification_pref for select to authenticated
  using (user_id = (select auth.uid()));
create policy "owner insert" on public.notification_pref for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy "owner update" on public.notification_pref for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
revoke all on public.notification_pref from anon;
revoke insert, update on public.notification_pref from authenticated;
grant insert (push_enabled, sms_enabled, sms_consent_at, sms_consent_text) on public.notification_pref to authenticated;
grant update (push_enabled, sms_enabled, sms_consent_at, sms_consent_text) on public.notification_pref to authenticated;
create trigger notification_pref_set_updated_at before update on public.notification_pref
  for each row execute function public.set_updated_at();

-- Turning texts back on after STOP is the person's own choice (a new consent):
-- clear the opt-out when they re-enable with a fresh consent time.
create or replace function public.notification_pref_reconsent()
returns trigger language plpgsql set search_path = ''
as $$
begin
  if new.sms_enabled and new.sms_consent_at is distinct from old.sms_consent_at then
    new.sms_opted_out_at := null;
  end if;
  return new;
end $$;
create trigger notification_pref_reconsent before update on public.notification_pref
  for each row execute function public.notification_pref_reconsent();

-- One row per attempt to deliver an alert on a channel (cost tracking, daily cap).
create table public.alert_delivery (
  id          bigint generated always as identity primary key,
  alert_id    bigint references public.alert (id) on delete set null,
  user_id     uuid not null references auth.users (id) on delete cascade,
  channel     text not null check (channel in ('push', 'sms')),
  ok          boolean not null,
  detail      text,
  created_at  timestamptz not null default now()
);
create index alert_delivery_user_day_idx on public.alert_delivery (user_id, channel, created_at);
alter table public.alert_delivery enable row level security;
create policy "owner select" on public.alert_delivery for select to authenticated
  using (user_id = (select auth.uid()));

-------------------------------------------------------------------------------
-- alert_channels(): how to reach each user right now (for the send worker).
-------------------------------------------------------------------------------
create or replace function public.alert_channels(p_user_ids uuid[], p_daily_cap integer default 20)
returns table (user_id uuid, push_enabled boolean, sms_to text, sms_blocked_reason text)
language sql stable security definer set search_path = ''
as $$
  select u.id,
         coalesce(np.push_enabled, true),
         case when sms_ok.ok then '+' || ltrim(u.phone, '+') end,
         case
           when not coalesce(np.sms_enabled, false) then null
           when u.phone is null or u.phone = '' or u.phone_confirmed_at is null then 'no verified phone number'
           when np.sms_opted_out_at is not null then 'replied STOP'
           when sent.n >= p_daily_cap then 'daily text limit reached'
         end
  from auth.users u
  left join public.notification_pref np on np.user_id = u.id
  cross join lateral (
    select count(*) as n from public.alert_delivery d
    where d.user_id = u.id and d.channel = 'sms' and d.ok and d.created_at > now() - interval '24 hours'
  ) sent
  cross join lateral (
    select coalesce(np.sms_enabled, false) and u.phone is not null and u.phone <> ''
           and u.phone_confirmed_at is not null and np.sms_opted_out_at is null
           and sent.n < p_daily_cap as ok
  ) sms_ok
  where u.id = any (p_user_ids)
$$;

create or replace function public.record_deliveries(rows jsonb)
returns void language sql security definer set search_path = ''
as $$
  insert into public.alert_delivery (alert_id, user_id, channel, ok, detail)
  select (r->>'alert_id')::bigint, (r->>'user_id')::uuid, r->>'channel', (r->>'ok')::boolean, r->>'detail'
  from jsonb_array_elements(rows) r
$$;

create or replace function public.mark_sms_opted_out(p_user_ids uuid[])
returns void language sql security definer set search_path = ''
as $$
  update public.notification_pref set sms_opted_out_at = now()
  where user_id = any (p_user_ids) and sms_opted_out_at is null
$$;

-------------------------------------------------------------------------------
-- queue_alerts(): a user can now be reached by push OR text.
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
    -- reachable: a push device (with push on) or a text-ready phone number
    and exists (select 1 from public.alert_channels(array[s.user_id]) c
                where c.sms_to is not null
                   or (c.push_enabled and exists (select 1 from public.push_subscription ps where ps.user_id = s.user_id)))
  on conflict (user_id, prediction_id) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

revoke execute on function public.alert_channels(uuid[], integer) from public, anon, authenticated;
revoke execute on function public.record_deliveries(jsonb) from public, anon, authenticated;
revoke execute on function public.mark_sms_opted_out(uuid[]) from public, anon, authenticated;
grant execute on function public.alert_channels(uuid[], integer) to service_role;
grant execute on function public.record_deliveries(jsonb) to service_role;
grant execute on function public.mark_sms_opted_out(uuid[]) to service_role;
