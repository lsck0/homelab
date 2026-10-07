# the apps platform's laws over the real configurations (tests/policy-eval.nix)
#
# - the catalog holds: no route, host or port collision, every secret generated (modules/catalog.nix problems;
#   every host asserts them at build time, this catches them at evaluation)
# - every port an app publishes is guarded on every swarm node: the routing mesh publishes it on all of them
# - the builder's key does one thing: the forced command on the manager, from the builder's address only
# - ci isolation on the ci vm: every github runner is its own ephemeral user that holds no cache, registry or deploy
#   credential, reaches dns only, and never the nix daemon; no rootless user is in a group that is root, on the ci
#   vm or the builder's; only the builder reads the builder's credentials
# - the registry reads and writes on disjoint methods, so one host may pull and push with one credential each; reads
#   admit exactly the swarms (the apps zone, every cluster's manager) and the pushers, writes the pushers alone
# - vm-105 scrapes cadvisor and the log shipper on every node app tasks run on, a guest-placed app's own guest too
{ lib, configs, inventory, catalog, appsCatalog, ... }:
let
  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  # an inventory entry's name is its configuration's
  builderHost = catalog.builder.name;
  managerHost = catalog.manager.name;
  # every node app tasks run on: each cluster's workers (a guest-placed app's own guest is its cluster's one)
  appNodeIds = lib.unique (lib.concatMap (c: c.workerIds) (lib.attrValues catalog.clusters));
  swarmHosts = lib.filterAttrs (name: _: builtins.match "(${lib.concatStringsSep "|" ([ catalog.swarm.managerId ] ++ appNodeIds)})-.*" name != null) configs;
  # groups whose members are root on the vm, one way or another
  rootGroups = [ "wheel" "docker" "root" ];
  builderSecrets = [ "app-deploy-key" "registry-builder-password" ];
  dnsPort = 53;

  # -----------------------------------------------------------------------------
  # LAWS
  # -----------------------------------------------------------------------------

  published = catalog.ports.external ++ catalog.ports.internal ++ catalog.ports.metrics;
  guardLaws = lib.concatLists (lib.mapAttrsToList (name: c:
    map (port: "${name}: published app port ${toString port} is not in homelab.ingressOnly.ports, anyone reaches it")
      (lib.subtractLists c.homelab.ingressOnly.ports published)
  ) swarmHosts);

  manager = configs.${managerHost};
  builderIp = catalog.builder.ip;
  deployKeyLines = lib.filter (line: lib.hasInfix manager.homelab.swarm.deployKey line)
    manager.users.users.root.openssh.authorizedKeys.keys;
  deployKeyLaws =
    lib.optional (lib.length deployKeyLines != 1) "${managerHost}: the builder's key is authorised ${toString (lib.length deployKeyLines)} times, not once"
    ++ map (line: "${managerHost}: the builder's key is not restricted to its forced command from ${builderIp}: ${line}")
      (lib.filter (line: !(lib.hasPrefix ''restrict,from="${builderIp}",command="'' line)) deployKeyLines);

  builder = configs.${builderHost};
  # the vm running the github runners
  ciHost = lib.head (lib.attrNames (lib.filterAttrs (_: c: c.services.github-runners != { }) configs));
  ci = configs.${ciHost};
  runners = ci.services.github-runners;
  rootless = ci.homelab.rootlessDocker;
  runnerUser = r: r.user;
  isDns = a: a.port == dnsPort && lib.elem a.ip ci.networking.nameservers;
  runnerLaws = lib.concatLists (lib.mapAttrsToList (name: r: let user = runnerUser r; u = rootless.${user} or null; in
    lib.optional (user == null || user == "root") "${ciHost}: github runner ${name} runs as ${toString user}"
    ++ lib.optional (u == null) "${ciHost}: github runner ${name}'s user ${user} has no rootless docker of its own"
    ++ lib.optionals (u != null) (
      lib.optional (!u.ephemeral) "${ciHost}: github runner ${name}'s user ${user} keeps its state between jobs"
      ++ map (a: "${ciHost}: github runner ${name}'s user ${user} reaches ${a.ip}:${toString a.port} in the lab")
        (lib.filter (a: !(isDns a)) u.labAccess))
    ++ lib.optional (lib.length (lib.filter (r': runnerUser r' == user) (lib.attrValues runners)) > 1)
      "${ciHost}: github runner ${name} shares user ${user} with another runner"
    ++ lib.optional (lib.hasAttr "EnvironmentFile" r.serviceOverrides) "${ciHost}: github runner ${name} gets an EnvironmentFile (a credential)"
  ) runners);

  hostUserLaws = host: c: lib.concatLists (lib.mapAttrsToList (user: _: let groups = c.users.users.${user}.extraGroups; in
    map (g: "${host}: rootless user ${user} is in group ${g}, which is root") (lib.intersectLists groups rootGroups)
    ++ lib.optional (lib.elem user c.nix.settings.allowed-users) "${host}: ${user} may use the nix daemon"
  ) c.homelab.rootlessDocker)
  ++ lib.optional (lib.elem "*" c.nix.settings.allowed-users) "${host}: every user may use the nix daemon";
  userLaws = hostUserLaws ciHost ci ++ hostUserLaws builderHost builder
  ++ map (s: "${builderHost}: ${s} belongs to ${builder.sops.secrets.${s}.owner}, not the app builder")
    (lib.filter (s: builder.sops.secrets.${s}.owner != "appbuild") builderSecrets)
  ++ lib.optional (ci.sops.templates."sccache-redis.env".owner != "ci") "${ciHost}: the cache credential belongs to a user other than ci";

  hostSubIdLaws = host: c: let
    ranges = lib.concatLists (lib.mapAttrsToList (user: u: map (r: { inherit user; inherit (r) startUid count; }) u.subUidRanges)
      (lib.filterAttrs (_: u: u.subUidRanges != [ ]) c.users.users));
    overlap = a: b: a.startUid < b.startUid + b.count && b.startUid < a.startUid + a.count;
  in lib.concatLists (lib.imap0 (i: a: map (b: "${host}: the subuid ranges of ${a.user} and ${b.user} overlap")
    (lib.filter (b: overlap a b) (lib.drop (i + 1) ranges))) ranges);
  subIdLaws = hostSubIdLaws ciHost ci ++ hostSubIdLaws builderHost builder;

  inherit (catalog.internal) registry-api registry-push;
  sorted = lib.sort lib.lessThan;
  readers = sorted (lib.unique ([ catalog.appsZone ] ++ registry-push.sources
    ++ map (a: "${inventory.${a.cluster.manager}.ip}/32") (lib.attrValues catalog.apps) ++ [ "${catalog.manager.ip}/32" ]));
  registryLaws = lib.optional (sorted registry-api.sources != readers)
    "registry-api admits ${toString (sorted registry-api.sources)}, not the swarms and pushers ${toString readers}"
    ++ lib.optional (lib.intersectLists registry-api.methods registry-push.methods != [ ])
      "registry-api and registry-push share methods ${toString (lib.intersectLists registry-api.methods registry-push.methods)}: the longer rule wins, and a host that pulls and pushes is refused one of its credentials";

  telemetry = import ../../modules/telemetry.nix { inherit lib inventory; };
  collectorHost = inventory.${telemetry.collectorVmid}.name;
  scraped = lib.concatMap (job: lib.concatMap (s: s.targets) job.static_configs) configs.${collectorHost}.services.prometheus.scrapeConfigs;
  nodeTelemetryPorts = { cadvisor = appsCatalog.cadvisorPort; "log shipper" = telemetry.ports.promtail; };
  scrapeLaws = lib.optionals (catalog.apps != { }) (lib.concatMap (id: lib.mapAttrsToList (what: port:
    "${collectorHost} does not scrape the ${what} of app node vm-${id} (${inventory.${id}.ip}:${toString port})")
    (lib.filterAttrs (_: port: !(lib.elem "${inventory.${id}.ip}:${toString port}" scraped)) nodeTelemetryPorts)) appNodeIds);
in
map (p: "catalog: ${p}") catalog.problems
++ guardLaws ++ deployKeyLaws ++ runnerLaws ++ userLaws ++ subIdLaws ++ registryLaws ++ scrapeLaws
