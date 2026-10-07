# lab-wide: the positive controls of every law in tests/policy, over every configuration
# each law of tests/policy, run over the real facts (tests/policy/lib/facts.nix) with one thing broken the way the
# law forbids, must report it: a law that stays silent on its own violation proves nothing when policy-eval passes.
# A control is { law file; the words its violation carries; the tampered facts }.
{ pkgs, lib, inputs, specialArgs, ... }:
let
  facts = import ./policy/lib/facts.nix { inherit lib inputs specialArgs; };
  inherit (facts) configs inventory site;

  # one config with one value replaced at a path
  tamper = name: path: value: facts // {
    configs = configs // { ${name} = lib.recursiveUpdate configs.${name} (lib.setAttrByPath path value); };
  };
  http = name: configs.${name}.services.traefik.dynamicConfigOptions.http;
  edgeRouter = (http "200-external-traefik").routers.share-tls;
  forwardRules = configs."300-router".networking.firewall.extraForwardRules;
  natLine = lib.findFirst (l: lib.hasInfix "comment" l && lib.hasInfix "accept" l) "" (lib.splitString "\n" forwardRules);
  traefik = [ "services" "traefik" "dynamicConfigOptions" "http" ];
  # a well-formed app the ports law sees twice
  hello = facts.appsCatalog.apps.hello;

  network = law: tampered: { file = "network"; marker = "${law}: "; inherit tampered; };
  controls = {
    defence-chain = network "defence chain" (tamper "200-external-traefik" (traefik ++ [ "routers" "share-tls" ])
      (edgeRouter // { middlewares = lib.tail edgeRouter.middlewares; }));
    sso-routes = network "sso routes" (tamper "100-internal-traefik" (traefik ++ [ "routers" "grafana-tls" "middlewares" ])
      (lib.remove "authelia" (http "100-internal-traefik").routers.grafana-tls.middlewares));
    apps-zone = network "apps zone" (tamper "100-internal-traefik" (traefik ++ [ "routers" "grafana-tls" "rule" ]) "Host(`grafana.lsck0.dev`)");
    tls-verification = network "tls verification" (tamper "200-external-traefik" (traefik ++ [ "serversTransports" "grafana-relay" ])
      { insecureSkipVerify = true; });
    no-catch-all = network "no catch-all" (tamper "200-external-traefik" (traefik ++ [ "routers" "catch-all" ])
      { rule = "HostRegexp(`.+`)"; service = "noop@internal"; });
    client-identity = network "client identity" (tamper "100-internal-traefik" (traefik ++ [ "middlewares" "client-ip" "plugin" "client-ip" "trustedIPs" ])
      [ "10.0.0.0/8" ]);
    router-order = network "router order" (tamper "300-router" [ "networking" "firewall" "extraForwardRules" ] (natLine + "\n" + forwardRules));
    inventory = network "inventory" (facts // { inventory = inventory // { "206" = inventory."206" // { idle = "30m"; type = "apps"; }; }; });
    ingress-guards = network "ingress guards" (tamper "121-internal-paperless" [ "homelab" "ingressOnly" "trusted" ]
      [ "${inventory."114".ip}/32" ]);

    published-unguarded = { file = "apps"; marker = "is not in homelab.ingressOnly.ports";
      tampered = tamper "250-apps-swarm" [ "homelab" "ingressOnly" "ports" ] [ ]; };
    needs = { file = "guests"; marker = "vm.needs is";
      tampered = tamper "101-internal-authelia" [ "virtualisation" "podman" "enable" ] true; };
    shares = { file = "guests"; marker = "it does not declare";
      tampered = tamper "121-internal-paperless" [ "homelab" "nasShares" ]
        (configs."121-internal-paperless".homelab.nasShares ++ [ { path = "/srv/nas/data/stray"; readOnly = false; mode = "0700"; } ]); };
    memory-budget = { file = "guests"; marker = "host memory:";
      tampered = facts // { lab = facts.lab // { instances = facts.lab.instances // {
        "119" = lib.recursiveUpdate facts.lab.instances."119" { config.vm.balloonMiB = 1024 * 1024; };
      }; }; }; };
    port-twice = { file = "ports"; marker = "is published for";
      tampered = facts // { appsCatalog = facts.appsCatalog // { apps = facts.appsCatalog.apps // { twin = hello // { enable = true; }; }; }; }; };
    sso-groups = { file = "sso"; marker = "which lldap's bootstrap never creates";
      tampered = tamper "101-internal-authelia" [ "systemd" "services" "lldap-bootstrap" "environment" "BOOTSTRAP_GROUPS" ] "admins"; };
    realm-ldaps = { file = "sso"; marker = "proxmox realm: ";
      tampered = tamper "101-internal-authelia" [ "networking" "firewall" "allowedTCPPorts" ] [ 3890 ]; };
    secret-readable ={ file = "secrets"; marker = "is readable by others";
      tampered = tamper "101-internal-authelia" [ "sops" "secrets" "authelia-jwt-secret" "mode" ] "0444"; };
    query-readers = { file = "telemetry"; marker = "which is neither an internal guest";
      tampered = tamper "105-internal-grafana" [ "homelab" "ingressOnly" "allowed" "9090" ] [ site.lan.subnet ]; };
    push-tenant = { file = "telemetry"; marker = "forwards without the tenant its sender's address names";
      tampered = tamper "105-internal-grafana" [ "services" "nginx" "virtualHosts" "otlp-http" "locations" "= /v1/traces" "extraConfig" ]
        "proxy_pass http://127.0.0.1:14318;"; };
    relay-tenant = { file = "telemetry"; marker = "a relay location forwards without the tenant";
      tampered = tamper "250-apps-swarm" [ "homelab" "appTelemetry" "relayConfig" ] "location = /v1/traces { proxy_pass http://collector; }"; };
    access-log-secrets = { file = "telemetry"; marker = "unredacted";
      tampered = tamper "200-external-traefik" [ "services" "promtail" "configuration" "scrape_configs" ]
        (map (j: j // { pipeline_stages = lib.filter (s: !(s ? replace)) (j.pipeline_stages or [ ]); })
          configs."200-external-traefik".services.promtail.configuration.scrape_configs); };
    test-of-another-instance = { file = "placement"; marker = "tests instances/101-internal-b/lib/b.nix";
      tampered = facts // { src = ./policy/lib/placement-fixture; }; };
    instance-folder = { file = "placement"; marker = "src/instances/101-internal-authelia has no main.nix";
      tampered = facts // { src = builtins.path {
        path = facts.src;
        name = "src-without-a-main";
        filter = path: _: !(lib.hasSuffix "/instances/101-internal-authelia/main.nix" path);
      }; }; };
  };

  silent = lib.filterAttrs (_: c: !(lib.any (lib.hasInfix c.marker) (import ./policy/${c.file}.nix c.tampered))) controls;
in
assert lib.assertMsg (silent == { }) "these laws stay silent on their own violation: ${toString (lib.attrNames silent)}";
pkgs.runCommand "policy-controls" { } ''
  echo "policy-controls: ${toString (lib.length (lib.attrNames controls))} controls, each law reports its violation"
  touch $out
''
