#!/usr/bin/env bash
# secrets-sync.sh in scratch repos with throwaway age keys: placement and isolation, kinds, guarded secrets,
# idempotence, moves between files, prune, hosts leaving, refusals, the admin-key rotation (fresh data keys, renewed
# host keys, the history splice), atomicity under injected sops failures, and one run over the real plan.
#
# usage: secrets_sync_test.sh <repo src dir> <seed> <dir of plans: base moved minus unman renamed problem real .json>
# needs sops, age, jq, openssl, git, coreutils, findutils, diffutils on PATH; no network.
set -euo pipefail

SRC_IN=${1:?repo src dir}
SEED=${2:?seed}
P=${3:?plans dir}
echo "seed=$SEED"
RANDOM=$SEED

# injected faults per run: each draws the failing sops call from the seed
FAULT_TRIALS=12
# cross-decrypt pairs sampled over the real plan, whose full matrix is hosts x files decrypts
REAL_PAIRS=50

T=$(mktemp -d)
cd "$T"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

for k in A1 A2 A3; do age-keygen -o "$T/$k.key" 2>/dev/null; done
A1=$(age-keygen -y A1.key); A2=$(age-keygen -y A2.key); A3=$(age-keygen -y A3.key)

# -----------------------------------------------------------------------------
# HELPERS
# -----------------------------------------------------------------------------

# a scratch repo with the scripts under test and the terraform vars, encrypted to the admins A1 A2
repo_create() {
  mkdir -p "$1/src/terraform"
  cp -r "$SRC_IN/scripts" "$1/src/" && chmod -R u+w "$1/src"
  printf 'creation_rules:\n  - path_regex: src/terraform/terraform\\.tfvars\\.sops\\.json$\n    age: %s,%s\n' "$A1" "$A2" > "$1/.sops.yaml"
  echo '{"proxmox_api_token_secret": "tfvars-secret-value"}' \
    | SOPS_AGE_KEY_FILE="$T/A1.key" "$1/src/scripts/sops-encrypt.sh" "$1/src/terraform/terraform.tfvars.sops.json"
}
# sync <repo> <unlocking key> <admin recipients> <plan> [args]: one run of the script under test
sync() {
  local dir=$1 key=$2 admins=$3 plan=$4; shift 4
  SOPS_AGE_KEY_FILE="$key" SECRETS_ADMIN_RECIPIENTS="$admins" DOTFILES="$T/no-dotfiles" \
    "$dir/src/scripts/secrets-sync.sh" --plan "$P/$plan.json" "$@"
}
# dec <key file> <file>: the plaintext; fails when the key does not open it
dec() { SOPS_AGE_KEY_FILE="$1" sops --decrypt "$2" 2>/dev/null; }
opens() { dec "$1" "$2" >/dev/null; }
recipients() { jq -r '.sops.age[].recipient' "$1" | sort | paste -sd' '; }
sorted() { printf '%s\n' "$@" | sort | paste -sd' '; }
tree_hash() { (cd "$1" && find . -type f ! -path './.git/*' -print0 | sort -z | xargs -0 sha256sum); }
hash_of() { sha256sum "$1" | cut -d' ' -f1; }
plan_q() { jq -r "$2" "$P/$1.json"; }
# host_key <repo> <configuration> <plan> <out> <admin key>: that host's private key, from its age.sops
host_key() { dec "$5" "$1/src/$(plan_q "$3" ".hosts[\"$2\"].home")/age.sops" > "$4"; }
# the files a configuration reads, per the plan
reads_of() { plan_q "$1" ".files | to_entries[] | select(.value | index(\"$2\")) | .key"; }
# the names a sops file should hold: the declared ones of a values file, a host's shared list for its copy
names_of() {
  case "$2" in
    */secrets.shared.sops.json) plan_q "$1" ".hosts[] | select(.home + \"/secrets.shared.sops.json\" == \"$2\") | .shared | sort | .[]" ;;
    *) plan_q "$1" "[.secrets | to_entries[] | select(.value.file == \"$2\") | .key] | sort | .[]" ;;
  esac
}
refuses() { # refuses <repo> <expected message> <sync args...>
  local dir=$1 says=$2 before rc=0; shift 2
  before=$(tree_hash "$dir")
  sync "$dir" "$@" > "$T/refuse.log" 2>&1 || rc=$?
  [ "$rc" = 1 ] || fail "expected a refusal ($says), got rc=$rc: $(cat "$T/refuse.log")"
  grep -qF -- "$says" "$T/refuse.log" || fail "the refusal does not say '$says': $(cat "$T/refuse.log")"
  [ "$(tree_hash "$dir")" = "$before" ] || fail "a refused run ($says) wrote to the repo"
}
# check_layout <repo> <plan> <admin key> <admins...>: every file holds what the plan says, encrypted to exactly its
# readers and the admins, and every host key opens exactly the files it reads
check_layout() {
  local dir=$1 plan=$2 key=$3; shift 3
  local c f want got pubs
  declare -A pub=()
  for c in $(plan_q "$plan" '.hosts | keys[]'); do
    host_key "$dir" "$c" "$plan" "$T/$c.key" "$key"
    pub[$c]=$(age-keygen -y "$T/$c.key")
    [ "$(cat "$dir/src/$(plan_q "$plan" ".hosts[\"$c\"].home")/age.pub")" = "${pub[$c]}" ] || fail "$c's age.pub is not its key's"
  done
  for f in $(plan_q "$plan" '.files | keys[]'); do
    [ -f "$dir/src/$f" ] || fail "$f is missing"
    grep -qF "path_regex: src/${f//./\\.}\$" "$dir/.sops.yaml" || fail ".sops.yaml has no rule for $f"
    pubs=("$@"); for c in $(plan_q "$plan" ".files[\"$f\"][]"); do pubs+=("${pub[$c]}"); done
    [ "$(recipients "$dir/src/$f")" = "$(sorted "${pubs[@]}")" ] || fail "$f is not encrypted to exactly the admins and its readers"
    case "$f" in */age.sops) continue ;; esac
    want=$(names_of "$plan" "$f" | paste -sd' '); got=$(dec "$key" "$dir/src/$f" | jq -r 'keys[]' | paste -sd' ')
    [ "$got" = "$want" ] || fail "$f holds [$got], the plan says [$want]"
  done
  for c in $(plan_q "$plan" '.hosts | keys[]'); do
    for f in $(plan_q "$plan" '.files | keys[]'); do
      if opens "$T/$c.key" "$dir/src/$f"; then reads_of "$plan" "$c" | grep -qxF "$f" || fail "$c's key opens $f"
      elif reads_of "$plan" "$c" | grep -qxF "$f"; then fail "$c's key does not open $f, which it reads"; fi
    done
  done
}
value() { dec "$3" "$1/src/$2" | jq -r --arg k "$4" '.[$k]'; }

