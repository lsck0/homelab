# vm-119's gate before every nightly build (lib/archrepo-fetch.sh) in the sandbox: it checks out and prints a
# head signed by the pinned primary key (directly or by its signing subkey), and refuses an unsigned head and one
# signed by a foreign key, even when the commit swaps the key file in the repo for the foreign key, and a head without
# the key file (a dotfiles layout this script does not know). A refused head leaves the checkout of the last good one
# in place. Keys are made per build; no expectation depends on them.
{ pkgs, lib, ... }:
let
  # arch-dotfiles bootstrap.sh SIGNING_KEY_FILE, the path the script reads the pinned key from
  keyFile = "configs/base/gnupg/luca-sandrock.pub.asc";
  ref = "master";
in
pkgs.runCommand "archrepo-fetch" { nativeBuildInputs = [ pkgs.git pkgs.gnupg pkgs.coreutils pkgs.gawk pkgs.gnugrep ]; } ''
  set -euo pipefail
  export HOME=$PWD/home GNUPGHOME=$PWD/signer
  mkdir -p "$HOME" "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
  git config --global user.name test; git config --global user.email test@example.org
  git config --global init.defaultBranch ${ref}
  fail() { echo "FAIL: $*" >&2; exit 1; }
  pass() { echo "PASS: $*"; }

  # the owner's key: a certify-only primary with a signing subkey, and a stranger's key
  gpg --batch --pinentry-mode loopback --passphrase "" --quick-gen-key owner@example.org ed25519 cert never
  owner=$(gpg --list-keys --with-colons owner@example.org | awk -F: '$1 == "fpr" { print $10; exit }')
  gpg --batch --pinentry-mode loopback --passphrase "" --quick-add-key "$owner" ed25519 sign never
  gpg --batch --pinentry-mode loopback --passphrase "" --quick-gen-key stranger@example.org ed25519 sign never
  stranger=$(gpg --list-keys --with-colons stranger@example.org | awk -F: '$1 == "fpr" { print $10; exit }')

  repo=$PWD/dotfiles
  git init -q "$repo"
  mkdir -p "$repo/$(dirname ${keyFile})"
  gpg --armor --export "$owner" > "$repo/${keyFile}"
  commit() { # <message> [git commit args...]
    local message=$1; shift
    echo "$message" > "$repo/payload"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "$message" "$@"
    git -C "$repo" rev-parse HEAD
  }
  fetch() { bash ${../lib/archrepo-fetch.sh} "file://$repo" ${ref} "$PWD/checkout" "$owner"; }

  good=$(commit "signed by the owner's subkey" -S"$owner")
  [ "$(fetch)" = "$good" ] || fail "a head signed by the pinned key was not fetched"
  [ "$(cat checkout/payload)" = "signed by the owner's subkey" ] || fail "the checkout is not the fetched head"
  pass "a head signed by the pinned key (its signing subkey) is checked out"

  commit "unsigned" >/dev/null
  if fetch 2>err; then fail "an unsigned head was accepted"; fi
  grep -q "is not signed by $owner" err || fail "no refusal message: $(cat err)"
  [ "$(git -C checkout rev-parse HEAD)" = "$good" ] || fail "a refused head moved the checkout"
  pass "an unsigned head is refused, the last good checkout stays"

  commit "signed by a stranger" -S"$stranger" >/dev/null
  if fetch 2>err; then fail "a head signed by a foreign key was accepted"; fi
  pass "a head signed by a foreign key is refused"

  # the attacker controls the repo: the key file now holds the stranger's key, which the head is signed with
  gpg --armor --export "$stranger" > "$repo/${keyFile}"
  commit "the key file swapped" -S"$stranger" >/dev/null
  if fetch 2>err; then fail "a head signed by the key it ships was accepted"; fi
  [ "$(git -C checkout rev-parse HEAD)" = "$good" ] || fail "a refused head moved the checkout"
  pass "a head that ships its own key is refused: only the pinned fingerprint counts"

  # a dotfiles layout that keeps the key elsewhere stops the night before any build reads its package list
  git -C "$repo" rm -q "${keyFile}"
  gpg --armor --export "$owner" > "$repo/elsewhere.asc"
  commit "the key file moved" -S"$owner" >/dev/null
  if fetch 2>err; then fail "a head without ${keyFile} was accepted"; fi
  [ "$(git -C checkout rev-parse HEAD)" = "$good" ] || fail "a refused head moved the checkout"
  pass "a head without the key file is refused, the last good checkout stays"
  touch $out
''
