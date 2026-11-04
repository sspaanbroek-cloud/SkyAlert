-- Row-level security.
--
-- Model:
--   * Users sign in with Supabase Auth. Their own rows (spot, alert) are fully
--     theirs; predictions/assessments are visible only for spots they own.
--   * Shared reference and observation data (airports, weather, flights,
--     ADS-B) is readable by any signed-in user and written only by the ingest
--     workers using the service_role key (which bypasses RLS).
--   * The anon role gets nothing.

-- Enable RLS everywhere.
alter table public.airport               enable row level security;
alter table public.aircraft_type         enable row level security;
alter table public.cloud_cover           enable row level security;
alter table public.spot                  enable row level security;
alter table public.flight_plan           enable row level security;
alter table public.route_waypoint        enable row level security;
alter table public.track_point           enable row level security;
alter table public.recurring_flight      enable row level security;
alter table public.metar_observation     enable row level security;
alter table public.cloud_layer           enable row level security;
alter table public.overflight_prediction enable row level security;
alter table public.visibility_assessment enable row level security;
alter table public.alert                 enable row level security;

-- Belt and braces: anon has no table access at all.
revoke all on all tables in schema public from anon;
alter default privileges in schema public revoke all on tables from anon;

-- Ingest-only functions are not part of the public API.
revoke execute on function public.purge_track_points(interval) from public, anon, authenticated;

-------------------------------------------------------------------------------
-- Shared read-only data
-------------------------------------------------------------------------------
create policy "signed-in read" on public.airport           for select to authenticated using (true);
create policy "signed-in read" on public.aircraft_type     for select to authenticated using (true);
create policy "signed-in read" on public.cloud_cover       for select to authenticated using (true);
create policy "signed-in read" on public.flight_plan       for select to authenticated using (true);
create policy "signed-in read" on public.route_waypoint    for select to authenticated using (true);
create policy "signed-in read" on public.track_point       for select to authenticated using (true);
create policy "signed-in read" on public.recurring_flight  for select to authenticated using (true);
create policy "signed-in read" on public.metar_observation for select to authenticated using (true);
create policy "signed-in read" on public.cloud_layer       for select to authenticated using (true);

-------------------------------------------------------------------------------
-- spot: owner only
-------------------------------------------------------------------------------
create policy "owner select" on public.spot for select to authenticated
  using (user_id = (select auth.uid()));
create policy "owner insert" on public.spot for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy "owner update" on public.spot for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
create policy "owner delete" on public.spot for delete to authenticated
  using (user_id = (select auth.uid()));

-------------------------------------------------------------------------------
-- predictions / assessments: read-only, scoped to the caller's spots
-------------------------------------------------------------------------------
create policy "own spots" on public.overflight_prediction for select to authenticated
  using (exists (
    select 1 from public.spot s
    where s.id = overflight_prediction.spot_id and s.user_id = (select auth.uid())
  ));

create policy "own spots" on public.visibility_assessment for select to authenticated
  using (exists (
    select 1 from public.overflight_prediction p
    join public.spot s on s.id = p.spot_id
    where p.id = visibility_assessment.prediction_id and s.user_id = (select auth.uid())
  ));

-------------------------------------------------------------------------------
-- alert: owner manages their own; spot and prediction must also be theirs
-------------------------------------------------------------------------------
create policy "owner select" on public.alert for select to authenticated
  using (user_id = (select auth.uid()));
create policy "owner delete" on public.alert for delete to authenticated
  using (user_id = (select auth.uid()));

create policy "owner insert" on public.alert for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and sent_at is null
    and exists (
      select 1 from public.overflight_prediction p
      join public.spot s on s.id = p.spot_id
      where p.id = alert.prediction_id and p.spot_id = alert.spot_id
        and s.user_id = (select auth.uid())
    )
  );

-- Users may change notify_at / min_rating; sent_at is set by the worker only.
revoke update on public.alert from authenticated;
grant update (notify_at, min_rating) on public.alert to authenticated;
create policy "owner update" on public.alert for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- spot: user_id is fixed once created.
revoke update on public.spot from authenticated;
grant update (name, geog, elevation_ft, search_radius_nm, min_elevation_deg) on public.spot to authenticated;
