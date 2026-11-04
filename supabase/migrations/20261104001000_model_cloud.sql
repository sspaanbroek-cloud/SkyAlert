-- High cloud from a weather model (phase 2, part 3).
--
-- Ground stations (ASOS) can't see cloud above 12,000 ft. Open-Meteo gives
-- hourly cloud cover in three bands from the HRRR/GFS models:
--   low   surface to ~2 km  (~6,500 ft)
--   mid   ~2 to 6 km        (~6,500 to 19,700 ft)
--   high  above ~6 km       (~19,700 ft)
-- The `ingest-model-cloud` function stores them per 0.1-degree cell around
-- each spot; apply_model_cloud() then refines each pass's rating.
set search_path = public, extensions;

create table public.high_cloud_estimate (
  id              bigint generated always as identity primary key,
  cell_key        text not null,                  -- 'lat,lon' rounded to 0.1 deg
  geog            geography(Point, 4326) not null,
  valid_at        timestamptz not null,           -- start of the forecast hour (UTC)
  cloud_low_pct   smallint check (cloud_low_pct between 0 and 100),
  cloud_mid_pct   smallint check (cloud_mid_pct between 0 and 100),
  cloud_high_pct  smallint check (cloud_high_pct between 0 and 100),
  model           text not null default 'best_match',
  source          text not null default 'open-meteo',
  fetched_at      timestamptz not null default now(),
  unique (cell_key, valid_at)
);
create index high_cloud_estimate_valid_idx on public.high_cloud_estimate (valid_at);

alter table public.high_cloud_estimate enable row level security;
create policy "signed-in read" on public.high_cloud_estimate for select to authenticated using (true);

alter table public.visibility_assessment
  add column model_cloud_band text check (model_cloud_band in ('mid', 'high')),
  add column model_cloud_pct smallint check (model_cloud_pct between 0 and 100);

create or replace function public.cloud_cell_key(p_lat double precision, p_lon double precision)
returns text language sql immutable set search_path = ''
as $$ select to_char(round(p_lat::numeric, 1), 'FM990.0') || ',' || to_char(round(p_lon::numeric, 1), 'FM9990.0') $$;

-- Points to fetch: one per 0.1-degree cell holding a spot.
create or replace function public.model_cloud_points()
returns table (cell_key text, lat double precision, lon double precision)
language sql stable security definer set search_path = ''
as $$
  select distinct public.cloud_cell_key(s.lat, s.lon),
         round(s.lat::numeric, 1)::float8, round(s.lon::numeric, 1)::float8
  from public.spot s
  order by 1
$$;

