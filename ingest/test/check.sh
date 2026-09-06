#!/usr/bin/env bash
# End-to-end: replay the bundled slice of real history through extract.sh and
# build-db.sql, then assert the derived tables hang together. No network and no
# access to the surrounding checkout's history, so it also runs in a nix sandbox.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ingest=${VICEMERGENCY_INGEST_DIR:-$here/..}
extract=${VICEMERGENCY_EXTRACT:-$ingest/extract.sh}
bundle=${1:-$here/fixture.bundle}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME=$work

git clone -q "$bundle" "$work/repo"
"$extract" "$work/repo" "$work/shards" 50

shards="$work/shards/*.parquet"
duckdb "$work/events.duckdb" -c "SET VARIABLE shards='$shards'" -f "$ingest/build-db.sql"
duckdb "$work/events.duckdb" -c "SET VARIABLE shards='$shards'" -f "$here/assert.sql"
