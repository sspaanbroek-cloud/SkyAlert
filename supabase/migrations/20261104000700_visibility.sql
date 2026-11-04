-- Visibility rating per predicted pass (phase 1, step 5).
--
-- rate_sky()           one METAR vs one aircraft altitude -> rating + sentence
-- assess_visibility()  one pass: blend up to 3 nearby stations, store result
-- refresh_visibility_assessments()  all current passes; called by both
--                      ingest workers after new aircraft or weather data
set search_path = public, extensions;

-- "about 6,400 ft": nearest 100 ft.
create or replace function public.fmt_ft(ft numeric)
returns text language sql immutable set search_path = ''
as $$ select to_char(round(ft / 100.0) * 100, 'FM999,990') || ' ft' $$;

-------------------------------------------------------------------------------
-- Rate one observation for an aircraft at p_alt_ft (MSL).
--
-- Cloud cover in a METAR is cumulative (each layer's amount includes the
-- layers below it), so the sky between the spot and the aircraft is the
-- largest cover among layers whose base is below the aircraft:
--   none or FEW   -> clear
--   SCT or BKN    -> partial (visible through gaps)
--   OVC or VV     -> hidden
-- Cloud tops are never assumed: an aircraft above a layer's base may be above
-- or inside it, and both read as "above the clouds".
-- Visibility under 1 mile -> hidden; under 3 miles makes "clear" partial.
-- high_cloud_caveat: automated sensors (AUTO, or CLR/NCD reports) can't see
-- cloud above 12,000 ft AGL, and the aircraft is higher than that.
-------------------------------------------------------------------------------
create or replace function public.rate_sky(p_metar_id bigint, p_alt_ft integer)
returns table (rating text, limiting_cover text, clear_margin_ft integer,
               high_cloud_caveat boolean, explanation text)
language plpgsql stable set search_path = ''
as $$
declare
  m          public.metar_observation;
  elev       integer;
  b_cover    text;
  b_base     integer;
  a_cover    text;
  a_base     integer;
  lowest     integer;
  has_cb     boolean;
  r          text;
  expl       text;
  caveat     boolean;
begin
  select * into m from public.metar_observation where id = p_metar_id;
  if not found then
    return;
  end if;
  select a.elevation_ft into elev from public.airport a where a.icao = m.station;

  -- Strongest cover below the aircraft (ties: the lowest such layer).
  select c.cover, c.base_msl_ft into b_cover, b_base
  from public.cloud_layer c
  where c.metar_id = p_metar_id and c.base_msl_ft < p_alt_ft
  order by case c.cover when 'FEW' then 1 when 'SCT' then 2 when 'BKN' then 3 else 4 end desc, c.base_msl_ft
  limit 1;

  -- Lowest layer at or above the aircraft.
  select c.cover, c.base_msl_ft into a_cover, a_base
  from public.cloud_layer c
  where c.metar_id = p_metar_id and c.base_msl_ft >= p_alt_ft
  order by c.base_msl_ft
  limit 1;

  select min(c.base_msl_ft), bool_or(c.cloud_type = 'CB') into lowest, has_cb
  from public.cloud_layer c where c.metar_id = p_metar_id;

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
  elsif m.sky_clear_code is not null then
    r := 'clear';
    expl := case m.sky_clear_code
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

  if m.visibility_sm is not null and m.visibility_sm < 1 and r <> 'hidden' then
    r := 'hidden';
    expl := expl || ' But visibility is under 1 mile' || coalesce(' (' || m.wx_string || ')', '')
            || ', so it will be lost in the murk.';
  elsif m.visibility_sm is not null and m.visibility_sm < 3 and r <> 'hidden' then
    if r = 'clear' then r := 'partial'; end if;
    expl := expl || ' Visibility is only ' || trim(to_char(m.visibility_sm, 'FM990.##')) || ' miles'
            || coalesce(' (' || m.wx_string || ')', '') || ', so it may look faint.';
  end if;

  if has_cb then
    expl := expl || ' Thunderstorm clouds are reported nearby.';
  end if;

  caveat := (m.is_auto or m.sky_clear_code in ('CLR', 'NCD'))
            and p_alt_ft > coalesce(elev, 0) + 12000
            and r <> 'hidden';
  if caveat then
    expl := expl || ' The automated station can''t see cloud above 12,000 ft, so thin high cloud could still dim the view.';
  end if;

  return query select r,
    b_cover,
    case when b_cover is not null then b_base - p_alt_ft
         when lowest is not null then lowest - p_alt_ft end,
    caveat,
    expl;
