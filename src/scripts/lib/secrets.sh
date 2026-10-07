# shellcheck shell=bash
# sourced by the scripts that read or write secrets: the admin recipients, the layout's plan (modules/secrets.nix),
# and one secret by name from whichever file the layout puts it in. The caller sets SRC and SOPS_AGE_KEY_FILE.
#
#   . "$SRC/scripts/lib/secrets.sh"
#   secrets_admins_load               # ADMIN_RECIPIENTS (array), ADMIN_SORTED; exits 1 unless the run's key is one
#   secrets_plan_load <out> [<file>]  # the plan as json into <out>, from <file> or the flake; exits 1 on a problem
#   secrets_get <name>                # the value on stdout
#   secrets_set <name> <value>        # the value goes to sops on stdin, never into argv
#   secrets_age_key_link <link>       # <link> -> the dotfiles' age.txt, unless <link> is a file of its own

SECRETS_ADMIN_FILE="$SRC/secrets/admins.txt"
# the dotfiles checkout; its git-crypt secrets hold the admin age key (age.txt), the deploy ssh key and the ntfy token
SECRETS_DOTFILES="${DOTFILES:-$HOME/projects/arch-dotfiles}"
# env DOTFILES_SECRETS overrides it, e.g. a checkout still on the pre-modules layout (configs/secrets)
SECRETS_DOTFILES_DIR="${DOTFILES_SECRETS:-$SECRETS_DOTFILES/secrets}"
SECRETS_RECIPIENT_PATTERN='^age1[0-9a-z]+$'
SECRETS_ATTR="legacyPackages.x86_64-linux.secrets"
# the layout's names (modules/secrets.nix): the folders holding host homes, and the files a home holds
# shellcheck disable=SC2034 # read by the scripts sourcing this
{
  SECRETS_HOME_DIRS=(instances apps generated/nodes)
  # relative to src/, like every path of the plan
  SECRETS_CATALOG_FILE=secrets/shared.sops.json
  SECRETS_TFVARS_FILE=terraform/terraform.tfvars.sops.json
  SECRETS_VALUES_NAME=secrets.sops.json
  SECRETS_SHARED_NAME=secrets.shared.sops.json
  SECRETS_KEY_NAME=age.sops
  SECRETS_PUB_NAME=age.pub
}

# secrets_admins_load: src/secrets/admins.txt, or SECRETS_ADMIN_RECIPIENTS (space separated) in its place
secrets_admins_load() {
  local r kind unlocking
  if [ -n "${SECRETS_ADMIN_RECIPIENTS:-}" ]; then
    read -r -a ADMIN_RECIPIENTS <<<"$SECRETS_ADMIN_RECIPIENTS"
  else
    mapfile -t ADMIN_RECIPIENTS < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$SECRETS_ADMIN_FILE")
  fi
  [ "${#ADMIN_RECIPIENTS[@]}" -gt 0 ] || { echo "ERROR: no admin recipient in $SECRETS_ADMIN_FILE" >&2; exit 1; }
  for r in "${ADMIN_RECIPIENTS[@]}"; do
    [[ "$r" =~ $SECRETS_RECIPIENT_PATTERN ]] || { echo "ERROR: $r is no age recipient ($SECRETS_ADMIN_FILE)" >&2; exit 1; }
    # bech32 data never holds a 1, so the part before the last 1 is the kind: age1yubikey1... needs age-plugin-yubikey
    kind=${r%1*}
    [ "$kind" = age ] || tools_require "age-plugin-${kind#age1}"
  done
  ADMIN_SORTED=$(printf '%s\n' "${ADMIN_RECIPIENTS[@]}" | sort)
  [ -z "$(uniq -d <<<"$ADMIN_SORTED")" ] || { echo "ERROR: an admin recipient is listed twice in $SECRETS_ADMIN_FILE" >&2; exit 1; }

  # a run that leaves its own key out of the admin set would lock the owner out of every file it writes
  grep -qs '^AGE-SECRET-KEY-' "$SOPS_AGE_KEY_FILE" || { echo "ERROR: admin age key not readable at $SOPS_AGE_KEY_FILE" >&2; exit 1; }
  unlocking=$(grep '^AGE-SECRET-KEY-' "$SOPS_AGE_KEY_FILE" | age-keygen -y)
  if ! grep -qxF -f <(echo "$unlocking") <<<"$ADMIN_SORTED"; then
    echo "ERROR: the key unlocking this run ($SOPS_AGE_KEY_FILE: $(echo "$unlocking" | tr '\n' ' ')) is not an admin recipient." >&2
    echo "       Rotate in two runs: add the new recipient and run with the old key, then unlock with the new key and" >&2
    echo "       remove the old recipient (README.md, \"Rotating the admin key\")." >&2
    exit 1
  fi
}

# secrets_plan_load <out> [<file>]: {secrets, hosts, files, problems} as modules/secrets.nix plans it
secrets_plan_load() {
  if [ -n "${2:-}" ]; then
    cat "$2" > "$1"
  else
    echo ">>> Secrets: evaluating which host reads which secret..."
    nix eval --json --extra-experimental-features "nix-command flakes" "$SRC#$SECRETS_ATTR.plan" > "$1"
  fi
  jq -e '(.secrets | type == "object") and (.hosts | type == "object") and (.files | type == "object") and (.problems | type == "array")' \
    "$1" >/dev/null || { echo "ERROR: the secrets plan is not {secrets, hosts, files, problems}" >&2; exit 1; }
  [ "$(jq '.problems | length' "$1")" = 0 ] && return 0
  echo "ERROR: the lab's secrets are inconsistent:" >&2
  jq -r '.problems[]' "$1" >&2
  exit 1
}

# secrets_file_of <name>: the file holding it, relative to src/
secrets_file_of() {
  nix eval --raw --extra-experimental-features "nix-command flakes" "$SRC#$SECRETS_ATTR.declared.\"$1\".file"
}

secrets_get() {
  local file
  file=$(secrets_file_of "$1")
  sops --decrypt --extract "[\"$1\"]" "$SRC/$file"
}

secrets_set() {
  local file
  file=$(secrets_file_of "$1")
  printf '%s' "$2" | jq -Rs . | sops set --value-stdin "$SRC/$file" "[\"$1\"]"
}

secrets_age_key_link() {
  [ ! -e "$1" ] || [ -L "$1" ] || return 0
  mkdir -p "$(dirname "$1")"
  ln -sfn "$SECRETS_DOTFILES_DIR/age.txt" "$1"
}
