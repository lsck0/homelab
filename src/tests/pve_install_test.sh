#!/usr/bin/env bash
# scripts/pve-install.sh's own decisions, with the Proxmox and Debian tools stubbed: the lldap realm fails closed
# without the guest's certificate and binds over ldaps with it; pvestatd's lvm config is written whole, read back by
# lvm's own parser and installed only when it rejects every name of the bulk pv; openipmi is masked only on a host
# without a bmc; the node's name moves to its lan address only on a
# standalone host that holds it, and the api certificate is re-signed only when it does not name that address; an
# unavailable package mirror or github leaves the host exporter and OSSEC for the next run instead of stopping the
# converge.
#
# usage: pve_install_test.sh <scripts/pve-install.sh>
set -euo pipefail

T=$(mktemp -d)
CALLS=$T/calls
fail() { echo "FAIL: $*" >&2; exit 1; }
called() { grep -qF -- "$1" "$CALLS" || fail "$2: no call '$1' in: $(cat "$CALLS")"; }
not_called() { ! grep -qF -- "$1" "$CALLS" || fail "$2: unexpected call '$1'"; }

ACTION=converge TOKEN_DIR=$T/tokens TEMPLATES="$T/nixos.img $T/nixos-homelab.tar.xz"
PROXMOX_IP=192.168.178.200 ZONE_BRIDGES=vmbr1 WAKE_ZONES=internal NAS_ID=109 ROOT_PASSWORD=x ROOT_KEYS=key
LLDAP_VMID=101 LLDAP_HOST=10.100.0.101 LLDAP_PORT=6360 LLDAP_BASE_DN=dc=lab LLDAP_ADMIN_GROUP=admins LLDAP_BIND_PASSWORD=y
LLDAP_CERT=/var/lib/lldap/ldaps-cert.pem LLDAP_BIND_USER=proxmox-bind
# shellcheck source=src/scripts/pve-install.sh
. "${1:?pve-install.sh}"
REALM_PASSWORD_FILE=$T/realm/lldap.pw
REALM_CA_FILE=$T/realm/lldap-ca.pem
OSSEC_DIR=$T/ossec
OSSEC_CONTROL=$OSSEC_DIR/bin/ossec-control
NETWORK_INTERFACES=$T/interfaces
IPMI_DMI_ENTRY=$T/dmi-38-0
PVESTATD_LVM_DIR=$T/lvm-pvestatd
PVESTATD_DROPIN_DIR=$T/pvestatd.service.d
DISK_BY_ID_DIR=$T/by-id
BULK_PV=$T/dev/sdb
HOSTS_FILE=$T/hosts
COROSYNC_CONF=$T/corosync.conf
API_CERT=$T/pve-ssl.pem
API_CUSTOM_CERT=$T/pveproxy-ssl.pem
NODE=luca-server
INSTALLER_IP=192.168.178.2
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
pvesh() {
  log pvesh "$@"
  case "$1 $2" in
    "get /cluster/firewall/rules") echo '[{"pos": 0}, {"pos": 1}, {"pos": 2}]' ;;
    "get "*) echo '[]' ;;
  esac
}
ifreload() { log ifreload "$@"; }
dpkg-query() { echo "not-installed"; }
apt-get() { log apt-get "$@"; [ "$MIRROR" = up ]; }
# -O <file> <url>: the archive github serves, never the pinned one
wget() { log wget "$@"; [ "$GITHUB" = up ] && echo tampered > "${@: -2:1}"; }

# lvm: BULK_PV is the bulk group's pv; under an LVM_SYSTEM_DIR it shows the groups that config's filter lets through,
# the pve group while LVM_PVE is 1, the bulk one unless the filter names the pv and LVM_FILTERS is 1
pvs() {
  if [ -z "${LVM_SYSTEM_DIR:-}" ]; then printf '  %s bulk\n  /dev/nvme0n1p3 pve\n' "$BULK_PV"; return 0; fi
  if [ "$LVM_PVE" = 1 ]; then echo "  pve"; fi
  if [ "$LVM_FILTERS" = 0 ] || ! grep -qF "r|^$BULK_PV\$|" "$LVM_SYSTEM_DIR/lvm.conf"; then echo "  bulk"; fi
}

# the node's address: HOSTS_FILE is what the resolver reads, LOCAL_IP what the interfaces hold, CERT_IP what the api
# certificate names; pvecm signs the address the name resolves to
hostname() { echo "$NODE"; }
getent() { awk -v n="$NODE" '{ for (i = 2; i <= NF; i++) if ($i == n) { print $1 "  STREAM " n; exit } }' "$HOSTS_FILE"; }
ip() { echo "2: vmbr0    inet $LOCAL_IP/24 brd 192.168.178.255 scope global vmbr0"; }
openssl() { printf 'X509v3 Subject Alternative Name: \n    IP Address:127.0.0.1, DNS:localhost, IP Address:%s\n' "$CERT_IP"; }
pvecm() { log pvecm "$@"; CERT_IP=$(getent); CERT_IP=${CERT_IP%% *}; }
# IPMI_STATE: what is-enabled prints for the openipmi unit; IPMI_FAILED 1 when it failed
systemctl() {
  log systemctl "$@"
  case "$*" in
    "is-enabled "*) echo "$IPMI_STATE" ;;
    "-q is-failed "*) [ "$IPMI_FAILED" = 1 ] ;;
  esac
}


