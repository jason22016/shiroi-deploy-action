#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
backup=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
compose_dir=$HOME/mx-space/core
record_dir=$compose_dir/data/mx-space/site-deployment
if test "${MX_UPDATE_LOCK_HELD:-0}" != 1; then
  exec 9>"$HOME/site-update-backups/operation.lock"
  flock -w 120 9
fi
snapshot=$(cat "$backup/snapshot-image")
if ! docker image inspect "$snapshot" >/dev/null 2>&1; then
  gzip -dc "$backup/core-snapshot.tar.gz" | docker load >/dev/null
fi
# Only the application service is recreated; MongoDB, Redis and Shiroi are untouched.
sha256sum -c "$backup/config-before.sha256" >/dev/null
docker compose --project-directory "$compose_dir" -f "$compose_dir/docker-compose.yml" -f "$backup/compose.rollback.yml" up -d --no-deps --pull never app
ready=0
for attempt in $(seq 1 60); do
  if curl -fsS --max-time 5 http://127.0.0.1:2333/api/v2 > "$backup/rollback-health.json" &&
      python3 - "$backup" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);assert json.loads((p/'rollback-health.json').read_text())['version']==json.loads((p/'core-health-before.json').read_text())['version']
PY
  then ready=1; break; fi
  sleep 2
done
test "$ready" = 1
curl -fsS --max-time 20 http://127.0.0.1:2333/proxy/qaqdmin > "$backup/rollback-admin.html"
python3 - "$backup" <<'PY'
import pathlib,re,sys
p=pathlib.Path(sys.argv[1]);version=lambda f:re.search(r"window.version\s*=\s*'([^']+)'",(p/f).read_text()).group(1)
assert version('rollback-admin.html')==version('admin-before.html')
PY
# Restore only the two files introduced by private updates, preserving new content.
for name in github-token current.json; do
  if test -f "$backup/record-before/$name"; then
    mkdir -p "$record_dir"
    cp -p "$backup/record-before/$name" "$record_dir/$name"
  else
    rm -f "$record_dir/$name"
  fi
done
if test "$(cat "$backup/record-dir-existed")" = no; then rmdir "$record_dir" 2>/dev/null || true; fi
docker inspect mx-server > "$backup/core-rollback.json"
python3 - "$backup" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);before=json.loads((p/'core-before.json').read_text())[0];after=json.loads((p/'core-rollback.json').read_text())[0]
env=lambda o:dict(x.split('=',1) for x in o['Config'].get('Env',[]))
assert env(before)==env(after),'Rollback environment differs'
for key in ['Entrypoint','Cmd','User','WorkingDir']:assert before['Config'].get(key)==after['Config'].get(key),key
mounts=lambda o:sorted((m['Source'],m['Destination'],m['RW']) for m in o['Mounts'])
assert mounts(before)==mounts(after),'Rollback mounts differ'
assert before['HostConfig']['PortBindings']==after['HostConfig']['PortBindings'],'Rollback ports differ'
PY
# The snapshot contains the exact old writable-layer Admin files.
docker exec mx-server sh -c 'cd /app && find admin -type f -print0 | sort -z | xargs -0 sha256sum' > "$backup/admin-files-restored.sha256"
cmp "$backup/admin-files-before.sha256" "$backup/admin-files-restored.sha256"
printf 'success\n' > "$backup/rollback-result.txt"
echo 'PASS: original Core/Admin application files, versions, environment, mounts and ports restored; database data retained'
