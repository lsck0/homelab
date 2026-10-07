#!/usr/bin/env bash
# the plaintext guard as the pre-commit hook runs it: each case stages files in a scratch repo, commits, and expects
# the commit refused (HEAD unchanged, stderr naming the path or key) or accepted (HEAD advanced). Every refusal has an
# accepted control of the same shape. Throwaway age key, no network.
#
# usage: secrets_check_test.sh <dir with .githooks/ and src/>
set -euo pipefail

FIXTURE=${1:?dir with .githooks and src}
T=$(mktemp -d)
cd "$T"
fail() { echo "FAIL: $*" >&2; exit 1; }

age-keygen -o "$T/admin.key" 2>/dev/null
ADMIN=$(age-keygen -y "$T/admin.key")
age-keygen -o "$T/host.key" 2>/dev/null
HOST=$(age-keygen -y "$T/host.key")
export SOPS_AGE_KEY_FILE="$T/admin.key"
# the public kind, which the guard otherwise reads from the flake
export SECRETS_PUBLIC_NAMES=proxmox-user

# fixture values: a generated secret, an identifier (public), a multi-line key, one too short to scan
LLDAP=4f2c9a7e1b3d5f60a8c2e4b6d8f0a1c3e5b7d9f1a3c5e7b9
# an openssh key: its first body line is the format header every ed25519 key shares, the second is its own
PEM_HEADER=b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
PEM_BODY=QyNTUxOQAAACBf3x9Qm1x7cXJ0dGVzdC1maXh0dXJlLW5vdC1hLXJlYWwta2V5AAAA
# armor and identities assembled at run time: written out, this file would match the patterns it tests
armor() { printf -- '-----%s %s-----' "$1" "$2"; }
YUBIKEY_IDENTITY="AGE-PLUGIN-YUBIKEY-1$(printf 'Q%.0s' {1..27})"
SHORT=abc

# -----------------------------------------------------------------------------
# the base repo every case starts from
# -----------------------------------------------------------------------------
B=$T/base
H=src/instances/1-internal-x
mkdir -p "$B/$H" "$B/src/secrets"
cp -r "$FIXTURE/.githooks" "$B/"
cp -r "$FIXTURE/src/scripts" "$B/src/"
chmod -R u+w "$B"
# the real rule shapes (secrets-sync.sh): the shared values admin-only, a host's key admin-only, its own values to it
cat > "$B/.sops.yaml" <<EOF
creation_rules:
  - path_regex: src/secrets/shared\.sops\.json$
    age: $ADMIN
  - path_regex: $H/age\.sops$
    age: $ADMIN
  - path_regex: $H/secrets\.sops\.json$
    age: $ADMIN,$HOST
EOF
jq -n --arg header "$PEM_HEADER" --arg body "$PEM_BODY" --arg s "$SHORT" \
  --arg begin "$(armor BEGIN 'OPENSSH PRIVATE KEY')" --arg end "$(armor END 'OPENSSH PRIVATE KEY')" '{
  "app-deploy-key": "\($begin)\n\($header)\n\($body)\n\($end)\n",
  "proxmox-user": "homepage@pve!homepage",
  "short-one": $s}' | "$B/src/scripts/sops-encrypt.sh" "$B/src/secrets/shared.sops.json"
echo '{"lldap-admin-password": "'"$LLDAP"'"}' | "$B/src/scripts/sops-encrypt.sh" "$B/$H/secrets.sops.json"
grep AGE-SECRET-KEY "$T/host.key" | "$B/src/scripts/sops-encrypt.sh" "$B/$H/age.sops"
echo "hello" > "$B/README.md"
git -C "$B" init -q
git -C "$B" config user.name t && git -C "$B" config user.email t@t
git -C "$B" config core.hooksPath .githooks
git -C "$B" add -A && git -C "$B" commit -qm base --no-verify

