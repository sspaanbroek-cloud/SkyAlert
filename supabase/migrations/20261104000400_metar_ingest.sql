-- METAR ingest (phase 1, step 3).
--
-- Flow: the `ingest-metar` Edge Function asks metar_fetch_areas() which
-- bounding boxes to fetch from the Aviation Weather Center, parses each report,
-- and hands the batch to ingest_metars(), which stores it atomically per report.
set search_path = public, extensions;

-------------------------------------------------------------------------------
-- Which areas to fetch: one box per 1-degree grid cell that holds a spot,
-- padded by the largest search radius in that cell plus 30 nm of margin so
-- stations just outside the radius can still be blended in.
-------------------------------------------------------------------------------
create or replace function public.metar_fetch_areas(margin_nm numeric default 30)
returns table (min_lat double precision, min_lon double precision,
               max_lat double precision, max_lon double precision)
language sql stable security definer set search_path = ''
as $$
  with cells as (
    select floor(s.lat) as cell_lat, floor(s.lon) as cell_lon,
           (max(s.search_radius_nm) + margin_nm) / 60.0 as pad_lat   -- 1 deg lat = 60 nm
    from public.spot s
    group by 1, 2
  )
  select greatest(-90.0, cell_lat - pad_lat),
         greatest(-180.0, cell_lon - pad_lat / greatest(cos(radians(cell_lat + 0.5)), 0.2)),
         least(90.0, cell_lat + 1 + pad_lat),
         least(180.0, cell_lon + 1 + pad_lat / greatest(cos(radians(cell_lat + 0.5)), 0.2))
  from cells
  order by 1, 2
$$;

