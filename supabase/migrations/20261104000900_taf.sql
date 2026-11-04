-- TAF forecasts (phase 2, part 2).
--
-- Passes more than an hour ahead are rated from the forecast in force at the
-- pass time instead of the current METAR. The cloud rules move into one
-- function, rate_conditions(), used for both observations and forecasts.
set search_path = public, extensions;

-------------------------------------------------------------------------------
-- Storage
-------------------------------------------------------------------------------
create table public.taf_forecast (
  id          bigint generated always as identity primary key,
  station     text not null references public.airport (icao) on update cascade,
  issued_at   timestamptz not null,
  valid_from  timestamptz not null,
  valid_to    timestamptz not null,
  raw_text    text not null,
  source      text not null default 'awc',
  fetched_at  timestamptz not null default now(),
  unique (station, issued_at),
  check (valid_to > valid_from)
);
create index taf_station_valid_idx on public.taf_forecast (station, valid_to desc);

-- One row per change group, in report order (seq 0 = the base forecast).
-- BECMG periods list only what changes; null fields carry over.
create table public.taf_period (
  taf_id            bigint not null references public.taf_forecast (id) on delete cascade,
  seq               smallint not null check (seq >= 0),
  change_type       text not null check (change_type in ('BASE', 'FM', 'BECMG', 'TEMPO', 'PROB')),
  probability       smallint check (probability between 0 and 100),
  time_from         timestamptz not null,
  time_to           timestamptz,
  visibility_sm     numeric(5,2),
  visibility_is_min boolean not null default false,
  wx_string         text,
  sky_clear_code    text check (sky_clear_code in ('CLR', 'SKC', 'NSC', 'NCD', 'CAVOK')),
  layers            jsonb,   -- [{cover, base_agl_ft, cloud_type}], null = unchanged (BECMG)
  primary key (taf_id, seq)
);

alter table public.taf_forecast enable row level security;
alter table public.taf_period enable row level security;
create policy "signed-in read" on public.taf_forecast for select to authenticated using (true);
create policy "signed-in read" on public.taf_period for select to authenticated using (true);

alter table public.visibility_assessment
  add column weather_basis text not null default 'metar'
    check (weather_basis in ('metar', 'taf', 'metar_persistence', 'none')),
  add column taf_id bigint references public.taf_forecast (id) on delete set null;

