-- Route resolution and filed flight plans (phase 2, part 5).
--
-- nav_fix / airway_fix hold FAA NASR reference data (loaded every 28 days with
-- tools/nasr). resolve_route() turns a filed route string into points;
-- ingest_flight_plans() stores plans from any source with their resolved
-- route, waypoint ETAs and altitudes; compute_plan_predictions() predicts
-- passes from them. Live tracking replaces a plan pass when it picks the
-- flight up.
set search_path = public, extensions;

-------------------------------------------------------------------------------
-- Reference data
-------------------------------------------------------------------------------
create table public.nav_fix (
  id            bigint generated always as identity primary key,
  ident         text not null,
  kind          text not null check (kind in ('fix', 'navaid', 'airport')),
  icao_ident    text,                 -- airports: ICAO id (KSEA) when ident is the FAA id (SEA)
  name          text,
  geog          geography(Point, 4326) not null,
  state_code    text,
  country_code  text,
  source        text not null default 'nasr',
  cycle         date
);
create index nav_fix_ident_idx on public.nav_fix (ident);
create index nav_fix_icao_idx on public.nav_fix (icao_ident) where icao_ident is not null;
create index nav_fix_geog_gix on public.nav_fix using gist (geog);

create table public.airway_fix (
  airway_id  text not null,
  seq        integer not null,
  ident      text not null,
  geog       geography(Point, 4326) not null,
  primary key (airway_id, seq)
);
create index airway_fix_ident_idx on public.airway_fix (airway_id, ident);

alter table public.nav_fix enable row level security;
alter table public.airway_fix enable row level security;
create policy "signed-in read" on public.nav_fix for select to authenticated using (true);
create policy "signed-in read" on public.airway_fix for select to authenticated using (true);

alter table public.flight_plan
  add column filed_speed_kt integer check (filed_speed_kt between 50 and 700),
  add column route_status text not null default 'unresolved'
    check (route_status in ('unresolved', 'resolved', 'partial', 'failed')),
  add column route_note text,
  add column route_total_nm numeric(7,1),
  add column resolved_at timestamptz;

alter table public.route_waypoint add column cum_nm numeric(7,1), add column via text;

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

-- Filed coordinate tokens: 4730N12230W (deg+min), 47N122W (deg), 473015N1223045W (deg+min+sec).
create or replace function public.parse_coord_token(t text)
returns extensions.geography language plpgsql immutable set search_path = ''
as $$
declare m text[]; lat float8; lon float8;
begin
  m := regexp_match(t, '^(\d{2})(\d{2})?(\d{2})?([NS])(\d{3})(\d{2})?(\d{2})?([EW])$');
  if m is null then
    return null;
  end if;
  lat := m[1]::float8 + coalesce(m[2]::float8, 0) / 60 + coalesce(m[3]::float8, 0) / 3600;
  lon := m[5]::float8 + coalesce(m[6]::float8, 0) / 60 + coalesce(m[7]::float8, 0) / 3600;
  if m[4] = 'S' then lat := -lat; end if;
  if m[8] = 'W' then lon := -lon; end if;
  if lat > 90 or lon > 180 then
    return null;
  end if;
  return extensions.st_setsrid(extensions.st_makepoint(lon, lat), 4326)::extensions.geography;
end $$;

-- Airport position by ICAO or FAA id: SkyAlert's airport table first, then NASR.
create or replace function public.airport_point(p_id text)
returns extensions.geography language sql stable set search_path = ''
as $$
  select coalesce(
    (select a.geog from public.airport a where a.icao = upper(p_id)),
    (select n.geog from public.nav_fix n where n.kind = 'airport' and (n.icao_ident = upper(p_id) or n.ident = upper(p_id)) limit 1),
    (select n.geog from public.nav_fix n where n.kind = 'airport' and length(p_id) = 4 and upper(p_id) like 'K%'
       and n.ident = substr(upper(p_id), 2) limit 1))
$$;

