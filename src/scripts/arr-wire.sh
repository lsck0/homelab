# shellcheck shell=bash
# Wires the media stack together through the apps' own APIs. Idempotent: every
# step checks first and only creates what is missing, so it runs on a timer
# and converges as VMs come up. API keys come from the NAS token dir, where
# each VM exports its own.
#
#   qBittorrent  <- download client in Prowlarr/Radarr/Sonarr/Lidarr/Bookshelf
#   root folders   movies, tv + anime, music, books under /data/media
#   Prowlarr     -> apps (full indexer sync) + default public indexers
#                   + Tor SOCKS5 indexer proxy applied to every indexer
#   Jellyseerr   -> Jellyfin login, libraries, Radarr + Sonarr (anime folder)
#   Bazarr       -> Radarr + Sonarr, English profile
#
# Env: INDEXERS (space-separated Prowlarr definition names). Addresses default
# to the lab; tests override them (src/tests/media-stack.sh).

T=${TOKEN_DIR:-/var/lib/homepage-tokens}
QBIT_HOST=${QBIT_HOST:-10.100.0.112};       QBIT_PORT=${QBIT_PORT:-80}
PROWLARR_HOST=${PROWLARR_HOST:-10.100.0.129}; PROWLARR_PORT=${PROWLARR_PORT:-80}
RADARR_HOST=${RADARR_HOST:-10.100.0.130};     RADARR_PORT=${RADARR_PORT:-80}
SONARR_HOST=${SONARR_HOST:-10.100.0.131};     SONARR_PORT=${SONARR_PORT:-80}
JELLYFIN_HOST=${JELLYFIN_HOST:-10.100.0.134}; JELLYFIN_PORT=${JELLYFIN_PORT:-80}
BOOKSHELF_HOST=${BOOKSHELF_HOST:-10.100.0.135}; BOOKSHELF_PORT=${BOOKSHELF_PORT:-8787}
LIDARR_HOST=${LIDARR_HOST:-10.100.0.136};     LIDARR_PORT=${LIDARR_PORT:-8686}
JELLYSEERR_URL=${JELLYSEERR_URL:-http://10.100.0.128}
BAZARR_URL=${BAZARR_URL:-http://10.100.0.132}
# vm-113's isolated SOCKS port (the torrent client uses 9050 with shared
# circuits; indexers get per-destination circuits on 9055).
TOR_HOST=${TOR_HOST:-10.100.0.113};           TOR_PORT=${TOR_PORT:-9055}
pending=0

key() { cat "$T/$1.token" 2>/dev/null; }
api() { # method url apikey [json]
  if [ -n "${4:-}" ]; then
    curl -sf -X "$1" -H "X-Api-Key: $3" -H "Content-Type: application/json" --data "$4" "$2"
  else
    curl -sf -X "$1" -H "X-Api-Key: $3" "$2"
  fi
}
later() { echo "$1"; pending=1; }

# Existence is not the same as being right: a renumber leaves every row in
# place pointing at the old address. fix_fields <label> <url> <key> <json>
# <jq args...> writes back only when the filter changes something. Addresses
# only, since the APIs return keys and passwords masked.
fix_fields() {
  local label=$1 url=$2 k=$3 cur=$4 want
  shift 4
  want=$(echo "$cur" | jq -c "$@")
  [ "$(echo "$cur" | jq -cS .)" = "$(echo "$want" | jq -cS .)" ] && return 0
  if api PUT "$url?forceSave=true" "$k" "$want" >/dev/null; then
    echo "$label: corrected"
  else
    later "$label: correction failed"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SERVARR APPS
# ─────────────────────────────────────────────────────────────────────────────
# wire_servarr <name> <base url> <api version> <category field> <category> <root folder>...
wire_servarr() {
  local name=$1 url=$2 v=$3 catfield=$4 cat=$5; shift 5
  local k a body qpass
  k=$(key "$name-key") || { later "$name: API key not exported yet"; return; }
  qpass=$(key qbittorrent-pass) || { later "$name: qBittorrent password not exported yet"; return; }
  a="$url/api/$v"
  api GET "$a/system/status" "$k" >/dev/null || { later "$name: unreachable"; return; }

  local clients
  clients=$(api GET "$a/downloadclient" "$k")
  if echo "$clients" | jq -e 'any(.[]; .implementation == "QBittorrent")' >/dev/null; then
    local cur id
    cur=$(echo "$clients" | jq -c 'first(.[] | select(.implementation == "QBittorrent"))')
    id=$(echo "$cur" | jq -r .id)
    fix_fields "$name/qbittorrent" "$a/downloadclient/$id" "$k" "$cur" \
      --arg qh "$QBIT_HOST" --arg qp "$QBIT_PORT" \
      '.fields |= map(
          if .name == "host" then .value = $qh
          elif .name == "port" then .value = ($qp | tonumber)
          else . end)'
  else
    body=$(api GET "$a/downloadclient/schema" "$k" | jq -c --arg cf "$catfield" --arg cat "$cat" \
      --arg qh "$QBIT_HOST" --arg qp "$QBIT_PORT" --arg qpass "$qpass" '
      first(.[] | select(.implementation == "QBittorrent"))
      | .name = "qBittorrent" | .enable = true | .priority = 1
      | .removeCompletedDownloads = true | .removeFailedDownloads = true
      | .fields |= map(
          if .name == "host" then .value = $qh
          elif .name == "port" then .value = ($qp | tonumber)
          elif .name == "username" then .value = "admin"
          elif .name == "password" then .value = $qpass
          elif .name == $cf then .value = $cat
          else . end)')
    if api POST "$a/downloadclient?forceSave=true" "$k" "$body" >/dev/null; then
      echo "$name: added qBittorrent download client"
    else
      later "$name: adding qBittorrent failed"
    fi
  fi

  local path qp mp
  for path in "$@"; do
    api GET "$a/rootfolder" "$k" | jq -e --arg p "$path" 'any(.[]; .path == $p)' >/dev/null && continue
    if [ "$v" = v1 ]; then
      # Lidarr/Bookshelf root folders carry default profiles.
      qp=$(api GET "$a/qualityprofile" "$k" | jq '.[0].id')
      mp=$(api GET "$a/metadataprofile" "$k" | jq '.[0].id')
      body=$(jq -cn --arg p "$path" --arg n "$(basename "$path")" --argjson qp "$qp" --argjson mp "$mp" \
        '{name: $n, path: $p, defaultQualityProfileId: $qp, defaultMetadataProfileId: $mp,
          defaultMonitorOption: "all", defaultNewItemMonitorOption: "all", defaultTags: [],
          isCalibreLibrary: false}')
    else
      body=$(jq -cn --arg p "$path" '{path: $p}')
    fi
    if api POST "$a/rootfolder" "$k" "$body" >/dev/null; then
      echo "$name: added root folder $path"
    else
      later "$name: adding root folder $path failed"
    fi
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# PROWLARR
# ─────────────────────────────────────────────────────────────────────────────
wire_prowlarr() {
  local P="http://$PROWLARR_HOST:$PROWLARR_PORT/api/v1" pk apps spec impl name url k body have schema="" def
  pk=$(key prowlarr-key) || { later "prowlarr: API key not exported yet"; return; }
  apps=$(api GET "$P/applications" "$pk") || { later "prowlarr: unreachable"; return; }

  for spec in "Radarr radarr http://$RADARR_HOST:$RADARR_PORT" "Sonarr sonarr http://$SONARR_HOST:$SONARR_PORT" \
              "Lidarr lidarr http://$LIDARR_HOST:$LIDARR_PORT" "Readarr bookshelf http://$BOOKSHELF_HOST:$BOOKSHELF_PORT"; do
    read -r impl name url <<< "$spec"
    k=$(key "$name-key") || { later "prowlarr: waiting for $name API key"; continue; }
    if echo "$apps" | jq -e --arg i "$impl" 'any(.[]; .implementation == $i)' >/dev/null; then
      local cur id
      cur=$(echo "$apps" | jq -c --arg i "$impl" 'first(.[] | select(.implementation == $i))')
      id=$(echo "$cur" | jq -r .id)
      fix_fields "prowlarr/$name" "$P/applications/$id" "$pk" "$cur" \
        --arg u "$url" --arg pu "http://$PROWLARR_HOST:$PROWLARR_PORT" \
        '.fields |= map(
            if .name == "baseUrl" then .value = $u
            elif .name == "prowlarrUrl" then .value = $pu
            else . end)'
      continue
    fi
    body=$(api GET "$P/applications/schema" "$pk" | jq -c --arg i "$impl" --arg n "$name" --arg u "$url" --arg k "$k" \
      --arg pu "http://$PROWLARR_HOST:$PROWLARR_PORT" '
      first(.[] | select(.implementation == $i))
      | .name = $n | .syncLevel = "fullSync"
      | .fields |= map(
          if .name == "prowlarrUrl" then .value = $pu
          elif .name == "baseUrl" then .value = $u
          elif .name == "apiKey" then .value = $k
          else . end)')
    if api POST "$P/applications?forceSave=true" "$pk" "$body" >/dev/null; then
      echo "prowlarr: connected $name"
    else
      later "prowlarr: connecting $name failed"
    fi
  done

  # Tor SOCKS5 in front of the indexers. A Prowlarr proxy only applies to the
  # indexers that carry the same tag, so the tag is created first and then put
  # on every indexer, including ones added by hand in the UI later.
  local tag proxies ind id
  tag=$(api GET "$P/tag" "$pk" | jq -r '.[] | select(.label == "tor") | .id')
  if [ -z "$tag" ]; then
    tag=$(api POST "$P/tag" "$pk" '{"label":"tor"}' | jq -r '.id // empty')
  fi
  if [ -n "$tag" ]; then
    proxies=$(api GET "$P/indexerproxy" "$pk")
    if echo "$proxies" | jq -e 'any(.[]; .implementation == "Socks5")' >/dev/null; then
      # this is what actually carries indexer traffic; stale here means every
      # search times out at 100s
      local cur id
      cur=$(echo "$proxies" | jq -c 'first(.[] | select(.implementation == "Socks5"))')
      id=$(echo "$cur" | jq -r .id)
      fix_fields "prowlarr/tor-proxy" "$P/indexerproxy/$id" "$pk" "$cur" \
        --arg h "$TOR_HOST" --arg p "$TOR_PORT" \
        '.fields |= map(
            if .name == "host" then .value = $h
            elif .name == "port" then .value = ($p | tonumber)
            else . end)'
    else
      body=$(api GET "$P/indexerproxy/schema" "$pk" | jq -c --argjson t "$tag" \
        --arg h "$TOR_HOST" --arg p "$TOR_PORT" '
        first(.[] | select(.implementation == "Socks5"))
        | .name = "tor" | .tags = [$t]
        | .fields |= map(
            if .name == "host" then .value = $h
            elif .name == "port" then .value = ($p | tonumber)
            else . end)')
      if api POST "$P/indexerproxy?forceSave=true" "$pk" "$body" >/dev/null; then
        echo "prowlarr: added Tor SOCKS5 indexer proxy ($TOR_HOST:$TOR_PORT)"
      else
        # same reasoning as the indexers below: a proxy that is momentarily
        # unreachable must not keep the whole stack reported as "pending"
        # forever. Retried on the next run.
        echo "prowlarr: Tor indexer proxy not added (is vm-113 up?), retried next run"
      fi
    fi
  else
    later "prowlarr: could not create the tor tag"
  fi

  have=$(api GET "$P/indexer" "$pk" | jq -r '.[].definitionName')
  for def in $INDEXERS; do
    echo "$have" | grep -qx "$def" && continue
    [ -n "$schema" ] || schema=$(api GET "$P/indexer/schema" "$pk")
    body=$(echo "$schema" | jq -c --arg d "$def" \
      'first(.[] | select(.definitionName == $d)) | .enable = true | .appProfileId = 1 | .priority = 25')
    [ -n "$body" ] || { echo "prowlarr: unknown indexer definition '$def'"; continue; }
    # Prowlarr tests the site even with forceSave; a blocked or down site must
    # not keep the rest of the stack "pending".
    if api POST "$P/indexer?forceSave=true" "$pk" "$body" >/dev/null; then
      echo "prowlarr: added indexer $def"
    else
      echo "prowlarr: indexer $def unreachable, skipped (retried next run)"
    fi
  done

  # after the indexers exist: put the tor tag on any that lack it, so indexers
  # added here or by hand in the UI all egress through vm-113.
  if [ -n "$tag" ]; then
    for id in $(api GET "$P/indexer" "$pk" | jq -r --argjson t "$tag" \
                  '.[] | select((.tags // []) | index($t) | not) | .id'); do
      ind=$(api GET "$P/indexer/$id" "$pk" | jq -c --argjson t "$tag" '.tags = ((.tags // []) + [$t])')
      api PUT "$P/indexer/$id" "$pk" "$ind" >/dev/null \
        && echo "prowlarr: indexer $id now goes through Tor"
    done
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# JELLYSEERR
# ─────────────────────────────────────────────────────────────────────────────
wire_jellyseerr() {
  local S="$JELLYSEERR_URL/api/v1" jar rk sk rp sp ids
  [ "$(curl -sf "$S/settings/public" | jq -r '.initialized // empty')" = true ] && return
  [ -n "$(curl -sf "$S/settings/public")" ] || { later "jellyseerr: unreachable"; return; }
  if ! { rk=$(key radarr-key) && sk=$(key sonarr-key) && [ -s "$T/jellyfin-key.token" ]; }; then
    later "jellyseerr: waiting for radarr/sonarr/jellyfin"; return
  fi

  jar=$(mktemp); trap 'rm -f "$jar"' RETURN
  js() { curl -sf -c "$jar" -b "$jar" -H "Content-Type: application/json" "$@"; }

  js -X POST "$S/auth/jellyfin" -d "$(jq -cn --arg p "$(key jellyfin-admin-pass)" \
    --arg h "$JELLYFIN_HOST" --argjson port "$JELLYFIN_PORT" \
    '{username: "admin", password: $p, hostname: $h, port: $port, useSsl: false,
      urlBase: "", email: "admin@lsck0.dev", serverType: 2}')" >/dev/null || true
  js "$S/auth/me" >/dev/null || { later "jellyseerr: Jellyfin login failed"; return; }

  js "$S/settings/jellyfin/library?sync=true" >/dev/null
  ids=$(js "$S/settings/jellyfin/library" | jq -r 'map(.id) | join(",")')
  js "$S/settings/jellyfin/library?enable=$ids" >/dev/null

  rp=$(api GET "http://$RADARR_HOST:$RADARR_PORT/api/v3/qualityprofile" "$rk" | jq -c '.[0]')
  sp=$(api GET "http://$SONARR_HOST:$SONARR_PORT/api/v3/qualityprofile" "$sk" | jq -c '.[0]')
  js -X POST "$S/settings/radarr" -d "$(jq -cn --arg k "$rk" --argjson p "$rp" \
    --arg h "$RADARR_HOST" --argjson port "$RADARR_PORT" '{
    name: "Radarr", hostname: $h, port: $port, apiKey: $k, useSsl: false, baseUrl: "",
    activeProfileId: $p.id, activeProfileName: $p.name, activeDirectory: "/data/media/movies",
    minimumAvailability: "released", tags: [], is4k: false, isDefault: true,
    externalUrl: "https://radarr.lsck0.dev", syncEnabled: true, preventSearch: false}')" >/dev/null \
    || { later "jellyseerr: adding Radarr failed"; return; }
  js -X POST "$S/settings/sonarr" -d "$(jq -cn --arg k "$sk" --argjson p "$sp" \
    --arg h "$SONARR_HOST" --argjson port "$SONARR_PORT" '{
    name: "Sonarr", hostname: $h, port: $port, apiKey: $k, useSsl: false, baseUrl: "",
    activeProfileId: $p.id, activeProfileName: $p.name, activeDirectory: "/data/media/tv",
    activeAnimeProfileId: $p.id, activeAnimeProfileName: $p.name, activeAnimeDirectory: "/data/media/anime",
    seriesType: "standard", animeSeriesType: "anime", tags: [], animeTags: [],
    is4k: false, isDefault: true, enableSeasonFolders: true,
    externalUrl: "https://sonarr.lsck0.dev", syncEnabled: true, preventSearch: false}')" >/dev/null \
    || { later "jellyseerr: adding Sonarr failed"; return; }
  js -X POST "$S/settings/initialize" >/dev/null && echo "jellyseerr: initialised"
}

# ─────────────────────────────────────────────────────────────────────────────
# BAZARR
# ─────────────────────────────────────────────────────────────────────────────
wire_bazarr() {
  local B="$BAZARR_URL/api" bk rk sk
  if ! { bk=$(key bazarr-key) && rk=$(key radarr-key) && sk=$(key sonarr-key); }; then
    later "bazarr: waiting for API keys"; return
  fi
  [ "$(curl -sf -H "X-API-KEY: $bk" "$B/system/settings" | jq -r '.general.use_radarr // empty')" = true ] && return
  if curl -sf -X POST -H "X-API-KEY: $bk" "$B/system/settings" \
    --data-urlencode "settings-general-use_radarr=true" \
    --data-urlencode "settings-general-use_sonarr=true" \
    --data-urlencode "settings-radarr-ip=$RADARR_HOST" \
    --data-urlencode "settings-radarr-port=$RADARR_PORT" \
    --data-urlencode "settings-radarr-apikey=$rk" \
    --data-urlencode "settings-sonarr-ip=$SONARR_HOST" \
    --data-urlencode "settings-sonarr-port=$SONARR_PORT" \
    --data-urlencode "settings-sonarr-apikey=$sk" \
    --data-urlencode "settings-general-enabled_providers=podnapisi" \
    --data-urlencode "languages-enabled=en" \
    --data-urlencode 'languages-profiles=[{"profileId":1,"name":"English","cutoff":null,"items":[{"id":1,"language":"en","audio_exclude":"False","hi":"False","forced":"False"}],"mustContain":[],"mustNotContain":[],"originalFormat":false}]' \
    --data-urlencode "settings-general-serie_default_enabled=true" \
    --data-urlencode "settings-general-serie_default_profile=1" \
    --data-urlencode "settings-general-movie_default_enabled=true" \
    --data-urlencode "settings-general-movie_default_profile=1" >/dev/null; then
    echo "bazarr: connected Radarr + Sonarr"
  else
    later "bazarr: settings update failed"
  fi
}

# Prowlarr needs its own download client: "Grab" in its search UI hands the
# release to Prowlarr, not to an *arr, so without one the button silently does
# nothing. No root folders: Prowlarr does not manage files.
wire_servarr prowlarr  "http://$PROWLARR_HOST:$PROWLARR_PORT"   v1 category     prowlarr
wire_servarr radarr    "http://$RADARR_HOST:$RADARR_PORT"       v3 movieCategory radarr    /data/media/movies
wire_servarr sonarr    "http://$SONARR_HOST:$SONARR_PORT"       v3 tvCategory    sonarr    /data/media/tv /data/media/anime
wire_servarr lidarr    "http://$LIDARR_HOST:$LIDARR_PORT"       v1 musicCategory lidarr    /data/media/music
wire_servarr bookshelf "http://$BOOKSHELF_HOST:$BOOKSHELF_PORT" v1 bookCategory  bookshelf /data/media/books
wire_prowlarr
wire_jellyseerr
wire_bazarr

if [ "$pending" -eq 0 ]; then echo "media stack fully wired"; else echo "some steps pending, retrying on next run"; fi
