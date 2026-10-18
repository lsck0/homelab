# real-format values for the secrets whose services parse them, for testing.secretValues (tests/stubs/sops.nix)
#
# a key a test only needs well-formed derives from its name, so every build agrees: a WireGuard key is the base64 of
# sha256("homelab-test/<name>"), a hex secret that hash. A key that needs real structure (RSA, OpenSSH) is generated
# at build time: private key material never sits in the repo, whose pre-commit hook refuses it. Public halves are
# under `public`. No oracle depends on a key's value.
#   testing.secretValues = { inherit (secretValues) wireguard-private-key; };
{ pkgs }:
let
  seedOf = name: "homelab-test/${name}";
  hexOf = name: builtins.hashString "sha256" (seedOf name);
  wireguardOf = name: builtins.convertHash { hash = hexOf name; hashAlgo = "sha256"; toHashFormat = "base64"; };

  wireguardPublic = name: pkgs.runCommand "${name}.pub" { nativeBuildInputs = [ pkgs.wireguard-tools ]; } ''
    printf '%s' ${wireguardOf name} | wg pubkey | tr -d '\n' > $out
  '';

  rsaKey = name: pkgs.runCommand name { nativeBuildInputs = [ pkgs.openssl ]; } ''
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out $out
  '';
  rsaPublic = name: key: pkgs.runCommand "${name}.pub" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    openssl pkey -in ${key} -pubout -out $out
  '';

  sshKey = name: comment: pkgs.runCommand name { nativeBuildInputs = [ pkgs.openssh ]; } ''
    ssh-keygen -q -t ed25519 -N "" -C ${comment} -f key
    mv key $out
  '';
  sshPublic = name: key: pkgs.runCommand "${name}.pub" { nativeBuildInputs = [ pkgs.openssh ]; } ''
    ssh-keygen -y -f ${key} | tr -d '\n' > $out
  '';

  authelia-oidc-issuer-key = rsaKey "authelia-oidc-issuer-key";
  # lldap's opaque server setup, base64 as vm-101's lldap decodes it; lldap itself writes one for a fresh db
  lldap-server-key = pkgs.runCommand "lldap-server-key" { nativeBuildInputs = [ pkgs.lldap pkgs.coreutils ]; } ''
    export LLDAP_JWT_SECRET=build-time-only-jwt-secret LLDAP_LDAP_USER_PASS=build-time-only
    export LLDAP_KEY_FILE=$PWD/server_key LLDAP_DATABASE_URL="sqlite://$PWD/users.db?mode=rwc"
    lldap create_schema >/dev/null
    base64 -w0 server_key > $out
  '';
  # the comment the production key carries (modules/swarm homelab.swarm.deployKey)
  app-deploy-key = sshKey "app-deploy-key" "app-builder";
in {
  wireguard-private-key = wireguardOf "wireguard-private-key";
  protonvpn-private-key = wireguardOf "protonvpn-private-key";
  anubis-ed25519-key = hexOf "anubis-ed25519-key";
  lab-gate-key = hexOf "lab-gate-key";
  authelia-oidc-hmac = hexOf "authelia-oidc-hmac";
  inherit authelia-oidc-issuer-key app-deploy-key lldap-server-key;
  # an onion route's key (<route>-onion-key): any 32 bytes are an ed25519 seed, base64 as scripts/lib/onion.nu reads it
  onionSeedOf = wireguardOf;

  public = {
    wireguard-private-key = wireguardPublic "wireguard-private-key";
    protonvpn-private-key = wireguardPublic "protonvpn-private-key";
    authelia-oidc-issuer-key = rsaPublic "authelia-oidc-issuer-key" authelia-oidc-issuer-key;
    app-deploy-key = sshPublic "app-deploy-key" app-deploy-key;
  };
}
