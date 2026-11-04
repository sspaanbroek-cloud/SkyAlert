#!/usr/bin/env bash
# Load converted NASR data (from convert.ts) into SkyAlert, replacing the
# previous cycle in one transaction.
#   tools/nasr/load.sh <out dir> [psql connection args]   (default: $DATABASE_URL)
# Get the connection string from the Supabase dashboard (Connect, direct connection).
set -euo pipefail
DIR="$(cd "${1:?usage: load.sh <dir with nav_fix.csv and airway_fix.csv> [psql args]}" && pwd)"
shift
[ $# -eq 0 ] && set -- "${DATABASE_URL:?set DATABASE_URL or pass psql connection args}"
for f in nav_fix.csv airway_fix.csv; do [ -f "$DIR/$f" ] || { echo "missing $DIR/$f" >&2; exit 1; }; done

psql "$@" -v ON_ERROR_STOP=1 -q -X <<SQL
begin;
create temp table nf (ident text, kind text, icao_ident text, name text, lat float8, lon float8,
                      state_code text, country_code text, cycle date);
create temp table af (airway_id text, seq integer, ident text, lat float8, lon float8);
\copy nf from '$DIR/nav_fix.csv' with (format csv, header true)
\copy af from '$DIR/airway_fix.csv' with (format csv, header true)

delete from public.nav_fix where source = 'nasr';
insert into public.nav_fix (ident, kind, icao_ident, name, geog, state_code, country_code, source, cycle)
select ident, kind, nullif(icao_ident, ''), nullif(name, ''),
       extensions.st_setsrid(extensions.st_makepoint(lon, lat), 4326)::extensions.geography,
       nullif(state_code, ''), nullif(country_code, ''), 'nasr', cycle
from nf;

truncate public.airway_fix;
insert into public.airway_fix (airway_id, seq, ident, geog)
select airway_id, seq, ident, extensions.st_setsrid(extensions.st_makepoint(lon, lat), 4326)::extensions.geography
from af;
commit;
select 'loaded ' || (select count(*) from public.nav_fix where source = 'nasr') || ' fixes/navaids/airports and '
       || (select count(distinct airway_id) from public.airway_fix) || ' airways' as result;
SQL
