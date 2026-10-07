# a test certificate authority and the leaves the lab's tls names need: *.lsck0.dev (both ingresses) and
# github.com (the app builder's forge, served by a stand-in in tests)
#
# Keys are random per build and never leave the store; no oracle depends on them. Nodes trust the ca through
# security.pki.certificateFiles (lib/lab.nix does it for every lab node), which python, curl, git and go all read.
#
#   pki = import ./pki.nix { inherit pkgs; };
#   security.pki.certificateFiles = [ pki.ca ];
#   services.nginx.virtualHosts."github.com" = {
#     sslCertificate = pki.github.cert;
#     sslCertificateKey = pki.github.key;
#   };
{ pkgs }:
let
  # far beyond any test run; a test vm's clock starts at the build host's
  validDays = 3650;
  leaves = {
    lsck0 = [ "lsck0.dev" "*.lsck0.dev" ];
    github = [ "github.com" "api.github.com" ];
  };
  # quoted: stdenv's nullglob would drop an unmatched *.lsck0.dev
  quote = word: "'${word}'";
  leafCall = name: "leaf ${name} ${builtins.concatStringsSep " " (map quote leaves.${name})}";
  leafCalls = builtins.concatStringsSep "\n" (map leafCall (builtins.attrNames leaves));

  tree = pkgs.runCommand "homelab-test-pki" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out && cd $out
    # python 3.13 verifies strictly (VERIFY_X509_STRICT): a ca without key usage, a leaf without its issuer's key id fail
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days ${toString validDays} \
      -subj "/CN=homelab test ca" -addext keyUsage=critical,keyCertSign,cRLSign -keyout ca.key -out ca.crt
    leaf() {
      name=$1; shift
      san=$(printf 'DNS:%s,' "$@"); san=''${san%,}
      openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "/CN=$1" \
        -keyout "$name.key" -out "$name.csr"
      printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature\nauthorityKeyIdentifier=keyid\n' "$san" > "$name.ext"
      openssl x509 -req -in "$name.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -days ${toString validDays} \
        -extfile "$name.ext" -out "$name.crt"
      rm "$name.csr" "$name.ext"
    }
    ${leafCalls}
  '';
in {
  ca = "${tree}/ca.crt";
} // builtins.mapAttrs (name: _: { cert = "${tree}/${name}.crt"; key = "${tree}/${name}.key"; }) leaves
