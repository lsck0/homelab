# a tor v3 onion service's address and key file from its 32-byte ed25519 seed (base64), the secret kind `onion`
#
# secrets-sync.nu generates the seed and writes each address to src/generated/onions.json; the router turns the seed
# into the key file tor reads (`onion.nu secret-key < seed > hs_ed25519_secret_key`). Both derive from the seed alone.
# rend-spec-v3: address = base32(pubkey | checksum | version), checksum = sha3-256(".onion checksum" | pubkey |
# version)[:2]. The key file is a 32-byte header and sha512(seed) with its scalar half clamped (rfc 8032 5.1.5), which
# openssl does not export; nu's `hash` has no sha3 or sha512, so openssl computes those.

# the pkcs8 der of an ed25519 private key up to its seed (rfc 8410)
const PKCS8_PREFIX = 0x[302e020100300506032b657004220420]
const SEED_BYTES = 32
const PUBKEY_BYTES = 32
const VERSION = 0x[03]
const CHECKSUM_BYTES = 2
const CHECKSUM_PREFIX = ".onion checksum"
const KEY_HEADER = "== ed25519v1-secret: type0 =="
const KEY_HEADER_BYTES = 32
# rfc 8032 5.1.5: the scalar's lowest three bits cleared, its top bit cleared and the one below it set
const CLAMP_FIRST = 248
const CLAMP_LAST_MASK = 127
const CLAMP_LAST_SET = 64
const SCALAR_BYTES = 32

def seed-decode [seed: string]: nothing -> binary {
    let bytes = try { $seed | str trim | decode base64 } catch { 0x[] }
    if ($bytes | bytes length) != $SEED_BYTES { error make {msg: $"onion: the seed is not ($SEED_BYTES) bytes of base64"} }
    $bytes
}

def byte [value: int]: nothing -> binary { $value | into binary | first 1 }

export def onion-seed-generate []: nothing -> string {
    let seed = ^openssl rand -base64 $SEED_BYTES
    $seed | str trim
}

export def onion-address [seed: string]: nothing -> string {
    let der = bytes build $PKCS8_PREFIX (seed-decode $seed)
    let public_der = $der | ^openssl pkey -inform DER -pubout -outform DER
    let pubkey = $public_der | into binary | last $PUBKEY_BYTES
    let digest = bytes build ($CHECKSUM_PREFIX | into binary) $pubkey $VERSION | ^openssl dgst -sha3-256 -binary
    let checksum = $digest | into binary | first $CHECKSUM_BYTES
    $"(bytes build $pubkey $checksum $VERSION | encode base32 | str trim --right --char '=' | str downcase).onion"
}

export def onion-secret-key [seed: string]: nothing -> binary {
    let digest = seed-decode $seed | ^openssl dgst -sha512 -binary
    let expanded = $digest | into binary
    let first = $expanded | first 1 | into int | bits and $CLAMP_FIRST
    let last = $expanded | bytes at ($SCALAR_BYTES - 1)..($SCALAR_BYTES - 1) | into int | bits and $CLAMP_LAST_MASK | bits or $CLAMP_LAST_SET
    let header = $KEY_HEADER | into binary
    let padding = 1..($KEY_HEADER_BYTES - ($header | bytes length)) | each { 0x[00] } | bytes collect
    (bytes build $header $padding (byte $first) ($expanded | bytes at 1..($SCALAR_BYTES - 2))
        (byte $last) ($expanded | bytes at $SCALAR_BYTES..))
}

# the router's key file: the seed on stdin, tor's file on stdout
def "main secret-key" []: string -> nothing {
    onion-secret-key $in | print --raw
}

def "main address" []: string -> nothing {
    print (onion-address $in)
}

def main []: nothing -> nothing {
    print -e "usage: onion.nu secret-key|address < seed"
    exit 2
}
