-- Contract test: tools/nasr/convert.ts output, loaded with tools/nasr/load.sh,
-- resolves a real-format route. Runs after load.sh in run.sh.
begin;
set search_path = public, extensions;
select plan(3);
select is((select count(*)::int from nav_fix where source = 'nasr'), 7, 'sample NASR loaded');
select is((select array_agg(p->>'ident') from jsonb_array_elements(resolve_route('BTG V23 SEA', 'KBFI', 'KSEA')->'points') p),
  array['KBFI','BTG','OLM','SUMMA','SEA','KSEA'], 'route through V23 expands to the loaded fixes');
select ok((select (p->>'lat')::float8 > 46 from jsonb_array_elements(resolve_route('BTG V23 SEA', 'KBFI', 'KSEA')->'points') p
           where p->>'ident' = 'OLM'), 'OLM is the Washington one');
select * from finish(true);
rollback;
