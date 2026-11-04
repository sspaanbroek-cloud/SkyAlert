#!/usr/bin/env bash
# Run migrations + seed + pgTAP tests on a throwaway local Postgres cluster.
# Needs: postgres 16+ server binaries, PostGIS, pgTAP. For the real stack use
# `supabase start && supabase test db` instead.
# If Deno is installed (or DENO points at it) a TS->SQL contract test runs too.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PGBIN="${PGBIN:-$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)}"
WORK="$(mktemp -d)"; PORT="${PORT:-54329}"
trap '"$PGBIN/pg_ctl" -D "$WORK/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
RUN_AS=(); [ "$(id -u)" = 0 ] && { chown -R postgres "$WORK"; RUN_AS=(runuser -u postgres --); }
"${RUN_AS[@]}" "$PGBIN/initdb" -D "$WORK/data" -U postgres -A trust >/dev/null
"${RUN_AS[@]}" "$PGBIN/pg_ctl" -D "$WORK/data" -o "-p $PORT -k $WORK -c listen_addresses=''" -w start >/dev/null
PSQL=(psql -h "$WORK" -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 -q -X)
"${PSQL[@]}" -f "$ROOT/db-test/auth_stub.sql"
for f in "$ROOT"/supabase/migrations/*.sql; do echo "migrate: $(basename "$f")"; "${PSQL[@]}" -f "$f"; done
"${PSQL[@]}" -f "$ROOT/supabase/seed.sql"
"${PSQL[@]}" -c 'create extension if not exists pgtap with schema extensions'
for t in "$ROOT"/supabase/tests/*.sql; do echo "test: $(basename "$t")"; "${PSQL[@]}" -t -A -f "$t" | grep -v '^$'; done
DENO="${DENO:-$(command -v deno || true)}"
if [ -n "$DENO" ]; then
  echo "test: contract (TS parser -> ingest_metars)"
  PAYLOAD="$(DENO_NO_UPDATE_CHECK=1 "$DENO" run --quiet --no-prompt "$ROOT/db-test/contract_payload.ts")"
  "${PSQL[@]}" -t -A -v payload="$PAYLOAD" -f "$ROOT/db-test/contract.sql" | grep -v '^$'
else
  echo "skip: contract test (no deno)"
fi
