# lab-wide: the network laws' positive controls, over every configuration
# the positive controls of tests/policy/network.nix: each law, run over the real configurations with one thing
# broken the way the law forbids, must report it. A law that stays silent on its own violation proves nothing when
# policy-eval passes.
{ pkgs, lib, inputs, specialArgs, ... }:
let
  configs = lib.mapAttrs (_: system: system.config) inputs.self.nixosConfigurations;
  appsCatalog = configs."300-router".homelab.appsCatalog;
  facts = {
    inherit lib configs appsCatalog;
    inherit (specialArgs) inventory site nasClients;
    catalog = import ../modules/catalog.nix { inherit lib appsCatalog; inherit (specialArgs) inventory site lab; };
  };
  laws = import ./policy/network.nix;

  # one config with one value replaced at a path
  tamper = name: path: value: facts // {
    configs = configs // { ${name} = lib.recursiveUpdate configs.${name} (lib.setAttrByPath path value); };
  };
  http = name: configs.${name}.services.traefik.dynamicConfigOptions.http;
  edgeRouter = (http "200-external-traefik").routers.share-tls;
  forwardRules = configs."300-router".networking.firewall.extraForwardRules;
  natLine = lib.findFirst (l: lib.hasInfix "comment" l && lib.hasInfix "accept" l) "" (lib.splitString "\n" forwardRules);

  controls = {
    "defence chain" = tamper "200-external-traefik" [ "services" "traefik" "dynamicConfigOptions" "http" "routers" "share-tls" ]
      (edgeRouter // { middlewares = lib.tail edgeRouter.middlewares; });
    "sso routes" = tamper "100-internal-traefik" [ "services" "traefik" "dynamicConfigOptions" "http" "routers" "grafana-tls" "middlewares" ]
      (lib.remove "authelia" (http "100-internal-traefik").routers.grafana-tls.middlewares);
    "apps zone" = tamper "100-internal-traefik" [ "services" "traefik" "dynamicConfigOptions" "http" "routers" "grafana-tls" "rule" ]
      "Host(`grafana.lsck0.dev`)";
    "tls verification" = tamper "200-external-traefik" [ "services" "traefik" "dynamicConfigOptions" "http" "serversTransports" "grafana-relay" ]
      { insecureSkipVerify = true; };
    "no catch-all" = tamper "200-external-traefik" [ "services" "traefik" "dynamicConfigOptions" "http" "routers" "catch-all" ]
      { rule = "HostRegexp(`.+`)"; service = "noop@internal"; };
    "client identity" = tamper "100-internal-traefik" [ "services" "traefik" "dynamicConfigOptions" "http" "middlewares" "client-ip" "plugin" "client-ip" "trustedIPs" ]
      [ "10.0.0.0/8" ];
    "router order" = tamper "300-router" [ "networking" "firewall" "extraForwardRules" ] (natLine + "\n" + forwardRules);
    "inventory" = facts // { inventory = facts.inventory // { "206" = facts.inventory."206" // { enabled = "ondemand"; }; }; };
    "ingress guards" = tamper "121-internal-paperless" [ "homelab" "ingressOnly" "extraSources" ] [ "${facts.inventory."114".ip}/32" ];
  };

  silent = lib.filterAttrs (law: tampered: !(lib.any (v: lib.hasPrefix "${law}: " v) (laws tampered))) controls;
in
assert lib.assertMsg (silent == { }) "policy/network.nix stays silent on its own violation: ${toString (lib.attrNames silent)}";
pkgs.runCommand "policy-network-controls" { } ''
  echo "policy-network-controls: ${toString (lib.length (lib.attrNames controls))} laws each report their violation"
  touch $out
''
