#!/bin/bash
set -e # Exit with nonzero exit code if anything fails
#set -x # debug: print commands before they are executed
set -o pipefail
set -o errexit

dockerBuilds(){
    local dockerGitHistory="git-history"
    local dockerSQLUtil="sqlite-utils"

    docker build --tag "$dockerGitHistory" --pull --file git-history.Dockerfile . &
    docker build --tag "$dockerSQLUtil" --pull --file sqlite-utils.Dockerfile . &
    wait
}

makeDB() {
  local db="$1"

  local dockerGitHistory="git-history"
  local dockerSQLUtil="sqlite-utils"

#  rm "$db" || true

  docker run \
    -u"$(id -u):$(id -g)" \
    -v"$(pwd):/wd" \
    -w /wd \
    "$dockerGitHistory" file "$db" events.json --convert '
  def flatten_dict(d, parent_key="", sep="_"):
        items = []
        for k, v in d.items():
            new_key = f"{parent_key}{sep}{k}" if parent_key else k
            if isinstance(v, dict):
                items.extend(flatten_dict(v, new_key, sep=sep).items())
            else:
                items.append((new_key, v))
        return dict(items)
  try:
      data = json.loads(content)
      for event in data["features"]:
          flattened_event = flatten_dict(event)
          flattened_event["id"] = flattened_event["properties_id"]
          yield flattened_event
  except json.JSONDecodeError as e:
      print(f"JSON decode error: {e}")
  except KeyError as e:
      print(f"Key error: {e}")
  except Exception as e:
      print(f"An error occurred: {e}")
' --id id

  docker run \
    -u"$(id -u):$(id -g)" \
    -v"$(pwd):/wd" \
    -w /wd \
    "$dockerSQLUtil" extract "$db" item properties_sourceOrg properties_sourceFeed

}

getDBs() {
  local db="$1"
  git fetch origin "$dbBranch"
  git ls-tree -r --name-only "origin/$dbBranch" |
    sort |
    xargs -I % -n1 git show "origin/$dbBranch:%" |
    tar -zxf "$db" || return 0
}

publishDB() {
  local dockerDatasette="datasette"
  docker build --tag "$dockerDatasette" --pull --file datasette.Dockerfile .
  docker run \
      -v"$(pwd):/wd" \
      -w /wd \
      "$dockerDatasette" \
    publish vercel "$db" --token $VERCEL_TOKEN --project=vicemergency
}


commitData() {

  mv "$db" "$tempDB"

  git config user.name "Automated"
  git config user.email "actions@users.noreply.github.com"
  git add -A
  timestamp=$(date -u)
  git commit -m "Latest data: ${timestamp}" || true
  git push

  git branch -D "$dbBranch" || true
  git checkout --orphan "$dbBranch"
  rm -rf *
  mkdir -p "$(dirname $db)"
  mv "$tempDB" "$db"
  tar -cvzf "$db.tar.gz" "$db"
  split -b 99M "$db.tar.gz" "$db.tar.gz.part"
  git add "$db.tar.gz.part*"
  git commit "$db.tar.gz.part*" -m "push db parts"
  git add "$db"
  git commit "$db" -m "push db"
  git push origin "$dbBranch" -f
}


run() {
  local db="events.db"
  dockerBuilds &
  { getDBs "$db" || true
  } &
  wait

  makeDB "$db"
#  publishDB "$db"
  commitDB "$db"

}

run "$@"
