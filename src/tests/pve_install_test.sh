#!/usr/bin/env bash
# scripts/pve-install.sh's own decisions, with the Proxmox and Debian tools stubbed: the lldap realm fails closed
# without the guest's certificate and binds over ldaps with it, and an unavailable package mirror or github leaves
# the host exporter and OSSEC for the next run instead of stopping the converge.
#
# usage: pve_install_test.sh <scripts/pve-install.sh>
set -euo pipefail

T=$(mktemp -d)
CALLS=$T/calls
fail() { echo "FAIL: $*" >&2; exit 1; }
called() { grep -qF -- "$1" "$CALLS" || fail "$2: no call '$1' in: $(cat "$CALLS")"; }
not_called() { ! grep -qF -- "$1" "$CALLS" || fail "$2: unexpected call '$1'"; }

PROXMOX_IP=192.168.178.200 ZONE_BRIDGES=vmbr1 WAKE_ZONES=internal NAS_ID=109 ROOT_PASSWORD=x ROOT_KEYS=key
LLDAP_VMID=101 LLDAP_HOST=10.100.0.101 LLDAP_PORT=6360 LLDAP_BASE_DN=dc=lab LLDAP_ADMIN_GROUP=admins LLDAP_BIND_PASSWORD=y
# shellcheck source=src/scripts/pve-install.sh
. "${1:?pve-install.sh}"
REALM_PASSWORD_FILE=$T/realm/lldap.pw
REALM_CA_FILE=$T/realm/lldap-ca.pem
OSSEC_DIR=$T/ossec
OSSEC_CONTROL=$OSSEC_DIR/bin/ossec-control
CERT=$'-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----'

# the stubs: every call logged; GUEST (vm, lxc, down), ACL, MIRROR and GITHUB (up, down) set what the host answers
log() { echo "$*" >> "$CALLS"; }
qm() {
  log qm "$@"
  case "$1 $GUEST" in
    "status vm") return 0 ;;
    "status "*) return 2 ;;
    "guest vm") jq -n --arg c "$CERT" '{exitcode: 0, "out-data": $c}' ;;
  esac
}
pct() { log pct "$@"; [ "$GUEST" = lxc ] && printf '%s\n' "$CERT" > "$4"; }
pveum() {
  log pveum "$@"
  case "$1 $2" in
    "acl list") if [ "$ACL" = 1 ]; then echo '[{"ugid": "admins-lldap", "path": "/", "roleid": "Administrator"}]'; else echo '[]'; fi ;;
    "realm list"|"group list") echo '[]' ;;
  esac
}
pvesh() { log pvesh "$@"; [ "$1" != get ] || echo '[]'; }
dpkg-query() { echo "not-installed"; }
apt-get() { log apt-get "$@"; [ "$MIRROR" = up ]; }
# -O <file> <url>: the archive github serves, never the pinned one
wget() { log wget "$@"; [ "$GITHUB" = up ] && echo tampered > "${@: -2:1}"; }

reset() { : > "$CALLS"; rm -rf "$T/realm" "$OSSEC_DIR"; GUEST=$1 ACL=${2:-0} MIRROR=${3:-up} GITHUB=${4:-up}; }

# -----------------------------------------------------------------------------
# the realm
# -----------------------------------------------------------------------------
reset down 1
realm_converge 2>"$T/err"
called "pveum acl delete / --groups admins-lldap --roles Administrator" "no certificate: the group's admin goes"
not_called "pveum realm" "no certificate: the realm is left alone"
grep -q "administers nothing" "$T/err" || fail "no certificate: no warning"

reset down 0
realm_converge 2>/dev/null
not_called "acl delete" "no certificate and no grant: nothing to revoke"

for guest in vm lxc; do
  reset "$guest"
  realm_converge
  called "pveum realm add lldap --type ldap --server1 10.100.0.101 --port 6360 --mode ldaps --verify 1 --capath $REALM_CA_FILE" "$guest: ldaps, verified"
  called "--tfa type=oath" "$guest: a second factor"
  called "pveum acl modify / --groups admins-lldap --roles Administrator" "$guest: the group administers"
  [ "$(cat "$REALM_CA_FILE")" = "$CERT" ] || fail "$guest: the realm does not trust the guest's own certificate"
done

# -----------------------------------------------------------------------------
# outages outside the lab
# -----------------------------------------------------------------------------
reset vm 0 down
! packages_install jq || fail "mirror down: packages_install reports success"

reset vm 0 down
ossec_converge 2>"$T/err" || fail "mirror down: ossec_converge stops the converge"
grep -q "unavailable" "$T/err" || fail "mirror down: no warning"
not_called wget "mirror down: github fetched anyway"

reset vm 0 up down
ossec_converge 2>"$T/err" || fail "github down: ossec_converge stops the converge"
grep -q "unavailable" "$T/err" || fail "github down: no warning"
[ ! -e "$OSSEC_DIR/etc" ] || fail "github down: configured an OSSEC that is not installed"

# a tampered archive is no outage: it stops the run
reset vm 0 up up
if (ossec_converge 2>"$T/err"); then fail "a tampered archive was installed"; fi
grep -q "does not match its pinned sha256" "$T/err" || fail "a tampered archive: no error"

echo "pve-install: all cases pass"
