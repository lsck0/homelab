#!/usr/bin/env bash
# lib/crowdsec-home-whitelist.sh with getent and podman faked: a table of what the router serves, each run checked
# for the whitelist it leaves, whether crowdsec was told to reload, and which bans it lifted
#
# usage: crowdsec_home_whitelist_test.sh <lib/crowdsec-home-whitelist.sh>
set -euo pipefail

SCRIPT=${1:?crowdsec-home-whitelist.sh}
T=$(mktemp -d)
fail() { echo "FAIL: $*" >&2; exit 1; }

export PUBLIC_HOST=wg.lsck0.dev PUBLIC_PREFIX_HOST=house-prefix.lsck0.dev PUBLIC_PREFIX_LENGTH=56
export CROWDSEC_CONFIG=$T/config FAKE=$T/fake
OUT=$CROWDSEC_CONFIG/parsers/s02-enrich/home-whitelist.yaml
mkdir -p "$FAKE" "$T/bin"

# fake <command>: the script on stdin, run by this bash (the sandbox has no /usr/bin/env)
fake() { { echo "#!$BASH"; cat; } > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
# getent: ahostsv4 answers the A record, hosts the AAAA record or else the A record, as glibc does
fake getent <<'EOF'
case "$1" in
  ahostsv4) [ -s "$FAKE/$2.a" ] && printf '%s      STREAM %s\n' "$(cat "$FAKE/$2.a")" "$2" ;;
  hosts) if [ -s "$FAKE/$2.aaaa" ]; then printf '%s %s\n' "$(cat "$FAKE/$2.aaaa")" "$2";
         else [ -s "$FAKE/$2.a" ] && printf '%s  %s\n' "$(cat "$FAKE/$2.a")" "$2"; fi ;;
  *) exit 1 ;;
esac
EOF
# podman: every call recorded
fake podman <<'EOF'
echo "$*" >> "$FAKE/podman"
EOF
export PATH=$T/bin:$PATH

# serve <v4 or -> <v6 network or -> <v4 of the prefix name or ->: what the router's coredns answers
serve() {
  rm -f "$FAKE"/*.a "$FAKE"/*.aaaa
  [ "$1" = - ] || echo "$1" > "$FAKE/$PUBLIC_HOST.a"
  [ "$2" = - ] || echo "$2" > "$FAKE/$PUBLIC_PREFIX_HOST.aaaa"
  [ "$3" = - ] || echo "$3" > "$FAKE/$PUBLIC_PREFIX_HOST.a"
}
# expect <case> <ip or -> <cidr or -> <reloaded: yes|no> <lifted bans, space separated>
expect() {
  local ip cidr podman_calls
  if [ "$2" = - ]; then
    [ ! -e "$OUT" ] || fail "$1: a whitelist was written"
  else
    ip=$(yq -r '.whitelist.ip | join(" ")' "$OUT")
    cidr=$(yq -r '.whitelist.cidr // [] | join(" ")' "$OUT")
    [ "$ip" = "$2" ] || fail "$1: ip '$ip', expected '$2'"
    [ "$cidr" = "${3#-}" ] || fail "$1: cidr '$cidr', expected '${3#-}'"
  fi
  podman_calls=$(cat "$FAKE/podman" 2>/dev/null || true)
  if [ "$4" = yes ]; then
    grep -qx "kill --signal HUP crowdsec" <<<"$podman_calls" || fail "$1: crowdsec was not reloaded"
  else
    ! grep -q "kill" <<<"$podman_calls" || fail "$1: crowdsec was reloaded"
  fi
  local lifted
  lifted=$(sed -n 's/^exec crowdsec cscli decisions delete //p' <<<"$podman_calls" | tr '\n' ';')
  [ "$lifted" = "$5" ] || fail "$1: lifted '$lifted', expected '$5'"
  echo "ok: $1"
}
# run: one pass of the script, its podman calls alone recorded
run() { rm -f "$FAKE/podman"; bash "$SCRIPT" >/dev/null; }

serve - 2003:f7:8f41:6700:: -; run
expect "no v4 address yet: nothing written, nothing lifted" - - no ""

serve 203.0.113.9 - -; run
expect "no prefix yet: the v4 address alone" 203.0.113.9 - yes "--ip 203.0.113.9;"

serve 203.0.113.9 2003:f7:8f41:6700:: -; run
expect "the prefix learned" 203.0.113.9 2003:f7:8f41:6700::/56 yes \
  "--ip 203.0.113.9;--range 2003:f7:8f41:6700::/56 --contained;"

run
expect "unchanged: no reload, bans lifted again" 203.0.113.9 2003:f7:8f41:6700::/56 no \
  "--ip 203.0.113.9;--range 2003:f7:8f41:6700::/56 --contained;"

serve 198.51.100.4 - -; run
expect "v4 rotated, prefix unknown: the prefix kept" 198.51.100.4 2003:f7:8f41:6700::/56 yes \
  "--ip 198.51.100.4;--range 2003:f7:8f41:6700::/56 --contained;"

serve 198.51.100.4 - 198.51.100.4; run
expect "the prefix name answering v4 only is no prefix: kept" 198.51.100.4 2003:f7:8f41:6700::/56 no \
  "--ip 198.51.100.4;--range 2003:f7:8f41:6700::/56 --contained;"

serve 198.51.100.4 2003:f7:8f42:1200:: -; run
expect "the prefix rotated" 198.51.100.4 2003:f7:8f42:1200::/56 yes \
  "--ip 198.51.100.4;--range 2003:f7:8f42:1200::/56 --contained;"

serve - - -; run
expect "nothing resolves: the file as it is, nothing lifted" 198.51.100.4 2003:f7:8f42:1200::/56 no ""