-------------------------------------------------------------------------------
-- resolve_route(route, origin, destination) -> jsonb
--   {points: [{ident, lat, lon, kind, via}], unresolved: [...], skipped: [...]}
--
-- Tokens are split on spaces and dots (FAA "SEA..J70.LKV" style works too).
-- Dropped: DCT, speed/level groups (N0450F350), "/..." suffixes, IFR/VFR.
-- An airway between two fixes is expanded to the fixes along it. A token that
-- looks like a SID/STAR (letters + digit, e.g. SUMMA1) and isn't a known fix is
-- skipped and listed. Ambiguous identifiers resolve to the candidate nearest
-- the previous point. Origin and destination airports bracket the route.
-------------------------------------------------------------------------------
create or replace function public.resolve_route(p_route text, p_origin text, p_dest text)
returns jsonb language plpgsql stable set search_path = ''
as $$
declare
  tokens     text[];
  t          text;
  i          integer;
  prev       extensions.geography;
  prev_ident text;
  dest_pt    extensions.geography;
  pt         extensions.geography;
  kind       text;
  airway     text;
  seq_a      integer;
  seq_b      integer;
  pts        jsonb := '[]'::jsonb;
  unresolved jsonb := '[]'::jsonb;
  skipped    jsonb := '[]'::jsonb;
  r          record;
begin
  prev := public.airport_point(p_origin);
  dest_pt := public.airport_point(p_dest);
  if prev is not null then
    pts := pts || jsonb_build_object('ident', upper(p_origin), 'lat', extensions.st_y(prev::extensions.geometry),
                                     'lon', extensions.st_x(prev::extensions.geometry), 'kind', 'airport', 'via', null);
    prev_ident := upper(p_origin);
  end if;

  tokens := regexp_split_to_array(upper(trim(coalesce(p_route, ''))), '[\s.]+');
  for i in 1 .. coalesce(array_length(tokens, 1), 0) loop
    t := split_part(tokens[i], '/', 1);
    continue when t = '' or t in ('DCT', 'IFR', 'VFR') or t ~ '^[NKM]\d{3,4}([FASM]\d{3,4})?$';
    -- The origin/destination written into the route. Its 3-letter FAA form
    -- (SEA for KSEA) only counts at the very start or end, and never right
    -- after an airway: there, and mid-route, SEA is the Seattle VOR.
    continue when t in (upper(p_origin), upper(p_dest))
                  or (length(t) = 3 and ('K' || t) in (upper(p_origin), upper(p_dest))
                      and i in (1, array_length(tokens, 1)) and airway is null);

    -- Airway: remember it; it's expanded when the exit fix arrives.
    if t ~ '^[A-Z]{1,2}\d{1,4}$' and exists (select 1 from public.airway_fix a where a.airway_id = t) then
      airway := t;
      continue;
    end if;

    pt := public.parse_coord_token(t);
    kind := 'coord';
    if pt is null then
      select n.geog, n.kind into pt, kind
      from public.nav_fix n
      where n.ident = t
      order by case when prev is null then 0 else extensions.st_distance(n.geog, prev) end
      limit 1;
    end if;

    if pt is null then
      if t ~ '^[A-Z]{2,5}\d[A-Z]?$' then
        skipped := skipped || to_jsonb(t);       -- SID/STAR or transition name
      else
        unresolved := unresolved || to_jsonb(t);
      end if;
      airway := null;
      continue;
    end if;

    if airway is not null and prev_ident is not null then
      -- Entry and exit positions on the airway (nearest occurrences).
      select a.seq into seq_a from public.airway_fix a
      where a.airway_id = airway and a.ident = prev_ident
      order by extensions.st_distance(a.geog, coalesce(prev, a.geog)) limit 1;
      select a.seq into seq_b from public.airway_fix a
      where a.airway_id = airway and a.ident = t
      order by extensions.st_distance(a.geog, pt) limit 1;

      if seq_a is not null and seq_b is not null then
        for r in
          select a.ident, a.geog from public.airway_fix a
          where a.airway_id = airway
            and a.seq > least(seq_a, seq_b) and a.seq < greatest(seq_a, seq_b)
          order by case when seq_b > seq_a then a.seq else -a.seq end
        loop
          pts := pts || jsonb_build_object('ident', r.ident, 'lat', extensions.st_y(r.geog::extensions.geometry),
                                           'lon', extensions.st_x(r.geog::extensions.geometry), 'kind', 'fix', 'via', airway);
        end loop;
      else
        unresolved := unresolved || to_jsonb(airway || ' (' || coalesce(prev_ident, '?') || '-' || t || ')');
      end if;
    end if;

    pts := pts || jsonb_build_object('ident', t, 'lat', extensions.st_y(pt::extensions.geometry),
                                     'lon', extensions.st_x(pt::extensions.geometry), 'kind', kind, 'via', airway);
    prev := pt;
    prev_ident := t;
    airway := null;
    seq_a := null;
    seq_b := null;
  end loop;

  if dest_pt is not null then
    pts := pts || jsonb_build_object('ident', upper(p_dest), 'lat', extensions.st_y(dest_pt::extensions.geometry),
                                     'lon', extensions.st_x(dest_pt::extensions.geometry), 'kind', 'airport', 'via', null);
  end if;

  return jsonb_build_object('points', pts, 'unresolved', unresolved, 'skipped', skipped);