-- points: [{cell_key, lat, lon, valid_at, low, mid, high, model}]
create or replace function public.ingest_model_cloud(points jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare n integer; removed integer;
begin
  if jsonb_typeof(points) is distinct from 'array' then
    raise exception 'points must be a JSON array';
  end if;
  with rows as (
    select * from jsonb_to_recordset(points) as x(cell_key text, lat float8, lon float8, valid_at timestamptz,
                                                  low smallint, mid smallint, high smallint, model text)
    where cell_key is not null and valid_at is not null
  ), up as (
    insert into public.high_cloud_estimate as e (cell_key, geog, valid_at, cloud_low_pct, cloud_mid_pct, cloud_high_pct, model, fetched_at)
    select cell_key, extensions.st_setsrid(extensions.st_makepoint(lon, lat), 4326)::extensions.geography,
           valid_at, low, mid, high, coalesce(model, 'best_match'), now()
    from rows
    on conflict (cell_key, valid_at) do update set
      cloud_low_pct = excluded.cloud_low_pct, cloud_mid_pct = excluded.cloud_mid_pct,
      cloud_high_pct = excluded.cloud_high_pct, model = excluded.model, fetched_at = excluded.fetched_at
    returning 1
  )
  select count(*) into n from up;

  delete from public.high_cloud_estimate where valid_at < now() - interval '6 hours';
  get diagnostics removed = row_count;
  return jsonb_build_object('upserted', n, 'removed', removed);
end $$;

-------------------------------------------------------------------------------
-- apply_model_cloud(): refine one pass's stored assessment with model cloud.
--
-- Band: 'high' for an aircraft at or above 19,700 ft. 'mid' for an aircraft
-- between the station's 12,000 ft sensor limit and 19,700 ft, only when the
-- assessment carries the automated-station caveat (otherwise the METAR/TAF
-- already describes that layer).
--   >= 70%  clear -> partial; "a lot of high cloud ... dimmed or hidden at times"
--   30-69%  note only; "some high cloud ... could dim it"
--   <  30%  "little high cloud", and the automated-station caveat is dropped
-- Model cloud never makes a pass 'hidden' on its own: thin high cloud rarely
-- blocks an aircraft completely. Hidden and unknown ratings are left alone.
-- Uses the forecast hour nearest the pass (within 90 min), fetched < 12 h ago.
-------------------------------------------------------------------------------
create or replace function public.apply_model_cloud(p_prediction_id bigint)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  p       public.overflight_prediction;
  va      public.visibility_assessment;
  s       public.spot;
  e       public.high_cloud_estimate;
  band    text;
  pct     smallint;
  caveat_text constant text := ' The automated station can''t see cloud above 12,000 ft, so thin high cloud could still dim the view.';
  where_txt text;
  expl    text;
  r       text;
begin
  select * into p from public.overflight_prediction where id = p_prediction_id;
  select * into va from public.visibility_assessment where prediction_id = p_prediction_id;
  if p.id is null or va.prediction_id is null or va.rating in ('hidden', 'unknown') or p.altitude_ft is null then
    return va.rating;
  end if;
  select * into s from public.spot where id = p.spot_id;

  if p.altitude_ft >= 19700 then
    band := 'high';
  elsif va.high_cloud_caveat then
    band := 'mid';
  else
    return va.rating;
  end if;

  select * into e from public.high_cloud_estimate h
  where h.cell_key = public.cloud_cell_key(s.lat, s.lon)
    and h.valid_at between p.closest_approach_at - interval '90 minutes' and p.closest_approach_at + interval '90 minutes'
    and h.fetched_at > now() - interval '12 hours'
  order by abs(extract(epoch from h.valid_at - p.closest_approach_at))
  limit 1;
  if e.id is null then
    return va.rating;
  end if;

  pct := case band when 'high' then e.cloud_high_pct else e.cloud_mid_pct end;
  if pct is null then
    return va.rating;
  end if;
  where_txt := case band when 'high' then 'high cloud (' || pct || '%) above about 20,000 ft'
                         else 'cloud between 12,000 and 20,000 ft (' || pct || '%)' end;

  expl := replace(va.explanation, caveat_text, '');
  r := va.rating;
  if pct >= 70 then
    if r = 'clear' then r := 'partial'; end if;
    expl := expl || ' The weather model expects a lot of ' || where_txt || ', so it may be dimmed or hidden at times.';
  elsif pct >= 30 then
    expl := expl || ' The weather model expects some ' || where_txt || ', which could dim it.';
  else
    expl := expl || ' The weather model shows little ' || where_txt || ', so the sky above looks clear too.';
  end if;

  update public.visibility_assessment set
    rating = r, explanation = expl, high_cloud_caveat = false,
    model_cloud_band = band, model_cloud_pct = pct
  where prediction_id = p_prediction_id;
  return r;
end $$;

-- refresh_visibility_assessments(): now applies model cloud after each assessment.
create or replace function public.refresh_visibility_assessments(p_since interval default interval '5 minutes')
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  pid bigint;
  r   text;
  counts jsonb := '{"clear":0,"partial":0,"hidden":0,"unknown":0}'::jsonb;
begin
  for pid in
    select id from public.overflight_prediction where closest_approach_at >= now() - p_since
  loop
    perform public.assess_visibility(pid);
    update public.visibility_assessment set model_cloud_band = null, model_cloud_pct = null
    where prediction_id = pid;
    r := public.apply_model_cloud(pid);
    counts := jsonb_set(counts, array[r], to_jsonb((counts->>r)::integer + 1));
  end loop;
  return counts;
end $$;

revoke execute on function public.model_cloud_points() from public, anon, authenticated;
revoke execute on function public.ingest_model_cloud(jsonb) from public, anon, authenticated;
revoke execute on function public.apply_model_cloud(bigint) from public, anon, authenticated;
grant execute on function public.model_cloud_points() to service_role;
grant execute on function public.ingest_model_cloud(jsonb) to service_role;
grant execute on function public.apply_model_cloud(bigint) to service_role;

do $outer$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron')
     or not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_cron/pg_net not installed: skipping model-cloud schedule';
    return;
  end if;
  perform cron.schedule('ingest-model-cloud', '13 * * * *', $job$
    select net.http_post(
      url     := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
                 || '/functions/v1/ingest-model-cloud',
      headers := jsonb_build_object(
                   'Content-Type', 'application/json',
                   'x-ingest-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'ingest_secret')),
      body    := '{}'::jsonb,
      timeout_milliseconds := 55000)
  $job$);
end
$outer$;
