#!/usr/bin/env bash
# End-to-end test of the media stack wiring, against the real app containers.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# tools from the flake's nixpkgs, so the scripts run with the same versions.
if [ -z "${MEDIA_TEST_SHELL:-}" ]; then
  exec nix shell --inputs-from "$SRC" \
    nixpkgs#bash nixpkgs#curl nixpkgs#jq nixpkgs#yq-go nixpkgs#gnused nixpkgs#gnugrep \
    nixpkgs#coreutils nixpkgs#openssl nixpkgs#findutils nixpkgs#python3 \
    -c env MEDIA_TEST_SHELL=1 bash "${BASH_SOURCE[0]}" "$@"
fi

W=$(mktemp -d /tmp/media-stack.XXXXXX)
NET=mediatest
SUBNET=172.30.99.0/24
P=mt-   # container name prefix on the host; aliases are the plain names
FAILED=0
KEEP=${KEEP:-0}

APPS="qbittorrent prowlarr radarr sonarr lidarr jellyfin jellyseerr bazarr janitorr-stats janitorr"
cleanup() {
  if [ "$KEEP" = 1 ]; then echo ">>> KEEP=1: containers left running, workdir $W"; return; fi
  for a in $APPS; do docker rm -f "$P$a" >/dev/null 2>&1 || true; done
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker run --rm -v "$W:/w" alpine rm -rf /w/* >/dev/null 2>&1 || true
  rm -rf "$W" 2>/dev/null || true
}
trap cleanup EXIT

ok()   { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAILED=1; }
check() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi; }

nixeval() { nix eval --no-warn-dirty --raw "$SRC#nixosConfigurations.$1.config.$2"; }
image() { nixeval "$1" "virtualisation.oci-containers.containers.$2.image"; }

# script body of a NixOS unit, with lab-specific strings replaced. unit_script <host> <unit>
unit_script() {
  local host=$1 unit=$2 out="$W/scripts/$2.sh"; shift 2
  mkdir -p "$W/scripts"
  # realise the unit so every store path its script references exists here
  nix build --no-warn-dirty --no-link "$SRC#nixosConfigurations.$host.config.systemd.units.\"$unit.service\".unit"
  { echo 'set -e'; nixeval "$host" "systemd.services.\"$unit\".script"; } > "$out"
  local e; for e in "$@"; do sed -i "$e" "$out"; done
  echo "$out"
}
run_unit() { local s; s=$(unit_script "$@"); echo ">>> $2"; bash "$s"; }

# the unit scripts call podman on the VMs; Docker here.
mkdir -p "$W/bin" "$W/tokens"
printf '#!/bin/sh\nexec docker "$@"\n' > "$W/bin/podman"; chmod +x "$W/bin/podman"
export PATH="$W/bin:$PATH"

TOK="s#/var/lib/homepage-tokens#$W/tokens#g"

echo ">>> workdir $W"
for a in $APPS; do docker rm -f "$P$a" >/dev/null 2>&1 || true; done
docker network rm "$NET" >/dev/null 2>&1 || true
docker network create --subnet "$SUBNET" "$NET" >/dev/null

mkdir -p "$W"/media/{movies,tv,anime,music,books,manga,audiobooks,leaving-soon} "$W/torrents"
chmod -R 777 "$W/media" "$W/torrents" "$W/tokens"

# run_app <name> <image> <published host:container port> [docker args...]
run_app() {
  local name=$1 img=$2 port=$3; shift 3
  mkdir -p "$W/$name"; chmod 777 "$W/$name"
  docker rm -f "$P$name" >/dev/null 2>&1 || true
  docker run -d --name "$P$name" --network "$NET" --network-alias "$name" \
    -p "127.0.0.1:$port" -e PUID=1000 -e PGID=1000 -e TZ=Europe/Berlin "$@" "$img" >/dev/null
  echo "    started $name ($img)"
}

echo ">>> Starting containers (images from the NixOS configs)"
DATA=(-v "$W/media:/data/media" -v "$W/torrents:/data/torrents")
run_app qbittorrent "$(image 112-internal-qbittorrent qbittorrent)" 18080:8080 -e WEBUI_PORT=8080 \
  -v "$W/qbittorrent:/config" -v "$W/torrents:/data/torrents"
run_app prowlarr  "$(image 129-internal-prowlarr prowlarr)"      19696:9696 -v "$W/prowlarr:/config" "${DATA[@]}"
run_app radarr    "$(image 130-internal-radarr radarr)"          17878:7878 -v "$W/radarr:/config" "${DATA[@]}"
run_app sonarr    "$(image 131-internal-sonarr sonarr)"          18989:8989 -v "$W/sonarr:/config" "${DATA[@]}"
run_app lidarr    "$(image 136-internal-navidrome lidarr)"       18686:8686 -v "$W/lidarr:/config" "${DATA[@]}"
mkdir -p "$W/jellyfin/config" "$W/jellyfin/cache"
run_app jellyfin  "$(image 134-internal-jellyfin jellyfin)"      18096:8096 \
  -v "$W/jellyfin/config:/config" -v "$W/jellyfin/cache:/cache" -v "$W/media:/data/media:ro"
run_app jellyseerr "$(image 128-internal-jellyseerr jellyseerr)" 15055:5055 --init -e PORT=5055 -v "$W/jellyseerr:/app/config"
run_app bazarr    "$(image 132-internal-bazarr bazarr)"          16767:6767 -v "$W/bazarr:/config" -v "$W/media:/data/media"
mkdir -p "$W/manga" "$W/books"
  -v "$W/media/manga:/manga:ro" -v "$W/media/books:/books:ro"

# ─────────────────────────────────────────────────────────────────────────────
# PER-VM SETUP UNITS
Q="s#/var/lib/qbittorrent#$W/qbittorrent#g"
run_unit 112-internal-qbittorrent qbittorrent-disable-auth "$Q" \
  "s#systemctl stop podman-qbittorrent.service#docker stop ${P}qbittorrent#" \
  "s#systemctl start podman-qbittorrent.service#docker start ${P}qbittorrent#"
# the API whitelist lists the lab VMs; here the *arrs live on the test subnet.
nix build --no-warn-dirty --no-link "$SRC#nixosConfigurations.112-internal-qbittorrent.config.systemd.units.\"qbittorrent-settings.service\".unit"
QPREFS=$(nixeval 112-internal-qbittorrent systemd.services.qbittorrent-settings.script | grep -o '/nix/store/[^ ]*-qbittorrent-prefs.json')
jq --arg s "$SUBNET" '.bypass_auth_subnet_whitelist = $s' "$QPREFS" > "$W/qbittorrent-prefs.json"
run_unit 112-internal-qbittorrent qbittorrent-settings "$TOK" \
  "s#$QPREFS#$W/qbittorrent-prefs.json#" \
  "s#podman exec qbittorrent#podman exec ${P}qbittorrent#"

for app in prowlarr:129-internal-prowlarr radarr:130-internal-radarr sonarr:131-internal-sonarr \
           lidarr:136-internal-navidrome; do
  name=${app%%:*}; host=${app#*:}
  run_unit "$host" "$name-setup" "$TOK" "s#/var/lib/$name#$W/$name#g" \
    "s#systemctl stop podman-$name.service#docker stop $P$name#" "s#systemctl start podman-$name.service#docker start $P$name#"
done

run_unit 134-internal-jellyfin jellyfin-setup "$TOK" "s#http://127.0.0.1:80#http://127.0.0.1:18096#g"
run_unit 128-internal-jellyseerr jellyseerr-token "$TOK" "s#/var/lib/jellyseerr#$W/jellyseerr#g"
run_unit 132-internal-bazarr bazarr-token "$TOK" "s#/var/lib/bazarr#$W/bazarr#g"
# an install from before generated passwords: admin with the old default
for i in $(seq 1 60); do
  curl -s -X POST http://127.0.0.1:15000/api/Account/register -H "Content-Type: application/json" \
    -d '{"username":"admin","password":"Admin123!","email":"admin@internal"}' >/dev/null || true
  curl -sf -X POST http://127.0.0.1:15000/api/Account/login -H "Content-Type: application/json" \
    -d '{"username":"admin","password":"Admin123!"}' >/dev/null && break
  sleep 5
done

echo ">>> Exported tokens: $(cd "$W/tokens" && echo *)"

# ─────────────────────────────────────────────────────────────────────────────
# ARR-WIRE (THE REAL SCRIPT BUILT FOR VM-132, RUN ON THE TEST NETWORK)
nix build --no-warn-dirty --no-link "$SRC#nixosConfigurations.133-internal-recyclarr.config.systemd.services.arr-wire.serviceConfig.ExecStart"
WIRE=$(nixeval 133-internal-recyclarr systemd.services.arr-wire.serviceConfig.ExecStart)
arr_wire() {
  docker run --rm --network "$NET" -v /nix/store:/nix/store:ro -v "$W/tokens:/tokens" \
    -e TOKEN_DIR=/tokens \
    -e QBIT_HOST=qbittorrent -e QBIT_PORT=8080 \
    -e PROWLARR_HOST=prowlarr -e PROWLARR_PORT=9696 \
    -e RADARR_HOST=radarr -e RADARR_PORT=7878 \
    -e SONARR_HOST=sonarr -e SONARR_PORT=8989 \
    -e LIDARR_HOST=lidarr -e LIDARR_PORT=8686 \
    -e JELLYFIN_HOST=jellyfin -e JELLYFIN_PORT=8096 \
    -e JELLYSEERR_URL=http://jellyseerr:5055 -e BAZARR_URL=http://bazarr:6767 \
    alpine "$WIRE"
}

echo ">>> arr-wire until converged (it retries on a timer in the lab)"
converged=0
for i in 1 2 3 4 5 6; do
  echo "--- run $i"
  out=$(arr_wire 2>&1); echo "$out"
  if echo "$out" | grep -q "media stack fully wired"; then converged=1; break; fi
  sleep 20
done

echo ">>> Checks"
[ "$converged" = 1 ] && ok "arr-wire converged" || fail "arr-wire did not converge"

key() { cat "$W/tokens/$1.token"; }
api() { curl -sf -H "X-Api-Key: $2" "$1"; }
test_client() { # base apiver key  -> run the app's own connection test on its qBittorrent client
  local body; body=$(api "$1/api/$2/downloadclient" "$3" | jq -c 'first(.[] | select(.implementation=="QBittorrent"))')
  curl -sf -X POST -H "X-Api-Key: $3" -H "Content-Type: application/json" --data "$body" "$1/api/$2/downloadclient/test"
}
for spec in radarr:17878:v3:/data/media/movies sonarr:18989:v3:/data/media/anime \
            lidarr:18686:v1:/data/media/music; do
  IFS=: read -r name port v folder <<< "$spec"
  base=http://127.0.0.1:$port; k=$(key "$name-key")
  check "$name: qBittorrent download client connects" test_client "$base" "$v" "$k"
  check "$name: root folder $folder" sh -c "curl -sf -H 'X-Api-Key: $k' $base/api/$v/rootfolder | jq -e 'any(.[]; .path==\"$folder\" and .accessible)'"
done
check "sonarr: root folder /data/media/tv" sh -c "curl -sf -H 'X-Api-Key: $(key sonarr-key)' http://127.0.0.1:18989/api/v3/rootfolder | jq -e 'any(.[]; .path==\"/data/media/tv\")'"

pk=$(key prowlarr-key)
check "prowlarr: 4 apps connected" sh -c "curl -sf -H 'X-Api-Key: $pk' http://127.0.0.1:19696/api/v1/applications | jq -e 'length==4'"
for id in $(api http://127.0.0.1:19696/api/v1/applications "$pk" | jq -r '.[].id'); do
  body=$(api "http://127.0.0.1:19696/api/v1/applications/$id" "$pk")
  name=$(echo "$body" | jq -r .name)
  check "prowlarr: app $name connection test" curl -sf -X POST -H "X-Api-Key: $pk" -H "Content-Type: application/json" \
    --data "$body" http://127.0.0.1:19696/api/v1/applications/test
done
check "prowlarr: qBittorrent download client present (so Grab works)" \
  sh -c "curl -sf -H 'X-Api-Key: $pk' http://127.0.0.1:19696/api/v1/downloadclient | jq -e 'any(.[]; .implementation==\"QBittorrent\" and .enable)'"
check "prowlarr: Tor indexer proxy present" \
  sh -c "curl -sf -H 'X-Api-Key: $pk' http://127.0.0.1:19696/api/v1/indexerproxy | jq -e 'any(.[]; .implementation==\"Socks5\")'"
check "prowlarr: every indexer carries the tor tag" \
  sh -c "t=\$(curl -sf -H 'X-Api-Key: $pk' http://127.0.0.1:19696/api/v1/tag | jq -r '.[] | select(.label==\"tor\") | .id');
         [ -n \"\$t\" ] && curl -sf -H 'X-Api-Key: $pk' http://127.0.0.1:19696/api/v1/indexer | jq -e --argjson t \"\$t\" 'all(.[]; (.tags // []) | index(\$t))'"
echo "  info  prowlarr indexers: $(api http://127.0.0.1:19696/api/v1/indexer "$pk" | jq -r '[.[].definitionName] | join(", ")')"
check "prowlarr: nyaasi (anime) indexer present" sh -c "curl -sf -H 'X-Api-Key: $pk' http://127.0.0.1:19696/api/v1/indexer | jq -e 'any(.[]; .definitionName==\"nyaasi\")'"
check "radarr: indexers synced from Prowlarr" sh -c "sleep 30; curl -sf -H 'X-Api-Key: $(key radarr-key)' http://127.0.0.1:17878/api/v3/indexer | jq -e 'length>0'"

jk=$(key jellyseerr-key)
check "jellyseerr: initialized" sh -c "curl -sf http://127.0.0.1:15055/api/v1/settings/public | jq -e '.initialized==true'"
for arr in radarr sonarr; do
  check "jellyseerr: $arr connection test" sh -c "body=\$(curl -sf -H 'X-Api-Key: $jk' http://127.0.0.1:15055/api/v1/settings/$arr | jq -c '.[0]'); \
    curl -sf -X POST -H 'X-Api-Key: $jk' -H 'Content-Type: application/json' --data \"\$body\" http://127.0.0.1:15055/api/v1/settings/$arr/test"
done
check "jellyseerr: sonarr anime folder set" sh -c "curl -sf -H 'X-Api-Key: $jk' http://127.0.0.1:15055/api/v1/settings/sonarr | jq -e '.[0].activeAnimeDirectory==\"/data/media/anime\"'"

bk=$(key bazarr-key)
check "bazarr: radarr + sonarr enabled" sh -c "curl -sf -H 'X-API-KEY: $bk' http://127.0.0.1:16767/api/system/settings | jq -e '.general.use_radarr and .general.use_sonarr'"

# every test client is on the API whitelist, where any login succeeds: check the stored PBKDF2
qbit_password_is() {
  python3 - "$W/qbittorrent/qBittorrent/qBittorrent.conf" "$1" <<'PY'
import base64, hashlib, re, sys
salt, key = (base64.b64decode(x) for x in re.search(r'Password_PBKDF2="@ByteArray\(([^:]+):([^)]+)\)"', open(sys.argv[1]).read()).groups())
sys.exit(hashlib.pbkdf2_hmac("sha512", sys.argv[2].encode(), salt, 100000, len(key)) != key)
PY
}
check "qbittorrent: WebUI password is the generated one" qbit_password_is "$(key qbittorrent-pass)"

jfk=$(key jellyfin-key)
check "jellyfin: Movies/Shows/Anime libraries" sh -c "curl -sf -H 'Authorization: MediaBrowser Token=\"$jfk\"' http://127.0.0.1:18096/Library/VirtualFolders | jq -e '[.[].Name] | contains([\"Movies\",\"Shows\",\"Anime\"])'"
check "jellyfin: janitorr user can delete" sh -c "curl -sf -H 'Authorization: MediaBrowser Token=\"$jfk\"' http://127.0.0.1:18096/Users | jq -e 'any(.[]; .Name==\"janitorr\" and .Policy.EnableContentDeletion)'"


echo ">>> Idempotence: second arr-wire run must change nothing"
out=$(arr_wire 2>&1); echo "$out"
if echo "$out" | grep -vE "unreachable, skipped" | grep -qE "added|connected|initialised|failed"; then fail "arr-wire second run made changes"; else ok "arr-wire second run is a no-op"; fi

# ─────────────────────────────────────────────────────────────────────────────
# JANITORR
echo ">>> Janitorr with the config NixOS renders"
mkdir -p "$W/janitorr/logs" "$W/janitorr/stats"; chmod -R 777 "$W/janitorr"
run_unit 134-internal-jellyfin janitorr-config "$TOK" "s#/var/lib/janitorr#$W/janitorr#g" "s#chown 1000:1000#true#"
for f in application.yml stats.yml; do
  sed -i -e 's#http://10.100.0.131#http://sonarr:8989#; s#http://10.100.0.130#http://radarr:7878#' \
         -e 's#http://10.100.0.134#http://jellyfin:8096#; s#http://10.100.0.128#http://jellyseerr:5055#' \
         -e 's#http://127.0.0.1:8081#http://janitorr-stats:8081#' "$W/janitorr/$f"
done
chmod 644 "$W/janitorr/"*.yml
docker rm -f "${P}janitorr-stats" "${P}janitorr" >/dev/null 2>&1 || true
docker run -d --name "${P}janitorr-stats" --network "$NET" --network-alias janitorr-stats \
  -v "$W/janitorr/stats.yml:/work/config/application.yml:ro" -v "$W/janitorr/stats:/data" \
  "$(image 134-internal-jellyfin janitorr-stats)" >/dev/null
docker run -d --name "${P}janitorr" --network "$NET" --user 1000:1000 -e SERVER_PORT=8082 --memory=512m \
  -v "$W/janitorr/application.yml:/config/application.yml:ro" -v "$W/janitorr/logs:/logs" "${DATA[@]}" \
  "$(image 134-internal-jellyfin janitorr)" >/dev/null
sleep 90
check "janitorr-stats running" sh -c "[ \"\$(docker inspect -f '{{.State.Running}}' ${P}janitorr-stats)\" = true ]"
check "janitorr running" sh -c "[ \"\$(docker inspect -f '{{.State.Running}}' ${P}janitorr)\" = true ]"
levels() { docker logs "$1" 2>&1 | grep -E '^[0-9T:., -]+Z? +(ERROR|WARN)' || true; }
check "janitorr ran a cleanup cycle" sh -c "docker logs ${P}janitorr 2>&1 | grep -q 'Deleting Movies and updating Leaving Soon'"
if [ -n "$(levels "${P}janitorr")$(levels "${P}janitorr-stats")" ]; then
  fail "janitorr / janitorr-stats logged ERROR or WARN:"; levels "${P}janitorr" | head -5; levels "${P}janitorr-stats" | head -5
else
  ok "janitorr + janitorr-stats: no ERROR/WARN"
fi

echo
if [ "$FAILED" = 0 ]; then echo ">>> ALL CHECKS PASSED"; else echo ">>> SOME CHECKS FAILED"; exit 1; fi
