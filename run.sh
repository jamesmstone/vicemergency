run() {
  local db="events.db"
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

run "$@"
