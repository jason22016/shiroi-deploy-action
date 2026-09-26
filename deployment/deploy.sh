#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
run_id=${1:?Run id required}
backup_id=${2:?Verified backup run id required}
[[ "$run_id" =~ ^[0-9]+$ && "$backup_id" =~ ^[0-9]+$ ]]
incoming=/tmp/site-deployment-$run_id
state=$HOME/site-deployments/$run_id
backup=$HOME/site-update-backups/$backup_id
compose_dir=$HOME/mx-space/core
record_dir=$compose_dir/data/mx-space/site-deployment
test "$(cat "$backup/status")" = verified
mkdir -p "$HOME/site-deployments"
exec 9>"$HOME/site-update-backups/operation.lock"
flock -w 120 9
test ! -e "$state"
mkdir -m 700 "$state"
cd "$incoming"
sha256sum -c SHA256SUMS
cp source-manifest.json release-sha SHA256SUMS "$state/"
printf '%s\n' "$backup" > "$state/rollback-backup"
core_version=$(python3 -c 'import json;print(json.load(open("source-manifest.json"))["core"]["version"])')
admin_version=$(python3 -c 'import json;print(json.load(open("source-manifest.json"))["admin"]["version"])')
# The accepted original container must still be running; never overwrite intervening updates.
docker inspect mx-server > "$state/core-before.json"
python3 - "$backup" "$state" <<'PY'
import json,pathlib,sys
b=pathlib.Path(sys.argv[1]);s=pathlib.Path(sys.argv[2]);old=json.loads((b/'core-before.json').read_text())[0];now=json.loads((s/'core-before.json').read_text())[0]
assert old['Id']==now['Id'] and old['Image']==now['Image'],'Production changed after backup; prepare a fresh backup'
assert old['Config']==now['Config'],'Runtime configuration changed after backup'
assert json.loads((s/'source-manifest.json').read_text())['shiroi']['commit']=='6047be878d039a93d750037ea5b46c73e97b32e5'
PY
sha256sum -c "$backup/config-before.sha256" >/dev/null
docker exec mx-server sh -c 'cd /app && find admin -type f -print0 | sort -z | xargs -0 sha256sum' > "$state/admin-files-before.sha256"
cmp "$backup/admin-files-before.sha256" "$state/admin-files-before.sha256"
docker exec -i mongo mongosh --quiet < content-fingerprint.js | sha256sum > "$state/content-before.sha256"
cmp "$backup/content-before.sha256" "$state/content-before.sha256"
pm2 jlist > "$state/pm2-before.json"
# Fail before touching production if the private release or its asset cannot be read.
python3 - "$incoming/github-token" "$admin_version" <<'PY'
import json,pathlib,sys,urllib.request,urllib.error
req=urllib.request.Request('https://api.github.com/repos/jason22016/mx-admin/releases/tags/v'+sys.argv[2],headers={'Authorization':'Bearer '+pathlib.Path(sys.argv[1]).read_text().strip(),'Accept':'application/vnd.github+json','User-Agent':'Private-update-preflight'})
try:
 with urllib.request.urlopen(req,timeout=30) as r:data=json.load(r)
 assert not data.get('draft') and not data.get('prerelease')
 assert any(a['name']=='release.zip' and a.get('state')=='uploaded' for a in data['assets'])
except Exception:raise SystemExit('Private Admin release access check failed; no installation performed')
print('PASS: server credential reads the private Admin release and install asset metadata')
PY
mkdir -p "$state/image/core" "$state/image/admin"
tar -xzf core.tar.gz -C "$state/image/core"
tar -xzf admin.tar.gz -C "$state/image/admin"
test -f "$state/image/core/main.mjs"
grep -Fq "window.version = '$admin_version'" "$state/image/admin/index.html"
test "$(cat "$state/image/admin/version")" = "$admin_version"
cat > "$state/image/Dockerfile" <<'DOCKER'
FROM innei/mx-server@sha256:fa34592f79c3fd604e5b8474d4e5293438366ae8195484d9608cf3fe92e3c4a9
COPY core/ /app/
COPY admin/ /app/admin/
DOCKER
docker build --network none -t "jason-core-private-updates:$run_id" "$state/image"
docker run --rm --network none --entrypoint node "jason-core-private-updates:$run_id" --check /app/main.mjs
cat > "$state/compose.install.yml" <<YAML
services:
  app:
    image: jason-core-private-updates:$run_id
    environment:
      MX_ADMIN_DEPLOY_MANAGED: 'false'
