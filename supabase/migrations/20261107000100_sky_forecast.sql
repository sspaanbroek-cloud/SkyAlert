-- "Sky near this spot": airport forecast (TAF) and lightning remarks.
set search_path = public, extensions;

-------------------------------------------------------------------------------
-- The lightning phrase from a METAR's remarks, e.g. "OCNL LTGICCG DSNT NE",
-- or null. Frequency word (OCNL/FRQ/CONS) + LTG + type letters, then distance
-- and direction words.
-------------------------------------------------------------------------------
create or replace function public.lightning_remark(p_raw text)
returns text language sql immutable set search_path = ''
as $$
  select nullif(trim(substring(p_raw from
    '(?:\m(?:OCNL|FRQ|CONS)\s+)?\mLTG[A-Z]*(?:\s+(?:DSNT|VC|OHD|ALQDS|AND|[NSEW]{1,2}(?:-[NSEW]{1,2})*))*')), '')
$$;

-------------------------------------------------------------------------------
-- nearby_weather(): unchanged, plus lightning_remark. (Return type changes,
-- so the function is dropped and re-created.)
-------------------------------------------------------------------------------
drop function public.nearby_weather(uuid, numeric, integer);

create function public.nearby_weather(
  p_spot_id uuid,
  p_max_nm  numeric default 60,
  p_limit   integer default 5)
returns table (
  station          text,
  station_name     text,
  distance_nm      numeric,
  bearing_deg      integer,
  station_elevation_ft integer,
  metar_id         bigint,
  observed_at      timestamptz,
  age_min          integer,
  flight_category  text,
  is_auto          boolean,
  visibility_sm    numeric,
  visibility_is_min boolean,
  wx_string        text,
  raw_text         text,
  sky_summary      text,
  layers           jsonb,
  lightning_remark text)
language sql stable set search_path = ''
as $$
  select a.icao, a.name,
         round((extensions.st_distance(s.geog, a.geog) / 1852.0)::numeric, 1),
         (round(degrees(extensions.st_azimuth(s.geog, a.geog)))::integer) % 360,
         a.elevation_ft,
         m.id, m.observed_at,
         floor(extract(epoch from now() - m.observed_at) / 60)::integer,
         m.flight_category, m.is_auto, m.visibility_sm, m.visibility_is_min, m.wx_string, m.raw_text,
         public.sky_summary(m.id),
         coalesce((select jsonb_agg(jsonb_build_object(
                     'cover', c.cover, 'cloud_type', c.cloud_type,
                     'base_agl_ft', c.base_agl_ft, 'base_msl_ft', c.base_msl_ft,
                     'plain_label', c.plain_label) order by c.seq)
                   from public.cloud_layer c where c.metar_id = m.id), '[]'::jsonb),
         public.lightning_remark(m.raw_text)
  from public.spot s
  join public.airport a
    on extensions.st_dwithin(s.geog, a.geog, p_max_nm * 1852.0)
  cross join lateral (
    select * from public.metar_observation mo
    where mo.station = a.icao
    order by mo.observed_at desc
    limit 1
  ) m
  where s.id = p_spot_id
  order by s.geog operator(extensions.<->) a.geog
  limit greatest(1, least(p_limit, 20))
$$;

revoke execute on function public.nearby_weather(uuid, numeric, integer) from public, anon;
grant execute on function public.nearby_weather(uuid, numeric, integer) to authenticated, service_role;

