# shellcheck shell=bash disable=SC2016 # single quotes hold jq programs, whose $names are jq's
# wires the media stack via app apis; idempotent, runs on a timer
#
# Every address comes from the environment: lib/recyclarr.nix sets it from the inventory and the routes on
# vm-130, src/tests/media-stack.sh from its test network. A missing one stops the run before it touches anything.

# -----------------------------------------------------------------------------
# CONSTANTS
T=${TOKEN_DIR:?directory of the lab tokens}
SECRETS=${SECRET_DIR:?directory of the sops secrets}
INDEXERS=${INDEXERS:?space separated prowlarr indexer definitions to seed}
QBIT_HOST=${QBIT_HOST:?};         QBIT_PORT=${QBIT_PORT:?}
PROWLARR_HOST=${PROWLARR_HOST:?}; PROWLARR_PORT=${PROWLARR_PORT:?}
RADARR_HOST=${RADARR_HOST:?};     RADARR_PORT=${RADARR_PORT:?}
SONARR_HOST=${SONARR_HOST:?};     SONARR_PORT=${SONARR_PORT:?}
LIDARR_HOST=${LIDARR_HOST:?};     LIDARR_PORT=${LIDARR_PORT:?}
JELLYFIN_HOST=${JELLYFIN_HOST:?}; JELLYFIN_PORT=${JELLYFIN_PORT:?}
JELLYSEERR_URL=${JELLYSEERR_URL:?}
BAZARR_URL=${BAZARR_URL:?}
# where jellyseerr links the owner to
RADARR_PUBLIC_URL=${RADARR_PUBLIC_URL:?}; SONARR_PUBLIC_URL=${SONARR_PUBLIC_URL:?}
# the router's socks port isolated per destination
TOR_HOST=${TOR_HOST:?};           TOR_PORT=${TOR_PORT:?}
# jellyseerr's initialisation wants a mail address for the jellyfin admin it imports
JELLYSEERR_ADMIN_EMAIL=${JELLYSEERR_ADMIN_EMAIL:?}
# the jellyfin api key the arrs' library notifications use (134-internal-jellyfin mints one per consumer)
JELLYFIN_KEY=jellyfin-key-arr
# when radarr starts looking
MIN_AVAILABILITY=announced
# jellyfin account that owns the lab
OWNER_USER=luca
# seerr's permission bits: REQUEST (32) and AUTO_APPROVE (128), so the owner's requests go straight to the arrs
SEERR_PERMISSION_REQUEST=32
SEERR_PERMISSION_AUTO_APPROVE=128
OWNER_PERMISSIONS=$((SEERR_PERMISSION_REQUEST | SEERR_PERMISSION_AUTO_APPROVE))
pending=0

# jq prelude: field(name; value) sets one entry of an *arr row's .fields
JQ_FIELD='def field($n; $v): .fields |= map(if .name == $n then .value = $v else . end);'

token() { cat "$T/$1.token" 2>/dev/null; }
secret() { cat "$SECRETS/$1" 2>/dev/null; }
api() { # method url apikey [json]
  if [ -n "${4:-}" ]; then
    curl -sf -X "$1" -H "X-Api-Key: $3" -H "Content-Type: application/json" --data "$4" "$2"
  else
    curl -sf -X "$1" -H "X-Api-Key: $3" "$2"
  fi
}
later() { echo "$1"; pending=1; }
json_same() { [ "$(jq -cS . <<<"$1")" = "$(jq -cS . <<<"$2")" ]; }
row_of() { jq -c --arg i "$2" 'first(.[] | select(.implementation == $i))' <<<"$1"; } # <rows> <implementation>

# existing rows go stale when an address or setting changes; correct them
fix_fields() { # <label> <collection url> <api key> <row> <jq args...>
  local label=$1 url k=$3 cur=$4 want
  url="$2/$(jq -r .id <<<"$cur")"
  shift 4
  want=$(jq -c "$@" <<<"$cur")
  json_same "$cur" "$want" && return 0
  if api PUT "$url?forceSave=true" "$k" "$want" >/dev/null; then
    echo "$label: corrected"
  else
    later "$label: correction failed"
  fi
}

# prowlarr's sync never rewrites the address of an indexer it already pushed, so a moved prowlarr strands them all
fix_prowlarr_indexers() {
  local name=$1 a=$2 k=$3 row
  while read -r row; do
    [ -n "$row" ] || continue
    fix_fields "$name/indexer $(jq -r .name <<<"$row")" "$a/indexer" "$k" "$row" \
      --arg pu "http://$PROWLARR_HOST:$PROWLARR_PORT/" \
      '.fields |= map(if .name == "baseUrl" then .value |= sub("^https?://[^/]+/"; $pu) else . end)'
  done < <(api GET "$a/indexer" "$k" | jq -c '.[] | select(.name | endswith("(Prowlarr)"))')
}