reset() { : > "$CALLS"; rm -rf "$T/realm" "$OSSEC_DIR"; GUEST=$1 ACL=${2:-0} MIRROR=${3:-up} GITHUB=${4:-up}; }

# address_reset <the name's address> <the interfaces' address> <the certificate's address>
address_reset() {
  : > "$CALLS"
  rm -f "$COROSYNC_CONF" "$API_CUSTOM_CERT"
  printf '127.0.0.1 localhost\n%s %s.lan %s\n' "$1" "$NODE" "$NODE" > "$HOSTS_FILE"
  LOCAL_IP=$2 CERT_IP=$3
}

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
# the node's address and the api certificate
# -----------------------------------------------------------------------------
address_reset "$PROXMOX_IP" "$PROXMOX_IP" "$PROXMOX_IP"
hosts_converge
api_cert_converge
not_called "systemctl restart pve-cluster" "converged: pmxcfs restarted"
not_called pvecm "converged: the certificate re-signed"

address_reset "$INSTALLER_IP" "$PROXMOX_IP" "$INSTALLER_IP"
hosts_converge >/dev/null
api_cert_converge >/dev/null
grep -qx "$PROXMOX_IP $NODE.lan $NODE" "$HOSTS_FILE" || fail "moved address: the name still resolves to $(getent)"
called "systemctl restart pve-cluster" "moved address: pmxcfs keeps the old address"
called "pvecm updatecerts --force" "moved address: the certificate is not re-signed"
called "systemctl restart pveproxy" "moved address: pveproxy serves the old certificate"
[ "$CERT_IP" = "$PROXMOX_IP" ] || fail "moved address: the certificate names $CERT_IP"

address_reset "$INSTALLER_IP" "$INSTALLER_IP" "$INSTALLER_IP"
if (hosts_converge 2>"$T/err"); then fail "an address no interface holds was written"; fi
grep -q "no interface" "$T/err" || fail "an address no interface holds: no error"
grep -qx "$INSTALLER_IP $NODE.lan $NODE" "$HOSTS_FILE" || fail "an address no interface holds: $HOSTS_FILE changed"

address_reset "$INSTALLER_IP" "$PROXMOX_IP" "$INSTALLER_IP"
touch "$COROSYNC_CONF"
if (hosts_converge 2>"$T/err"); then fail "a cluster node's address was changed"; fi
not_called "systemctl restart pve-cluster" "a cluster node: pmxcfs restarted"

address_reset "$PROXMOX_IP" "$PROXMOX_IP" "$INSTALLER_IP"
touch "$API_CUSTOM_CERT"
if (api_cert_converge 2>"$T/err"); then fail "an uploaded certificate was kept"; fi
grep -q "pvenode cert delete" "$T/err" || fail "an uploaded certificate: no error"
not_called pvecm "an uploaded certificate: re-signed anyway"

# -----------------------------------------------------------------------------
# pvestatd's lvm view
# -----------------------------------------------------------------------------
# lvm_reset <filters> <pve seen>: the bulk pv with two by-id names, one unrelated disk
lvm_reset() {
  : > "$CALLS"
  LVM_FILTERS=$1 LVM_PVE=$2
  rm -rf "${T:?}/dev" "$DISK_BY_ID_DIR"
  mkdir -p "$T/dev" "$DISK_BY_ID_DIR"
  touch "$BULK_PV" "$T/dev/nvme0n1"
  ln -s ../dev/sdb "$DISK_BY_ID_DIR/ata-WDC_WD40-1"
  ln -s ../dev/sdb "$DISK_BY_ID_DIR/wwn-0x50014ee2"
  ln -s ../dev/nvme0n1 "$DISK_BY_ID_DIR/nvme-Samsung_980"
}
conf_filter() { LVM_SYSTEM_DIR=$PVESTATD_LVM_DIR lvmconfig devices/global_filter 2>/dev/null; }

rm -rf "$PVESTATD_LVM_DIR" "$PVESTATD_DROPIN_DIR"
lvm_reset 1 1
pvestatd_lvm_converge >/dev/null 2>&1
for name in "$BULK_PV" "$DISK_BY_ID_DIR/ata-WDC_WD40-1" "$DISK_BY_ID_DIR/wwn-0x50014ee2"; do
  [[ "$(conf_filter)" == *"\"r|^$name\$|\""* ]] || fail "lvm reads no reject of $name from: $(conf_filter)"