# -----------------------------------------------------------------------------
# 1 to 4: a first run over an empty repo, a first deploy
# -----------------------------------------------------------------------------
R=$T/repo
repo_create "$R"
refuses "$R" "vault in src/secrets/shared.sops.json" A1.key "$A1 $A2" base --apply
sync "$R" A1.key "$A1 $A2" base --apply --generate-guarded --host-keys-out "$T/out.json" > run1.log
check_layout "$R" base A1.key "$A1" "$A2"
ok "1 every file the plan lists, with its names, encrypted to the admins and its readers; host keys open exactly theirs"

CAT=secrets/shared.sops.json
[[ "$(value "$R" "$CAT" A1.key gen)" =~ ^[0-9a-f]{32}$ ]] || fail "gen (hex:16) is $(value "$R" "$CAT" A1.key gen)"
[[ "$(value "$R" "$CAT" A1.key tok)" =~ ^tk_[a-z0-9]{29}$ ]] || fail "tok is no ntfy token"
[[ "$(value "$R" apps/x/secrets.sops.json A1.key x-app)" =~ ^GK[0-9a-f]{24}$ ]] || fail "x-app is no garage key id"
[[ "$(value "$R" "$CAT" A1.key vault)" =~ ^[0-9a-f]{32}$ ]] || fail "vault (guardsData:hex:16) is $(value "$R" "$CAT" A1.key vault)"
[ "$(value "$R" "$CAT" A1.key wg | base64 -d | wc -c)" = 32 ] || fail "wg is no 32-byte base64 wireguard key"
[ -z "$(value "$R" "$CAT" A1.key man)" ] && [ -z "$(value "$R" "$CAT" A1.key pub)" ] || fail "manual and public are not empty"
grep -qF "add     man -> $CAT (empty, fill it: sops src/$CAT)" run1.log || fail "an empty manual secret is not reported"
[ "$(value "$R" instances/100-internal-a/secrets.shared.sops.json A1.key shared)" = "$(value "$R" "$CAT" A1.key shared)" ] \
  || fail "a's shared copy differs from src/secrets/shared.sops.json"
ok "2 values by kind (hex, wireguard, ntfy token, garage key id, guarded hex; manual and public empty), shared copies equal the source"

