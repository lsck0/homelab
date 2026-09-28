# shellcheck shell=bash
# wires the media stack via app apis; idempotent, runs on a timer
# env: INDEXERS; addresses overridden by src/tests/media-stack.sh

T=${TOKEN_DIR:-/var/lib/homepage-tokens}
QBIT_HOST=${QBIT_HOST:-10.100.0.112};       QBIT_PORT=${QBIT_PORT:-80}
PROWLARR_HOST=${PROWLARR_HOST:-10.100.0.130}; PROWLARR_PORT=${PROWLARR_PORT:-9696}
RADARR_HOST=${RADARR_HOST:-10.100.0.130};     RADARR_PORT=${RADARR_PORT:-7878}
SONARR_HOST=${SONARR_HOST:-10.100.0.130};     SONARR_PORT=${SONARR_PORT:-8989}
JELLYFIN_HOST=${JELLYFIN_HOST:-10.100.0.134}; JELLYFIN_PORT=${JELLYFIN_PORT:-80}
LIDARR_HOST=${LIDARR_HOST:-10.100.0.130};     LIDARR_PORT=${LIDARR_PORT:-8686}
JELLYSEERR_URL=${JELLYSEERR_URL:-http://10.100.0.128}
BAZARR_URL=${BAZARR_URL:-http://10.100.0.130:6767}
# router's isolated socks port
TOR_HOST=${TOR_HOST:-10.100.0.1};           TOR_PORT=${TOR_PORT:-9055}
# when radarr starts looking
MIN_AVAILABILITY=${MIN_AVAILABILITY:-announced}
# jellyfin account that owns the lab
OWNER_USER=${OWNER_USER:-luca}
OWNER_PERMISSIONS=${OWNER_PERMISSIONS:-160}
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

# existing rows go stale after a renumber; correct them
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
      # lidarr root folders need default profiles
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
# JELLYFIN NOTIFICATION
wire_jellyfin_notify() {
  local name=$1 url=$2 k jk cur id body
  k=$(key "$name-key") || { later "$name: API key not exported yet"; return; }
  jk=$(key jellyfin-key) || { later "$name: waiting for the Jellyfin API key"; return; }
  local a="$url/api/v3"

  cur=$(api GET "$a/notification" "$k") || { later "$name: unreachable"; return; }
  if echo "$cur" | jq -e 'any(.[]; .implementation == "MediaBrowser")' >/dev/null; then
    local one
    one=$(echo "$cur" | jq -c 'first(.[] | select(.implementation == "MediaBrowser"))')
    id=$(echo "$one" | jq -r .id)
    fix_fields "$name/jellyfin" "$a/notification/$id" "$k" "$one" \
      --arg h "$JELLYFIN_HOST" --arg p "$JELLYFIN_PORT" \
      '.onDownload = true | .onUpgrade = true | .onRename = true
       | .fields |= map(
           if .name == "host" then .value = $h
           elif .name == "port" then .value = ($p | tonumber)
           elif .name == "updateLibrary" then .value = true
           else . end)'
    return
  fi

  body=$(api GET "$a/notification/schema" "$k" | jq -c \
    --arg h "$JELLYFIN_HOST" --arg p "$JELLYFIN_PORT" --arg jk "$jk" '
    first(.[] | select(.implementation == "MediaBrowser"))
    | .name = "Jellyfin"
    # library changes on import and rename
    | .onDownload = true | .onUpgrade = true | .onRename = true
    | .fields |= map(
        if .name == "host" then .value = $h
        elif .name == "port" then .value = ($p | tonumber)
        elif .name == "apiKey" then .value = $jk
        elif .name == "updateLibrary" then .value = true
        else . end)')
  if api POST "$a/notification?forceSave=true" "$k" "$body" >/dev/null; then
    echo "$name: added the Jellyfin library-update notification"
  else
    later "$name: adding the Jellyfin notification failed"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# PROWLARR
wire_prowlarr() {
  local P="http://$PROWLARR_HOST:$PROWLARR_PORT/api/v1" pk apps spec impl name url k body have schema="" def
  pk=$(key prowlarr-key) || { later "prowlarr: API key not exported yet"; return; }
  apps=$(api GET "$P/applications" "$pk") || { later "prowlarr: unreachable"; return; }

  for spec in "Radarr radarr http://$RADARR_HOST:$RADARR_PORT" "Sonarr sonarr http://$SONARR_HOST:$SONARR_PORT" \
              "Lidarr lidarr http://$LIDARR_HOST:$LIDARR_PORT"; do
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

  # tor socks5 in front of the indexers
  local tag proxies ind id
  tag=$(api GET "$P/tag" "$pk" | jq -r '.[] | select(.label == "tor") | .id')
  if [ -z "$tag" ]; then
    tag=$(api POST "$P/tag" "$pk" '{"label":"tor"}' | jq -r '.id // empty')
  fi
  if [ -n "$tag" ]; then
    proxies=$(api GET "$P/indexerproxy" "$pk")
    if echo "$proxies" | jq -e 'any(.[]; .implementation == "Socks5")' >/dev/null; then
      # carries indexer traffic; stale means every search times out
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
        # unreachable proxy must not fail the run
        echo "prowlarr: Tor indexer proxy not added (is the router up?), retried next run"
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
    # prowlarr tests the site even with forceSave
    if api POST "$P/indexer?forceSave=true" "$pk" "$body" >/dev/null; then
      echo "prowlarr: added indexer $def"
    else
      echo "prowlarr: indexer $def unreachable, skipped (retried next run)"
    fi
  done

  # tag untagged indexers with tor
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
wire_jellyseerr() {
  local S="$JELLYSEERR_URL/api/v1" jar rk sk rp sp ids initialised
  initialised=$(curl -sf "$S/settings/public" | jq -r '.initialized // empty')
  [ -n "$(curl -sf "$S/settings/public")" ] || { later "jellyseerr: unreachable"; return; }
  if ! { rk=$(key radarr-key) && sk=$(key sonarr-key) && [ -s "$T/jellyfin-key.token" ]; }; then
    later "jellyseerr: waiting for radarr/sonarr/jellyfin"; return
  fi

  jar=$(mktemp); trap 'rm -f "$jar"' RETURN
  js() { curl -sf -c "$jar" -b "$jar" -H "Content-Type: application/json" "$@"; }

  # endpoint shape differs before initialisation
  if [ "$initialised" = true ]; then
    js -X POST "$S/auth/jellyfin" -d "$(jq -cn --arg p "$(key jellyfin-admin-pass)" \
      '{username: "admin", password: $p}')" >/dev/null || true
  else
    js -X POST "$S/auth/jellyfin" -d "$(jq -cn --arg p "$(key jellyfin-admin-pass)" \
      --arg h "$JELLYFIN_HOST" --argjson port "$JELLYFIN_PORT" \
      '{username: "admin", password: $p, hostname: $h, port: $port, useSsl: false,
        urlBase: "", email: "admin@lsck0.dev", serverType: 2}')" >/dev/null || true
  fi
  js "$S/auth/me" >/dev/null || { later "jellyseerr: Jellyfin login failed"; return; }

  # initialised jellyseerr still gets corrected
  if [ "$initialised" = true ]; then
    local cur want
    cur=$(js "$S/settings/radarr" | jq -c '.[0] // empty')
    if [ -z "$cur" ]; then
      later "jellyseerr: initialised but has no Radarr server"
    else
      # id is read-only on the way back in
      want=$(echo "$cur" | jq -c --arg k "$rk" --arg h "$RADARR_HOST" \
        --argjson port "$RADARR_PORT" --arg min "$MIN_AVAILABILITY" \
        '.apiKey = $k | .hostname = $h | .port = $port | .minimumAvailability = $min')
      if [ "$(echo "$cur" | jq -cS .)" != "$(echo "$want" | jq -cS .)" ]; then
        js -X PUT "$S/settings/radarr/$(echo "$cur" | jq -r .id)" \
          -d "$(echo "$want" | jq -c 'del(.id)')" >/dev/null \
          && echo "jellyseerr: Radarr server corrected" \
          || later "jellyseerr: correcting the Radarr server failed"
      fi
    fi
    # unapproved requests never reach radarr
    local uid
    uid=$(js "$S/user?take=100" | jq -r --arg u "$OWNER_USER" \
      'first(.results[] | select(.displayName == $u or .jellyfinUsername == $u)) | .id // empty')
    if [ -n "$uid" ]; then
      if [ "$(js "$S/user/$uid" | jq -r .permissions)" != "$OWNER_PERMISSIONS" ]; then
        js -X PUT "$S/user/$uid" -d "$(jq -cn --argjson p "$OWNER_PERMISSIONS" '{permissions: $p}')" >/dev/null \
          && echo "jellyseerr: $OWNER_USER may now approve its own requests" \
          || later "jellyseerr: could not set permissions for $OWNER_USER"
      fi
    else
      later "jellyseerr: no user called $OWNER_USER"
    fi
    if [ "$(js "$S/settings/main" | jq -r .defaultPermissions)" != "$OWNER_PERMISSIONS" ]; then
      js -X POST "$S/settings/main" -d "$(jq -cn --argjson p "$OWNER_PERMISSIONS" '{defaultPermissions: $p}')" >/dev/null \
        && echo "jellyseerr: default permissions corrected" \
        || later "jellyseerr: could not set default permissions"
    fi

    cur=$(js "$S/settings/sonarr" | jq -c '.[0] // empty')
    if [ -n "$cur" ]; then
      want=$(echo "$cur" | jq -c --arg k "$sk" --arg h "$SONARR_HOST" \
        --argjson port "$SONARR_PORT" '.apiKey = $k | .hostname = $h | .port = $port')
      if [ "$(echo "$cur" | jq -cS .)" != "$(echo "$want" | jq -cS .)" ]; then
        js -X PUT "$S/settings/sonarr/$(echo "$cur" | jq -r .id)" \
          -d "$(echo "$want" | jq -c 'del(.id)')" >/dev/null \
          && echo "jellyseerr: Sonarr server corrected" \
          || later "jellyseerr: correcting the Sonarr server failed"
      fi
    fi
    return
  fi

  js "$S/settings/jellyfin/library?sync=true" >/dev/null
  ids=$(js "$S/settings/jellyfin/library" | jq -r 'map(.id) | join(",")')
  js "$S/settings/jellyfin/library?enable=$ids" >/dev/null

  rp=$(api GET "http://$RADARR_HOST:$RADARR_PORT/api/v3/qualityprofile" "$rk" | jq -c '.[0]')
  sp=$(api GET "http://$SONARR_HOST:$SONARR_PORT/api/v3/qualityprofile" "$sk" | jq -c '.[0]')
  js -X POST "$S/settings/radarr" -d "$(jq -cn --arg k "$rk" --argjson p "$rp" \
    --arg h "$RADARR_HOST" --argjson port "$RADARR_PORT" --arg min "$MIN_AVAILABILITY" '{
    name: "Radarr", hostname: $h, port: $port, apiKey: $k, useSsl: false, baseUrl: "",
    activeProfileId: $p.id, activeProfileName: $p.name, activeDirectory: "/data/media/movies",
    minimumAvailability: $min, tags: [], is4k: false, isDefault: true,
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
# BAZARR (languages in preference order)
SUBTITLE_LANGUAGES=${SUBTITLE_LANGUAGES:-de en}
# no-account providers; opensubtitles.com needs one
SUBTITLE_PROVIDERS=${SUBTITLE_PROVIDERS:-podnapisi gestdown tvsubtitles yifysubtitles}

wire_bazarr() {
  local B="$BAZARR_URL/api" bk rk sk cur want args=()
  if ! { bk=$(key bazarr-key) && rk=$(key radarr-key) && sk=$(key sonarr-key); }; then
    later "bazarr: waiting for API keys"; return
  fi
  cur=$(curl -sf -H "X-API-KEY: $bk" "$B/system/settings") || { later "bazarr: unreachable"; return; }

  # sent every run, not only when unconfigured
  local profile items i=0 lang
  items=""
  for lang in $SUBTITLE_LANGUAGES; do
    i=$((i + 1))
    # audio_only_include required, else KeyError on indexing
    items="$items${items:+,}$(jq -cn --arg l "$lang" --argjson id "$i" \
      '{id: $id, language: $l, audio_exclude: "False", audio_only_include: "False",
        hi: "False", forced: "False"}')"
  done
  profile=$(jq -cn --argjson items "[$items]" --arg n "$(echo "$SUBTITLE_LANGUAGES" | tr ' ' '+')" \
    '[{profileId: 1, name: $n, cutoff: null, items: $items,
       mustContain: [], mustNotContain: [], originalFormat: false, tag: null}]')

  args=(
    --data-urlencode "settings-general-use_radarr=true"
    --data-urlencode "settings-general-use_sonarr=true"
    --data-urlencode "settings-radarr-ip=$RADARR_HOST"
    --data-urlencode "settings-radarr-port=$RADARR_PORT"
    --data-urlencode "settings-radarr-apikey=$rk"
    --data-urlencode "settings-sonarr-ip=$SONARR_HOST"
    --data-urlencode "settings-sonarr-port=$SONARR_PORT"
    --data-urlencode "settings-sonarr-apikey=$sk"
    --data-urlencode "languages-profiles=$profile"
    --data-urlencode "settings-general-serie_default_enabled=true"
    --data-urlencode "settings-general-serie_default_profile=1"
    --data-urlencode "settings-general-movie_default_enabled=true"
    --data-urlencode "settings-general-movie_default_profile=1"
  )
  for p in $SUBTITLE_PROVIDERS; do
    args+=(--data-urlencode "settings-general-enabled_providers=$p")
  done
  for lang in $SUBTITLE_LANGUAGES; do
    args+=(--data-urlencode "languages-enabled=$lang")
  done

  if ! curl -sf -X POST -H "X-API-KEY: $bk" "$B/system/settings" "${args[@]}" >/dev/null; then
    later "bazarr: settings update failed"
    return
  fi

  # bazarr reads the profile only at start
  if [ "$(echo "$cur" | jq -r '[.radarr.ip, .radarr.port, .sonarr.ip, .sonarr.port] | map(tostring) | join(",")')" \
       != "$RADARR_HOST,$RADARR_PORT,$SONARR_HOST,$SONARR_PORT" ]; then
    echo "bazarr: corrected the Radarr/Sonarr addresses, restarting it to reload the profile"
    curl -sf -X POST -H "X-API-KEY: $bk" "$B/system?action=restart" >/dev/null || true
  fi
  echo "bazarr: ${SUBTITLE_LANGUAGES// /+} subtitles from ${SUBTITLE_PROVIDERS// /, }"
}

# prowlarr needs its own client for search-ui grabs
wire_servarr prowlarr  "http://$PROWLARR_HOST:$PROWLARR_PORT"   v1 category     prowlarr
wire_servarr radarr    "http://$RADARR_HOST:$RADARR_PORT"       v3 movieCategory radarr    /data/media/movies
wire_jellyfin_notify radarr "http://$RADARR_HOST:$RADARR_PORT"
wire_jellyfin_notify sonarr "http://$SONARR_HOST:$SONARR_PORT"
wire_servarr sonarr    "http://$SONARR_HOST:$SONARR_PORT"       v3 tvCategory    sonarr    /data/media/tv /data/media/anime
wire_servarr lidarr    "http://$LIDARR_HOST:$LIDARR_PORT"       v1 musicCategory lidarr    /data/media/music
wire_prowlarr
wire_jellyseerr
wire_bazarr

if [ "$pending" -eq 0 ]; then echo "media stack fully wired"; else echo "some steps pending, retrying on next run"; fi
