#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

run_id=${1:?GitHub run id required}
[[ "$run_id" =~ ^[0-9]+$ ]] || exit 2
incoming=/tmp/site-verification-$run_id
state=$HOME/site-verification/$run_id
compose_dir=$HOME/mx-space/core
shiro_dir=$HOME/shiro
expected_image=sha256:034d0e00f775abcf1fc60927638178fce6c158a88ca0f4861eadd71e4171d616

mkdir -p "$HOME/site-verification"
exec 9>"$HOME/site-verification/deploy.lock"
flock -n 9 || { echo 'Another deployment is active'; exit 1; }
test ! -e "$state" || { echo 'This run already has deployment state; inspect it before retrying'; exit 1; }
mkdir -m 700 "$state"
cd "$incoming"
sha256sum -c SHA256SUMS
cp source-manifest.json SHA256SUMS "$state/"
test "$(docker inspect mx-server --format '{{.Image}}')" = "$expected_image"
test "$(docker image inspect "$expected_image" --format '{{.Architecture}}')" = amd64
test -f "$compose_dir/docker-compose.yml"
test -f "$shiro_dir/.env"
test -f "$shiro_dir/ecosystem.config.js"
test -f "$shiro_dir/server.js"
old_shiro=$(readlink -f "$shiro_dir/server.js")
printf '%s\n' "$old_shiro" > "$state/old-shiro-entry"
docker inspect mx-server > "$state/core-before.json"
docker image inspect "$expected_image" > "$state/image-before.json"
docker inspect mongo redis --format '{{.Name}} {{.Id}} {{.State.StartedAt}}' > "$state/databases-before.txt"
sha256sum "$compose_dir/docker-compose.yml" "$shiro_dir/.env" "$shiro_dir/ecosystem.config.js" > "$state/config-before.sha256"
docker tag "$expected_image" "jason-core-rollback:$run_id"

# Back up the running MongoDB to this private server directory. Never upload it.
docker exec mongo mongodump --archive --gzip > "$state/mongo-before.archive.gz" 2>"$state/mongodump.log"
test -s "$state/mongo-before.archive.gz"
docker exec -i mongo mongosh --quiet < content-fingerprint.js | sha256sum > "$state/content-before.sha256"

mkdir -p "$state/image/core" "$state/image/admin" "$state/shiroi"
tar -xzf core.tar.gz -C "$state/image/core"
tar -xzf admin.tar.gz -C "$state/image/admin"
tar -xzf shiroi.tar.gz -C "$state/shiroi"
test -f "$state/image/core/main.mjs"
test -f "$state/image/admin/index.html"
test -f "$state/shiroi/standalone/apps/web/server.js"
grep -q "window.version = '6.1.5'" "$state/image/admin/index.html"
node --check "$state/shiroi/standalone/apps/web/server.js"

cat > "$state/image/Dockerfile" <<EOF
FROM jason-core-rollback:$run_id
COPY core/ /app/
COPY admin/ /app/admin/
EOF
docker build --network none -t "jason-core-verification:$run_id" "$state/image"
docker run --rm --network none --entrypoint node "jason-core-verification:$run_id" --check /app/main.mjs

overlay=$state/compose.verify.yml
cat > "$overlay" <<EOF
services:
  app:
    image: jason-core-verification:$run_id
EOF
cat > "$state/compose.rollback.yml" <<EOF
services:
  app:
    image: jason-core-rollback:$run_id
EOF
docker compose --project-directory "$compose_dir" -f "$compose_dir/docker-compose.yml" -f "$overlay" config --format json > "$state/planned-compose.json"

# Reject a stale on-disk configuration rather than silently changing runtime settings.
python3 - "$state" <<'PY'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1])
old=json.loads((p/'core-before.json').read_text())[0]
image=json.loads((p/'image-before.json').read_text())[0]
plan=json.loads((p/'planned-compose.json').read_text())['services']['app']
env=lambda values: dict(item.split('=',1) for item in values or [])
expected=env(image['Config'].get('Env'))
expected.update({k:str(v) for k,v in plan.get('environment',{}).items() if v is not None})
if expected != env(old['Config'].get('Env')):
    raise SystemExit('ABORT: disk Compose environment differs from running Core; values were not printed')