YAML
docker compose --project-directory "$compose_dir" -f "$compose_dir/docker-compose.yml" -f "$state/compose.install.yml" config --format json > "$state/planned-compose.json"
python3 - "$state" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);before=json.loads((p/'core-before.json').read_text())[0];plan=json.loads((p/'planned-compose.json').read_text())['services']['app']
old=dict(x.split('=',1) for x in before['Config'].get('Env',[]));old['MX_ADMIN_DEPLOY_MANAGED']='false'
# Runtime equality is also checked after startup; here reject changed Compose values.
for k,v in plan.get('environment',{}).items():assert old.get(k)==str(v), 'Compose environment differs: '+k
PY
docker compose --project-directory "$compose_dir" -f "$compose_dir/docker-compose.yml" -f "$backup/compose.rollback.yml" config --format json > "$state/planned-rollback.json"
python3 - "$backup" "$state" <<'PYCHECK'
import json,pathlib,sys
b=pathlib.Path(sys.argv[1]);s=pathlib.Path(sys.argv[2]);before=json.loads((b/'core-before.json').read_text())[0]
old=dict(x.split('=',1) for x in before['Config'].get('Env',[]));plan=json.loads((s/'planned-rollback.json').read_text())['services']['app']['environment']
assert old=={k:str(v) for k,v in plan.items() if v is not None},'Rollback configuration cannot reproduce original environment'
PYCHECK
changed=0
rollback_on_error() {
  code=$?
  trap - ERR
  if ((changed)); then
    if MX_UPDATE_LOCK_HELD=1 bash "$backup/rollback.sh"; then echo 'ROLLBACK VERIFIED'; else echo 'ROLLBACK NEEDS ATTENTION'; fi
  fi
  printf 'failed\n' > "$state/result.txt"
  exit "$code"
}
trap rollback_on_error ERR
install_credentials() {
  mkdir -p "$record_dir"
  cp "$incoming/github-token" "$record_dir/github-token"
  chmod 600 "$record_dir/github-token"
}
start_new() {
  install_credentials
  docker compose --project-directory "$compose_dir" -f "$compose_dir/docker-compose.yml" -f "$state/compose.install.yml" up -d --no-deps --pull never app
  ready=0
  for attempt in $(seq 1 60); do
    if curl -fsS --max-time 5 http://127.0.0.1:2333/api/v2 > "$state/core-health.json" &&
      python3 -c 'import json,sys;assert json.load(open(sys.argv[1]))["version"]==sys.argv[2]' "$state/core-health.json" "$core_version"; then ready=1; break; fi
    sleep 2
  done
  test "$ready" = 1
  curl -fsS --max-time 20 http://127.0.0.1:2333/proxy/qaqdmin > "$state/admin-after.html"
  grep -Fq "window.version = '$admin_version'" "$state/admin-after.html"
}
changed=1
start_new
# Exercise the actual recovery command once, verify old files/config, then reapply the new version.
MX_UPDATE_LOCK_HELD=1 bash "$backup/rollback.sh"
printf 'verified\n' > "$state/rollback-drill.txt"
start_new
sha256sum -c "$backup/config-before.sha256" >/dev/null
docker inspect mongo redis --format '{{.Name}} {{.Id}} {{.State.StartedAt}}' > "$state/databases-after.txt"
cmp "$backup/databases-before.txt" "$state/databases-after.txt"
docker exec -i mongo mongosh --quiet < content-fingerprint.js | sha256sum > "$state/content-after.sha256"
cmp "$state/content-before.sha256" "$state/content-after.sha256"
pm2 jlist > "$state/pm2-after.json"
docker inspect mx-server > "$state/core-after.json"
python3 - "$state" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);before=json.loads((p/'core-before.json').read_text())[0];after=json.loads((p/'core-after.json').read_text())[0]
env=lambda o:dict(x.split('=',1) for x in o['Config'].get('Env',[]));expected=env(before);expected['MX_ADMIN_DEPLOY_MANAGED']='false'
assert expected==env(after),'Unexpected runtime environment change'
for key in ['Entrypoint','Cmd','User','WorkingDir']:assert before['Config'].get(key)==after['Config'].get(key),key
mounts=lambda o:sorted((m['Source'],m['Destination'],m['RW']) for m in o['Mounts'])
assert mounts(before)==mounts(after),'Mounts changed'
assert before['HostConfig']['PortBindings']==after['HostConfig']['PortBindings'],'Ports changed'
def shiro(f):
 a=next(x for x in json.loads((p/f).read_text()) if x['name']=='shiro');return (a['pid'],a['pm2_env']['pm_uptime'],a['pm2_env']['restart_time'],a['pm2_env']['pm_exec_path'])
assert shiro('pm2-before.json')==shiro('pm2-after.json'),'Shiroi process changed'
PY
curl -fsS --max-time 20 http://127.0.0.1:2323/api/healthz > "$state/shiro-health.json"
python3 - "$state" "$record_dir" "$run_id" "$backup" <<'PY'
import json,os,pathlib,sys
p=pathlib.Path(sys.argv[1]);out=pathlib.Path(sys.argv[2]);record={'releaseSha':(p/'release-sha').read_text().strip(),'manifest':json.loads((p/'source-manifest.json').read_text()),'runId':int(sys.argv[3]),'imageId':json.loads((p/'core-after.json').read_text())[0]['Image'],'rollbackBackup':sys.argv[4]}
f=out/'current.json.tmp';f.write_text(json.dumps(record));os.chmod(f,0o600);os.replace(f,out/'current.json')
PY
trap - ERR
printf 'success\n' > "$state/result.txt"
echo 'PASS: original UI/private update source installed; real rollback drill passed; Shiroi process, content/settings, Mongo/Redis and original config unchanged'
echo "Recovery command: bash $backup/rollback.sh"
echo "Current Compose overlay: $state/compose.install.yml"