end $$;

-------------------------------------------------------------------------------
-- ingest_flight_plans(plans): store plans from any source and resolve routes.
--   [{source, source_ref, callsign, origin, destination, aircraft_type, rules,
--     filed_cruise_ft, filed_speed_kt, filed_etd, route_string, status}]
--
-- Waypoint ETAs: off the ground 15 min after the filed departure time, then
-- the filed speed (420 kt if none) along the route. Altitudes: climb about
-- 300 ft per nm from the origin, descend on a 3 degree path (318 ft per nm)
-- to the destination, never above the filed cruise level.
-------------------------------------------------------------------------------
create or replace function public.ingest_flight_plans(plans jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  f        jsonb;
  fid      bigint;
  res      jsonb;
  total_nm float8;
  v_status text;
  v_note   text;
  o_elev   integer;
  d_elev   integer;
  stored   integer := 0;
  rejected jsonb := '[]'::jsonb;
begin
  if jsonb_typeof(plans) is distinct from 'array' then
    raise exception 'plans must be a JSON array';
  end if;

  for f in select value from jsonb_array_elements(plans) loop
    begin
      insert into public.flight_plan as fp (source, source_ref, callsign, origin, destination, aircraft_type, rules,
                                            filed_cruise_ft, filed_speed_kt, filed_etd, route_string, status)
      values (f->>'source', f->>'source_ref', upper(f->>'callsign'), upper(f->>'origin'), upper(f->>'destination'),
              upper(f->>'aircraft_type'), f->>'rules', (f->>'filed_cruise_ft')::integer,
              (f->>'filed_speed_kt')::integer, (f->>'filed_etd')::timestamptz, f->>'route_string',
              coalesce(f->>'status', 'filed'))
      on conflict (source, source_ref) do update set
        callsign = excluded.callsign, origin = excluded.origin, destination = excluded.destination,
        aircraft_type = excluded.aircraft_type, rules = excluded.rules, filed_cruise_ft = excluded.filed_cruise_ft,
        filed_speed_kt = excluded.filed_speed_kt, filed_etd = excluded.filed_etd,
        route_string = excluded.route_string, status = excluded.status
      returning id into fid;

      res := public.resolve_route(f->>'route_string', f->>'origin', f->>'destination');
      delete from public.route_waypoint where flight_plan_id = fid;

      if jsonb_array_length(res->'points') < 2 then
        update public.flight_plan set route_geog = null, route_status = 'failed', route_total_nm = null,
          route_note = 'not enough resolvable points: ' || (res->'unresolved')::text, resolved_at = now()
        where id = fid;
        stored := stored + 1;
        continue;
      end if;

      select coalesce(a.elevation_ft, 0) into o_elev from public.airport a where a.icao = upper(f->>'origin');
      select coalesce(a.elevation_ft, 0) into d_elev from public.airport a where a.icao = upper(f->>'destination');

      with p as (
        select (x.ord - 1)::integer as seq, x.v->>'ident' as ident, x.v->>'via' as via,
               extensions.st_setsrid(extensions.st_makepoint((x.v->>'lon')::float8, (x.v->>'lat')::float8), 4326)::extensions.geography as g
        from jsonb_array_elements(res->'points') with ordinality as x(v, ord)
      ), legs as (
        select p.*, coalesce(extensions.st_distance(lag(g) over (order by seq), g), 0) / 1852.0 as leg_nm from p
      ), cum as (
        select legs.*, sum(leg_nm) over (order by seq) as cum_nm, sum(leg_nm) over () as total from legs
      )
      insert into public.route_waypoint (flight_plan_id, seq, fix_name, geog, cum_nm, via, altitude_ft, eta)
      select fid, seq, ident, g, round(cum_nm::numeric, 1), via,
             least(coalesce((f->>'filed_cruise_ft')::integer, 35000),
                   coalesce(o_elev, 0) + cum_nm * 300,
                   coalesce(d_elev, 0) + (total - cum_nm) * 318)::integer,
             (f->>'filed_etd')::timestamptz + interval '15 minutes'
               + make_interval(secs => cum_nm / coalesce((f->>'filed_speed_kt')::float8, 420) * 3600)
      from cum;

      select max(cum_nm) into total_nm from public.route_waypoint where flight_plan_id = fid;
      v_status := case when jsonb_array_length(res->'unresolved') = 0 then 'resolved' else 'partial' end;
      v_note := nullif(concat_ws('; ',
                case when jsonb_array_length(res->'unresolved') > 0 then 'unresolved: ' || (res->'unresolved')::text end,
                case when jsonb_array_length(res->'skipped') > 0 then 'procedures not expanded: ' || (res->'skipped')::text end), '');

      update public.flight_plan set
        route_geog = (select extensions.st_makeline(array_agg(w.geog::extensions.geometry order by w.seq))::extensions.geography
                      from public.route_waypoint w where w.flight_plan_id = fid),
        route_status = v_status, route_note = v_note, route_total_nm = round(total_nm::numeric, 1), resolved_at = now()
      where id = fid;
      stored := stored + 1;
    exception when others then
      rejected := rejected || jsonb_build_object('source_ref', f->>'source_ref', 'error', sqlerrm);
    end;
  end loop;

  return jsonb_build_object('stored', stored, 'rejected', rejected);
end $$;

-------------------------------------------------------------------------------
-- compute_plan_predictions(): passes from filed plans departing from 6 h ago
-- up to p_horizon_hours ahead. Closest point of the route to each spot within
-- its radius; ETA and altitude interpolated between the waypoints either side.
-- Confidence at most 0.5 (plans are intentions; ATC changes routes) and lower
-- the further ahead the pass is.
-------------------------------------------------------------------------------
create or replace function public.compute_plan_predictions(p_horizon_hours integer default 12)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  run_at  timestamptz := now();
  c       record;
  h_m     float8;
  el      float8;
  ins     integer := 0;
  low     integer := 0;
  removed integer := 0;
begin
  for c in
    with cand as (
      select fp.id as fid, fp.callsign, fp.aircraft_type, s.id as spot_id, s.geog as spot_geog,
             s.elevation_ft as spot_elev, s.min_elevation_deg, fp.route_total_nm,
             extensions.st_linelocatepoint(fp.route_geog::extensions.geometry, s.geog::extensions.geometry) as frac
      from public.flight_plan fp
      join public.spot s on extensions.st_dwithin(fp.route_geog, s.geog, s.search_radius_nm::float8 * 1852.0)
      where fp.route_geog is not null and fp.status in ('filed', 'active')
        and fp.filed_etd between run_at - interval '6 hours' and run_at + make_interval(hours => p_horizon_hours)
    ), pos as (
      select cand.*,
             extensions.st_lineinterpolatepoint(
               (select fp.route_geog::extensions.geometry from public.flight_plan fp where fp.id = cand.fid), frac
             )::extensions.geography as cpa,
             frac * route_total_nm as at_nm
      from cand
    )
    select pos.*,
           extensions.st_distance(pos.spot_geog, pos.cpa) as dist_m,
           coalesce(degrees(extensions.st_azimuth(pos.spot_geog, pos.cpa)), 0) as az,
           wa.cum_nm::float8 as a_nm, wa.eta as a_eta, wa.altitude_ft::float8 as a_alt,
           wb.cum_nm::float8 as b_nm, wb.eta as b_eta, wb.altitude_ft::float8 as b_alt
    from pos
    -- waypoints either side of the closest point
    cross join lateral (select w.cum_nm, w.eta, w.altitude_ft from public.route_waypoint w
                        where w.flight_plan_id = pos.fid and w.cum_nm <= pos.at_nm + 0.05
                        order by w.cum_nm desc limit 1) wa
    cross join lateral (select w.cum_nm, w.eta, w.altitude_ft from public.route_waypoint w
                        where w.flight_plan_id = pos.fid and w.cum_nm >= pos.at_nm - 0.05
                        order by w.cum_nm limit 1) wb
  loop
    declare
      w    float8 := case when c.b_nm > c.a_nm then (c.at_nm - c.a_nm) / (c.b_nm - c.a_nm) else 0 end;
      eta  timestamptz := c.a_eta + (c.b_eta - c.a_eta) * w;
      alt  float8 := c.a_alt + (c.b_alt - c.a_alt) * w;
      lead float8;
      conf float8;
    begin
      continue when eta < run_at - interval '2 minutes';
      h_m := (alt - c.spot_elev) * 0.3048 - (c.dist_m * c.dist_m) * 0.87 / (2 * 6371000.0);
      el := degrees(atan2(h_m, greatest(c.dist_m, 1.0)));
      if el < c.min_elevation_deg then
        low := low + 1;
        continue;
      end if;
      lead := greatest(0, extract(epoch from eta - run_at) / 3600.0);
      conf := 0.5 * (1.0 - least(lead, 12) / 24.0);

      insert into public.overflight_prediction as p (
        spot_id, basis, flight_plan_id, callsign, aircraft_type, pass_key, closest_approach_at,
        closest_distance_nm, closest_point, altitude_ft, azimuth_deg, elevation_deg, confidence, computed_at)
      values (c.spot_id, 'filed_plan', c.fid, c.callsign, c.aircraft_type, 'plan:' || c.fid, eta,
              round((c.dist_m / 1852.0)::numeric, 2), c.cpa, round(alt)::integer,
              round(mod((c.az + 360)::numeric, 360), 1) % 360, round(el::numeric, 1), round(conf::numeric, 2), run_at)
      on conflict (spot_id, pass_key) do update set
        closest_approach_at = excluded.closest_approach_at, closest_distance_nm = excluded.closest_distance_nm,
        closest_point = excluded.closest_point, altitude_ft = excluded.altitude_ft, azimuth_deg = excluded.azimuth_deg,
        elevation_deg = excluded.elevation_deg, confidence = excluded.confidence, computed_at = excluded.computed_at,
        callsign = excluded.callsign, aircraft_type = excluded.aircraft_type;
      ins := ins + 1;
    end;
  end loop;

  -- Plans that no longer produce a pass (cancelled, rerouted).
  delete from public.overflight_prediction
  where basis = 'filed_plan' and computed_at < run_at and closest_approach_at > run_at;
  get diagnostics removed = row_count;

  return jsonb_build_object('upserted', ins, 'too_low', low, 'removed', removed);
end $$;

-------------------------------------------------------------------------------
-- Live tracking replaces "usual" and filed-plan passes for the same callsign
-- within 45 min, carrying pending alerts over with the same lead time.
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
      and p.spot_id = new.spot_id and p.basis in ('recurring', 'filed_plan') and p.callsign = new.callsign
      and p.closest_approach_at between new.closest_approach_at - interval '45 minutes'
                                    and new.closest_approach_at + interval '45 minutes'
      and not exists (select 1 from public.alert x where x.user_id = a.user_id and x.prediction_id = new.id);

    delete from public.overflight_prediction p
    where p.spot_id = new.spot_id and p.basis in ('recurring', 'filed_plan') and p.callsign = new.callsign
      and p.closest_approach_at between new.closest_approach_at - interval '45 minutes'
                                    and new.closest_approach_at + interval '45 minutes';
  end if;
  return null;
end $$;

-- A plan pass shouldn't come back once live tracking has the flight.
create or replace function public.skip_plan_if_live()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if exists (select 1 from public.overflight_prediction l
             where l.spot_id = new.spot_id and l.basis = 'live_adsb' and l.callsign = new.callsign
               and l.closest_approach_at between new.closest_approach_at - interval '45 minutes'
                                             and new.closest_approach_at + interval '45 minutes') then
    return null;
  end if;
  return new;
end $$;
create trigger skip_plan_if_live before insert on public.overflight_prediction
  for each row when (new.basis = 'filed_plan') execute function public.skip_plan_if_live();

revoke execute on function public.resolve_route(text, text, text) from public, anon;
grant execute on function public.resolve_route(text, text, text) to authenticated, service_role;
revoke execute on function public.ingest_flight_plans(jsonb) from public, anon, authenticated;
revoke execute on function public.compute_plan_predictions(integer) from public, anon, authenticated;
grant execute on function public.ingest_flight_plans(jsonb) to service_role;
grant execute on function public.compute_plan_predictions(integer) to service_role;

do $outer$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not installed: skipping plan-prediction schedule';
    return;
  end if;
  perform cron.schedule('plan-predictions', '*/10 * * * *', $job$
    select public.compute_plan_predictions();
    select public.refresh_visibility_assessments();
  $job$);
end
$outer$;
