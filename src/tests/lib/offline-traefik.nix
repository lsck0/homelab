# a real ingress (instances/100-internal-traefik/main.nix or 200-external-traefik.nix) in a test vm without internet
#
# Import it on top of the instance (lab.guest "100" { instance = ...; } plus this module). Every route keeps its
# rules and middlewares; what changes is where the outside world was:
# - tls: lets encrypt is out of reach, so the routes' certResolver falls back to the default certificate, the
#   test ca's *.lsck0.dev leaf (lib/pki.nix), which every lab node trusts: clients verify, no `curl -k`.
# - crowdsec: the real container unit runs lib/crowdsec-stub.py instead of crowdsec, so the real bouncer plugin
#   (pinned, modules/traefik) asks a local api a test controls. Ban an address by writing it to
#   /var/lib/crowdsec/data/stub-bans; every lapi and appsec call lands in /var/lib/crowdsec/data/stub-calls.jsonl.
#   The plugin's live mode caches its verdict per client address for a minute: ban an address before its first
#   request, or use a fresh one. AppSec answers 403 to a request carrying X-Test-Attack: 1. The bouncer refuses
#   everything until the stub listens: wait for /var/lib/crowdsec/data/stub-ready before the first request.
# - the house whitelist job asks ipify for the public address: off.
{ config, lib, pkgs, ... }:
let
  pki = import ./pki.nix { inherit pkgs; };
  images = import ./images.nix { inherit pkgs; };
in {
  config = lib.mkMerge [
    {
      assertions = [{
        assertion = config.homelab.traefik.enable;
        message = "lib/offline-traefik.nix belongs on an ingress: import it with 100- or 200-*-traefik.nix";
      }];

      # traefik waits for the nas-held acme store otherwise
      systemd.tmpfiles.rules = [ "f /var/lib/traefik/acme/acme.json 0600 traefik traefik -" ];

      services.traefik.dynamicConfigOptions.tls.stores.default.defaultCertificate = {
        certFile = pki.lsck0.cert;
        keyFile = pki.lsck0.key;
      };

      virtualisation.oci-containers.containers.crowdsec = {
        image = lib.mkForce "crowdsec-stub:test";
        imageFile = images.crowdsec-stub;
      };
    }

    (lib.mkIf config.homelab.traefik.crowdsecBouncer.enable {
      systemd.services.crowdsec-home-whitelist.wantedBy = lib.mkForce [ ];
      systemd.timers.crowdsec-home-whitelist.wantedBy = lib.mkForce [ ];
    })
  ];
}
