# both ingresses as production configures them serve the lab's wildcard to a client naming no router's host (an ech
# outer name, a scanner), never traefik's self-signed default, and send X-XSS-Protection: 0 and no interest-cohort
#
# Each ingress runs its production tls store, not offline-traefik's test certificate: the acme store is seeded with the
# test ca's *.lsck0.dev leaf under the resolver's name, as lets encrypt would have left it, so only defaultGeneratedCert
# can hand it to an unknown name.
{
  pkgs,
  lib,
  inputs,
  specialArgs,
  ...
}:
let
  lab = import ../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
  pki = import ../../../tests/lib/pki.nix { inherit pkgs; };
  inherit (specialArgs.site) domain;
  ingresses = {
    "100" = "100-internal-traefik";
    "200" = "200-external-traefik";
  };
  traefikOf = id: inputs.self.nixosConfigurations.${ingresses.${id}}.config.services.traefik;
  storeOf = id: (traefikOf id).dynamicConfigOptions.tls.stores.default;
  resolverOf = id: (storeOf id).defaultGeneratedCert.resolver;
  secureHeaderSets =
    id: lib.filterAttrs (n: _: lib.hasPrefix "secure-headers" n) (traefikOf id).dynamicConfigOptions.http.middlewares;
  acmeStorage = "/var/lib/traefik/acme/acme.json";
  unknownName = "unknown.example";

  acmeSeed =
    id:
    pkgs.runCommand "acme-seed-${id}.json" { nativeBuildInputs = [ pkgs.jq ]; } ''
      jq -n --arg cert "$(base64 -w0 ${pki.lsck0.cert})" --arg key "$(base64 -w0 ${pki.lsck0.key})" '{
        "${resolverOf id}": {
          Account: null,
          Certificates: [{ domain: ${builtins.toJSON (storeOf id).defaultGeneratedCert.domain}, certificate: $cert, key: $key, Store: "default" }]
        }
      }' > $out
    '';

  ingress = id: {
    imports = [
      (lab.guest id {
        flat = true;
        instance = ../../../instances/core/${ingresses.${id}}/main.nix;
      })
      ../../../tests/lib/offline-traefik.nix
    ];
    environment.systemPackages = [
      pkgs.curl
      pkgs.openssl
    ];
    services.traefik.dynamicConfigOptions.tls.stores.default = lib.mkForce (storeOf id);
    systemd.services.acme-seed = {
      wantedBy = [ "traefik.service" ];
      before = [ "traefik.service" ];
      serviceConfig.Type = "oneshot";
      script = "install -o traefik -g traefik -m 600 ${acmeSeed id} ${acmeStorage}";
    };
  };
in
assert lib.all (
  id:
  lib.all (h: h.headers.customResponseHeaders.X-XSS-Protection == "0" && !(h.headers.browserXssFilter or false)) (
    lib.attrValues (secureHeaderSets id)
  )
  && !(lib.hasInfix "interest-cohort" (builtins.toJSON (secureHeaderSets id)))
  && (storeOf id).defaultGeneratedCert.domain.main == domain
) (lib.attrNames ingresses);
pkgs.testers.runNixOSTest {
  name = "default-cert";
  node.specialArgs = lab.specialArgs;

  nodes = lib.mapAttrs' (id: _: lib.nameValuePair "vm-${id}" (ingress id)) ingresses;

  testScript = ''
    start_all()
    for vm in (vm_100, vm_200):
        vm.wait_for_unit("traefik.service")
        vm.wait_for_open_port(443)
        vm.wait_until_succeeds("test -e /var/lib/crowdsec/data/stub-ready")
        for name in ("${unknownName}", "${domain}"):
            chain = vm.wait_until_succeeds(
                f"openssl s_client -connect 127.0.0.1:443 -servername {name} -verify_return_error </dev/null 2>&1"
                " | grep -E '^ *[0-9]+ s:|Verify return code'"
            )
            assert "TRAEFIK DEFAULT CERT" not in chain, chain
            assert "s:CN=${domain}" in chain and "Verify return code: 0 (ok)" in chain, chain

    # robots.txt answers every host the bot defence covers, an unknown one included, through the secure headers
    headers = vm_200.succeed(
        "curl -sS -o /dev/null -D - --resolve ${unknownName}:443:127.0.0.1 -k https://${unknownName}/robots.txt"
    ).lower()
    assert "x-xss-protection: 0\r\n" in headers and "interest-cohort" not in headers, headers
  '';
}
