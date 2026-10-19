# a fake proton-drive cli (0.8.0's `filesystem` verbs and json) for ../proton-mirror.nix and ../proton-bisync.nix: the
# drive is the folder FAKE_DRIVE (/my-files/x is $FAKE_DRIVE/my-files/x), FAKE_LOG gets one line per call. Like the
# real one, an upload keeps the local mtime as the file's claimed modification time (ms) and skips nothing, a download
# does not set the local mtime, trash lets same-named items pile up and delete refuses an ambiguous one, and upload
# takes a local path holding none of * ? [ { as it is, backslashes included, and expands any other as a glob: a
# backslash escapes, braces match nothing (the real one matched no {GUID} folder) and a path matching nothing fails the
# call. Faults:
# FAKE_UPLOAD_FAIL set fails every upload; a call naming a path that matches a glob line of the file FAKE_FAIL_FILE
# fails whole, its cause on stdout under a banner on stderr, as the real one prints some.
{ pkgs }:
pkgs.writeShellApplication {
  name = "proton-drive";
  runtimeInputs = with pkgs; [
    coreutils
    findutils
    gnused
    jq
  ];
  text = ''
    echo "$*" >> "$FAKE_LOG"
    [ "$1" = filesystem ] || { echo "fake: no command $1" >&2; exit 2; }
    verb=$2
    shift 2
    if [ -s "''${FAKE_FAIL_FILE:-/nonexistent}" ]; then
      for arg in "$@"; do
        while IFS= read -r pattern; do
          # shellcheck disable=SC2053 # the pattern is a glob on purpose
          [[ $arg == $pattern ]] && { echo "fake: $arg fails"; echo "=====" >&2; exit 1; }
        done < "$FAKE_FAIL_FILE"
      done
    fi
    local_of() { echo "$FAKE_DRIVE$1"; }
    missing() { echo "$1: Node not found" >&2; exit 1; }
    oks() { jq -n --argjson n "$1" '[range($n) | { ok: true }]'; }
    iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.%3NZ; }
    # one node of `list -j`: a revision uid that changes with the content or the mtime, as a new revision does
    node() { # <path>
      local base mtime sha
      base=$(basename "$1")
      mtime=$(stat -c %.9Y "$1")
      if [ -d "$1" ]; then
        jq -n --arg n "$base" --arg t "$(iso "$mtime")" \
          '{ uid: ("folder-" + $n), name: { ok: true, value: $n }, type: "folder", creationTime: $t, modificationTime: $t }'
      else
        sha=$(sha1sum < "$1" | cut -d' ' -f1)
        jq -n --arg n "$base" --arg t "$(iso "$mtime")" --arg sha "$sha" --argjson size "$(stat -c %s "$1")" \
          --arg rev "rev-$(echo "$sha $mtime" | sha1sum | cut -c1-12)" \
          '{ uid: ("file-" + $n), name: { ok: true, value: $n }, type: "file", creationTime: $t, modificationTime: $t,
             activeRevision: { uid: $rev, claimedSize: $size, claimedModificationTime: $t, claimedDigests: { sha1: $sha } } }'
      fi
    }
    glob_expand() { # <path>: its matches, NUL-separated
      if [[ $1 != *['*?[{']* ]]; then
        if [ -e "$1" ] || [ -L "$1" ]; then printf '%s\0' "$1"; fi
        return
      fi
      local bare=''${1//\\?/}
      if [[ $bare != *[][{}*?]* ]]; then
        local literal
        literal=$(printf '%s' "$1" | sed 's/\\\(.\)/\1/g')
        if [ -e "$literal" ] || [ -L "$literal" ]; then printf '%s\0' "$literal"; fi
      elif [[ $bare != *[{}]* ]]; then
        compgen -G "$1" | tr '\n' '\0'
      fi
    }
    strategies_skip() { while [ $# -gt 0 ]; do case $1 in -f|-d) shift 2 ;; -j|-t) shift ;; *) printf '%s\0' "$1"; shift ;; esac; done; }
    case $verb in
      list)
        [ "$1" = -j ] && shift
        [ -d "$(local_of "$1")" ] || missing "$1"
        find "$(local_of "$1")" -mindepth 1 -maxdepth 1 -print0 | while IFS= read -r -d "" p; do node "$p"; done | jq -s . ;;
      create-folder)
        [ -d "$(local_of "$1")" ] || missing "$1"
        [ ! -e "$(local_of "$1/$2")" ] || { echo "$1/$2 already exists" >&2; exit 1; }
        mkdir "$(local_of "$1/$2")" ;;
      upload)
        [ -z "''${FAKE_UPLOAD_FAIL:-}" ] || { echo "fake: network down" >&2; exit 1; }
        mapfile -d "" -t paths < <(strategies_skip "$@")
        parent=''${paths[-1]}
        unset 'paths[-1]'
        [ -d "$(local_of "$parent")" ] || missing "$parent"
        sources=()
        for pattern in "''${paths[@]}"; do
          mapfile -d "" -t matches < <(glob_expand "$pattern")
          [ "''${#matches[@]}" -gt 0 ] || { echo "No paths matched: $pattern" >&2; exit 1; }
          sources+=("''${matches[@]}")
        done
        failures='[]'
        for src in "''${sources[@]}"; do
          dest=$(local_of "$parent")/$(basename "$src")
          if [ -f "$src" ] && [ ! -L "$src" ]; then cp --preserve=timestamps "$src" "$dest"; continue; fi
          mkdir -p "$dest"
          while IFS= read -r -d "" rel; do
            if [ -d "$src/$rel" ] && [ ! -L "$src/$rel" ]; then mkdir -p "$dest/$rel"
            elif [ -f "$src/$rel" ] && [ ! -L "$src/$rel" ]; then cp --preserve=timestamps "$src/$rel" "$dest/$rel"
            else failures=$(jq -c --arg p "$rel" '. + [{ path: $p, error: "Not a regular file or directory" }]' <<<"$failures")
            fi
          done < <(find "$src" -mindepth 1 -printf '%P\0')
        done
        echo "uploading ..."
        jq -c -n --argjson f "$failures" '{ failures: $f }'
        [ "$failures" = '[]' ] ;;
      download)
        mapfile -d "" -t paths < <(strategies_skip "$@")
        target=''${paths[-1]}
        unset 'paths[-1]'
        for p in "''${paths[@]}"; do [ -e "$(local_of "$p")" ] || missing "$p"; done
        for p in "''${paths[@]}"; do
          rm -rf "''${target:?}/$(basename "$p")"
          cp -r "$(local_of "$p")" "$target/"
        done ;;
      rename)
        [ -e "$(local_of "$1")" ] || missing "$1"
        mv "$(local_of "$1")" "$(dirname "$(local_of "$1")")/$2" ;;
      trash)
        [ "$1" = -j ] && shift
        for p in "$@"; do [ -e "$(local_of "$p")" ] || missing "$p"; done
        for p in "$@"; do
          slot=$FAKE_DRIVE/trash/$(basename "$p")
          mkdir -p "$slot"
          mv "$(local_of "$p")" "$slot/$(find "$slot" -mindepth 1 -maxdepth 1 | wc -l)"
        done
        oks $# ;;
      delete)
        [ "$1" = -j ] && shift
        for p in "$@"; do
          slot=$(local_of "$p")
          [ -d "$slot" ] || { echo "$p: Trashed node not found" >&2; exit 1; }
          [ "$(find "$slot" -mindepth 1 -maxdepth 1 | wc -l)" = 1 ] || { echo "$p: name conflicts with other nodes" >&2; exit 1; }
        done
        for p in "$@"; do rm -rf "$(local_of "$p")"; done
        oks $# ;;
      *) echo "fake: no verb $verb" >&2; exit 2 ;;
    esac
  '';
}
