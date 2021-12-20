#!/bin/bash
set -e # Exit with nonzero exit code if anything fails
#set -x # debug: print commands before they are executed
set -o pipefail
set -o errexit

makeDB() {
  local db="$1"

  local dockerGitHistory="git-history"
  local dockerSQLUtil="sqlite-utils"

  rm "$db" || true

  docker build --tag "$dockerGitHistory" --pull --file git-history.Dockerfile .
  docker build --tag "$dockerSQLUtil" --pull --file sqlite-utils.Dockerfile .

  docker run \
    -u"$(id -u):$(id -g)" \
    -v"$(pwd):/wd" \
    -w /wd \
    "$dockerGitHistory" file "$db" events.json --convert 'data = json.loads(content)
for event in data["features"]:
    yield event["properties"]
' --id id

  docker run \
    -u"$(id -u):$(id -g)" \
    -v"$(pwd):/wd" \
    -w /wd \
    "$dockerSQLUtil" extract "$db" item sourceOrg sourceFeed

}

commitDB() {
  local dbBranch="db"
  local db="$1"
  local tempDB="$(mktemp)"
  git branch -D "$dbBranch"
  git checkout --orphan "$dbBranch"
  mv "$db" "$tempDB"
  rm -rf *
  mv "$tempDB" "$db"
  git add "$db"
  git commit "$db" -m "push db"
  git push origin "$dbBranch" -f
}


publishDB() {
  local dockerDatasette="datasette"
  docker build --tag "$dockerDatasette" --pull --file datasette.Dockerfile .
    docker run \
    -v"$(pwd):/wd" \
    -w /wd \
    "$dockerDatasette" \
    publish vercel "$db" --token $VERCEL_TOKEN --load-extension=spatialite --project=vicemergency
}

run() {
  local db="events.db"
  makeDB "$db"
  publishDB "$db"
  commitDB "$db"


}

run "$@"