end $$;

-------------------------------------------------------------------------------
-- Assess one pass and store the result.
--
-- Uses the latest report (<= 120 min old) from up to 3 stations within 40 nm
-- of the spot; the line of sight crosses low and mid cloud close to the spot.
-- Each station's rating is weighted by 1/distance^2 (distance floored at 3 nm)
-- and by report age (full weight to 60 min, falling to 0.3 at 120 min). The
-- blended score (clear 0, partial 1, hidden 2) picks the rating; the sentence
-- comes from the strongest station that agrees with it.
-------------------------------------------------------------------------------
create or replace function public.assess_visibility(p_prediction_id bigint)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  p         public.overflight_prediction;
  s_geog    extensions.geography;
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
    insert into public.visibility_assessment as v (prediction_id, rating, explanation, computed_at)
    values (p.id, 'unknown', 'The aircraft''s altitude isn''t known, so visibility can''t be judged.', now())
    on conflict (prediction_id) do update set
      metar_station = null, metar_observation_id = null, stations_used = '{}', obs_age_min = null,
      clear_margin_ft = null, limiting_cover = null, rating = excluded.rating,
      explanation = excluded.explanation, high_cloud_caveat = false, computed_at = excluded.computed_at;
    return 'unknown';
  end if;

  create temp table if not exists _va_station (
    station text, metar_id bigint, dist_nm float8, age_min integer, weight float8,
    rating text, limiting_cover text, clear_margin_ft integer, high_cloud_caveat boolean, explanation text
  ) on commit drop;
  truncate _va_station;

  insert into _va_station
  select a.icao, m.id, d.dist_nm, d.age_min,
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
    if not found then  -- blend landed between the stations' ratings
      select * into best from _va_station where rating <> 'unknown' order by weight desc limit 1;
    end if;
    expl := best.explanation;
    select string_agg(station || ' looks ' || rating, ', ' order by dist_nm) into others
    from _va_station where rating not in (final, 'unknown');
    if others is not null then
      expl := expl || ' Other nearby reports differ (' || others || '), so conditions may be patchy.';
    end if;
  end if;

  insert into public.visibility_assessment as v (
    prediction_id, metar_station, metar_observation_id, stations_used, obs_age_min,
    clear_margin_ft, limiting_cover, rating, explanation, high_cloud_caveat, computed_at)
  values (p.id, best.station, best.metar_id, coalesce(used, '{}'), best.age_min,
          best.clear_margin_ft, best.limiting_cover, final, expl, coalesce(best.high_cloud_caveat, false), now())
  on conflict (prediction_id) do update set
    metar_station = excluded.metar_station, metar_observation_id = excluded.metar_observation_id,
    stations_used = excluded.stations_used, obs_age_min = excluded.obs_age_min,
    clear_margin_ft = excluded.clear_margin_ft, limiting_cover = excluded.limiting_cover,
    rating = excluded.rating, explanation = excluded.explanation,
    high_cloud_caveat = excluded.high_cloud_caveat, computed_at = excluded.computed_at;

  return final;
end $$;

-- Re-rate every pass that is upcoming or just happened.
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
    r := public.assess_visibility(pid);
    counts := jsonb_set(counts, array[r], to_jsonb((counts->>r)::integer + 1));
  end loop;
  return counts;
end $$;

revoke execute on function public.rate_sky(bigint, integer) from public, anon;
revoke execute on function public.assess_visibility(bigint) from public, anon, authenticated;
revoke execute on function public.refresh_visibility_assessments(interval) from public, anon, authenticated;
grant execute on function public.rate_sky(bigint, integer) to authenticated, service_role;
grant execute on function public.assess_visibility(bigint) to service_role;
grant execute on function public.refresh_visibility_assessments(interval) to service_role;