-------------------------------------------------------------------------------
-- Store a batch of parsed reports.
--
-- reports: JSON array of
--   { station: {icao, name, lat, lon, elevation_ft},
--     observed_at, raw_text, report_type, is_auto, visibility_sm,
--     visibility_is_min, flight_category, wind_dir_deg, wind_variable,
--     wind_speed_kt, wind_gust_kt, temp_c, dewpoint_c, altimeter_hpa,
--     wx_string, sky_clear_code,
--     layers: [{cover, base_agl_ft, cloud_type}] }   -- lowest first
--
-- Each report is stored in its own subtransaction, so one bad report is
-- rejected without losing the rest. Re-sending an identical report is a no-op;
-- a corrected report (same station + time, different text) replaces the old
-- one and its cloud layers.
-------------------------------------------------------------------------------
create or replace function public.ingest_metars(reports jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  r         jsonb;
  st        jsonb;
  mid       bigint;
  stored    integer := 0;
  unchanged integer := 0;
  rejected  jsonb := '[]'::jsonb;
begin
  if jsonb_typeof(reports) is distinct from 'array' then
    raise exception 'reports must be a JSON array';
  end if;

  for r in select value from jsonb_array_elements(reports) loop
    begin
      st  := r->'station';
      mid := null;

      insert into public.airport as a (icao, name, geog, elevation_ft, has_metar, updated_at)
      values (
        st->>'icao',
        st->>'name',
        extensions.st_setsrid(extensions.st_makepoint((st->>'lon')::float8, (st->>'lat')::float8), 4326)::extensions.geography,
        (st->>'elevation_ft')::integer,
        true, now())
      on conflict (icao) do update
        set name = coalesce(excluded.name, a.name),
            geog = excluded.geog,
            elevation_ft = excluded.elevation_ft,
            has_metar = true,
            updated_at = now()
        where (a.name, a.elevation_ft, a.has_metar) is distinct from (coalesce(excluded.name, a.name), excluded.elevation_ft, true)
           or not extensions.st_equals(a.geog::extensions.geometry, excluded.geog::extensions.geometry);

      insert into public.metar_observation as m (
        station, observed_at, raw_text, report_type, is_auto, visibility_sm, visibility_is_min,
        flight_category, wind_dir_deg, wind_variable, wind_speed_kt, wind_gust_kt, temp_c,
        dewpoint_c, altimeter_hpa, wx_string, sky_clear_code, source, fetched_at)
      values (
        st->>'icao',
        (r->>'observed_at')::timestamptz,
        r->>'raw_text',
        coalesce(r->>'report_type', 'METAR'),
        coalesce((r->>'is_auto')::boolean, false),
        (r->>'visibility_sm')::numeric,
        coalesce((r->>'visibility_is_min')::boolean, false),
        r->>'flight_category',
        (r->>'wind_dir_deg')::smallint,
        coalesce((r->>'wind_variable')::boolean, false),
        (r->>'wind_speed_kt')::smallint,
        (r->>'wind_gust_kt')::smallint,
        (r->>'temp_c')::numeric,
        (r->>'dewpoint_c')::numeric,
        (r->>'altimeter_hpa')::numeric,
        r->>'wx_string',
        r->>'sky_clear_code',
        'awc',
        now())
      on conflict (station, observed_at) do update set
        raw_text = excluded.raw_text, report_type = excluded.report_type, is_auto = excluded.is_auto,
        visibility_sm = excluded.visibility_sm, visibility_is_min = excluded.visibility_is_min,
        flight_category = excluded.flight_category, wind_dir_deg = excluded.wind_dir_deg,
        wind_variable = excluded.wind_variable, wind_speed_kt = excluded.wind_speed_kt,
        wind_gust_kt = excluded.wind_gust_kt, temp_c = excluded.temp_c, dewpoint_c = excluded.dewpoint_c,
        altimeter_hpa = excluded.altimeter_hpa, wx_string = excluded.wx_string,
        sky_clear_code = excluded.sky_clear_code, fetched_at = now()
        where m.raw_text is distinct from excluded.raw_text
      returning id into mid;

      if mid is null then
        unchanged := unchanged + 1;
        continue;
      end if;

      delete from public.cloud_layer where metar_id = mid;
      insert into public.cloud_layer (metar_id, seq, cover, cloud_type, base_agl_ft)
      select mid, (t.ord - 1)::smallint, t.x->>'cover', t.x->>'cloud_type', (t.x->>'base_agl_ft')::integer
      from jsonb_array_elements(coalesce(r->'layers', '[]'::jsonb)) with ordinality as t(x, ord);

      stored := stored + 1;
    exception when others then
      rejected := rejected || jsonb_build_object(
        'station', coalesce(r->'station'->>'icao', '?'),
        'observed_at', r->>'observed_at',
        'error', sqlerrm);
    end;
  end loop;

  return jsonb_build_object('stored', stored, 'unchanged', unchanged, 'rejected', rejected);
end $$;

create or replace function public.purge_metar_observations(keep interval default interval '3 days')
returns integer language plpgsql set search_path = ''
as $$
declare n integer;
begin
  delete from public.metar_observation where observed_at < now() - keep;
  get diagnostics n = row_count;
  return n;
end $$;

-------------------------------------------------------------------------------
-- Plain-language sky description for one observation.
-------------------------------------------------------------------------------
create or replace function public.sky_summary(p_metar_id bigint)
returns text
language sql stable set search_path = ''
as $$
  with m as (
    select * from public.metar_observation where id = p_metar_id
  ), l as (
    select string_agg(
             case when seq = 0 then plain_label
                  else lower(left(plain_label, 1)) || substr(plain_label, 2) end,
             ', then ' order by seq) as labels,
           max(base_agl_ft) as top_base,
           bool_or(cover in ('OVC', 'VV')) as sealed
    from public.cloud_layer where metar_id = p_metar_id
  )
  select case
    when l.labels is not null then
      l.labels
      || case when m.is_auto and not l.sealed and l.top_base < 12000
              then '. Automated station: it can''t see cloud above 12,000 ft'
              else '' end
    when m.sky_clear_code = 'CLR' then 'No cloud below 12,000 ft (automated sensor; it can''t see higher)'
    when m.sky_clear_code = 'NCD' then 'No cloud detected (automated sensor; high cloud may be missed)'
    when m.sky_clear_code = 'SKC' then 'Clear sky'
    when m.sky_clear_code = 'NSC' then 'No significant cloud'
    when m.sky_clear_code = 'CAVOK' then 'No cloud below 5,000 ft and good visibility'
    else 'Sky condition not reported'
  end
  from m cross join l
$$;

-------------------------------------------------------------------------------
-- Latest observation from each station near one of the caller's spots.
-- SECURITY INVOKER: RLS on spot means you only get answers for your own spots.
-------------------------------------------------------------------------------
create or replace function public.nearby_weather(
  p_spot_id uuid,
  p_max_nm  numeric default 60,
  p_limit   integer default 5)
returns table (
  station          text,
  station_name     text,
  distance_nm      numeric,
  bearing_deg      integer,      -- from the spot to the station
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
  layers           jsonb)
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
                   from public.cloud_layer c where c.metar_id = m.id), '[]'::jsonb)
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

-------------------------------------------------------------------------------
-- Privileges
-------------------------------------------------------------------------------
revoke execute on function public.metar_fetch_areas(numeric) from public, anon, authenticated;
revoke execute on function public.ingest_metars(jsonb) from public, anon, authenticated;
revoke execute on function public.purge_metar_observations(interval) from public, anon, authenticated;
grant execute on function public.metar_fetch_areas(numeric) to service_role;
grant execute on function public.ingest_metars(jsonb) to service_role;
grant execute on function public.purge_metar_observations(interval) to service_role;

revoke execute on function public.nearby_weather(uuid, numeric, integer) from public, anon;
revoke execute on function public.sky_summary(bigint) from public, anon;
grant execute on function public.nearby_weather(uuid, numeric, integer) to authenticated, service_role;
grant execute on function public.sky_summary(bigint) to authenticated, service_role;