# -----------------------------------------------------------------------------
# one case: a fresh copy, the setup stages files, a commit decides
# -----------------------------------------------------------------------------
cases=0
# check <name> accepted|refused <stderr substring or -> <setup> [env assignments for the commit]
check() {
  local name=$1 expect=$2 says=$3 setup=$4; shift 4
  local R=$T/case-$cases head rc=0
  cases=$((cases + 1))
  cp -a "$B" "$R"
  (cd "$R" && $setup)
  head=$(git -C "$R" rev-parse HEAD)
  (cd "$R" && env "$@" git commit -qm "case $name") > "$T/out" 2>&1 || rc=$?
  if [ "$expect" = accepted ]; then
    [ "$rc" = 0 ] && [ "$(git -C "$R" rev-parse HEAD)" != "$head" ] || fail "$name: expected accepted, got rc=$rc: $(cat "$T/out")"
  else
    [ "$rc" != 0 ] && [ "$(git -C "$R" rev-parse HEAD)" = "$head" ] || fail "$name: expected refused, got rc=$rc"
    grep -qF -- "$says" "$T/out" || fail "$name: the refusal does not say '$says': $(cat "$T/out")"
    grep -qF -- "$LLDAP" "$T/out" && fail "$name: the refusal prints a secret value"
  fi
  echo "ok: $name -> $expect"
}

# -----------------------------------------------------------------------------
# sops-managed paths
# -----------------------------------------------------------------------------
host_encrypted() {
  echo '{"lldap-admin-password": "changed-value-x"}' | src/scripts/sops-encrypt.sh "$H/secrets.sops.json"
  git add "$H/secrets.sops.json"
}
check "encrypted host file" accepted - host_encrypted
host_plain() { echo '{"lldap-admin-password": "plain-value-123"}' > "$H/secrets.sops.json"; git add "$H/secrets.sops.json"; }
check "plaintext host file" refused "$H/secrets.sops.json is staged unencrypted" host_plain
secrets_plain() { echo '{"proxmox-user": "x"}' > src/secrets/shared.sops.json; git add src/secrets/shared.sops.json; }
check "plaintext shared values" refused "src/secrets/shared.sops.json is staged unencrypted" secrets_plain
key_plain() { grep AGE-SECRET-KEY "$T/host.key" > "$H/age.sops"; git add "$H/age.sops"; }
check "plaintext host key" refused "$H/age.sops is staged unencrypted" key_plain
key_encrypted() { grep AGE-SECRET-KEY "$T/admin.key" | src/scripts/sops-encrypt.sh "$H/age.sops"; git add "$H/age.sops"; }
check "encrypted host key" accepted - key_encrypted
staged_then_encrypted() {
  echo '{"a": "plain-value-staged"}' > "$H/secrets.sops.json"; git add "$H/secrets.sops.json"
  echo '{"a": "plain-value-staged"}' | src/scripts/sops-encrypt.sh "$H/secrets.sops.json"
}
check "plaintext staged, worktree encrypted" refused "$H/secrets.sops.json" staged_then_encrypted
plain_beside_cipher() {
  jq '.added = "plaintext-beside-ciphertext"' "$H/secrets.sops.json" > x && mv x "$H/secrets.sops.json"
  git add "$H/secrets.sops.json"
}
check "plaintext value beside ciphertext" refused "plaintext value beside its ciphertext" plain_beside_cipher
metadata_stripped() { jq 'del(.sops)' "$H/secrets.sops.json" > x && mv x "$H/secrets.sops.json"; git add "$H/secrets.sops.json"; }
check "sops metadata stripped" refused "$H/secrets.sops.json" metadata_stripped
not_json() { echo 'a: plain' > "$H/secrets.sops.json"; git add "$H/secrets.sops.json"; }
check "non-json under a rule says why" refused "$H/secrets.sops.json is staged unencrypted" not_json
unknown_host() {
  mkdir -p src/generated/nodes/250-apps-swarm
  echo '{"x": "plain-value-unruled"}' > src/generated/nodes/250-apps-swarm/secrets.shared.sops.json
  git add src/generated/nodes
}
check "host file without a .sops.yaml rule" refused "src/generated/nodes/250-apps-swarm/secrets.shared.sops.json" unknown_host
backup_copy() { sops -d "$H/secrets.sops.json" > "$H/secrets.sops.json.bak"; git add "$H/secrets.sops.json.bak"; }
check "decrypted .bak beside the host files" refused "$H/secrets.sops.json.bak" backup_copy
deletion() { git rm -q "$H/secrets.sops.json"; }
check "staged deletion of a secrets file" accepted - deletion