for v in $(dec A1.key "$R/src/$CAT" | jq -r '.[] | select(length > 0)') tfvars-secret-value; do
  grep -rqF -- "$v" "$R" && fail "plaintext $v lies in the repo"
done
for c in $(plan_q base '.hosts | keys[]'); do grep -rqF -- "$(cat "$T/$c.key")" "$R" && fail "$c's private key lies in the repo"; done
ok "3 no plaintext value and no host private key anywhere under the repo"

[ "$(stat -c %a "$T/out.json")" = 600 ] || fail "--host-keys-out is not mode 0600"
for c in $(plan_q base '.hosts | keys[]'); do [ "$(jq -r --arg c "$c" '.[$c]' "$T/out.json")" = "$(cat "$T/$c.key")" ] || fail "--host-keys-out's $c"; done
ok "4 --host-keys-out maps every configuration to its key, mode 0600"

# -----------------------------------------------------------------------------
# 5 to 8: idempotence, dry run, moves, prune, hosts leaving
# -----------------------------------------------------------------------------
git -C "$R" init -q && git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t commit -qm run1
before=$(tree_hash "$R")
sync "$R" A1.key "$A1 $A2" base --apply > run2.log
[ "$(tree_hash "$R")" = "$before" ] || fail "a second run changed bytes"
grep -q '0 file(s) changed' run2.log || fail "a second run reports changes: $(cat run2.log)"
ok "5 a second run changes no byte"

gen=$(value "$R" "$CAT" A1.key gen)
router=$(hash_of "$R/src/instances/300-router/secrets.sops.json")
sync "$R" A1.key "$A1 $A2" moved > dry.log
[ "$(tree_hash "$R")" = "$before" ] || fail "a dry run wrote"
grep -qF "move    gen: $CAT -> instances/100-internal-a/secrets.sops.json" dry.log || fail "the dry run does not report the move: $(cat dry.log)"
sync "$R" A1.key "$A1 $A2" moved --apply > moved.log
check_layout "$R" moved A1.key "$A1" "$A2"
[ "$(value "$R" instances/100-internal-a/secrets.sops.json A1.key gen)" = "$gen" ] || fail "gen changed value on its move"
[ "$(hash_of "$R/src/instances/300-router/secrets.sops.json")" = "$router" ] || fail "the move rewrote an unrelated file"
sync "$R" A1.key "$A1 $A2" base --apply > back.log
[ "$(value "$R" "$CAT" A1.key gen)" = "$gen" ] || fail "gen changed value on its way back"
ok "6 a dry run reports and writes nothing; a value moves into its new file and back unchanged, unrelated files untouched"

sync "$R" A1.key "$A1 $A2" unman --apply > unman.log
{ grep -qF "unused  man in $CAT" unman.log && dec A1.key "$R/src/$CAT" | jq -e 'has("man")' >/dev/null; } \
  || fail "an undeclared value is not kept and reported"
TFV=terraform/terraform.tfvars.sops.json
dec A1.key "$R/src/$TFV" | jq '.proxmox_ssh_password = "tfvars-dead-value"' | SOPS_AGE_KEY_FILE="$T/A1.key" "$R/src/scripts/sops-encrypt.sh" "$R/src/$TFV"
sync "$R" A1.key "$A1 $A2" unman --apply --prune > prune.log
dec A1.key "$R/src/$CAT" | jq -e 'has("man") | not' >/dev/null || fail "--prune kept man"
dec A1.key "$R/src/$TFV" | jq -e 'has("proxmox_ssh_password") | not' >/dev/null || fail "--prune kept the dead tfvars key"
[ "$(value "$R" "$TFV" A1.key proxmox_api_token_secret)" = tfvars-secret-value ] || fail "--prune touched a declared tfvars value"
sync "$R" A1.key "$A1 $A2" base --apply > /dev/null
ok "7 an undeclared value is kept and reported, --prune deletes it, in the terraform vars too"

a_before=$(hash_of "$R/src/instances/100-internal-a/secrets.sops.json")
sync "$R" A1.key "$A1 $A2" minus --apply > minus.log
check_layout "$R" minus A1.key "$A1" "$A2"
[ ! -e "$R/src/instances/101-internal-b/age.sops" ] && [ ! -e "$R/src/instances/101-internal-b/secrets.shared.sops.json" ] \
  || fail "a removed host keeps its key or copy"
[ ! -e "$R/src/generated/nodes/250-apps-swarm" ] || fail "a removed worker keeps its folder"
[ "$(hash_of "$R/src/instances/100-internal-a/secrets.sops.json")" = "$a_before" ] || fail "removing hosts rewrote a's file"
sync "$R" A1.key "$A1 $A2" base --apply > /dev/null
check_layout "$R" base A1.key "$A1" "$A2"
ok "8 removed hosts lose key, copy and folder, the app's file its reader; others byte-identical; they come back"

