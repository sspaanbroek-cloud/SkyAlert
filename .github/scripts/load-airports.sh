#!/usr/bin/env bash
# Load (or refresh) the airport directory from OurAirports (public domain).
#   load-airports.sh "<postgres connection string>" [airports.csv]
# Without a CSV argument it downloads the current file.
set -euo pipefail
DB="${1:?usage: load-airports.sh <db url> [airports.csv]}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SRC="${2:-}"
if [ -z "$SRC" ]; then
  SRC="$WORK/airports.csv"
  curl -fsSL --retry 3 -o "$SRC" https://davidmegginson.github.io/ourairports-data/airports.csv \
    || curl -fsSL --retry 3 -o "$SRC" https://raw.githubusercontent.com/davidmegginson/ourairports-data/main/airports.csv
fi

# Keep airports only; normalise empty codes to blanks; output our columns.
python3 -I - "$SRC" "$WORK/clean.csv" <<'PY'
import csv, sys
src, out = sys.argv[1], sys.argv[2]
keep = {'small_airport', 'medium_airport', 'large_airport'}
need = ['ident', 'type', 'name', 'latitude_deg', 'longitude_deg', 'elevation_ft', 'iso_country',
        'municipality', 'iata_code', 'gps_code', 'local_code']
with open(src, encoding='utf-8', newline='') as f, open(out, 'w', encoding='utf-8', newline='') as o:
    r = csv.DictReader(f)
    missing = [c for c in need if c not in (r.fieldnames or [])]
    if missing:
        sys.exit(f"airports.csv is missing columns {missing}; found {r.fieldnames}")
    w = csv.writer(o)
    n = 0
    for row in r:
        if row['type'] not in keep:
            continue
        try:
            lat, lon = float(row['latitude_deg']), float(row['longitude_deg'])
        except ValueError:
            continue
        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            continue
        up = lambda k: (row.get(k) or '').strip().upper()
        elev = (row['elevation_ft'] or '').strip()
        w.writerow([up('ident'), up('icao_code'), up('iata_code'), up('gps_code'), up('local_code'),
                    row['name'].strip(), row['municipality'].strip(), up('iso_country'), row['type'],
                    lat, lon, elev if elev.lstrip('-').isdigit() else ''])
        n += 1
print(f"airports kept: {n}", file=sys.stderr)
PY

psql "$DB" -X -q -v ON_ERROR_STOP=1 <<SQL
begin;
create temp table ad (ident text, icao_code text, iata_code text, gps_code text, local_code text, name text,
                      municipality text, iso_country text, type text, lat float8, lon float8, elevation_ft integer);
\copy ad from '$WORK/clean.csv' with (format csv)
delete from public.airport_directory;
insert into public.airport_directory (ident, icao_code, iata_code, gps_code, local_code, name, municipality,
                                      iso_country, type, geog, elevation_ft)
select distinct on (ident) ident, nullif(icao_code, ''), nullif(iata_code, ''), nullif(gps_code, ''), nullif(local_code, ''),
       name, nullif(municipality, ''), nullif(iso_country, ''), type,
       extensions.st_setsrid(extensions.st_makepoint(lon, lat), 4326)::extensions.geography, elevation_ft
from ad where ident <> ''
order by ident;
commit;
select 'airport directory: ' || count(*) || ' airports' from public.airport_directory;
SQL
