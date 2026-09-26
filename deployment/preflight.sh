#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
run_id=${1:?Run id required}
[[ "$run_id" =~ ^[0-9]+$ ]]
root=$HOME/site-update-backups
backup=$root/$run_id
compose_dir=$HOME/mx-space/core
incoming=/tmp/private-update-preflight-$run_id
mkdir -p "$root"
exec 9>"$root/operation.lock"
flock -w 120 9
test ! -e "$backup"
mkdir -m 700 "$backup"
# Freeze the accepted baseline, before any merge or production installation.
test "$(docker inspect mx-server --format '{{.Image}}')" = "$(docker image inspect jason-core-verification:36262517016 --format '{{.Id}}')"
docker inspect mx-server > "$backup/core-before.json"
docker inspect mongo redis --format '{{.Name}} {{.Id}} {{.State.StartedAt}}' > "$backup/databases-before.txt"
pm2 jlist > "$backup/pm2-before.json"
readlink -f "$HOME/shiro/server.js" > "$backup/shiro-entry-before"
sha256sum "$compose_dir/docker-compose.yml" "$HOME/shiro/.env" "$HOME/shiro/ecosystem.config.js" "$(cat "$backup/shiro-entry-before")" > "$backup/config-before.sha256"
cp -p "$compose_dir/docker-compose.yml" "$backup/docker-compose.original.yml"
curl -fsS --max-time 20 http://127.0.0.1:2333/api/v2 > "$backup/core-health-before.json"
curl -fsS --max-time 20 http://127.0.0.1:2333/proxy/qaqdmin > "$backup/admin-before.html"
docker exec mx-server sh -c 'cd /app && find admin -type f -print0 | sort -z | xargs -0 sha256sum' > "$backup/admin-files-before.sha256"
# Check space before creating the snapshot and backup archives.
image_bytes=$(docker image inspect "$(docker inspect mx-server --format '{{.Image}}')" --format '{{.Size}}')
data_bytes=$(du -sb "$compose_dir/data/mx-space" | cut -f1)
python3 - "$backup" "$image_bytes" "$data_bytes" <<'PY'
import os,sys
s=os.statvfs(sys.argv[1]);assert s.f_bavail*s.f_frsize > 2*int(sys.argv[2])+2*int(sys.argv[3])+2*1024**3,'Insufficient free space for verified rollback'
PY
mkdir "$backup/record-before"
if test -d "$compose_dir/data/mx-space/site-deployment"; then
  echo yes > "$backup/record-dir-existed"
  for name in github-token current.json; do
    if test -f "$compose_dir/data/mx-space/site-deployment/$name"; then cp -p "$compose_dir/data/mx-space/site-deployment/$name" "$backup/record-before/$name"; fi
  done
else echo no > "$backup/record-dir-existed"; fi
# Commit captures the current container layer, including any button-installed Admin.
snapshot=jason-core-private-update-backup:$run_id
docker commit mx-server "$snapshot" > "$backup/snapshot-image-id"
printf '%s\n' "$snapshot" > "$backup/snapshot-image"
docker save "$snapshot" | gzip -1 > "$backup/core-snapshot.tar.gz"
gzip -t "$backup/core-snapshot.tar.gz"
# Live access logs may change while archiving; tar status 1 does not invalidate the archive.
tar -czf "$backup/data-before.tar.gz" -C "$compose_dir/data" mx-space 2> "$backup/data-backup.log" || test "$?" = 1
tar -tzf "$backup/data-before.tar.gz" >/dev/null
docker exec -i mongo mongosh --quiet < "$incoming/content-fingerprint.js" | sha256sum > "$backup/content-before.sha256"
docker exec mongo mongodump --archive --gzip > "$backup/mongo-before.archive.gz" 2> "$backup/mongodump.log"
test -s "$backup/mongo-before.archive.gz"
gzip -t "$backup/mongo-before.archive.gz"
# Restore into a disposable, network-isolated MongoDB, never the live database.
check=mongo-private-update-restore-$run_id
cleanup() { docker rm -f "$check" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker run -d --rm --network none --name "$check" "$(docker inspect mongo --format '{{.Image}}')" --bind_ip 127.0.0.1 >/dev/null
ready=0
for attempt in $(seq 1 30); do
  if docker exec "$check" mongosh --quiet --eval 'quit(db.adminCommand({ping:1}).ok ? 0 : 1)' >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done
test "$ready" = 1
docker exec -i "$check" mongorestore --archive --gzip < "$backup/mongo-before.archive.gz" > "$backup/mongorestore-check.log" 2>&1
docker exec -i "$check" mongosh --quiet < "$incoming/content-fingerprint.js" | sha256sum > "$backup/content-restored.sha256"
cmp "$backup/content-before.sha256" "$backup/content-restored.sha256"
cleanup
trap - EXIT
cp "$incoming/rollback.sh" "$backup/rollback.sh"
cp "$incoming/content-fingerprint.js" "$backup/content-fingerprint.js"
chmod 700 "$backup/rollback.sh"
python3 - "$backup" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);before=json.loads((p/'core-before.json').read_text())[0]
env=dict(x.split('=',1) for x in before['Config'].get('Env',[]));env['MX_ADMIN_DEPLOY_MANAGED']=env.get('MX_ADMIN_DEPLOY_MANAGED')
(p/'compose.rollback.yml').write_text(json.dumps({'services':{'app':{'image':(p/'snapshot-image').read_text().strip(),'environment':env}}}))
PY
# Confirm Docker can start the snapshot independently and read exactly the old Admin files.
docker run --rm --network none --entrypoint sh "$snapshot" -c 'cd /app && node --check main.mjs && find admin -type f -print0 | sort -z | xargs -0 sha256sum' > "$backup/admin-files-snapshot.sha256"
cmp "$backup/admin-files-before.sha256" "$backup/admin-files-snapshot.sha256"
sha256sum -c "$backup/config-before.sha256" >/dev/null
docker inspect mongo redis --format '{{.Name}} {{.Id}} {{.State.StartedAt}}' > "$backup/databases-after.txt"
cmp "$backup/databases-before.txt" "$backup/databases-after.txt"
printf 'verified\n' > "$backup/status"
echo "PASS: backup $run_id includes exact running application snapshot, configuration, data files and a successfully restored isolated MongoDB backup"
