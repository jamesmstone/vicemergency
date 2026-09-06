#!/usr/bin/env bash
# Walk every commit that touched events.json and emit one parquet shard per
# chunk of commits: a row per feature per snapshot, tagged with the commit time.
set -euo pipefail

repo=${1:?usage: extract.sh <repo> <outdir> [chunk]}
outdir=${2:?usage: extract.sh <repo> <outdir> [chunk]}
chunk=${3:-1000}

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# extract.jq and schema.txt sit beside this script in a checkout, but move to
# their own store path when it is packaged.
ingest=${VICEMERGENCY_INGEST_DIR:-$here}
# read_ndjson infers per shard, so an all-null column in one chunk would land as
# a different type than the same column elsewhere and refuse to union. Pin it.
columns=$(tr -d '\n' < "$ingest/schema.txt")

mkdir -p "$outdir"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git -C "$repo" log --format='%H %ct' --diff-filter=AM --reverse -- events.json \
  > "$work/commits.txt"
split -l "$chunk" -d -a 4 "$work/commits.txt" "$work/part-"

export repo ingest outdir columns

shard() {
  local part=$1
  local name out
  name=$(basename "$part")
  out="$outdir/$name.parquet"
  [ -f "$out" ] && return 0
  while read -r c ts; do
    git -C "$repo" show "$c:events.json" \
      | jq -c --arg ts "$ts" --arg commit "$c" -f "$ingest/extract.jq"
  done < "$part" \
    | duckdb -c "COPY (SELECT * FROM read_ndjson('/dev/stdin', columns := {$columns}))
                 TO '$out.tmp' (FORMAT parquet, COMPRESSION zstd)"
  mv "$out.tmp" "$out"
}
export -f shard

find "$work" -name 'part-*' -print0 \
  | xargs -0 -P "$(nproc)" -I{} bash -c 'shard "$@"' _ {}

echo "shards: $(find "$outdir" -name '*.parquet' | wc -l)"
