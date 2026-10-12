#!/usr/bin/env bash
# lib/public-prefix.sh with curl faked as the fritzbox: a table of its answers, each run checked for its exit, the
# hosts line it leaves and the upnp action it asked for
#
# usage: public_prefix_test.sh <lib/public-prefix.sh>
set -euo pipefail

SCRIPT=${1:?public-prefix.sh}
T=$(mktemp -d)
fail() { echo "FAIL: $*" >&2; exit 1; }

export PREFIX_URL=http://192.168.178.1:49000/igdupnp/control/WANIPConn1 PREFIX_FILE=$T/prefix6
export PREFIX_HOST=house-prefix.lsck0.dev PREFIX_LENGTH=56 FAKE=$T/fake
mkdir -p "$FAKE" "$T/bin"
# curl: its arguments recorded; the fritzbox's answer, or a refused connection (curl's 7) without one
{ echo "#!$BASH"; cat; } > "$T/bin/curl" <<'EOF'
printf '%s\n' "$@" > "$FAKE/curl"
[ -f "$FAKE/answer" ] || exit 7
cat "$FAKE/answer"
EOF
chmod +x "$T/bin/curl"
export PATH=$T/bin:$PATH

# answer <prefix> <length>: the fritzbox's X_AVM_DE_GetIPv6Prefix response, as it sends it
answer() {
  cat > "$FAKE/answer" <<EOF
<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body>
<u:X_AVM_DE_GetIPv6PrefixResponse xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1">
<NewIPv6Prefix>$1</NewIPv6Prefix>
<NewPrefixLength>$2</NewPrefixLength>
<NewValidLifetime>14035</NewValidLifetime>
<NewPreferedLifetime>1435</NewPreferedLifetime>
</u:X_AVM_DE_GetIPv6PrefixResponse>
</s:Body>
</s:Envelope>
EOF
}
# expect <case> <exit: 0|1> <hosts line or -> <message the run prints or ->
expect() {
  local rc=0 output
  output=$(bash "$SCRIPT" 2>&1) || rc=$?
  [ "$rc" = "$2" ] || fail "$1: exit $rc, expected $2: $output"
  if [ "$3" = - ]; then
    [ ! -e "$PREFIX_FILE" ] || fail "$1: a prefix was published: $(cat "$PREFIX_FILE")"
  else
    [ "$(cat "$PREFIX_FILE")" = "$3" ] || fail "$1: published '$(cat "$PREFIX_FILE")', expected '$3'"
  fi
  [ "$4" = - ] || grep -qF "$4" <<<"$output" || fail "$1: no '$4' in: $output"
  grep -qx "SoapAction: urn:schemas-upnp-org:service:WANIPConnection:1#X_AVM_DE_GetIPv6Prefix" "$FAKE/curl" \
    || fail "$1: the upnp action was not asked for"
  grep -qx "$PREFIX_URL" "$FAKE/curl" || fail "$1: the fritzbox was not asked"
  echo "ok: $1"
}

expect "upnp off: nothing published, the setting named" 1 - "Statusinformationen ueber UPnP"
answer "" ""
expect "a house without ipv6: nothing published" 1 - "no ipv6 prefix"
answer 2003:f7:8f41:6700:: 56
expect "the prefix published" 0 "2003:f7:8f41:6700:: $PREFIX_HOST" -
answer "::" 56
expect "the unspecified address: the last prefix kept" 1 "2003:f7:8f41:6700:: $PREFIX_HOST" "no ipv6 prefix"
answer 2003:f7:8f41:6700:: 64
expect "another length: the last prefix kept" 1 "2003:f7:8f41:6700:: $PREFIX_HOST" "expects a /56"
answer 2003:f7:8f42:1200:: 56
expect "the prefix rotated" 0 "2003:f7:8f42:1200:: $PREFIX_HOST" -
rm "$FAKE/answer"
expect "the fritzbox gone: the last prefix kept" 1 "2003:f7:8f42:1200:: $PREFIX_HOST" "answers no upnp"
