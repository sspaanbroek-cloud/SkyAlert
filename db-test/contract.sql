-- Contract test: TS parser output -> real ingest_metars(). Run by run.sh with
-- -v payload=<json> when Deno is available.
begin;
set search_path = public, extensions;
select plan(7);
create temp table res as select ingest_metars(:'payload'::jsonb) as r;
select is((select (r->>'stored')::int from res), 4, 'all 4 parsed reports stored');
select is((select r->'rejected' from res), '[]'::jsonb, 'nothing rejected');
select is((select elevation_ft from airport where icao = 'KBFI'), 20, 'station elevation converted from metres');
select is((select report_type from metar_observation where station = 'KSFO'), 'SPECI', 'SPECI kept');
select is((select base_msl_ft from cloud_layer c join metar_observation m on m.id = c.metar_id
           where m.station = 'KSFO'), 210, 'VV002 at a 10 ft field is 210 ft MSL');
select is((select wind_variable from metar_observation where station = 'KRNT'), true, 'variable wind');
select is((select string_agg(coalesce(cloud_type, '-'), ',' order by seq) from cloud_layer c
           join metar_observation m on m.id = c.metar_id where m.station = 'KMIA'), 'CB,TCU,-', 'cloud types');
select * from finish(true);
rollback;
