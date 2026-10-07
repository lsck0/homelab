# shellcheck shell=bash
# sourced by the scripts that log in to the Proxmox host (sync.sh, init.sh, deinit.sh): the pinned host key, the
# terraform connection vars, the ssh command built from both, and the host's converge. The caller sets SRC and
# sources lib/tools.sh, and lib/secrets.sh for proxmox_converge.
#
#   . "$SRC/scripts/lib/proxmox.sh"
#   proxmox_tfvars_load <temp>        # PROXMOX_TFVARS: the tfvars decrypted into <temp> (the caller removes it);
#                                     # returns 1 when there are none
#   proxmox_tfvar_read <key>          # one value on stdout, empty when unset or no tfvars are loaded
#   proxmox_login_load                # PROXMOX_SSH_PORT, PROXMOX_SSH_USER from the tfvars
#   proxmox_pinned_host <ip> <port>   # the host's name in known_hosts
#   proxmox_ssh_init <ip> <port> <password>   # PROXMOX_SSH (array); exits 1 unless the host key is pinned
#   proxmox_ca_write <file>           # the cluster CA (site.json) that the api's certificate chains to
#   proxmox_converge <lab export> <bulk disk>   # scripts/pve-install.sh on the host, then the new tokens stored

# every host key of the lab: Proxmox's pinned by init.sh --pin, the guests' written by sync.sh
LAB_KNOWN_HOSTS="$SRC/generated/known_hosts"
# the machine and the house network, written by init.sh
LAB_SITE="$SRC/generated/site.json"
LAB_ZONES="$SRC/generated/zones.json"
PROXMOX_TFVARS_ENC="$SRC/terraform/terraform.tfvars.sops.json"
PROXMOX_SSH_PORT_DEFAULT=22
PROXMOX_SSH_USER_DEFAULT=root
# a dead connection ends the ssh after this, instead of hanging the run
PROXMOX_SSH_ALIVE_INTERVAL_S=15
PROXMOX_SSH_ALIVE_COUNT=4
# pve-install.sh leaves the secret of each api token it had to create here, one file per role
PROXMOX_TOKEN_DIR=/root/homelab-tokens
PROXMOX_TFVARS=""

proxmox_tfvars_load() {
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
  PROXMOX_SSH=(ssh -p "$port" -o UserKnownHostsFile="$LAB_KNOWN_HOSTS" -o StrictHostKeyChecking=yes
    -o ServerAliveInterval="$PROXMOX_SSH_ALIVE_INTERVAL_S" -o ServerAliveCountMax="$PROXMOX_SSH_ALIVE_COUNT")
  [ -n "$password" ] || return 0
  tools_require sshpass
  # sshpass -e reads it from the environment: -p would show it in ps
  export SSHPASS="$password"
  PROXMOX_SSH=(sshpass -e "${PROXMOX_SSH[@]}")
}

proxmox_ca_write() {
  jq -re '.proxmoxCa // empty' "$LAB_SITE" > "$1" \
    || { echo "ERROR: no proxmoxCa in $LAB_SITE: run src/scripts/init.sh." >&2; exit 1; }
}

# proxmox_token_store <role> <token id>=<secret>: where each consumer reads its token
proxmox_token_store() {
  local role=$1 id=${2%%=*} secret=${2#*=} tfvars
  case "$role" in
    terraform)
      tfvars=$(jq -n --arg id "$id" --arg secret "$secret" '{proxmox_api_token_id: $id, proxmox_api_token_secret: $secret}')
      [ -z "$PROXMOX_TFVARS" ] || tfvars=$(jq --argjson new "$tfvars" '. + $new' "$PROXMOX_TFVARS")
      printf '%s\n' "$tfvars" | "$SRC/scripts/sops-encrypt.sh" "$PROXMOX_TFVARS_ENC"
      [ -z "$PROXMOX_TFVARS" ] || printf '%s\n' "$tfvars" > "$PROXMOX_TFVARS" ;;
    homepage) secrets_set proxmox-user "$id"; secrets_set proxmox-pass "$secret" ;;
    wake-*) secrets_set "proxmox-wake-token-${role#wake-}" "$2" ;;
    *) echo "ERROR: Proxmox created a token for $role, which nothing reads." >&2; exit 1 ;;
  esac
  echo ">>> Proxmox: stored the new $role api token"
}

proxmox_converge() {
  local export=$1 bulk_disk=$2 host ldap bind_password root_password stored=() role value
  host="$PROXMOX_SSH_USER@$(jq -r .lan.proxmox "$LAB_SITE")"
  ldap=$(jq -ce '.ldap | select(.vmid and .host and .port and .baseDn and .adminGroup)' "$export") \
    || { echo "ERROR: the lab export names no ldaps listener for the realm (modules/lab-export.nix, ldap)." >&2; exit 1; }
  bind_password=$(secrets_get lldap-proxmox-bind-password)
  root_password=$(secrets_get proxmox-root-pass)
  [ -n "$bind_password" ] && [ -n "$root_password" ] \
    || { echo "ERROR: lldap-proxmox-bind-password or proxmox-root-pass is empty: run src/scripts/secrets-sync.sh --apply." >&2; exit 1; }
  {
    printf '%s=%q\n' \
      PROXMOX_IP "$(jq -r .lan.proxmox "$LAB_SITE")" \
      ZONE_BRIDGES "$(jq -r '[.[].bridge] | join(" ")' "$LAB_ZONES")" \
      WAKE_ZONES "$(jq -r '[.zones | to_entries[] | select(.value.ingress != null) | .key] | join(" ")' "$export")" \
      GPU_IDS "$(jq -r '.gpu.functionIds // [] | join(",")' "$LAB_SITE")" \
      BULK_DISK "$bulk_disk" \
      NAS_ID "$(jq -r .routes.nas.vmid "$export")" \
      LLDAP_VMID "$(jq -r .vmid <<<"$ldap")" \
      LLDAP_HOST "$(jq -r .host <<<"$ldap")" \
      LLDAP_PORT "$(jq -r .port <<<"$ldap")" \
      LLDAP_BASE_DN "$(jq -r .baseDn <<<"$ldap")" \
      LLDAP_ADMIN_GROUP "$(jq -r .adminGroup <<<"$ldap")" \
      LLDAP_BIND_PASSWORD "$bind_password" \
      ROOT_PASSWORD "$root_password" \
      ROOT_KEYS "$(cat "$SRC"/lab/keys/*.pub)"
    cat "$SRC/scripts/pve-install.sh"
  } | "${PROXMOX_SSH[@]}" "$host" "bash -s" || { echo "ERROR: the Proxmox host did not converge (above)." >&2; exit 1; }

  while read -r role value; do
    proxmox_token_store "$role" "$value"
    stored+=("$PROXMOX_TOKEN_DIR/$role")
  done < <("${PROXMOX_SSH[@]}" -n "$host" \
    "for f in $PROXMOX_TOKEN_DIR/*; do [ -f \"\$f\" ] && echo \"\${f##*/} \$(cat \"\$f\")\"; done; true")
  [ "${#stored[@]}" = 0 ] || "${PROXMOX_SSH[@]}" -n "$host" "rm -f ${stored[*]}"
}