# -----------------------------------------------------------------------------
# key material and decrypted copies anywhere
# -----------------------------------------------------------------------------
age_key() { cat "$T/host.key" > notes.txt; git add notes.txt; }
check "age private key in notes.txt" refused "notes.txt contains private key material" age_key
openssh_key() { printf '%s\nAAAA\n%s\n' "$(armor BEGIN 'OPENSSH PRIVATE KEY')" "$(armor END 'OPENSSH PRIVATE KEY')" > id_ed25519; git add id_ed25519; }
check "openssh private key" refused "id_ed25519 contains private key material" openssh_key
yubikey_identity() { echo "$YUBIKEY_IDENTITY" > identity.txt; git add identity.txt; }
check "yubikey identity" refused "identity.txt contains private key material" yubikey_identity
pgp_key() { printf '%s\n\nxx\n' "$(armor BEGIN 'PGP PRIVATE KEY BLOCK')" > signing.asc; git add signing.asc; }
check "pgp private key" refused "signing.asc contains private key material" pgp_key
binary_key() { { head -c 64 /dev/zero; cat "$T/host.key"; head -c 64 /dev/zero; } > blob.bin; git add blob.bin; }
check "key inside a binary file" refused "blob.bin contains private key material" binary_key
odd_path() { cat "$T/host.key" > "$(printf 'odd name\nwith newline.txt')"; git add -A; }
check "key in a path with a space and a newline" refused "contains private key material" odd_path
decrypted_name() { echo '{"nothing": "secret here"}' > secrets.dec.json; git add secrets.dec.json; }
check "a decrypted copy by name" refused "secrets.dec.json is named like a decrypted copy" decrypted_name
public_key() { age-keygen -y "$T/host.key" > recipient.txt; git add recipient.txt; }
check "a public age recipient" accepted - public_key

# -----------------------------------------------------------------------------
# secret values from every values file
# -----------------------------------------------------------------------------
value_in_notes() { printf 'password: %s\n' "$LLDAP" > notes.txt; git add notes.txt; }
check "a secret value in notes.txt" refused "notes.txt contains the value of lldap-admin-password" value_in_notes
pem_line() { printf 'key body %s\n' "$PEM_BODY" > dump.txt; git add dump.txt; }
check "one line of a multi-line secret" refused "dump.txt contains the value of app-deploy-key" pem_line
pem_header() { printf 'any ed25519 key starts %s\n' "$PEM_HEADER" > format.txt; git add format.txt; }
check "the format header every key shares" accepted - pem_header
public_value() { echo 'user = "homepage@pve!homepage"' > init.conf; git add init.conf; }
check "a public value (an id) in code" accepted - public_value
short_value() { echo "abc def" > short.txt; git add short.txt; }
check "a value below the scan length" accepted - short_value
value_without_key() { printf 'password: %s\n' "$LLDAP" > notes.txt; git add notes.txt; }
check "a secret value, no admin key (warns)" accepted - value_without_key SOPS_AGE_KEY_FILE=/nonexistent

# sync.sh's mode: the value scan is mandatory
R=$T/require; cp -a "$B" "$R"
(cd "$R" && printf 'password: %s\n' "$LLDAP" > notes.txt && git add notes.txt)
rc=0; (cd "$R" && SOPS_AGE_KEY_FILE=/nonexistent src/scripts/secrets-check.sh --require-values) > "$T/out" 2>&1 || rc=$?
{ [ "$rc" = 1 ] && grep -qF "the value scan is required" "$T/out"; } || fail "--require-values without a key: rc=$rc $(cat "$T/out")"
echo "ok: --require-values without the admin key -> refused"
rc=0; (cd "$R" && src/scripts/secrets-check.sh --require-values) > "$T/out" 2>&1 || rc=$?
{ [ "$rc" = 1 ] && grep -qF "notes.txt contains the value of lldap-admin-password" "$T/out"; } || fail "--require-values with a key: rc=$rc"
echo "ok: --require-values with the admin key -> refused naming the key"
rc=0; (cd "$R" && src/scripts/secrets-check.sh --aply) > "$T/out" 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "an unknown flag gave rc=$rc"
echo "ok: an unknown flag -> usage, rc 2"

# -----------------------------------------------------------------------------
# the rules themselves, and a clean commit
# -----------------------------------------------------------------------------
no_rules() { printf 'creation_rules: []\n' > .sops.yaml; echo x > a.txt; git add .sops.yaml a.txt; }
check ".sops.yaml without any path_regex" refused "no path_regex in .sops.yaml" no_rules
clean() { echo "more" >> README.md; git add README.md; }
check "a clean commit" accepted - clean

echo "secrets-check: $cases cases hold"