# -----------------------------------------------------------------------------
# 9: refusals leave the tree as it was
# -----------------------------------------------------------------------------
refuses "$R" "101-internal-b reads nope, which nothing declares" A1.key "$A1 $A2" problem --apply
refuses "$R" "vault2 in src/secrets/shared.sops.json" A1.key "$A1 $A2" renamed --apply
refuses "$R" "is not an admin recipient" A1.key "$A2 $A3" base --apply
cp "$R/src/instances/300-router/age.pub" "$T/pub.saved"; age-keygen -y A3.key > "$R/src/instances/300-router/age.pub"
refuses "$R" "instances/300-router/age.pub is not the public half" A1.key "$A1 $A2" base --apply
cp "$T/pub.saved" "$R/src/instances/300-router/age.pub"
ok "9 refused, nothing written: an undeclared read, a guarded secret without its value, a run locking its own key out, a foreign age.pub"

# -----------------------------------------------------------------------------
# 10: rotating the admin key, A1 out and A3 in
# -----------------------------------------------------------------------------
cp -a "$R/src" "$T/history"
sync "$R" A1.key "$A1 $A2 $A3" base --apply > rot1.log
check_layout "$R" base A1.key "$A1" "$A2" "$A3"
for c in $(plan_q base '.hosts | keys[]'); do cmp -s "$T/$c.key" <(dec A3.key "$R/src/$(plan_q base ".hosts[\"$c\"].home")/age.sops") || fail "adding an admin renewed $c's key"; done
for c in $(plan_q base '.hosts | keys[]'); do cp "$T/$c.key" "$T/$c.old.key"; done
sync "$R" A3.key "$A2 $A3" base --apply > rot2.log
check_layout "$R" base A3.key "$A2" "$A3"
for c in $(plan_q base '.hosts | keys[]'); do
  cmp -s "$T/$c.key" "$T/$c.old.key" && fail "removing A1 kept $c's key"
  for f in $(reads_of base "$c"); do opens "$T/$c.old.key" "$R/src/$f" && fail "$c's old key opens $f"; done
done
while IFS= read -r f; do opens A1.key "$R/src/$f" && fail "A1 opens $f after its removal"; done < <(plan_q base '.files | keys[]')
[ "$(dec A3.key "$R/src/$CAT" | jq -S .)" = "$(dec A1.key "$T/history/$CAT" | jq -S .)" ] || fail "the rotation changed values"
splice() { jq --slurpfile old "$1" --arg a1 "$A1" '.sops.age += [$old[0].sops.age[] | select(.recipient == $a1)]' "$2" > "$3"; }
for f in "$CAT" instances/100-internal-a/age.sops instances/100-internal-a/secrets.sops.json; do
  # the same name, so sops reads the splice in the file's own format
  spliced=$T/spliced-$(basename "$f")
  splice "$T/history/$f" "$R/src/$f" "$spliced"
  opens A1.key "$spliced" && fail "A1's old stanza spliced onto the new $f decrypts it: the data key was not renewed"
done
ok "10 adding an admin re-encrypts and keeps host keys; removing A1 re-encrypts without it, renews every host key, the splice fails"

# -----------------------------------------------------------------------------
# 11: an injected sops failure loses no value and leaves every file whole; a rerun converges
# -----------------------------------------------------------------------------
mkdir -p "$T/shim"
REAL_SOPS=$(command -v sops)
cat > "$T/shim/sops" <<EOF
#!$(command -v bash)
# fails the \$SOPS_FAIL_AT-th encrypt of the run
for a in "\$@"; do
  if [ "\$a" = --encrypt ]; then
    n=\$((\$(cat "\$SOPS_FAIL_COUNTER") + 1)); echo "\$n" > "\$SOPS_FAIL_COUNTER"
    [ "\$n" = "\$SOPS_FAIL_AT" ] && { echo "injected sops failure at encrypt \$n" >&2; exit 1; }
  fi
done
exec $REAL_SOPS "\$@"
EOF
chmod +x "$T/shim/sops"
# every value of a repo, as "<name> <value>" lines over all values files
values_of() {
  for f in "$1"/src/secrets/shared.sops.json "$1"/src/*/*/secrets.sops.json; do
    [ ! -f "$f" ] || dec A3.key "$f" | jq -r 'to_entries[] | "\(.key) \(.value)"'
  done | sort -u
}
# contents and recipient shape per file, host keys abstracted to the configuration owning them
state_of() {
  local dir=$1 f c
  declare -A name=(["$A2"]=A2 ["$A3"]=A3 ["$A1"]=A1)
  for c in $(plan_q moved '.hosts | keys[]'); do name[$(cat "$dir/src/$(plan_q moved ".hosts[\"$c\"].home")/age.pub")]=$c; done
  for f in $(plan_q moved '.files | keys[]'); do
    echo "$f $(jq -r '.sops.age[].recipient' "$dir/src/$f" | while read -r r; do echo "${name[$r]:-?}"; done | sort | paste -sd' ')"
    case "$f" in */age.sops) ;; *) dec A3.key "$dir/src/$f" | jq -cS . ;; esac
  done
}
# the faulted run: a move plus A1 back in, unlocked with A3
cp -a "$R" "$T/fault-base"
cp -a "$T/fault-base" "$T/reference"
echo 0 > "$T/counter"
PATH="$T/shim:$PATH" SOPS_FAIL_COUNTER="$T/counter" SOPS_FAIL_AT=0 sync "$T/reference" A3.key "$A1 $A2 $A3" moved --apply > reference.log
encrypts=$(cat "$T/counter")
[ "$encrypts" -gt 1 ] || fail "the reference run encrypted $encrypts file(s)"
reference=$(state_of "$T/reference")
base_values=$(values_of "$T/fault-base")
for trial in $(seq 1 "$FAULT_TRIALS"); do
  at=$((RANDOM % encrypts + 1))
  F=$T/fault-$trial
  cp -a "$T/fault-base" "$F"
  echo 0 > "$T/counter"
  rc=0
  PATH="$T/shim:$PATH" SOPS_FAIL_COUNTER="$T/counter" SOPS_FAIL_AT=$at sync "$F" A3.key "$A1 $A2 $A3" moved --apply > "$T/fault.log" 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "trial $trial: a failed sops encrypt $at went unnoticed"
  while IFS= read -r -d '' f; do opens A3.key "$f" || fail "trial $trial (encrypt $at): ${f#"$F/"} is neither old nor whole"; done \
    < <(find "$F/src" \( -name '*.sops.json' -o -name age.sops \) -print0)
  [ -z "$(comm -23 <(echo "$base_values") <(values_of "$F"))" ] || fail "trial $trial (encrypt $at): a value was lost"
  [ -z "$(find "$F" -name '.sops-encrypt.*')" ] || fail "trial $trial: a temp file stayed behind"
  sync "$F" A3.key "$A1 $A2 $A3" moved --apply > "$T/rerun.log"
  [ "$(state_of "$F")" = "$reference" ] || fail "trial $trial (encrypt $at): the rerun did not converge"
  echo "  trial $trial: encrypt $at of $encrypts failed: every file whole, no value lost, the rerun converged"
done
ok "11 $FAULT_TRIALS injected sops failures: safe, and a rerun converges"

# -----------------------------------------------------------------------------
# 12: the real plan
# -----------------------------------------------------------------------------
RR=$T/real
repo_create "$RR"
sync "$RR" A1.key "$A1 $A2" real --apply --generate-guarded > real1.log
mapfile -t REAL_CONFIGS < <(plan_q real '.hosts | keys[]')
mapfile -t REAL_FILES < <(plan_q real '.files | keys[]')
for c in "${REAL_CONFIGS[@]}"; do host_key "$RR" "$c" real "$T/real-$c.key" A1.key; done
for f in "${REAL_FILES[@]}"; do
  case "$f" in */age.sops) continue ;; esac
  [ "$(dec A1.key "$RR/src/$f" | jq -r 'keys[]' | paste -sd' ')" = "$(names_of real "$f" | paste -sd' ')" ] || fail "real $f holds other names than declared"
done
for _ in $(seq 1 "$REAL_PAIRS"); do
  c=${REAL_CONFIGS[RANDOM % ${#REAL_CONFIGS[@]}]}; f=${REAL_FILES[RANDOM % ${#REAL_FILES[@]}]}
  if opens "$T/real-$c.key" "$RR/src/$f"; then reads_of real "$c" | grep -qxF "$f" || fail "real $c's key opens $f"; fi
done
before=$(tree_hash "$RR")
sync "$RR" A1.key "$A1 $A2" real --apply > real2.log
[ "$(tree_hash "$RR")" = "$before" ] || fail "a second run over the real plan changed bytes"
ok "12 the real plan (${#REAL_CONFIGS[@]} configurations, ${#REAL_FILES[@]} files): contents, sampled isolation, idempotence"

echo "secrets-sync: all assertions hold"