-------------------------------------------------------------------------------
-- Plain-language cloud for one forecast period. Layers are AGL, as in the TAF;
-- wording matches the METAR labels ("Mostly cloudy with gaps at 6,000 ft above
-- ground"). Null when the period doesn't mention cloud (a BECMG of wind only).
-------------------------------------------------------------------------------
create or replace function public.taf_cloud_summary(p_layers jsonb, p_sky_clear text)
returns text language sql stable set search_path = ''
as $$
  select case
    when p_layers is not null and jsonb_array_length(p_layers) > 0 then (
      select string_agg(
               case when x.ord = 1 then lbl else lower(left(lbl, 1)) || substr(lbl, 2) end,
               ', then ' order by x.ord)
      from (
        select row_number() over (order by (l->>'base_agl_ft')::integer) as ord,
               cc.plain_label || ' at ' || to_char((l->>'base_agl_ft')::integer, 'FM999,999') || ' ft above ground'
               || case l->>'cloud_type' when 'CB' then ' (thunderstorm clouds)'
                                        when 'TCU' then ' (towering cumulus)' else '' end as lbl
        from jsonb_array_elements(p_layers) l
        join public.cloud_cover cc on cc.code = l->>'cover'
      ) x)
    when p_sky_clear = 'SKC' then 'Clear sky'
    when p_sky_clear = 'CAVOK' then 'No cloud below 5,000 ft and good visibility'
    when p_sky_clear in ('NSC', 'NCD', 'CLR') then 'No significant cloud'
    else null
  end
$$;

-------------------------------------------------------------------------------
-- nearby_forecast(): the TAF from the nearest station within p_max_nm that has
-- one valid now, and its change groups that overlap the next p_hours.
-- One row per group, in report order. SECURITY INVOKER: own spots only (RLS).
-------------------------------------------------------------------------------
create or replace function public.nearby_forecast(
  p_spot_id uuid,
  p_hours   integer default 12,
  p_max_nm  numeric default 40)
returns table (
  station           text,
  station_name      text,
  distance_nm       numeric,
  bearing_deg       integer,
  issued_at         timestamptz,
  issued_age_min    integer,
  valid_to          timestamptz,
  raw_text          text,
  seq               smallint,
  change_type       text,
  probability       smallint,
  time_from         timestamptz,
  time_to           timestamptz,
  cloud_summary     text,
  visibility_sm     numeric,
  visibility_is_min boolean,
  wx_string         text,
  thunder           boolean)
language sql stable set search_path = ''
as $$
  with taf as (
    select f.*, a.name, s.geog as spot_geog, a.geog as st_geog
    from public.spot s
    join public.airport a on extensions.st_dwithin(s.geog, a.geog, p_max_nm * 1852.0)
    cross join lateral (
      select * from public.taf_forecast tf
      where tf.station = a.icao and tf.valid_to > now() and tf.valid_from < now() + make_interval(hours => p_hours)
      order by tf.issued_at desc limit 1
    ) f
    where s.id = p_spot_id
    order by s.geog operator(extensions.<->) a.geog
    limit 1
  ), periods as (
    select p.*,
           -- a group lasts until its own end, or the next BASE/FM group, or the TAF's end
           coalesce(p.time_to,
                    (select min(n.time_from) from public.taf_period n
                     where n.taf_id = p.taf_id and n.seq > p.seq and n.change_type in ('BASE', 'FM')),
                    (select t.valid_to from taf t)) as ends
    from public.taf_period p
    where p.taf_id = (select id from taf)
  )
  select t.station, t.name,
         round((extensions.st_distance(t.spot_geog, t.st_geog) / 1852.0)::numeric, 1),
         (round(degrees(extensions.st_azimuth(t.spot_geog, t.st_geog)))::integer) % 360,
         t.issued_at, floor(extract(epoch from now() - t.issued_at) / 60)::integer, t.valid_to, t.raw_text,
         p.seq, p.change_type, p.probability, p.time_from, p.ends,
         public.taf_cloud_summary(p.layers, p.sky_clear_code),
         p.visibility_sm, p.visibility_is_min, p.wx_string,
         coalesce(p.wx_string ~ 'TS', false)   -- thunderstorm forecast (TSRA, VCTS, ...)
  from taf t
  join periods p on p.ends > now() and p.time_from < now() + make_interval(hours => p_hours)
  order by p.seq
$$;

revoke execute on function public.lightning_remark(text) from public, anon;
revoke execute on function public.taf_cloud_summary(jsonb, text) from public, anon;
revoke execute on function public.nearby_forecast(uuid, integer, numeric) from public, anon;
grant execute on function public.lightning_remark(text) to authenticated, service_role;
grant execute on function public.taf_cloud_summary(jsonb, text) to authenticated, service_role;
grant execute on function public.nearby_forecast(uuid, integer, numeric) to authenticated, service_role;
