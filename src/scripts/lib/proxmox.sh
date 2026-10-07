# shellcheck shell=bash
# sourced by the scripts that log in to the Proxmox host (sync.sh, init.sh, deinit.sh): the pinned host key, the
# terraform connection vars, and the ssh command built from both. The caller sets SRC and sources lib/tools.sh.
#
#   . "$SRC/scripts/lib/proxmox.sh"
#   proxmox_tfvars_load <temp>        # PROXMOX_TFVARS: the plain tfvars, else the encrypted ones decrypted into <temp>
#                                     # (the caller removes it); returns 1 when neither exists
#   proxmox_tfvar_read <key>          # one value on stdout, empty when unset or no tfvars are loaded
#   proxmox_login_load                # PROXMOX_SSH_PORT, PROXMOX_SSH_USER from the tfvars
#   proxmox_pinned_host <ip> <port>   # the host's name in known_hosts
#   proxmox_ssh_init <ip> <port> <password>   # PROXMOX_SSH (array); exits 1 unless the host key is pinned

# every host key of the lab: Proxmox's pinned by init.sh --pin, the guests' written by sync.sh
LAB_KNOWN_HOSTS="$SRC/generated/known_hosts"
PROXMOX_TFVARS_PLAIN="$SRC/terraform/terraform.tfvars"
PROXMOX_TFVARS_ENC="$SRC/terraform/terraform.tfvars.sops.json"
PROXMOX_SSH_PORT_DEFAULT=22
PROXMOX_SSH_USER_DEFAULT=root
PROXMOX_TFVARS=""

proxmox_tfvars_load() {
  if [ -f "$PROXMOX_TFVARS_PLAIN" ]; then PROXMOX_TFVARS=$PROXMOX_TFVARS_PLAIN; return 0; fi
  [ -f "$PROXMOX_TFVARS_ENC" ] || return 1
  # explicit exits: a caller testing the return value turns errexit off in here
  sops --decrypt "$PROXMOX_TFVARS_ENC" > "$1" || { echo "ERROR: cannot decrypt $PROXMOX_TFVARS_ENC" >&2; exit 1; }
  jq empty "$1" >/dev/null || { echo "ERROR: the decrypted $PROXMOX_TFVARS_ENC is no json" >&2; exit 1; }
  PROXMOX_TFVARS=$1
}

proxmox_tfvar_read() {
  [ -n "$PROXMOX_TFVARS" ] || return 0
  jq -r --arg key "$1" 'if has($key) and .[$key] != null then .[$key] else empty end' "$PROXMOX_TFVARS"
}

# shellcheck disable=SC2034 # the login is the caller's to use
proxmox_login_load() {
  PROXMOX_SSH_PORT=$(proxmox_tfvar_read proxmox_ssh_port); : "${PROXMOX_SSH_PORT:=$PROXMOX_SSH_PORT_DEFAULT}"
  PROXMOX_SSH_USER=$(proxmox_tfvar_read proxmox_ssh_user); : "${PROXMOX_SSH_USER:=$PROXMOX_SSH_USER_DEFAULT}"
}

proxmox_pinned_host() {
  if [ "$2" = "$PROXMOX_SSH_PORT_DEFAULT" ]; then echo "$1"; else echo "[$1]:$2"; fi
}

proxmox_ssh_init() {
  local ip=$1 port=$2 password=${3:-}
  ssh-keygen -F "$(proxmox_pinned_host "$ip" "$port")" -f "$LAB_KNOWN_HOSTS" >/dev/null 2>&1 || {
    echo "ERROR: Proxmox's host key is not pinned in src/generated/known_hosts." >&2
    echo "       Run src/scripts/init.sh --pin $ip and compare the fingerprint on the Proxmox console." >&2
    exit 1
  }
  PROXMOX_SSH=(ssh -p "$port" -o UserKnownHostsFile="$LAB_KNOWN_HOSTS" -o StrictHostKeyChecking=yes)
  [ -n "$password" ] || return 0
  tools_require sshpass
  # sshpass -e reads it from the environment: -p would show it in ps
  export SSHPASS="$password"
  PROXMOX_SSH=(sshpass -e "${PROXMOX_SSH[@]}")
}
