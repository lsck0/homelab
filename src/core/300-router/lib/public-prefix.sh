#!/usr/bin/env bash
# learn the house's public ipv6 prefix from the fritzbox and publish it as a hosts line coredns serves
#
# The router and the lab are v4-only, so the fritzbox tells the prefix it was delegated: its upnp igd service
# (X_AVM_DE_GetIPv6Prefix of WANIPConnection) answers on the house lan without a login. The ingresses' crowdsec
# whitelist and gate exempt the prefix (modules/traefik). No fritzbox, no prefix or another length: the last
# published prefix stays and the run fails.
#
#   PREFIX_URL      the fritzbox's WANIPConnection control url
#   PREFIX_FILE     the hosts file coredns serves the name from
#   PREFIX_HOST     the name the prefix's network address is served as
#   PREFIX_LENGTH   the length the house is delegated; any other is refused
set -euo pipefail

: "${PREFIX_URL:?the fritzbox upnp control url}" "${PREFIX_FILE:?the hosts file}"
: "${PREFIX_HOST:?the served name}" "${PREFIX_LENGTH:?the delegated length}"
SERVICE=urn:schemas-upnp-org:service:WANIPConnection:1
ACTION=X_AVM_DE_GetIPv6Prefix
TIMEOUT_S=10

envelope="<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" \
s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:$ACTION xmlns:u=\"$SERVICE\"/></s:Body></s:Envelope>"
if ! answer=$(curl -sSf --max-time "$TIMEOUT_S" -H 'Content-Type: text/xml; charset="utf-8"' \
  -H "SoapAction: $SERVICE#$ACTION" --data "$envelope" "$PREFIX_URL"); then
  echo "the fritzbox answers no upnp at $PREFIX_URL: is \"Statusinformationen ueber UPnP uebertragen\" on?" >&2
  exit 1
fi
field() { sed -n "s|.*<$1>\([^<]*\)</$1>.*|\1|p" <<<"$answer"; }
prefix=$(field NewIPv6Prefix)
length=$(field NewPrefixLength)

# a hex group first: never "::", never an empty answer of a house without ipv6
if ! [[ $prefix =~ ^[0-9a-fA-F]{1,4}:[0-9a-fA-F:]*$ ]]; then
  echo "the fritzbox answered no ipv6 prefix: '$prefix'" >&2
  exit 1
fi
if [ "$length" != "$PREFIX_LENGTH" ]; then
  echo "the fritzbox delegates $prefix/$length, the lab expects a /$PREFIX_LENGTH (net.nix publicPrefixLength)" >&2
  exit 1
fi

printf '%s %s\n' "$prefix" "$PREFIX_HOST" > "$PREFIX_FILE.tmp"
mv "$PREFIX_FILE.tmp" "$PREFIX_FILE"
echo "house prefix: $prefix/$length"
