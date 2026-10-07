# the collector: every fact about the lab's guests and apps, read from their folders, computed once
#
# An instance is a folder src/instances/<vmid>-<zone>-<service>/ (the router: 300-router/) holding main.nix (its
# nixos configuration) and instance.nix (what other hosts and terraform need to know about it, typed by
# modules/instance-schema.nix). The vmid and the zone come from the folder name; the name is the configuration's
# name and the proxmox guest's. The swarm's worker nodes have no folder: src/apps/swarm.nix `nodes` generates them,
# each running modules/swarm alone. An app is a folder src/apps/<name>/ with app.nix (typed by
# modules/apps-catalog). Folders starting with `_` (the template) are no instance.
#
# Everything below derives from those files plus src/generated/zones.json and src/generated/site.json; nothing reads
# a host's evaluated configuration, so the flake, every module (argument `lab`), every test and terraform
# (`terraform`, through `nix eval .#lab.terraform` in terraform/lib.tf) see the same facts without a generated file
# that could go stale.
#
#   lab = import ./modules/lab { inherit lib; };
#   lab.inventory."134"           # { name; type; kind; privileged; features; ip; prefix; gateway; powered; idle; }
#                                 # powered: vm.power is on; idle: idle.stopAfter, null for a guest that never idles
#   lab.instances."134"           # { id; zone; name; dir; main; source; config; }, config the evaluated instance.nix
#   lab.routes.jellyfin           # an instance service's route with every field (modules/service.nix), plus vmid
#   lab.appsCatalog               # src/apps/ typed by modules/apps-catalog: { apps; builder; swarm; cadvisorPort; controllerPort; }
#   lab.catalog                   # modules/catalog.nix over it: every route and app, what every host gets as `catalog`
#   lab.withApps f                # the lab collected again with its app folders passed through f (a test's fixture
#                                 # apps): workers, inventory and catalog follow them
#   lab.shares."140"              # [{ path; readOnly; mode; }] the nas paths a guest mounts: its instance.nix `shares`,
#                                 # its own token dir and those of the tokens it reads (lab.tokenReads."140")
#   lab.nasClients."10.100.0.140" # the same of every powered guest, by address: what vm-109 exports
#   lab.roles.collector           # "105": the vmid of the one instance declaring a role (instance.nix `roles`)
#   lab.alerts.backup_stale       # an instance's own alert rule (instance.nix `alerts`) plus its vmid; lab.probes alike
#
# problems: every broken lab-wide rule (zones.json against the instances, vmid ranges, vm shapes, duplicate names),
# one line each; the flake refuses to evaluate past one, so no host and no terraform plan proceeds.
#
# root: the tree to collect, src/ by default; tests/lab.nix collects broken fixture trees. apps: the app folders'
# app.nix values -> the ones collected (lab.withApps).
{ lib, root ? ../.., apps ? (folders: folders) }:
let
  # -------------------------------------------------------------------------------------------------------------
  # CONSTANTS
  # -------------------------------------------------------------------------------------------------------------

  instancesDir = root + "/instances";
  appsDir = root + "/apps";
  site = lib.importJSON (root + "/generated/site.json");
  zonesRaw = lib.importJSON (root + "/generated/zones.json");
  swarm = import (appsDir + "/swarm.nix");

  cidr = import ../cidr.nix { inherit lib; };
  limits = import ../limits { inherit lib; };
  schema = ../instance-schema.nix;

  # the router's role is its zone name in the folder and its type in the inventory
  routerZone = "router";
  # the swarm's workers live in this zone; their folder-less name is <vmid>-<zone>-<service>
  nodeZone = "apps";
  nodeService = "swarm";
  # `_template` and the like: documentation, never a guest
  hiddenPrefix = "_";
  # every nas path a guest declares lives below this on vm-109
  nasRoot = "/srv/nas";
  # a boot phase starts all its guests at once; the next waits this long so their boots do not stack up in ram
  bootPhaseWaitSeconds = 60;

  # -------------------------------------------------------------------------------------------------------------
  # INSTANCES
  # -------------------------------------------------------------------------------------------------------------

  # the visible subfolders of instances/ or apps/
  foldersOf = dir: lib.attrNames (lib.filterAttrs (name: kind: kind == "directory" && !(lib.hasPrefix hiddenPrefix name))
    (builtins.readDir dir));

  zonePattern = lib.concatStringsSep "|" (lib.attrNames zonesRaw);
  folderParse = folder:
    let
      guest = builtins.match "([1-9][0-9]*)-(${zonePattern})-([a-z0-9][a-z0-9-]*)" folder;
      router = builtins.match "([1-9][0-9]*)-${routerZone}" folder;
    in
    if guest != null then { id = lib.elemAt guest 0; zone = lib.elemAt guest 1; }
    else if router != null then { id = lib.head router; zone = routerZone; }
    else null;

  # a folder that is no instance is a problem below, never half an instance
  folderProblemOf = folder: let files = builtins.readDir (instancesDir + "/${folder}"); in
    if folderParse folder == null then
      "src/instances/${folder}: an instance folder is <vmid>-<zone>-<service> (zones: ${zonePattern}) or <vmid>-${routerZone}"
    else if !(files ? "main.nix" && files ? "instance.nix") then
      "src/instances/${folder}: an instance folder holds main.nix and instance.nix (see src/instances/_template)"
    else null;
  allFolders = foldersOf instancesDir;
  folders = lib.filter (folder: folderProblemOf folder == null) allFolders;

  # instance.nix over the schema; net and telemetry read the collected inventory, lazily, for ports and addresses
  instanceEval = { id, zone, module }: (lib.evalModules {
    modules = [ schema module ];
    specialArgs = { inherit id zone site net telemetry swarmManagers grantSourceNames; };
  }).config;

  instanceOfFolder = folder:
    let
      parsed = folderParse folder;
      dir = instancesDir + "/${folder}";
    in
    parsed // {
      name = folder;
      inherit dir;
      main = dir + "/main.nix";
      source = "instances/${folder}/instance.nix";
      config = instanceEval { inherit (parsed) id zone; module = dir + "/instance.nix"; };
    };

  # one entry generates every worker of the shared swarm: consecutive vmids, as many as its apps' reservations need
  sharedApps = lib.filterAttrs (_: a: a.enable && a.placement == null) appsCatalog.apps;
  workerCount = limits.workerCountOf { apps = sharedApps; inherit (swarm.nodes) vm; };
  workerIds = lib.genList (n: toString (swarm.nodes.first + n)) workerCount;
  nodeOf = id: {
    inherit id;
    zone = nodeZone;
    name = "${id}-${nodeZone}-${nodeService}";
    dir = null;
    main = null;
    source = "apps/swarm.nix";
    config = instanceEval { inherit id; zone = nodeZone; module = removeAttrs swarm.nodes [ "first" ]; };
  };

  # every enabled swarm's manager: the shared one and each enabled guest-placed app's own guest (a swarm of one)
  placedApps = lib.filterAttrs (_: a: a.placement != null) appsCatalog.apps;
  swarmManagers = [ roles.swarm-manager ]
    ++ lib.mapAttrsToList (_: a: toString a.placement.vmid) (lib.filterAttrs (_: a: a.enable) placedApps);

  # an app placed on its own guest: a single-node swarm in its zone, powered while the app is enabled
  appGuestOf = app: a: let id = toString a.placement.vmid; in {
    inherit id;
    inherit (a.placement) zone;
    name = "${id}-${a.placement.zone}-${app}";
    dir = null;
    main = null;
    source = "apps/${app}/app.nix";
    config = instanceEval {
      inherit id;
      inherit (a.placement) zone;
      module = {
        vm = { power = if a.enable then "on" else "off"; needs = [ "containers" "nfs" ]; } // a.placement.vm;
        # its manager role keeps its unlock key on its own share, as the shared manager does (modules/swarm)
        shares."data/swarm-manager-${id}" = { };
      };
    };
  };

  instanceList = map instanceOfFolder folders ++ map nodeOf workerIds
    ++ lib.mapAttrsToList appGuestOf placedApps;
  instances = lib.listToAttrs (map (i: lib.nameValuePair i.id i) instanceList);

  # -------------------------------------------------------------------------------------------------------------
  # INVENTORY
  # -------------------------------------------------------------------------------------------------------------

  addressOf = i:
    if i.zone == routerZone then {
      ip = site.lan.router;
      prefix = cidr.prefix site.lan.subnet;
      gateway = site.lan.gateway;
    } else {
      ip = cidr.host net.zones.${i.zone}.subnet (lib.toInt i.id);
      inherit (net.zones.${i.zone}) prefix;
      gateway = net.zones.${i.zone}.routerIp;
    };

  # the router is named by its hostname in proxmox; every guest by its folder
  nameOf = i: if i.zone == routerZone then i.config.hostName else i.name;

  # enabled: the tri-state string terraform and the scripts still compare, until they read powered and idle
  enabledOf = i: if i.config.vm.power == "off" then "false" else if i.config.idle.stopAfter != null then "onDemand" else "true";

  inventory = lib.mapAttrs (_: i: let vm = i.config.vm; in addressOf i // {
    name = nameOf i;
    type = i.zone;
    kind = vm.guestKind;
    inherit (vm) privileged features;
    powered = vm.power == "on";
    idle = i.config.idle.stopAfter;
    enabled = enabledOf i;
    cooldown = i.config.idle.stopAfter;
  }) instances;

  net = import ../net.nix { inherit lib inventory site; };
  telemetry = import ../telemetry.nix { inherit lib inventory; };

  # a grant's source (instance.nix `grants`, modules/flows.nix `guards`): a guest by vmid, or the house lan, the
  # proxmox node, the owner's wireguard devices, every address of a zone, or the router's leg in the granting guest's
  # zone; as the address a guard admits
  namedSources = {
    lan = net.wan.subnet;
    proxmox = "${net.wan.proxmox}/32";
    wireguard = net.wireguard.subnet;
  } // lib.mapAttrs (_: z: z.subnet) net.zones;
  grantSourceNames = [ "router" ] ++ lib.attrNames namedSources;
  sourceOf = zone: from:
    if builtins.match "[0-9]+" from != null then net.hostSource from
    else if from == "router" then "${net.zones.${zone}.routerIp}/32"
    else namedSources.${from};

  # -------------------------------------------------------------------------------------------------------------
  # FACTS: what instance.nix files declare for others, merged and checked for collisions
  # -------------------------------------------------------------------------------------------------------------

  # ascending vmid, the order every collected list keeps
  ordered = lib.sort (a: b: lib.toInt a.id < lib.toInt b.id) instanceList;
  idOf = i: lib.toInt i.id;

  # every instance service, its route being the service's exposure on the instance's own address
  serviceEntries = lib.concatMap (i: lib.mapAttrsToList (name: s: { inherit name i s; }) i.config.services) ordered;
  routes = lib.listToAttrs (map (e: lib.nameValuePair e.name (removeAttrs e.s [ "homepage" "oidc" "metrics" ] // { vmid = idOf e.i; }))
    serviceEntries);

  homepage = map (e: e.s.homepage // { route = e.name; vmid = idOf e.i; }) (lib.filter (e: e.s.off.homepage == null) serviceEntries);
  oidc = map (e: e.s.oidc // { id = e.name; secret = "${e.name}-oidc-secret"; route = e.name; vmid = idOf e.i; })
    (lib.filter (e: e.s.oidc != null) serviceEntries);
  grants = lib.concatMap (i: map (g: g // { to = i.id; }) i.config.grants) ordered;
  tokenEntries = lib.concatMap (i: map (name: { inherit name i; }) i.config.tokens) ordered;
  tokens = lib.listToAttrs (map (e: lib.nameValuePair e.name (idOf e.i)) tokenEntries);
  egress = lib.mapAttrs (_: i: i.config.egress // { vmid = idOf i; })
    (lib.filterAttrs (_: i: i.config.egress != null) instances);
  secretEntries = lib.concatMap (i: lib.mapAttrsToList (name: kind: { inherit name kind i; }) i.config.secrets) ordered;
  secrets = lib.listToAttrs (map (e: lib.nameValuePair e.name { inherit (e) kind; vmid = idOf e.i; }) secretEntries);
  roleEntries = lib.concatMap (i: map (name: { inherit name i; }) i.config.roles) ordered;
  roles = lib.listToAttrs (map (e: lib.nameValuePair e.name e.i.id) roleEntries);
  # an instance's own rules and probes, by grafana uid and probe name, each with the instance's vmid
  ownedOf = field: lib.concatMap (i: lib.mapAttrsToList (name: v: { inherit name i v; }) i.config.${field}) ordered;
  alertEntries = ownedOf "alerts";
  probeEntries = ownedOf "probes";
  withVmid = entries: lib.listToAttrs (map (e: lib.nameValuePair e.name (e.v // { vmid = idOf e.i; })) entries);

  # the tokens each guest reads: those its instance.nix names, and by role the dashboard every widget's token and
  # the operator every one
  widgetTokens = lib.unique (lib.concatMap (c: lib.optionals (c.widget != null) (lib.attrValues c.widget.tokens)) homepage);
  tokenReads = lib.mapAttrs (_: i: lib.unique (i.config.tokenReads
    ++ lib.optionals (lib.elem "dashboard" i.config.roles) widgetTokens
    ++ lib.optionals (lib.elem "operator" i.config.roles) (lib.attrNames tokens))) instances;

  # the nas dir of a guest's tokens: read-write to it, read-only to its readers; only its root writes there
  tokenShare = { pathOf = id: "data/tokens/vm-${toString id}"; mode = "0755"; };
  shareOf = path: { readOnly ? false, mode ? null }: { path = "${nasRoot}/${path}"; inherit readOnly mode; };
  sharesOf = i: let
    minted = lib.any (e: e.i.id == i.id) tokenEntries;
    readFrom = lib.remove (idOf i) (lib.unique (map (t: tokens.${t}) (lib.filter (t: tokens ? ${t}) tokenReads.${i.id})));
  in lib.mapAttrsToList shareOf i.config.shares
    ++ lib.optional minted (shareOf (tokenShare.pathOf i.id) { inherit (tokenShare) mode; })
    ++ map (id: shareOf (tokenShare.pathOf id) { readOnly = true; }) readFrom;
  shares = lib.mapAttrs (_: sharesOf) instances;
  # what vm-109 exports and the router opens nfs to: every powered guest's shares, by address
  nasClients = lib.listToAttrs (lib.filter (e: e.value != [ ]) (map (i: lib.nameValuePair inventory.${i.id}.ip shares.${i.id})
    (lib.filter (i: inventory.${i.id}.powered) ordered)));

  # -------------------------------------------------------------------------------------------------------------
  # APPS
  # -------------------------------------------------------------------------------------------------------------

  appFolders = foldersOf appsDir;
  appOf = name:
    let dir = appsDir + "/${name}"; in
    assert lib.assertMsg ((builtins.readDir dir) ? "app.nix") "src/apps/${name}: an app folder holds app.nix (see src/apps/_template)";
    import (dir + "/app.nix");

  # the app folders and src/apps/swarm.nix over modules/apps-catalog: every field typed and defaulted, once
  appsCatalog = removeAttrs (lib.evalModules {
    modules = [ ../apps-catalog {
      config = {
        apps = apps (lib.genAttrs appFolders appOf);
        inherit (swarm) cadvisorPort controllerPort;
        builder = lib.toInt roles.app-builder;
        swarm = { manager = lib.toInt roles.swarm-manager; inherit (swarm) state; workers = map lib.toInt workerIds; };
      };
    } ];
    specialArgs = { inherit telemetry; };
  }).config [ "_module" ];
  catalog = import ../catalog.nix { inherit lib site inventory appsCatalog; lab = result; };

  # -------------------------------------------------------------------------------------------------------------
  # TERRAFORM: what lib.tf turns into proxmox guests, one json string (the external data source's protocol)
  # -------------------------------------------------------------------------------------------------------------

  # proxmox starts guests by order, then id, waiting up_delay after each: only a phase's last autostarted guest waits
  bootLast = lib.mapAttrs (_: is: lib.foldl' lib.max 0 (map idOf is))
    (lib.groupBy (i: toString i.config.vm.bootOrder) (lib.filter (i: inventory.${i.id}.powered && inventory.${i.id}.idle == null) instanceList));
  terraformOf = id: i: let vm = i.config.vm; inv = inventory.${id}; in {
    inherit (inv) name type enabled powered idle kind privileged features ip prefix gateway;
    memory = vm.memoryMiB;
    balloon = vm.balloonMiB;
    inherit (vm) cores machine;
    cpu_units = vm.cpuUnits;
    disk = vm.diskGiB;
    hostpci = vm.pci;
    extra_disks = map (d: { size = d.sizeGiB; inherit (d) store; }) vm.disks;
    boot_order = vm.bootOrder;
    boot_wait = if (bootLast.${toString vm.bootOrder} or null) == idOf i then bootPhaseWaitSeconds else 0;
    cpu_limit = vm.cpuLimitCores;
    disk_limits = vm.diskLimits;
    nic_rate = vm.nicRateMBps;
  };

  # -------------------------------------------------------------------------------------------------------------
  # PROBLEMS
  # -------------------------------------------------------------------------------------------------------------

  duplicates = what: entries: lib.concatLists (lib.mapAttrsToList (key: es:
    lib.optional (lib.length es > 1) "${what} ${key} is declared by ${lib.concatMapStringsSep " and " (e: e.i.source) es}"
  ) (lib.groupBy (e: e.name) entries));

  zoneCount = lib.length (lib.attrNames zonesRaw);
  zoneProblems = lib.concatLists (lib.mapAttrsToList (name: z:
    lib.optional (lib.length (lib.filter (o: o.router_nic == z.router_nic) (lib.attrValues zonesRaw)) != 1
        || z.router_nic < 1 || z.router_nic > zoneCount)
      "zones.json ${name}: router_nic must be one of 1..${toString zoneCount}, each used once"
    ++ lib.optional (z.ingress != null && (instances.${toString z.ingress}.zone or null) != name)
      "zones.json ${name}: its ingress ${toString z.ingress} is no instance of the zone"
  ) zonesRaw);

  instanceProblems = i: let vm = i.config.vm; where = "src/${i.source}"; pool = zonesRaw.${i.zone}.dhcp_pool or null;
    range = zonesRaw.${i.zone}.vmids or null; in
    # the vmid names the zone: 1xx internal, 200-249 external, 250 on the swarm's workers (zones.json `vmids`)
    lib.optional (range != null && (lib.toInt i.id < range.first || lib.toInt i.id > range.last))
      "${where}: vmid ${i.id} lies outside zone ${i.zone}'s range ${toString range.first}..${toString range.last}"
    ++ lib.optional (i.zone != routerZone && i.config.hostName != "vm-${i.id}")
      "${where}: hostName is vm-${i.id} for every guest; only the router names itself"
    ++ lib.optional (vm.guestKind == "lxc" && (vm.pci != [ ] || vm.disks != [ ] || i.zone == routerZone))
      "${where}: an lxc takes no pci devices, extra disks or router role"
    # root in a privileged container is root on the host: never in a zone that runs strangers' traffic
    ++ lib.optional (vm.privileged && !(vm.guestKind == "lxc" && i.zone == "internal"))
      "${where}: privileged is lxc only, and only in the internal zone"
    ++ lib.optional (i.config.idle.stopAfter != null && (zonesRaw.${i.zone}.ingress or null) == null)
      "${where}: idle needs a zone whose ingress wakes it; ${i.zone} has none"
    # a static address inside the zone's lease pool flaps with whatever the dhcp server leased it to
    ++ lib.optional (pool != null && lib.toInt i.id >= pool.first && lib.toInt i.id <= pool.last)
      "${where}: vm-${i.id}'s address lies in zone ${i.zone}'s dhcp pool ${toString pool.first}..${toString pool.last}";

  problems = lib.filter (p: p != null) (map folderProblemOf allFolders)
    ++ zoneProblems
    ++ lib.concatMap instanceProblems instanceList
    ++ lib.concatLists (lib.mapAttrsToList (id: is:
      lib.optional (lib.length is > 1) "vmid ${id} is claimed by ${lib.concatMapStringsSep " and " (i: i.source) is}"
    ) (lib.groupBy (i: i.id) instanceList))
    ++ duplicates "service" serviceEntries
    ++ duplicates "token" tokenEntries
    ++ duplicates "secret" secretEntries
    ++ duplicates "role" roleEntries
    ++ lib.concatMap (i: map (t: "src/${i.source}: tokenReads names ${t}, which no instance mints")
      (lib.filter (t: !(tokens ? ${t})) i.config.tokenReads)) instanceList
    ++ duplicates "alert" alertEntries
    ++ duplicates "probe" probeEntries
    ++ map (p: "src/apps: ${p}") catalog.problems;

  result = {
    inherit site instances inventory appsCatalog catalog homepage oidc grants tokens tokenReads tokenShare egress secrets roles
      shares nasClients problems;
    alerts = withVmid alertEntries;
    probes = withVmid probeEntries;
    withApps = f: import ./. { inherit lib root; apps = folders: f (apps folders); };
    # zone: from: the address a grant's source stands for in a guard of that zone
    inherit sourceOf;

    # service name -> its route (modules/service.nix exposure) plus the instance's vmid; modules/catalog.nix adds the apps'
    inherit routes;

    # configuration name -> its instance record: what the flake builds, each host getting its own as `instance`
    hosts = lib.listToAttrs (map (i: lib.nameValuePair i.name i) instanceList);

    terraform.json = builtins.toJSON (lib.mapAttrs terraformOf instances);
  };
in
result
