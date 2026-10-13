# lab-wide: the positive controls of every law in tests/policy, over every configuration
# each law of tests/policy, run over the real facts (tests/policy/lib/facts.nix) with one thing broken the way the
# law forbids, must report it: a law that stays silent on its own violation proves nothing when policy-eval passes.
# A control is { law file; the words its violation carries; the tampered facts }.
{ pkgs, lib, inputs, specialArgs, ... }:
let
  facts = import ./policy/lib/facts.nix { inherit lib inputs specialArgs; };
  inherit (facts) configs inventory site catalog;
  net = import ../modules/net.nix { inherit lib inventory site; };

  # one config with one value replaced at a path
  tamper = name: path: value: facts // {
    configs = configs // { ${name} = lib.recursiveUpdate configs.${name} (lib.setAttrByPath path value); };
  };
  # one config mounting one more share
  mounting = name: path: tamper name [ "homelab" "nasShares" ]
    (configs.${name}.homelab.nasShares ++ [ { inherit path; readOnly = false; mode = null; localState = false; } ]);
  # the source tree without the files a predicate names
  srcWithout = name: drop: facts // { src = builtins.path { path = facts.src; inherit name; filter = path: _: !(drop path); }; };
  http = name: configs.${name}.services.traefik.dynamicConfigOptions.http;
  edgeRouter = (http "200-external-traefik").routers.share-tls;
  forwardRules = configs."300-router".networking.firewall.extraForwardRules;
  natLine = lib.findFirst (l: lib.hasInfix "comment" l && lib.hasInfix "accept" l) "" (lib.splitString "\n" forwardRules);
  traefik = [ "services" "traefik" "dynamicConfigOptions" "http" ];
  gate = [ "homelab" "traefik" "gate" "settings" ];
  # a well-formed app the ports law sees twice
  hello = facts.appsCatalog.apps.hello;
  # the first address of the router's first lease pool
  poolStart = lib.trim (lib.head (lib.splitString "-" (lib.head (lib.head configs."300-router".services.kea.dhcp4.settings.subnet4).pools).pool));
  # the ci vm, its github runner and its two rootless users
  ci = "111-internal-github-runner";
  runner = lib.head (lib.attrNames configs.${ci}.services.github-runners);
  builder = inventory.${catalog.swarm.builderId}.name;
  owner = "101-internal-authelia";
  parkedId = lib.findFirst (id: !inventory.${id}.powered) (throw "policy-controls: no powered-off guest") (lib.attrNames inventory);
  ownerFolder = facts.lab.hosts.${owner}.folder;

  network = law: tampered: { file = "network"; marker = "${law}: "; inherit tampered; };
  controls = {
    defence-chain = network "defence chain" (tamper "200-external-traefik" (traefik ++ [ "routers" "share-tls" ])
      (edgeRouter // { middlewares = lib.tail edgeRouter.middlewares; }));
    waf-without-gate = { file = "network"; marker = "router share-tls: the waf runs without the gate in front";
      tampered = tamper "200-external-traefik" (traefik ++ [ "routers" "share-tls" ])
        (edgeRouter // { middlewares = lib.filter (m: !(lib.hasPrefix "gate" m)) edgeRouter.middlewares; }); };
    sso-routes = network "sso routes" (tamper "100-internal-traefik" (traefik ++ [ "routers" "grafana-tls" "middlewares" ])
      (lib.remove "authelia" (http "100-internal-traefik").routers.grafana-tls.middlewares));
    sso-paths = network "sso paths" (facts // { catalog = catalog // { internal = catalog.internal // {
      forgejo = catalog.internal.forgejo // { ssoPaths = [ "/metrics" ]; };
    }; }; });
    direct-scrapes = network "direct scrapes" (tamper "103-internal-grafana" [ "services" "prometheus" "scrapeConfigs" ]
      (configs."103-internal-grafana".services.prometheus.scrapeConfigs
        ++ [ { job_name = "control"; static_configs = [ { targets = [ "${catalog.ingress.internal.ip}:${toString net.ports.https}" ]; } ]; } ]));
    apps-zone = network "apps zone" (tamper "100-internal-traefik" (traefik ++ [ "routers" "grafana-tls" "rule" ]) "Host(`grafana.lsck0.dev`)");
    pull-part-credential = { file = "network"; marker = "registry-api-tls-socket pulls without a credential";
      tampered = tamper "100-internal-traefik" (traefik ++ [ "routers" "registry-api-tls-socket" "middlewares" ])
        (lib.filter (m: !(lib.hasSuffix "-auth" m)) (http "100-internal-traefik").routers.registry-api-tls-socket.middlewares); };
    tls-verification = network "tls verification" (tamper "200-external-traefik" (traefik ++ [ "serversTransports" "grafana-relay" ])
      { insecureSkipVerify = true; });
    buffered-downloads = network "buffered downloads" (tamper "200-external-traefik" (traefik ++ [ "routers" "mirror-tls" "middlewares" ])
      ((http "200-external-traefik").routers.mirror-tls.middlewares
        ++ lib.take 1 (lib.attrNames (lib.filterAttrs (_: m: m ? buffering) (http "200-external-traefik").middlewares))));
    internal-only = network "internal only" (tamper "200-external-traefik" (traefik ++ [ "middlewares" "internal-only" "ipAllowList" "sourceRange" ])
      [ "10.0.0.0/8" ]);
    reach = network "reach" (tamper "300-router" [ "networking" "firewall" "extraForwardRules" ]
      (lib.concatStringsSep "\n" (lib.filter (l: !(lib.hasInfix "dport { ${toString facts.catalog.swarm.controllerPort} }" l))
        (lib.splitString "\n" forwardRules))));
    # the mirror's unlimited router answering the internet too
    house-routers = network "house routers" (tamper "200-external-traefik" (traefik ++ [ "routers" "mirror-house" "rule" ])
      "${(http "200-external-traefik").routers.mirror-house.rule} || ClientIP(`0.0.0.0/0`)");
    no-catch-all = network "no catch-all" (tamper "200-external-traefik" (traefik ++ [ "routers" "catch-all" ])
      { rule = "HostRegexp(`.+`)"; service = "noop@internal"; });
    client-identity = network "client identity" (tamper "100-internal-traefik" (traefik ++ [ "middlewares" "client-ip" "plugin" "client-ip" "trustedIPs" ])
      [ "10.0.0.0/8" ]);
    metrics-blocks = network "metrics blocks" (tamper "200-external-traefik" (traefik ++ [ "routers" "control-metrics-block" ])
      { rule = "PathPrefix(`/metrics`)"; priority = 1; service = "noop@internal"; });
    router-order = network "router order" (tamper "300-router" [ "networking" "firewall" "extraForwardRules" ] (natLine + "\n" + forwardRules));
    # a guest declared a tor member that the router does not render as one
    egress-killswitch = network "egress killswitch" (facts // { lab = facts.lab // {
      egress = facts.lab.egress // { "131" = { via = "tor"; inbound = false; vmid = 131; }; };
    }; });
    # a route declared onion, with an address, that neither the edge nor the router's tor serves
    onion = network "onion" (facts // { catalog = catalog // { external = catalog.external // {
      privatebin = catalog.external.privatebin // { onion = true; onionAddress = "${lib.fixedWidthString 56 "a" ""}.onion"; };
    }; }; });
    inventory = network "inventory" (facts // { inventory = inventory // { "212" = inventory."212" // { ip = poolStart; }; }; });
    ingress-guards = network "ingress guards" (tamper "131-internal-paperless" [ "homelab" "ingressOnly" "trusted" ]
      [ "${inventory.${facts.lab.roles.operator}.ip}/32" ]);
    probes-through-ingress = network "probes through the ingress" (tamper "131-internal-paperless" [ "homelab" "ingressOnly" "allowed" ]
      { ${toString catalog.internal.paperless.port} = [ "${inventory.${facts.lab.roles.collector}.ip}/32" ]; });
    # paperless configured with grafana's port, whose guard admits it nowhere (the target must run: a parked one is no call)
    direct-calls = network "direct calls" (tamper "131-internal-paperless" [ "systemd" "services" "paperless-scheduler" "environment" "CONTROL_URL" ]
      "http://${inventory.${toString catalog.internal.grafana.vmid}.ip}:${toString catalog.internal.grafana.port}/api");
    port-forwards = network "port forwards" (tamper "300-router" [ "networking" "nftables" "tables" "port-forwards" "content" ]
      "tcp dport  dnat to ${inventory.${facts.lab.roles.collector}.ip}:${toString catalog.internal.paperless.port}");

    gate-allow = { file = "antibot"; marker = "vm-200's gate stops wireguard";
      tampered = tamper "200-external-traefik" (gate ++ [ "allow" "cidrs" ]) [ net.wan.subnet ]; };
    gate-allow-house = { file = "antibot"; marker = "vm-100's gate stops the house's v6 prefix behind cloudflare";
      tampered = tamper "100-internal-traefik" (gate ++ [ "allow" "hosts" ])
        (lib.take 1 configs."100-internal-traefik".homelab.traefik.gate.settings.allow.hosts); };
    crowdsec-whitelist = { file = "antibot"; marker = "vm-100's crowdsec may ban the house lan";
      tampered = tamper "100-internal-traefik" [ "homelab" "traefik" "crowdsecBouncer" "whitelistCidrs" ] [ "10.0.0.0/8" ]; };
    gate-session = { file = "antibot"; marker = "vm-200's gate cannot tell a logged-in user";
      tampered = tamper "200-external-traefik" (gate ++ [ "session" ]) null; };
    captcha-default = { file = "antibot"; marker = "router share-tls: the gate's captcha is 0";
      tampered = tamper "200-external-traefik" (traefik ++ [ "middlewares" "gate" "forwardAuth" "address" ])
        (lib.replaceStrings [ "captcha=1" ] [ "captcha=0" ] (http "200-external-traefik").middlewares.gate.forwardAuth.address); };
    onion-captcha = { file = "antibot"; marker = "vm-200 onion router hello-onion has no gate";
      tampered = tamper "200-external-traefik" (traefik ++ [ "routers" "hello-onion" "middlewares" ])
        (lib.filter (m: !(lib.hasPrefix "gate" m)) (http "200-external-traefik").routers.hello-onion.middlewares); };
    onion-captcha-addresses = { file = "antibot"; marker = "vm-200's gate does not know the onion address";
      tampered = tamper "200-external-traefik" (gate ++ [ "captcha" "onions" ])
        (lib.mapAttrs (_: _: "${lib.fixedWidthString 56 "a" ""}.onion") configs."200-external-traefik".homelab.traefik.gate.settings.captcha.onions); };
    captcha-answer-log = { file = "antibot"; marker = "200-external-traefik logs every captcha's answer";
      tampered = tamper "200-external-traefik" (gate ++ [ "captcha" "answerLog" ]) "/run/lab-gate/answers"; };

    catalog = { file = "apps"; marker = "catalog: a control's problem";
      tampered = facts // { catalog = catalog // { problems = [ "a control's problem" ]; }; }; };
    published-unguarded = { file = "apps"; marker = "is not in homelab.ingressOnly.ports";
      tampered = tamper "250-apps-swarm" [ "homelab" "ingressOnly" "ports" ] [ ]; };
    deploy-key = { file = "apps"; marker = "the builder's key is authorised";
      tampered = tamper builder [ "users" "users" "root" "openssh" "authorizedKeys" "keys" ]
        (configs.${builder}.users.users.root.openssh.authorizedKeys.keys ++ [ configs.${builder}.homelab.swarm.deployKey ]); };
    runner-user = { file = "apps"; marker = "github runner ${runner} runs as root";
      tampered = tamper ci [ "services" "github-runners" runner "user" ] "root"; };
    nix-daemon = { file = "apps"; marker = "every user may use the nix daemon";
      tampered = tamper ci [ "nix" "settings" "allowed-users" ] [ "*" ]; };
    subuid-overlap = { file = "apps"; marker = "subuid ranges of";
      tampered = tamper ci [ "users" "users" configs.${ci}.services.github-runners.${runner}.user "subUidRanges" ]
        configs.${ci}.users.users.ci.subUidRanges; };
    registry-methods = { file = "apps"; marker = "share methods";
      tampered = facts // { catalog = catalog // { internal = catalog.internal // {
        registry-api = catalog.internal.registry-api // { methods = [ "GET" "PUT" ]; };
      }; }; }; };
    node-scrapes = { file = "apps"; marker = "does not scrape";
      tampered = tamper "103-internal-grafana" [ "services" "prometheus" "scrapeConfigs" ] [ ]; };

    needs = { file = "guests"; marker = "vm.needs is";
      tampered = tamper owner [ "virtualisation" "podman" "enable" ] true; };
    shares = { file = "guests"; marker = "it does not declare";
      tampered = mounting "131-internal-paperless" "/srv/nas/data/stray"; };
    memory-budget = { file = "guests"; marker = "host memory:";
      tampered = facts // { lab = facts.lab // { instances = facts.lab.instances // {
        "112" = lib.recursiveUpdate facts.lab.instances."112" { config.vm.balloonMiB = 1024 * 1024; };
      }; }; }; };

    port-twice = { file = "ports"; marker = "is published for";
      tampered = facts // { appsCatalog = facts.appsCatalog // { apps = facts.appsCatalog.apps // { twin = hello // { enable = true; }; }; }; }; };

    sso-groups = { file = "sso"; marker = "which lldap's bootstrap never creates";
      tampered = tamper owner [ "systemd" "services" "lldap-bootstrap" "environment" "BOOTSTRAP_GROUPS" ] "admins"; };
    lldap-once = { file = "sso"; marker = "not on exactly one host";
      tampered = tamper owner [ "services" "lldap" "enable" ] false; };
    realm-ldaps = { file = "sso"; marker = "proxmox realm: ";
      tampered = tamper owner [ "networking" "firewall" "allowedTCPPorts" ] [ 3890 ]; };
    long-run-mount = { file = "mounts"; marker = "outlives deploys yet RequiresMountsFor";
      tampered = tamper "112-internal-archbuild" [ "systemd" "services" "archbuild" "unitConfig" "RequiresMountsFor" ]
        [ "/var/lib/archrepo" ]; };
    image-pulled-at-start = { file = "images"; marker = "pulls 'always' at every start";
      tampered = tamper "213-external-share" [ "virtualisation" "oci-containers" "containers" "share" "pull" ] "always"; };
    secret-readable = { file = "secrets"; marker = "is readable by others";
      tampered = tamper owner [ "sops" "secrets" "authelia-jwt-secret" "mode" ] "0444"; };
    sqlite-on-nfs = { file = "secrets"; marker = "lies on the nas mount";
      tampered = tamper "140-internal-headscale" [ "homelab" "nasMounts" "/var/lib/headscale" ] { }; };
    secret-source = { file = "secrets"; marker = "secret authelia-jwt-secret comes from";
      tampered = tamper owner [ "sops" "secrets" "authelia-jwt-secret" "sopsFile" ] ./policy-controls.nix; };
    secret-key-file = { file = "secrets"; marker = "sops reads its key from";
      tampered = tamper owner [ "sops" "age" "keyFile" ] "/etc/age.key"; };
    secret-ssh-key = { file = "secrets"; marker = "an ssh host key doubles as a sops key";
      tampered = tamper owner [ "sops" "age" "sshKeyPaths" ] [ "/etc/ssh/ssh_host_ed25519_key" ]; };
    secret-placeholder = { file = "secrets"; marker = "contains a sops placeholder";
      tampered = tamper owner [ "systemd" "services" "sshd" "environment" "CONTROL" ] "<SOPS:0:PLACEHOLDER>"; };
    secret-file-missing = { file = "secrets"; marker = "src/${ownerFolder}/secrets.sops.json is missing";
      tampered = srcWithout "src-without-a-secrets-file" (lib.hasSuffix "/${ownerFolder}/secrets.sops.json"); };
    token-share = { file = "secrets"; marker = "mounts another producer's";
      tampered = mounting "131-internal-paperless" "/srv/nas/data/tokens/vm-999"; };
    dump-share = { file = "secrets"; marker = "not its own dump dir";
      tampered = mounting "131-internal-paperless" "/srv/nas/data/db-dumps/vm-999"; };
    dmz-share = { file = "secrets"; marker = "dmz or apps host mounts";
      tampered = mounting "213-external-share" "/srv/nas/bulk/media"; };

    query-readers = { file = "telemetry"; marker = "which is neither an internal guest";
      tampered = tamper "103-internal-grafana" [ "homelab" "ingressOnly" "allowed" "9090" ] [ site.lan.subnet ]; };
    push-tenant = { file = "telemetry"; marker = "forwards without the tenant its sender's address names";
      tampered = tamper "103-internal-grafana" [ "services" "nginx" "virtualHosts" "otlp-http" "locations" "= /v1/traces" "extraConfig" ]
        "proxy_pass http://127.0.0.1:14318;"; };
    relay-tenant = { file = "telemetry"; marker = "a relay location forwards without the tenant";
      tampered = tamper "250-apps-swarm" [ "homelab" "appTelemetry" "relayConfig" ] "location = /v1/traces { proxy_pass http://collector; }"; };
    access-log-secrets = { file = "telemetry"; marker = "unredacted";
      tampered = tamper "200-external-traefik" [ "services" "promtail" "configuration" "scrape_configs" ]
        (map (j: j // { pipeline_stages = lib.filter (s: !(s ? replace)) (j.pipeline_stages or [ ]); })
          configs."200-external-traefik".services.promtail.configuration.scrape_configs); };
    parked-scrape = { file = "telemetry"; marker = "a powered-off guest";
      tampered = tamper "103-internal-grafana" [ "services" "prometheus" "scrapeConfigs" ]
        (configs."103-internal-grafana".services.prometheus.scrapeConfigs
          ++ [ { job_name = "control"; static_configs = [ { targets = [ "${inventory.${parkedId}.ip}:${toString net.ports.nodeExporter}" ]; } ]; } ]); };
    # a powered-off guest's own rule (instance.nix `alerts`), provisioned all the same
    parked-rule = { file = "telemetry"; marker = "is a powered-off guest's own";
      tampered = tamper "103-internal-grafana" [ "services" "grafana" "provision" "alerting" "rules" "settings" "groups" ]
        (configs."103-internal-grafana".services.grafana.provision.alerting.rules.settings.groups
          ++ [ { name = "control"; rules = [ { uid = "control"; } ]; } ])
        // { lab = facts.lab // { alerts = facts.lab.alerts // { control.vmid = lib.toInt parkedId; }; }; }; };

    test-of-another-instance = { file = "placement"; marker = "tests instances/preconfigured/101-internal-b/lib/b.nix";
      tampered = facts // { src = ./policy/lib/placement-fixture; }; };
    instance-folder = { file = "placement"; marker = "src/${ownerFolder} has no main.nix";
      tampered = srcWithout "src-without-a-main" (lib.hasSuffix "/${ownerFolder}/main.nix"); };
    module-folder = { file = "placement"; marker = "src/modules/traefik has no default.nix";
      tampered = srcWithout "src-without-a-module" (lib.hasSuffix "/modules/traefik/default.nix"); };
  };

  silent = lib.filterAttrs (_: c: !(lib.any (lib.hasInfix c.marker) (import ./policy/${c.file}.nix c.tampered))) controls;
in
assert lib.assertMsg (silent == { }) "these laws stay silent on their own violation: ${toString (lib.attrNames silent)}";
pkgs.runCommand "policy-controls" { } ''
  echo "policy-controls: ${toString (lib.length (lib.attrNames controls))} controls, each law reports its violation"
  touch $out
''