PY

core_changed=0
shiro_changed=0
rollback() {
  code=$?
  trap - ERR
  echo 'Verification failed; restoring previous application artifacts, retaining all database data'
  if ((shiro_changed)); then
    ln -sfn "$old_shiro" "$shiro_dir/server.js"
    (cd "$shiro_dir" && pm2 reload ecosystem.config.js --update-env && pm2 save) || true
  fi
  if ((core_changed)); then
    docker compose --project-directory "$compose_dir" -f "$compose_dir/docker-compose.yml" -f "$state/compose.rollback.yml" up -d --no-deps --pull never app || true
  fi
  printf 'failed; rollback attempted\n' > "$state/result.txt"
  exit "$code"
}
trap rollback ERR

core_changed=1
docker compose --project-directory "$compose_dir" -f "$compose_dir/docker-compose.yml" -f "$overlay" up -d --no-deps --pull never app
core_ready=0
for attempt in $(seq 1 60); do
  if curl -fsS --max-time 5 http://127.0.0.1:2333/api/v2 > "$state/core-health.json" &&
      python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["version"] == "10.1.9"' "$state/core-health.json"; then
    core_ready=1
    break
  fi
  sleep 2
done
test "$core_ready" = 1
curl -fsS --max-time 20 http://127.0.0.1:2333/proxy/qaqdmin > "$state/admin-after.html"
grep -q "window.version = '6.1.5'" "$state/admin-after.html"

entry=$state/shiroi/standalone/apps/web
rm -f "$entry/.env"
ln -s "$shiro_dir/.env" "$entry/.env"
mkdir -p "$shiro_dir/.cache" "$entry/.next"
rm -rf "$entry/.next/cache"
ln -s "$shiro_dir/.cache" "$entry/.next/cache"
shiro_changed=1
ln -sfn "$entry/server.js" "$shiro_dir/server.js"
(cd "$shiro_dir" && pm2 reload ecosystem.config.js --update-env && pm2 save)
shiro_ready=0
for attempt in $(seq 1 60); do
  if curl -fsS --max-time 5 http://127.0.0.1:2323/api/healthz > "$state/shiro-health.json"; then
    shiro_ready=1
    break
  fi
  sleep 2
done
test "$shiro_ready" = 1
curl -fLsS --max-time 60 http://127.0.0.1:2323/ > "$state/home-after.html"
test -s "$state/home-after.html"
sha256sum -c "$state/config-before.sha256"
docker inspect mongo redis --format '{{.Name}} {{.Id}} {{.State.StartedAt}}' > "$state/databases-after.txt"
cmp "$state/databases-before.txt" "$state/databases-after.txt"
docker exec -i mongo mongosh --quiet < "$incoming/content-fingerprint.js" | sha256sum > "$state/content-after.sha256"
cmp "$state/content-before.sha256" "$state/content-after.sha256"
docker inspect mx-server > "$state/core-after.json"
python3 - "$state" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); before=json.loads((p/'core-before.json').read_text())[0]; after=json.loads((p/'core-after.json').read_text())[0]
for key in ['Env','Entrypoint','Cmd','User','WorkingDir']:
    assert before['Config'].get(key)==after['Config'].get(key), 'Runtime setting changed: '+key
mounts=lambda obj: sorted((m['Source'],m['Destination'],m['RW']) for m in obj['Mounts'])
assert mounts(before)==mounts(after), 'Mounts changed'
assert before['HostConfig']['PortBindings']==after['HostConfig']['PortBindings'], 'Ports changed'
PY
trap - ERR
printf 'success\n' > "$state/result.txt"
echo "SUCCESS: Core 10.1.9, Admin 6.1.5, Shiroi 6.6.7 rebuilt and deployed from original private-source commits"
echo 'PASS: runtime configuration, data mounts, Mongo/Redis processes and content fingerprint unchanged'
echo "Rollback artifacts and database backup retained under ~/site-verification/$run_id"
echo "Core Compose overlay: ~/site-verification/$run_id/compose.verify.yml"
