-- Airport directory for "pick a spot by airport code".
--
-- Loaded from OurAirports (public domain, https://ourairports.com/data/) by
-- .github/scripts/load-airports.sh, which the Deploy backend workflow runs.
-- Airports only (small, medium, large); no heliports, seaplane bases or
-- closed fields.
set search_path = public, extensions;

create table public.airport_directory (
  ident         text primary key,         -- OurAirports ident, e.g. KSEA, EGLL, K0S9
  icao_code     text,
  iata_code     text,
  gps_code      text,
  local_code    text,                     -- e.g. US FAA id (SEA, 0S9)
  name          text not null,
  municipality  text,
  iso_country   text,
  type          text not null check (type in ('small_airport', 'medium_airport', 'large_airport')),
  geog          geography(Point, 4326) not null,
  lat           double precision generated always as (st_y(geog::geometry)) stored,
  lon           double precision generated always as (st_x(geog::geometry)) stored,
  elevation_ft  integer,
  loaded_at     timestamptz not null default now()
);
create index airport_directory_icao_idx  on public.airport_directory (icao_code)  where icao_code is not null;
create index airport_directory_iata_idx  on public.airport_directory (iata_code)  where iata_code is not null;
create index airport_directory_gps_idx   on public.airport_directory (gps_code)   where gps_code is not null;
create index airport_directory_local_idx on public.airport_directory (local_code) where local_code is not null;

alter table public.airport_directory enable row level security;
create policy "signed-in read" on public.airport_directory for select to authenticated using (true);

-------------------------------------------------------------------------------
-- find_airport('KSEA' | 'SEA' | 'egll' | '0S9') -> best matches first.
-- Exact ICAO / ident / GPS code first, then IATA, then local (FAA) code;
-- within each, larger airports first. Up to 5.
-------------------------------------------------------------------------------
create or replace function public.find_airport(p_code text)
returns table (ident text, code text, name text, municipality text, iso_country text, type text,
               lat double precision, lon double precision, elevation_ft integer, matched text)
language sql stable set search_path = ''
as $$
  with q as (select upper(trim(p_code)) as c)
  select d.ident,
         coalesce(d.icao_code, d.gps_code, d.ident),
         d.name, d.municipality, d.iso_country, d.type, d.lat, d.lon, d.elevation_ft,
         case when q.c in (d.icao_code, d.ident, d.gps_code) then 'icao'
              when q.c = d.iata_code then 'iata' else 'local' end
  from public.airport_directory d, q
  where length(q.c) between 2 and 8
    and (d.icao_code = q.c or d.ident = q.c or d.gps_code = q.c or d.iata_code = q.c or d.local_code = q.c)
  order by case when q.c in (d.icao_code, d.ident, d.gps_code) then 0 when q.c = d.iata_code then 1 else 2 end,
           case d.type when 'large_airport' then 0 when 'medium_airport' then 1 else 2 end,
           d.name
  limit 5
$$;

revoke execute on function public.find_airport(text) from public, anon;
grant execute on function public.find_airport(text) to authenticated, service_role;