done
[[ "$(conf_filter)" == *'"r|/dev/zd.*|","r|/dev/rbd.*|"'* ]] || fail "pve-manager's own rejects are gone: $(conf_filter)"
[[ "$(conf_filter)" != *nvme* ]] || fail "another disk is rejected: $(conf_filter)"
grep -qx "Environment=LVM_SYSTEM_DIR=$PVESTATD_LVM_DIR" "$PVESTATD_DROPIN_DIR/homelab-no-hdd.conf" || fail "pvestatd runs without its lvm view"
called "systemctl restart pvestatd" "a new lvm view: pvestatd not restarted"

lvm_reset 1 1
pvestatd_lvm_converge >/dev/null 2>&1
not_called "restart pvestatd" "an unchanged lvm view: pvestatd restarted"
[ ! -e "$PVESTATD_LVM_DIR.new" ] || fail "an unchanged lvm view: the candidate stays"

lvm_reset 1 1
ln -s ../dev/sdb "$DISK_BY_ID_DIR/ata-WDC_WD40-1-part1-alias"
pvestatd_lvm_converge >/dev/null 2>&1
[[ "$(conf_filter)" == *"ata-WDC_WD40-1-part1-alias"* ]] || fail "a new name of the bulk pv is not rejected"
not_called "restart pvestatd" "a changed filter: pvestatd restarted (lvm reads its config per call)"

installed=$(cat "$PVESTATD_LVM_DIR/lvm.conf")
for case in "0:1:still sees the bulk pv" "1:0:loses the pve group"; do
  IFS=: read -r filters pve what <<<"$case"
  lvm_reset "$filters" "$pve"
  if (pvestatd_lvm_converge >/dev/null 2>"$T/err"); then fail "an lvm view that $what was installed"; fi
  grep -q ERROR "$T/err" || fail "an lvm view that $what: no error"
  [ "$(cat "$PVESTATD_LVM_DIR/lvm.conf")" = "$installed" ] || fail "an lvm view that $what replaced the last good one"
  [ ! -e "$PVESTATD_LVM_DIR.new" ] || fail "an lvm view that $what: the candidate stays"
done

lvm_reset 1 1
if (PVE_LVM_REJECTS=('r|"|'); pvestatd_lvm_converge >/dev/null 2>"$T/err"); then fail "an lvm.conf lvm cannot parse was installed"; fi
grep -q "cannot read" "$T/err" || fail "an lvm.conf lvm cannot parse: no error"
[ "$(cat "$PVESTATD_LVM_DIR/lvm.conf")" = "$installed" ] || fail "an lvm.conf lvm cannot parse replaced the last good one"

# -----------------------------------------------------------------------------
# the host's own units
# -----------------------------------------------------------------------------
: > "$CALLS"; rm -f "$IPMI_DMI_ENTRY"; IPMI_STATE=enabled IPMI_FAILED=1
ipmi_converge >/dev/null
called "systemctl mask --now openipmi.service" "no bmc: openipmi still starts"
called "systemctl reset-failed openipmi.service" "no bmc: openipmi stays failed"
: > "$CALLS"; IPMI_STATE=masked IPMI_FAILED=0
ipmi_converge >/dev/null
not_called "mask" "masked: masked again"
: > "$CALLS"; touch "$IPMI_DMI_ENTRY"; IPMI_STATE=enabled
ipmi_converge >/dev/null
not_called "mask" "a bmc: openipmi masked"

# -----------------------------------------------------------------------------
# teardown
# -----------------------------------------------------------------------------
reset down
printf 'auto vmbr0\niface vmbr0 inet static\n\nauto vmbr1\niface vmbr1 inet manual\n\n' > "$NETWORK_INTERFACES"
touch "$T/nixos.img" "$T/nixos-homelab.tar.xz"
teardown >/dev/null
called "pvesh set /cluster/firewall/options --enable 0" "teardown: the datacenter firewall stays on"
[ "$(grep -o 'pvesh delete /cluster/firewall/rules/[0-9]*' "$CALLS" | tr -dc '0-9')" = 210 ] \
  || fail "teardown: the cluster rules are not deleted last position first: $(cat "$CALLS")"
[ ! -e "$T/nixos.img" ] && [ ! -e "$T/nixos-homelab.tar.xz" ] || fail "teardown: the templates stay"
grep -qx 'auto vmbr0' "$NETWORK_INTERFACES" || fail "teardown: the installer's bridge went"
! grep -q vmbr1 "$NETWORK_INTERFACES" || fail "teardown: a zone bridge stays"
called "apt-get purge -y prometheus-node-exporter" "teardown: the exporter stays"

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
