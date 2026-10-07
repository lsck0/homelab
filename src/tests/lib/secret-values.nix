# real-format values for the secrets whose services parse them, for testing.secretValues (tests/stubs/sops.nix)
#
# Keys a test only needs to be well-formed are derived from their name, so every build agrees on them: a WireGuard
# key is the base64 of sha256("homelab-test/<name>") (wireguard clamps any 32 bytes into a valid key), a hex or
# hmac secret that hash's 64 hex chars. Keys that need real structure (RSA, OpenSSH) are generated at build time:
# private key material never sits in the repo, whose pre-commit hook refuses it. The public halves of the keys are
# derivations too, under `public`. No oracle depends on a key's value. lib/lab.nix's `guest` gives every secret its
# node reads the value named here; a node built otherwise (the router) sets them itself:
#
#   secretValues = import ./secret-values.nix { inherit pkgs; };
#   testing.secretValues = { inherit (secretValues) wireguard-private-key protonvpn-private-key; };
#   # a public half as a string option is read at evaluation, which builds the key first (import from derivation)
#   homelab.swarm.deployKey = builtins.readFile secretValues.public.app-deploy-key;
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
  app-deploy-key = sshKey "app-deploy-key" "app-builder@vm-117";
in {
  wireguard-private-key = wireguardOf "wireguard-private-key";
  protonvpn-private-key = wireguardOf "protonvpn-private-key";
  anubis-ed25519-key = hexOf "anubis-ed25519-key";
  authelia-oidc-hmac = hexOf "authelia-oidc-hmac";
  inherit authelia-oidc-issuer-key app-deploy-key lldap-server-key;

  public = {
    wireguard-private-key = wireguardPublic "wireguard-private-key";
    protonvpn-private-key = wireguardPublic "protonvpn-private-key";
    authelia-oidc-issuer-key = rsaPublic "authelia-oidc-issuer-key" authelia-oidc-issuer-key;
    app-deploy-key = sshPublic "app-deploy-key" app-deploy-key;
  };
}