-------------------------------------------------------------------------------
-- ingest_tafs(tafs): same contract style as ingest_metars().
--   [{station: {icao, name, lat, lon, elevation_ft}, issued_at, valid_from,
--     valid_to, raw_text, periods: [{change_type, probability, time_from,
--     time_to, visibility_sm, visibility_is_min, wx_string, sky_clear_code,
--     layers}]}]
-------------------------------------------------------------------------------
create or replace function public.ingest_tafs(tafs jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  t         jsonb;
  st        jsonb;
  tid       bigint;
  stored    integer := 0;
  unchanged integer := 0;
  rejected  jsonb := '[]'::jsonb;
begin
  if jsonb_typeof(tafs) is distinct from 'array' then
    raise exception 'tafs must be a JSON array';
  end if;

  for t in select value from jsonb_array_elements(tafs) loop
    begin
      st  := t->'station';
      tid := null;

      insert into public.airport as a (icao, name, geog, elevation_ft, has_metar, updated_at)
      values (st->>'icao', st->>'name',
              extensions.st_setsrid(extensions.st_makepoint((st->>'lon')::float8, (st->>'lat')::float8), 4326)::extensions.geography,
              (st->>'elevation_ft')::integer, false, now())
      on conflict (icao) do update
        set name = coalesce(a.name, excluded.name)
        where a.name is null and excluded.name is not null;

      insert into public.taf_forecast as f (station, issued_at, valid_from, valid_to, raw_text, fetched_at)
      values (st->>'icao', (t->>'issued_at')::timestamptz, (t->>'valid_from')::timestamptz,
              (t->>'valid_to')::timestamptz, t->>'raw_text', now())
      on conflict (station, issued_at) do update set
        valid_from = excluded.valid_from, valid_to = excluded.valid_to,
        raw_text = excluded.raw_text, fetched_at = now()
        where f.raw_text is distinct from excluded.raw_text
      returning id into tid;

      if tid is null then
        unchanged := unchanged + 1;
        continue;
      end if;

      delete from public.taf_period where taf_id = tid;
      insert into public.taf_period (taf_id, seq, change_type, probability, time_from, time_to,
                                     visibility_sm, visibility_is_min, wx_string, sky_clear_code, layers)
      select tid, (x.ord - 1)::smallint, x.p->>'change_type', (x.p->>'probability')::smallint,
             (x.p->>'time_from')::timestamptz, (x.p->>'time_to')::timestamptz,
             (x.p->>'visibility_sm')::numeric, coalesce((x.p->>'visibility_is_min')::boolean, false),
             x.p->>'wx_string', x.p->>'sky_clear_code',
             case when jsonb_typeof(x.p->'layers') = 'array' then x.p->'layers' end
      from jsonb_array_elements(coalesce(t->'periods', '[]'::jsonb)) with ordinality as x(p, ord);

      stored := stored + 1;
    exception when others then
      rejected := rejected || jsonb_build_object('station', coalesce(t->'station'->>'icao', '?'),
                                                 'issued_at', t->>'issued_at', 'error', sqlerrm);
    end;
  end loop;

  delete from public.taf_forecast where valid_to < now() - interval '1 day';
  return jsonb_build_object('stored', stored, 'unchanged', unchanged, 'rejected', rejected);
end $$;

-------------------------------------------------------------------------------
-- rate_conditions(): the cloud rules, independent of where the data came from.
-- p_layers: [{cover, base_msl_ft, cloud_type}] (any order).
-- Rules and wording are unchanged from the original rate_sky() (see
-- *_visibility.sql for the reasoning).
-------------------------------------------------------------------------------
create or replace function public.rate_conditions(
  p_layers    jsonb,
  p_alt_ft    integer,
  p_vis_sm    numeric,
  p_wx        text,
  p_sky_clear text,
  p_is_auto   boolean,
  p_elev_ft   integer)
returns table (rating text, limiting_cover text, clear_margin_ft integer,
               high_cloud_caveat boolean, explanation text)
language plpgsql stable set search_path = ''
as $$
declare
  b_cover text; b_base integer; a_cover text; a_base integer;
  lowest integer; has_cb boolean; r text; expl text; caveat boolean;
begin
  with l as (
    select x->>'cover' as cover, (x->>'base_msl_ft')::integer as base, x->>'cloud_type' as ctype
    from jsonb_array_elements(coalesce(p_layers, '[]'::jsonb)) x
  )
  select
    (select cover from l where base < p_alt_ft
       order by case cover when 'FEW' then 1 when 'SCT' then 2 when 'BKN' then 3 else 4 end desc, base limit 1),
    (select base from l where base < p_alt_ft
       order by case cover when 'FEW' then 1 when 'SCT' then 2 when 'BKN' then 3 else 4 end desc, base limit 1),
    (select cover from l where base >= p_alt_ft order by base limit 1),
    (select base from l where base >= p_alt_ft order by base limit 1),
    (select min(base) from l),
    (select coalesce(bool_or(ctype = 'CB'), false) from l)
  into b_cover, b_base, a_cover, a_base, lowest, has_cb;

  if b_cover is not null then
    r := case b_cover when 'FEW' then 'clear' when 'SCT' then 'partial' when 'BKN' then 'partial' else 'hidden' end;
    expl := case b_cover
      when 'FEW' then 'A few wisps of cloud at about ' || public.fmt_ft(b_base)
                      || ', below the aircraft. You should see it clearly, though a wisp could briefly get in the way.'
      when 'SCT' then 'Scattered clouds at about ' || public.fmt_ft(b_base)
                      || ', below the aircraft. It will be above the clouds: you''ll see it through the gaps, but a cloud may cover part of the pass.'
      when 'BKN' then 'Mostly cloudy at about ' || public.fmt_ft(b_base)
                      || ', so the aircraft will be above the clouds and visible only through gaps.'
      when 'OVC' then 'Solid overcast at about ' || public.fmt_ft(b_base)
                      || ', so the aircraft will be hidden above the clouds.'
      else 'The sky is obscured (fog, haze or precipitation), so the aircraft will be hidden.'
    end;
  elsif a_cover is not null then
    r := 'clear';
    expl := 'The lowest cloud, ' || lower((select cc.plain_label from public.cloud_cover cc where cc.code = a_cover))
            || ' at about ' || public.fmt_ft(a_base) || ', is above the aircraft, so it will fly below the clouds in clear view.';
  elsif p_sky_clear is not null then
    r := 'clear';
    expl := case p_sky_clear
      when 'CLR' then 'No cloud reported below 12,000 ft above the airport, so the view should be clear.'
      when 'SKC' then 'Clear sky, so the view should be clear.'
      when 'NCD' then 'No cloud detected, so the view should be clear.'
      else 'No significant cloud, so the view should be clear.'
    end;
  else
    return query select 'unknown'::text, null::text, null::integer, false,
      'This weather report doesn''t describe the sky, so visibility can''t be judged.'::text;
    return;
  end if;

  if p_vis_sm is not null and p_vis_sm < 1 and r <> 'hidden' then
    r := 'hidden';
    expl := expl || ' But visibility is under 1 mile' || coalesce(' (' || p_wx || ')', '')
            || ', so it will be lost in the murk.';
  elsif p_vis_sm is not null and p_vis_sm < 3 and r <> 'hidden' then
    if r = 'clear' then r := 'partial'; end if;
    expl := expl || ' Visibility is only ' || trim(to_char(p_vis_sm, 'FM990.##')) || ' miles'
            || coalesce(' (' || p_wx || ')', '') || ', so it may look faint.';
  end if;

  if has_cb then
    expl := expl || ' Thunderstorm clouds are reported nearby.';
  end if;

  caveat := (coalesce(p_is_auto, false) or p_sky_clear in ('CLR', 'NCD'))
            and p_alt_ft > coalesce(p_elev_ft, 0) + 12000
            and r <> 'hidden';
  if caveat then
    expl := expl || ' The automated station can''t see cloud above 12,000 ft, so thin high cloud could still dim the view.';
  end if;

  return query select r, b_cover,
    case when b_cover is not null then b_base - p_alt_ft
         when lowest is not null then lowest - p_alt_ft end,
    caveat, expl;
end $$;

-- rate_sky() now delegates; same signature and output as before.
create or replace function public.rate_sky(p_metar_id bigint, p_alt_ft integer)
returns table (rating text, limiting_cover text, clear_margin_ft integer,
               high_cloud_caveat boolean, explanation text)
language sql stable set search_path = ''
as $$
  select r.*
  from public.metar_observation m
  join public.airport a on a.icao = m.station
  cross join lateral public.rate_conditions(
    (select jsonb_agg(jsonb_build_object('cover', c.cover, 'base_msl_ft', c.base_msl_ft, 'cloud_type', c.cloud_type))
     from public.cloud_layer c where c.metar_id = m.id),
    p_alt_ft, m.visibility_sm, m.wx_string, m.sky_clear_code, m.is_auto, a.elevation_ft) r
  where m.id = p_metar_id
$$;

-------------------------------------------------------------------------------
-- rate_taf(): rate the forecast in force at p_at.
--
-- Prevailing conditions: BASE and FM periods reset everything; BECMG periods
-- that have started override only what they mention. TEMPO and PROB groups
-- covering p_at are checked separately: if one is worse, a clear rating
-- becomes partial (hidden stays hidden) and the sentence says so.
-------------------------------------------------------------------------------
create or replace function public.rate_taf(p_taf_id bigint, p_at timestamptz, p_alt_ft integer)
returns table (rating text, limiting_cover text, clear_margin_ft integer,
               high_cloud_caveat boolean, explanation text)
language plpgsql stable set search_path = ''
as $$
declare
  elev     integer;
  per      public.taf_period;
  vis      numeric; wx text; skc text;
  lay_agl  jsonb;   -- prevailing layers as forecast (AGL)
  lay      jsonb;   -- the same, converted to MSL
  base_r   record;
  tmp      record;
  worst    text;
  worst_e  text;
  rank     jsonb := '{"clear":0,"partial":1,"hidden":2,"unknown":-1}';
  final    text;
  expl     text;
begin
  select a.elevation_ft into elev
  from public.taf_forecast f join public.airport a on a.icao = f.station where f.id = p_taf_id;

  for per in
    select * from public.taf_period
    where taf_id = p_taf_id and change_type in ('BASE', 'FM', 'BECMG') and time_from <= p_at
    order by seq
  loop
    if per.change_type in ('BASE', 'FM') then
      vis := per.visibility_sm; wx := per.wx_string; skc := per.sky_clear_code; lay_agl := per.layers;
    else
      vis := coalesce(per.visibility_sm, vis);
      wx  := coalesce(per.wx_string, wx);
      if per.layers is not null or per.sky_clear_code is not null then
        lay_agl := per.layers; skc := per.sky_clear_code;
      end if;
    end if;
  end loop;

  -- AGL -> MSL with the station elevation.
  lay := (select jsonb_agg(jsonb_build_object('cover', x->>'cover',
                                              'base_msl_ft', (x->>'base_agl_ft')::integer + coalesce(elev, 0),
                                              'cloud_type', x->>'cloud_type'))
          from jsonb_array_elements(coalesce(lay_agl, '[]'::jsonb)) x);

  select * into base_r from public.rate_conditions(lay, p_alt_ft, vis, wx, skc, false, elev);
  final := base_r.rating;
  expl  := base_r.explanation;

  -- Worst temporary/probable group covering the pass time.
  for tmp in
    select r.rating, r.explanation, p.change_type, p.probability
    from public.taf_period p
    cross join lateral public.rate_conditions(
      (select jsonb_agg(jsonb_build_object('cover', x->>'cover',
                                           'base_msl_ft', (x->>'base_agl_ft')::integer + coalesce(elev, 0),
                                           'cloud_type', x->>'cloud_type'))
       from jsonb_array_elements(coalesce(p.layers, lay_agl, '[]'::jsonb)) x),
      p_alt_ft, coalesce(p.visibility_sm, vis), coalesce(p.wx_string, wx),
      coalesce(p.sky_clear_code, case when p.layers is null then skc end), false, elev) r
    where p.taf_id = p_taf_id and p.change_type in ('TEMPO', 'PROB')
      and p.time_from <= p_at and coalesce(p.time_to, p.time_from + interval '4 hours') > p_at
  loop
    if (rank->>tmp.rating)::int > coalesce((rank->>worst)::int, (rank->>final)::int) then
      worst := tmp.rating;
      worst_e := tmp.explanation;
    end if;
  end loop;

  if worst is not null then
    if final = 'clear' then final := 'partial'; end if;
    expl := expl || ' At times, though: ' || lower(left(worst_e, 1)) || substr(worst_e, 2);
  end if;

  return query select final, base_r.limiting_cover, base_r.clear_margin_ft, false, expl;
end $$;

-------------------------------------------------------------------------------
-- assess_visibility(), now forecast-aware.
--   pass within 60 min  -> latest METARs (as before), weather_basis 'metar'
--   later               -> TAFs valid at the pass time from up to 3 stations
--                          within 40 nm, weather_basis 'taf'
--   later, no TAF       -> current METARs, weather_basis 'metar_persistence',
--                          and the sentence says conditions may change
-- Blending (1/distance^2, agreeing station explains) is unchanged.
-------------------------------------------------------------------------------
create or replace function public.assess_visibility(p_prediction_id bigint)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  p         public.overflight_prediction;
  s_geog    extensions.geography;
  wbasis    text;
  score     float8;
  final     text;
  best      record;
  others    text;
  used      text[];
  expl      text;
begin
  select * into p from public.overflight_prediction where id = p_prediction_id;
  if not found then
    return null;
  end if;
  select sp.geog into s_geog from public.spot sp where sp.id = p.spot_id;

  if p.altitude_ft is null then
    insert into public.visibility_assessment as v (prediction_id, rating, explanation, weather_basis, computed_at)
    values (p.id, 'unknown', 'The aircraft''s altitude isn''t known, so visibility can''t be judged.', 'none', now())
    on conflict (prediction_id) do update set
      metar_station = null, metar_observation_id = null, taf_id = null, stations_used = '{}', obs_age_min = null,
      clear_margin_ft = null, limiting_cover = null, rating = excluded.rating, weather_basis = 'none',
      explanation = excluded.explanation, high_cloud_caveat = false, computed_at = excluded.computed_at;
    return 'unknown';
  end if;

  create temp table if not exists _va_station (
    station text, metar_id bigint, taf_id bigint, dist_nm float8, age_min integer, weight float8,
    rating text, limiting_cover text, clear_margin_ft integer, high_cloud_caveat boolean, explanation text
  ) on commit drop;
  truncate _va_station;

  if p.closest_approach_at > now() + interval '60 minutes' then
    insert into _va_station
    select a.icao, null, f.id, d.dist_nm, d.age_min,
           1.0 / power(greatest(d.dist_nm, 3.0), 2),
           r.rating, r.limiting_cover, r.clear_margin_ft, r.high_cloud_caveat, r.explanation
    from public.airport a
    cross join lateral (
      select tf.id, tf.issued_at from public.taf_forecast tf
      where tf.station = a.icao and tf.valid_from <= p.closest_approach_at and tf.valid_to > p.closest_approach_at
      order by tf.issued_at desc limit 1
    ) f
    cross join lateral (
      select extensions.st_distance(a.geog, s_geog) / 1852.0 as dist_nm,
             greatest(0, floor(extract(epoch from now() - f.issued_at) / 60))::integer as age_min
    ) d
    cross join lateral public.rate_taf(f.id, p.closest_approach_at, p.altitude_ft) r
    where extensions.st_dwithin(a.geog, s_geog, 40 * 1852.0)
    order by a.geog operator(extensions.<->) s_geog
    limit 3;
    wbasis := case when found then 'taf' else 'metar_persistence' end;
  else
    wbasis := 'metar';
  end if;

  if wbasis <> 'taf' then
    insert into _va_station
    select a.icao, m.id, null, d.dist_nm, d.age_min,
           (1.0 / power(greatest(d.dist_nm, 3.0), 2))
             * case when d.age_min <= 60 then 1.0 else greatest(0.3, 1.0 - (d.age_min - 60) / 60.0 * 0.7) end,
           r.rating, r.limiting_cover, r.clear_margin_ft, r.high_cloud_caveat, r.explanation
    from public.airport a
    cross join lateral (
      select mo.id, mo.observed_at from public.metar_observation mo
      where mo.station = a.icao and mo.observed_at > now() - interval '120 minutes'
      order by mo.observed_at desc limit 1
    ) m
    cross join lateral (
      select extensions.st_distance(a.geog, s_geog) / 1852.0 as dist_nm,
             greatest(0, floor(extract(epoch from now() - m.observed_at) / 60))::integer as age_min
    ) d
    cross join lateral public.rate_sky(m.id, p.altitude_ft) r
    where extensions.st_dwithin(a.geog, s_geog, 40 * 1852.0)
    order by a.geog operator(extensions.<->) s_geog
    limit 3;
    if not found then
      wbasis := 'none';
    end if;
  end if;

  select array_agg(station order by dist_nm) into used from _va_station;
  select sum(weight * case rating when 'clear' then 0 when 'partial' then 1 else 2 end) / sum(weight)
    into score
  from _va_station where rating <> 'unknown';

  if score is null then
    final := 'unknown';
    select * into best from _va_station order by weight desc limit 1;
    expl := coalesce(best.explanation,
      'No weather report from within 40 nm in the last 2 hours, so visibility can''t be judged.');
  else
    final := case when score < 0.5 then 'clear' when score < 1.5 then 'partial' else 'hidden' end;
    select * into best from _va_station where rating = final order by weight desc limit 1;
    if not found then
      select * into best from _va_station where rating <> 'unknown' order by weight desc limit 1;
    end if;
    expl := best.explanation;
    select string_agg(station || ' looks ' || rating, ', ' order by dist_nm) into others
    from _va_station where rating not in (final, 'unknown');
    if others is not null then
      expl := expl || ' Other nearby ' || case when wbasis = 'taf' then 'forecasts' else 'reports' end
              || ' differ (' || others || '), so conditions may be patchy.';
    end if;
    expl := case wbasis
      when 'taf' then 'Forecast: ' || expl
      when 'metar_persistence' then 'No forecast covers this time, so this uses current conditions, which may change. ' || expl
      else expl end;
  end if;

  insert into public.visibility_assessment as v (
    prediction_id, metar_station, metar_observation_id, taf_id, stations_used, obs_age_min,
    clear_margin_ft, limiting_cover, rating, explanation, high_cloud_caveat, weather_basis, computed_at)
  values (p.id, best.station, best.metar_id, best.taf_id, coalesce(used, '{}'), best.age_min,
          best.clear_margin_ft, best.limiting_cover, final, expl, coalesce(best.high_cloud_caveat, false),
          wbasis, now())
  on conflict (prediction_id) do update set
    metar_station = excluded.metar_station, metar_observation_id = excluded.metar_observation_id,
    taf_id = excluded.taf_id, stations_used = excluded.stations_used, obs_age_min = excluded.obs_age_min,
    clear_margin_ft = excluded.clear_margin_ft, limiting_cover = excluded.limiting_cover,
    rating = excluded.rating, explanation = excluded.explanation,
    high_cloud_caveat = excluded.high_cloud_caveat, weather_basis = excluded.weather_basis,
    computed_at = excluded.computed_at;

  return final;
end $$;

revoke execute on function public.ingest_tafs(jsonb) from public, anon, authenticated;
grant execute on function public.ingest_tafs(jsonb) to service_role;
revoke execute on function public.rate_conditions(jsonb, integer, numeric, text, text, boolean, integer) from public, anon;
revoke execute on function public.rate_taf(bigint, timestamptz, integer) from public, anon;
grant execute on function public.rate_conditions(jsonb, integer, numeric, text, text, boolean, integer) to authenticated, service_role;
grant execute on function public.rate_taf(bigint, timestamptz, integer) to authenticated, service_role;
