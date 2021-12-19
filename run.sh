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
    docker run \
    -v"$(pwd):/wd" \
    -w /wd \
    datasetteproject/datasette \
    datasette -token $VERCEL_TOKEN --load-extension=spatialite publish vercel "$db" --project=vicemergency
}

run() {
  local db="events.db"
  makeDB "$db"
  publishDB "$db"
  commitDB "$db"


}

run "$@"