# -----------------------------------------------------------------------------
# SERVARR APPS
wire_servarr() {
  local name=$1 url=$2 v=$3 catfield=$4 cat=$5; shift 5
  local k a body qpass
  k=$(secret "$name-key") || { later "$name: no API key"; return; }
  qpass=$(secret qbittorrent-pass) || { later "$name: no qBittorrent password"; return; }
  a="$url/api/$v"
  api GET "$a/system/status" "$k" >/dev/null || { later "$name: unreachable"; return; }
  [ "$name" = prowlarr ] || fix_prowlarr_indexers "$name" "$a" "$k"

  local cur
  cur=$(row_of "$(api GET "$a/downloadclient" "$k")" QBittorrent)
  if [ -n "$cur" ]; then
    fix_fields "$name/qbittorrent" "$a/downloadclient" "$k" "$cur" --arg qh "$QBIT_HOST" --arg qp "$QBIT_PORT" \
      "$JQ_FIELD"' field("host"; $qh) | field("port"; $qp | tonumber)'
  else
    body=$(row_of "$(api GET "$a/downloadclient/schema" "$k")" QBittorrent | jq -c --arg cf "$catfield" \
      --arg cat "$cat" --arg qh "$QBIT_HOST" --arg qp "$QBIT_PORT" --arg qpass "$qpass" "$JQ_FIELD"'
      .name = "qBittorrent" | .enable = true | .priority = 1
      | .removeCompletedDownloads = true | .removeFailedDownloads = true
      | field("host"; $qh) | field("port"; $qp | tonumber) | field("username"; "admin") | field("password"; $qpass)
      | field($cf; $cat)')
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

# -----------------------------------------------------------------------------
# JELLYFIN NOTIFICATION
wire_jellyfin_notify() {
  local name=$1 url=$2 k jk cur body
  k=$(secret "$name-key") || { later "$name: no API key"; return; }
  jk=$(token "$JELLYFIN_KEY") || { later "$name: waiting for the Jellyfin API key"; return; }
  local a="$url/api/v3" notify
  # library changes on import and rename
  notify="$JQ_FIELD"' .onDownload = true | .onUpgrade = true | .onRename = true
    | field("host"; $h) | field("port"; $p | tonumber) | field("updateLibrary"; true)'

  cur=$(api GET "$a/notification" "$k") || { later "$name: unreachable"; return; }
  cur=$(row_of "$cur" MediaBrowser)
  if [ -n "$cur" ]; then
    fix_fields "$name/jellyfin" "$a/notification" "$k" "$cur" --arg h "$JELLYFIN_HOST" --arg p "$JELLYFIN_PORT" "$notify"
    return
  fi

  body=$(row_of "$(api GET "$a/notification/schema" "$k")" MediaBrowser | jq -c \
    --arg h "$JELLYFIN_HOST" --arg p "$JELLYFIN_PORT" --arg jk "$jk" "$notify"' | .name = "Jellyfin" | field("apiKey"; $jk)')
  if api POST "$a/notification?forceSave=true" "$k" "$body" >/dev/null; then
    echo "$name: added the Jellyfin library-update notification"
  else
    later "$name: adding the Jellyfin notification failed"
  fi
}

# -----------------------------------------------------------------------------
# PROWLARR
wire_prowlarr() {
  local prowlarr_url="http://$PROWLARR_HOST:$PROWLARR_PORT" P pk apps spec impl name url k cur body have schema="" def
  P="$prowlarr_url/api/v1"
  pk=$(secret prowlarr-key) || { later "prowlarr: no API key"; return; }
  apps=$(api GET "$P/applications" "$pk") || { later "prowlarr: unreachable"; return; }

  for spec in "Radarr radarr http://$RADARR_HOST:$RADARR_PORT" "Sonarr sonarr http://$SONARR_HOST:$SONARR_PORT" \
              "Lidarr lidarr http://$LIDARR_HOST:$LIDARR_PORT"; do
    read -r impl name url <<< "$spec"
    k=$(secret "$name-key") || { later "prowlarr: no $name API key"; continue; }
    cur=$(row_of "$apps" "$impl")
    if [ -n "$cur" ]; then
      fix_fields "prowlarr/$name" "$P/applications" "$pk" "$cur" --arg u "$url" --arg pu "$prowlarr_url" \
        "$JQ_FIELD"' field("baseUrl"; $u) | field("prowlarrUrl"; $pu)'
      continue
    fi
    body=$(row_of "$(api GET "$P/applications/schema" "$pk")" "$impl" | jq -c --arg n "$name" --arg u "$url" \
      --arg k "$k" --arg pu "$prowlarr_url" "$JQ_FIELD"'
      .name = $n | .syncLevel = "fullSync" | field("prowlarrUrl"; $pu) | field("baseUrl"; $u) | field("apiKey"; $k)')
    if api POST "$P/applications?forceSave=true" "$pk" "$body" >/dev/null; then
      echo "prowlarr: connected $name"
    else
      later "prowlarr: connecting $name failed"
    fi
  done

  # apps of removed services fail every sync; the three above are the only ones the lab has
  local stale
  for stale in $(echo "$apps" | jq -r '.[] | select(.name | IN("radarr", "sonarr", "lidarr") | not) | .id'); do
    api DELETE "$P/applications/$stale" "$pk" >/dev/null && echo "prowlarr: removed stale application $stale"
  done

  # tor socks5 in front of the indexers
  local tag tor ind id
  tag=$(api GET "$P/tag" "$pk" | jq -r '.[] | select(.label == "tor") | .id')
  if [ -z "$tag" ]; then
    tag=$(api POST "$P/tag" "$pk" '{"label":"tor"}' | jq -r '.id // empty')
  fi
  if [ -n "$tag" ]; then
    # carries indexer traffic; stale means every search times out
    tor="$JQ_FIELD"' field("host"; $h) | field("port"; $p | tonumber)'
    cur=$(row_of "$(api GET "$P/indexerproxy" "$pk")" Socks5)
    if [ -n "$cur" ]; then
      fix_fields "prowlarr/tor-proxy" "$P/indexerproxy" "$pk" "$cur" --arg h "$TOR_HOST" --arg p "$TOR_PORT" "$tor"
    else
      body=$(row_of "$(api GET "$P/indexerproxy/schema" "$pk")" Socks5 | jq -c --argjson t "$tag" \
        --arg h "$TOR_HOST" --arg p "$TOR_PORT" "$tor"' | .name = "tor" | .tags = [$t]')
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

# -----------------------------------------------------------------------------
# JELLYSEERR
wire_jellyseerr() {
  local S="$JELLYSEERR_URL/api/v1" jar rk sk rp sp ids public initialised
  public=$(curl -sf "$S/settings/public") || { later "jellyseerr: unreachable"; return; }
  initialised=$(echo "$public" | jq -r '.initialized // empty')
  if ! { rk=$(secret radarr-key) && sk=$(secret sonarr-key) && [ -s "$T/$JELLYFIN_KEY.token" ]; }; then
    later "jellyseerr: waiting for radarr/sonarr/jellyfin"; return
  fi

  jar=$(mktemp); trap 'rm -f "$jar"' RETURN
  js() { curl -sf -c "$jar" -b "$jar" -H "Content-Type: application/json" "$@"; }

  # the first server of a kind follows the lab's addresses and keys; its id is read-only on the way back in
  seerr_fix_server() { # <kind> <label> <jq args...>
    local kind=$1 label=$2 cur want
    shift 2
    cur=$(js "$S/settings/$kind" | jq -c '.[0] // empty')
    [ -n "$cur" ] || { later "jellyseerr: initialised but has no $label server"; return; }
    want=$(jq -c "$@" <<<"$cur")
    json_same "$cur" "$want" && return
    if js -X PUT "$S/settings/$kind/$(jq -r .id <<<"$cur")" -d "$(jq -c 'del(.id)' <<<"$want")" >/dev/null; then
      echo "jellyseerr: $label server corrected"
    else
      later "jellyseerr: correcting the $label server failed"
    fi
  }

  # endpoint shape differs before initialisation; the password goes on stdin, never on argv
  if [ "$initialised" = true ]; then
    jq -cn --rawfile p "$SECRETS/jellyfin-admin-pass" '{username: "admin", password: $p}'
  else
    jq -cn --rawfile p "$SECRETS/jellyfin-admin-pass" --arg h "$JELLYFIN_HOST" --argjson port "$JELLYFIN_PORT" \
      --arg email "$JELLYSEERR_ADMIN_EMAIL" '{username: "admin", password: $p, hostname: $h, port: $port,
        useSsl: false, urlBase: "", email: $email, serverType: 2}'
  fi | js -X POST "$S/auth/jellyfin" -d @- >/dev/null
  js "$S/auth/me" >/dev/null || { later "jellyseerr: Jellyfin login failed"; return; }

  # initialised jellyseerr still gets corrected
  if [ "$initialised" = true ]; then
    seerr_fix_server radarr Radarr --arg k "$rk" --arg h "$RADARR_HOST" --argjson port "$RADARR_PORT" \
      --arg min "$MIN_AVAILABILITY" '.apiKey = $k | .hostname = $h | .port = $port | .minimumAvailability = $min'
    seerr_fix_server sonarr Sonarr --arg k "$sk" --arg h "$SONARR_HOST" --argjson port "$SONARR_PORT" \
      '.apiKey = $k | .hostname = $h | .port = $port'
    # unapproved requests never reach radarr
    local uid
    uid=$(js "$S/user?take=100" | jq -r --arg u "$OWNER_USER" \
      'first(.results[] | select(.displayName == $u or .jellyfinUsername == $u)) | .id // empty')
    if [ -n "$uid" ]; then
      if [ "$(js "$S/user/$uid" | jq -r .permissions)" != "$OWNER_PERMISSIONS" ]; then
        if js -X PUT "$S/user/$uid" -d "$(jq -cn --argjson p "$OWNER_PERMISSIONS" '{permissions: $p}')" >/dev/null; then
          echo "jellyseerr: $OWNER_USER may now approve its own requests"
        else
          later "jellyseerr: could not set permissions for $OWNER_USER"
        fi
      fi
    else
      later "jellyseerr: no user called $OWNER_USER"
    fi
    if [ "$(js "$S/settings/main" | jq -r .defaultPermissions)" != "$OWNER_PERMISSIONS" ]; then
      if js -X POST "$S/settings/main" -d "$(jq -cn --argjson p "$OWNER_PERMISSIONS" '{defaultPermissions: $p}')" \
        >/dev/null; then
        echo "jellyseerr: default permissions corrected"
      else
        later "jellyseerr: could not set default permissions"
      fi
    fi
    return
  fi

  js "$S/settings/jellyfin/library?sync=true" >/dev/null
  ids=$(js "$S/settings/jellyfin/library" | jq -r 'map(.id) | join(",")')
  js "$S/settings/jellyfin/library?enable=$ids" >/dev/null

  rp=$(api GET "http://$RADARR_HOST:$RADARR_PORT/api/v3/qualityprofile" "$rk" | jq -c '.[0]')
  sp=$(api GET "http://$SONARR_HOST:$SONARR_PORT/api/v3/qualityprofile" "$sk" | jq -c '.[0]')
  js -X POST "$S/settings/radarr" -d "$(jq -cn --arg k "$rk" --argjson p "$rp" --arg url "$RADARR_PUBLIC_URL" \
    --arg h "$RADARR_HOST" --argjson port "$RADARR_PORT" --arg min "$MIN_AVAILABILITY" '{
    name: "Radarr", hostname: $h, port: $port, apiKey: $k, useSsl: false, baseUrl: "",
    activeProfileId: $p.id, activeProfileName: $p.name, activeDirectory: "/data/media/movies",
    minimumAvailability: $min, tags: [], is4k: false, isDefault: true,
    externalUrl: $url, syncEnabled: true, preventSearch: false}')" >/dev/null \
    || { later "jellyseerr: adding Radarr failed"; return; }
  js -X POST "$S/settings/sonarr" -d "$(jq -cn --arg k "$sk" --argjson p "$sp" --arg url "$SONARR_PUBLIC_URL" \
    --arg h "$SONARR_HOST" --argjson port "$SONARR_PORT" '{
    name: "Sonarr", hostname: $h, port: $port, apiKey: $k, useSsl: false, baseUrl: "",
    activeProfileId: $p.id, activeProfileName: $p.name, activeDirectory: "/data/media/tv",
    activeAnimeProfileId: $p.id, activeAnimeProfileName: $p.name, activeAnimeDirectory: "/data/media/anime",
    seriesType: "standard", animeSeriesType: "anime", tags: [], animeTags: [],
    is4k: false, isDefault: true, enableSeasonFolders: true,
    externalUrl: $url, syncEnabled: true, preventSearch: false}')" >/dev/null \
    || { later "jellyseerr: adding Sonarr failed"; return; }
  js -X POST "$S/settings/initialize" >/dev/null && echo "jellyseerr: initialised"
}

# -----------------------------------------------------------------------------
# BAZARR (languages in preference order)
SUBTITLE_LANGUAGES=${SUBTITLE_LANGUAGES:-de en}
# no-account providers; opensubtitles.com needs one
SUBTITLE_PROVIDERS=${SUBTITLE_PROVIDERS:-podnapisi gestdown tvsubtitles yifysubtitles}

wire_bazarr() {
  local B="$BAZARR_URL/api" bk rk sk cur want args=()
  if ! { bk=$(token bazarr-key) && rk=$(secret radarr-key) && sk=$(secret sonarr-key); }; then
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
    curl -sf -X POST -H "X-API-KEY: $bk" "$B/system?action=restart" >/dev/null || later "bazarr: restart failed"
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
