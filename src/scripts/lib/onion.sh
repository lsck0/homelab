# shellcheck shell=bash
# a tor v3 onion service's address and key file from its 32-byte ed25519 seed (base64), the secret kind `onion`
#
# secrets-sync.sh generates the seed and writes each address to src/generated/onions.json, the router turns the seed
# into the key file tor reads (instances/300-router/main.nix); both derive from the seed alone, so they cannot drift.
#
#   seed=$(onion_seed_generate)
#   onion_address "$seed"                   # <56 base32 characters>.onion
#   onion_secret_key "$seed" > hs_ed25519_secret_key
#
# rend-spec-v3, encoding onion addresses: base32(pubkey | checksum | version), checksum the first two bytes of
# sha3-256(".onion checksum" | pubkey | version). Tor's key file is a header padded to 32 bytes and the expanded
# ed25519 secret: sha512(seed) with its scalar half clamped (rfc 8032 5.1.5), which openssl does not export; openssl
# derives the public key from the seed itself. Needs openssl and coreutils.

# the pkcs8 der of an ed25519 private key up to its seed (rfc 8410)
ONION_PKCS8_PREFIX=302e020100300506032b657004220420
ONION_SEED_BYTES=32
ONION_PUBKEY_BYTES=32
ONION_VERSION=03
ONION_CHECKSUM_BYTES=2
ONION_CHECKSUM_PREFIX=".onion checksum"
ONION_KEY_HEADER="== ed25519v1-secret: type0 =="
ONION_KEY_HEADER_BYTES=32
# rfc 8032 5.1.5: the scalar's lowest three bits cleared, its top bit cleared and the one below it set
ONION_CLAMP_FIRST=248
ONION_CLAMP_LAST_MASK=127
ONION_CLAMP_LAST_SET=64

onion_hex_from_bytes() { od -An -v -tx1 | tr -d ' \n'; }
onion_bytes_from_hex() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | basenc -d --base16; }

onion_seed_generate() { openssl rand -base64 "$ONION_SEED_BYTES"; }

# onion_seed_hex <seed>: the seed as hex, refused unless it is exactly ONION_SEED_BYTES
onion_seed_hex() {
  local hex
  hex=$(base64 -d <<<"$1" | onion_hex_from_bytes)
  if [ "${#hex}" -ne $((ONION_SEED_BYTES * 2)) ]; then
    echo "onion: the seed is not $ONION_SEED_BYTES bytes of base64" >&2
    return 1
  fi
  printf '%s' "$hex"
}

onion_address() {
  local seed pubkey checksum
  seed=$(onion_seed_hex "$1")
  pubkey=$(onion_bytes_from_hex "$ONION_PKCS8_PREFIX$seed" | openssl pkey -inform DER -pubout -outform DER \
    | tail -c "$ONION_PUBKEY_BYTES" | onion_hex_from_bytes)
  checksum=$({ printf '%s' "$ONION_CHECKSUM_PREFIX"; onion_bytes_from_hex "$pubkey$ONION_VERSION"; } \
    | openssl dgst -sha3-256 -binary | head -c "$ONION_CHECKSUM_BYTES" | onion_hex_from_bytes)
  printf '%s.onion\n' "$(onion_bytes_from_hex "$pubkey$checksum$ONION_VERSION" | base32 | tr -d '=' | tr '[:upper:]' '[:lower:]')"
}

onion_secret_key() {
  local seed expanded header first last
  seed=$(onion_seed_hex "$1")
  expanded=$(onion_bytes_from_hex "$seed" | openssl dgst -sha512 -binary | onion_hex_from_bytes)
  first=$(printf '%02x' $((16#${expanded:0:2} & ONION_CLAMP_FIRST)))
  last=$(printf '%02x' $(((16#${expanded:62:2} & ONION_CLAMP_LAST_MASK) | ONION_CLAMP_LAST_SET)))
  header=$(printf '%s' "$ONION_KEY_HEADER" | onion_hex_from_bytes)
  while [ "${#header}" -lt $((ONION_KEY_HEADER_BYTES * 2)) ]; do header="${header}00"; done
  onion_bytes_from_hex "$header$first${expanded:2:60}$last${expanded:64}"
}
