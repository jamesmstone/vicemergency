#!/usr/bin/env bash
# Rebuild fixture.bundle: the last N commits that touched events.json, replayed
# into a fresh repo. Real snapshots rather than synthesised ones, so the check
# meets the feed's actual shape; git deltas 200 of them down to under a
# megabyte, small enough to live in the tree and keep the check offline.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=${1:-$(cd "$here/../.." && pwd)}
out=${2:-$here/fixture.bundle}
n=${3:-200}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git -C "$repo" log --format='%H %ct' --diff-filter=AM --reverse -- events.json \
  | tail -n "$n" > "$work/commits.txt"

git init -q -b main "$work/repo"
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@invalid
while read -r c ts; do
  git -C "$repo" show "$c:events.json" > "$work/repo/events.json"
  git -C "$work/repo" add events.json
  GIT_AUTHOR_DATE="$ts +0000" GIT_COMMITTER_DATE="$ts +0000" \
    git -C "$work/repo" commit -q -m "Latest data: $ts"
done < "$work/commits.txt"

git -C "$work/repo" gc -q --aggressive --prune=now
# HEAD too, or a clone of the bundle has no branch to check out.
git -C "$work/repo" bundle create -q "$out" HEAD main
echo "$out: $(wc -c < "$out") bytes, $(wc -l < "$work/commits.txt") snapshots"
