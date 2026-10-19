# Minecraft on vm-214: several servers behind mc-gate, at most one running
#
# `Conflicts=` between the server units is what keeps it to one: the guest has one heap, one game port and one rcon
# port to give. whitelist.json and ops.json (`mc-rcon whitelist add`, `mc-rcon op`) are shared state, not in this repo.
{
  config,
  lib,
  pkgs,
  utils,
  inventory,
  site,
  nasMount,
  catalog,
  instance,
  ...
}:
let
  net = import ../../../modules/net.nix { inherit lib inventory site; };
  mcGate = import ./lib/mc-gate.nix { inherit pkgs lib; };
  serverNames = import ./lib/servers.nix { inherit lib; };

  # the key is the dns label below *.mc; version and protocol answer a ping before the server ever answered one; image
  # is the java its minecraft release names (the version manifest's javaVersion); pack seeds modpack.env.
  # The vm test passes its own set as `mcServers`. A formal with a default would still be looked up in `_module.args`
  # and fail wherever nothing defines it, so it is read from there by hand.
  servers =
    config._module.args.mcServers or {
      cobblemon = {
        version = "1.21.1";
        protocol = 767;
      };
      vanilla = {
        image = imageJava25;
      };
      atm = {
        version = "1.21.1";
        protocol = 767;
        allowFlight = true;
        # 375 mods in an 8 GiB guest: a shorter view keeps it out of swap
        viewDistance = 8;
        simulationDistance = 6;
        pack = ''
          TYPE=NEOFORGE
          VERSION=1.21.1
          NEOFORGE_VERSION=21.1.249
          GENERIC_PACK=/modpacks/allthemons-serverfiles-1.3.0.zip
          COPY_CONFIG_SRC=/modpacks/atm-config
          SYNC_SKIP_NEWER_IN_DESTINATION=false
          LEVEL=allthemons
        '';
      };
    };

  data = "/var/lib/minecraft";
  dataAutomount = "${utils.escapeSystemdPath data}.automount";
  modpacksDir = "/var/lib/minecraft-modpacks";
  # where the container sees modpacksDir, read-only
  containerModpacksDir = "/modpacks";
  # each server's own jars beside its pack (mc-mod), copied into its mods at every start
  extraModsName = "extra";
  extraModsDir = "${modpacksDir}/${extraModsName}";
  gateStateDir = "/var/lib/mc-gate";
  gateRuntimeDir = "/run/mc-gate";
  gateUser = "mc-gate";
  gateSettingsPath = "/etc/mc-gate/settings.json";
  gateMetricsName = "mc-gate";
  gateMetricsFile = "${gateStateDir}/metrics.prom";
  # sync.nu marks the guest before terraform may reboot it and removes the mark with its deploy or its failure
  # (scripts/lib/lab.nu DEPLOY_PENDING_FILE); sync.nu's REAPER_PAUSE_S bounds a run, so a mark a dead run left expires
  deployPendingFile = "/var/lib/homelab/deploy-pending";
  deployPendingMaxS = 14400;
  # the server's secrets, rendered by sops under /run: never on the nas, never in a snapshot
  serverEnv = config.sops.templates."minecraft-server.env".path;
  imageJava21 = "itzg/minecraft-server:2026.9.1-java21";
  imageJava25 = "itzg/minecraft-server:2026.9.1-java25";
  # the image's uid and gid
  serverUid = "1000";
  # the gate stats each server's modpack.env through the 0750 data dirs
  serverGroup = "minecraft";

  publicPort = catalog.l4.minecraft.port;
  # the container's game port and rcon port, published on loopback for the gate and mc-rcon only; one server runs at
  # a time, so every server reuses them
  serverPort = 25566;
  rconPort = 25575;
  # live data is ~2.6 GiB with a few players (spark heapsummary); 5 GiB plus ~2 GiB off-heap stays under the container
  heapSize = "5G";
  # the guest's kernel, sshd and the gate (~440 MiB used beside a running pack); the container gets the rest, and
  # past it its coldest pages (atm's ~2 GiB off-heap, 375 mods' classes) go to zram instead of the oom killer
  guestReserveMiB = 768;
  containerMemoryMiB = instance.config.vm.memoryMiB - guestReserveMiB;
  containerDns = [
    "1.1.1.1"
    "8.8.8.8"
  ];
  # a copy in the share: its origin answers 403, which fails the image's fetch (d.furaffinity.net/art/skullfugg/
  # 1697237475/1697237475.skullfugg_boykisser_ych_mdp_alt_for_frostywuff__1.png, scaled to 64x64)
  icon = "${containerModpacksDir}/server-icon.png";
  motd = "nya~ minecwaft sewvew 🐾✨";

  # the world the guest ran before it had several: mc-layout moves it into its own dir once
  legacyServer = "cobblemon";
  layoutUnit = "mc-layout.service";
  # an empty json array is what the server expects
  sharedFiles = [
    "whitelist.json"
    "ops.json"
  ];
  sharedEmpty = "[]";

  limits = {
    # a client that sends no first frame in five seconds is a scanner holding a socket
    handshakeTimeoutS = 5;
    handshakeBytesMax = 1024;
    statusCacheS = 5;
    reconcileS = 5;
    # above the server's own login timeout (600 ticks), so a forged login never holds a server
    loginGraceS = 60;
    loopWindowS = 600;
    loopShortSessionsMax = 3;
    sessionsPerSourceMax = 4;
    # the kicked player's window to rejoin the server they woke
    rejoinS = 180;
    # a short break keeps the world warm, an evening off frees the heap
    sleepAfterS = 1800;
    minimumOnlineS = 300;
    startsPerSourcePerHourMax = 3;
    switchesPerHourMax = 6;
    startTimeoutS = 300;
    # the first start after a pack change downloads the pack
    firstStartTimeoutS = 1200;
  };

  # a v4 name stands for its one address
  ipv4AddressBits = 32;

  defaultModpack = ''
    TYPE=VANILLA
    VERSION=LATEST
    LEVEL=vanilla
  '';

  names = serverNames.check servers;
  unitOf = name: "minecraft-${name}.service";
  dirOf = name: "${data}/${name}";
  modpackEnvOf = name: "${dirOf name}/modpack.env";
  extraModsOf = name: "${extraModsDir}/${name}";
  containerOf = name: "minecraft-${name}";
  # ordering one way only: a cycle in `Conflicts=` peers makes systemd solve it by deleting a job
  earlierThan = name: map unitOf (lib.filter (other: other < name) names);
  othersThan = name: map unitOf (lib.filter (other: other != name) names);

  podman = "${pkgs.podman}/bin/podman";
  jq = "${pkgs.jq}/bin/jq";
  serverList = lib.concatStringsSep " " names;
  stateFile = "${gateRuntimeDir}/state.json";

  # a file bind mount makes one server's write visible in all
  sharedMounts = lib.concatMapStringsSep " " (file: "-v ${data}/${file}:/data/${file}") sharedFiles;

  serverPreStart =
    name:
    pkgs.writeShellScript "minecraft-${name}-pre-start" ''
      set -euo pipefail
      install -d -m 0750 -o ${serverUid} -g ${serverUid} ${dirOf name}
      ${lib.concatMapStrings (file: ''
        [ -s ${data}/${file} ] || install -m 0640 -o ${serverUid} -g ${serverUid} \
          ${pkgs.writeText "minecraft-${file}" sharedEmpty} ${data}/${file}
      '') sharedFiles}
      # the image copies the jars as its own uid: one copied in by root at 0600 ended the start after 5 s
      install -d -m 0750 -o ${serverUid} -g ${serverGroup} ${extraModsDir} ${extraModsOf name}
      chown -R ${serverUid}:${serverGroup} ${extraModsOf name}
      chmod -R u=rwX,g=rX,o= ${extraModsOf name}
      [ -s ${modpackEnvOf name} ] || printf '%s' ${lib.escapeShellArg (servers.${name}.pack or defaultModpack)} \
        > ${modpackEnvOf name}
      ${podman} rm --force --ignore ${containerOf name}
    '';

  # a boot after the mark runs the generation the sync is about to replace, and a server keeps the unit it started
  # with until it sleeps (restartIfChanged): it waits for the deploy instead
  deployGuard = pkgs.writeShellScript "minecraft-deploy-guard" ''
    [ -e ${deployPendingFile} ] || exit 0
    max_s=${toString deployPendingMaxS}
    now=$(date +%s)
    marked=$(stat -c %Y ${deployPendingFile})
    booted=$((now - $(cut -d. -f1 /proc/uptime)))
    if [ "$marked" -lt "$booted" ] && [ $((now - marked)) -lt "$max_s" ]; then
      echo "rebooted under a sync that has not deployed this guest yet: no server starts on the old generation"
      exit 1
    fi
  '';

  # distant horizons draws the far terrain, so the server sends and ticks less of it (view and simulation distance)
  serverStart =
    name:
    pkgs.writeShellScript "minecraft-${name}-start" ''
      set -euo pipefail
      # passthrough: the unit's stdout is the one journal copy, the journald driver would write every line again
      exec ${podman} run --rm --name ${containerOf name} --log-driver=passthrough \
        --memory=${toString containerMemoryMiB}m \
        ${lib.concatMapStringsSep " " (ip: "--dns=${ip}") containerDns} \
        -p 127.0.0.1:${toString serverPort}:${toString publicPort} \
        -p 127.0.0.1:${toString rconPort}:${toString rconPort} \
        -v ${dirOf name}:/data -v ${modpacksDir}:${containerModpacksDir}:ro \
        ${sharedMounts} \
        --env-file ${serverEnv} --env-file ${modpackEnvOf name} \
        -e EULA=TRUE \
        -e MEMORY=${heapSize} \
        -e DIFFICULTY=hard \
        -e ALLOW_FLIGHT=${lib.boolToString (servers.${name}.allowFlight or false)} \
        -e ICON=${icon} \
        -e OVERRIDE_ICON=TRUE \
        -e "MOTD=[${name}] ${motd}" \
        -e USE_AIKAR_FLAGS=true \
        -e VIEW_DISTANCE=${toString (servers.${name}.viewDistance or 12)} \
        -e SIMULATION_DISTANCE=${toString (servers.${name}.simulationDistance or 8)} \
        -e SPAWN_PROTECTION=0 \
        -e MAX_PLAYERS=42069 \
        -e ENABLE_RCON=true \
        -e ENABLE_WHITELIST=true \
        -e ENFORCE_WHITELIST=true \
        -e REMOVE_OLD_MODS=TRUE \
        -e MODS=${containerModpacksDir}/${extraModsName}/${name} \
        -e MAX_TICK_TIME=-1 \
        -e STOP_DURATION=90 \
        ${servers.${name}.image or imageJava21}
    '';

  # only the gate starts a server, so it has no wantedBy
  serverUnit = name: {
    description = "Minecraft server ${name}";
    # a switch would kick every player: a running server takes a new unit when the gate next stops it, after
    # sleepAfterS with nobody on, or at `systemctl restart`
    restartIfChanged = false;
    # the automount, not the mount (RequiresMountsFor): an idle expiry or a restart of the mount would stop the server
    requires = [
      layoutUnit
      dataAutomount
    ];
    after = [
      layoutUnit
      dataAutomount
    ]
    ++ earlierThan name;
    conflicts = othersThan name;
    path = [ pkgs.podman ];
    serviceConfig = {
      # a condition, not a failure: the start is skipped, the unit stays inactive and the gate puts it back to sleep
      ExecCondition = deployGuard;
      ExecStartPre = serverPreStart name;
      ExecStart = serverStart name;
      # podman stops the container, not its client: a stopped client would leave conmon and the jvm holding the ports
      ExecStop = "${podman} stop --time 120 ${containerOf name}";
      ExecStopPost = "${podman} rm --force --ignore ${containerOf name}";
      # over the container's own 120 s, so systemd never kills a world that is still saving
      TimeoutStopSec = 150;
      # the first start downloads a pack of several gigabytes
      TimeoutStartSec = "infinity";
    };
  };

  gateSettingsFile = pkgs.writeText "mc-gate-settings.json" (
    builtins.toJSON {
      listen = "0.0.0.0:${toString publicPort}";
      # the route is the wildcard host `*.mc`; what a player dials is one label below it, so the star is no part of
      # the suffix the gate strips
      suffix = ".${lib.removePrefix "*." catalog.l4.minecraft.host}.${net.domain}";
      backend = "127.0.0.1:${toString serverPort}";
      stateDir = gateStateDir;
      runtimeDir = gateRuntimeDir;
      servers = map (name: {
        inherit name;
        unit = unitOf name;
        version = servers.${name}.version or null;
        protocol = servers.${name}.protocol or null;
        modpackEnv = modpackEnvOf name;
      }) names;
      inherit limits;
      # who the gate never marks as looping and never caps: the sources lab-gate never stops either
      # (modules/traefik/default.nix), the house among them, since its players arrive hairpinned as one address
      allow = {
        cidrs = net.privateRanges;
        hosts = [
          {
            name = net.fqdn net.wan.publicHost;
            network = "ip4";
            bits = ipv4AddressBits;
          }
          {
            name = net.fqdn net.wan.publicPrefixHost;
            network = "ip6";
            bits = net.wan.publicPrefixLength;
          }
        ];
      };
    }
  );

  # through a temp dir, so a crash halfway resumes
  layoutScript = pkgs.writeShellScript "mc-layout" ''
    set -euo pipefail
    tmp=${data}/${legacyServer}.tmp
    # the server dir's own pack is the marker that the move already happened: a world dir that happens to be named
    # like the server is not one, and a temp dir restored from a snapshot of a half-done move is no reason to move
    # anything again
    if [ -e ${modpackEnvOf legacyServer} ] || { [ ! -e ${data}/modpack.env ] && [ ! -d "$tmp" ]; }; then
      echo "mc-layout: the data dir holds no old layout"
      exit 0
    fi
    # the old world may still be open: the guest ran one container named after no server at all
    ${podman} rm --force --ignore minecraft
    [ -d "$tmp" ] || install -d -m 0750 -o ${serverUid} -g ${serverUid} "$tmp"
    echo "mc-layout: moving the old layout into ${dirOf legacyServer}"
    for entry in ${data}/* ${data}/.*; do
      base=$(basename -- "$entry")
      case "$base" in
        .|..|${legacyServer}.tmp|${lib.concatStringsSep "|" sharedFiles}) continue ;;
      esac
      [ -e "$entry" ] || continue
      mv -- "$entry" "$tmp/"
    done
    # -T so a destination that exists stops the move instead of nesting the layout inside itself
    mv -T -- "$tmp" ${dirOf legacyServer}
    echo "mc-layout: moved"
  '';

  mcModpack = pkgs.writeShellScriptBin "mc-modpack" ''
    set -euo pipefail
    server="''${1:-}"; arg="''${2:-}"
    version="''${3:-LATEST}"
    if [ -z "$server" ]; then
      for name in ${serverList}; do
        # shellcheck disable=SC2016 # $n is jq's argument, not the shell's
        phase=$(${jq} -r --arg n "$name" '.servers[] | select(.name == $n) | .phase' ${stateFile} 2>/dev/null || true)
        pack=$(grep -h -E '^(TYPE|MODRINTH_MODPACK|CF_PAGE_URL|LEVEL)=' ${data}/"$name"/modpack.env 2>/dev/null \
          | tr '\n' ' ' || true)
        echo "$name: ''${phase:-unknown}: ''${pack:-no pack}"
      done
      echo "usage: mc-modpack <server> <modrinth url|modrinth slug|curseforge url|vanilla> [minecraft version]"
      exit 0
    fi
    known=""
    for name in ${serverList}; do
      if [ "$name" = "$server" ]; then known=yes; fi
    done
    [ -n "$known" ] || { echo "mc-modpack: no server $server; the servers are ${serverList}" >&2; exit 1; }
    if [ -z "$arg" ]; then
      cat ${data}/"$server"/modpack.env
      exit 0
    fi
    slug=$(basename "''${arg%/}")
    case "$arg" in
      vanilla) env="TYPE=VANILLA" ;;
      # most curseforge packs need the minecraft-cf-api-key secret
      *curseforge.com*) env=$(printf 'TYPE=AUTO_CURSEFORGE\nCF_PAGE_URL=%s' "$arg") ;;
      *) env=$(printf 'TYPE=MODRINTH\nMODRINTH_MODPACK=%s' "$arg") ;;
    esac
    install -d -m 0750 -o ${serverUid} -g ${serverUid} ${data}/"$server"
    printf '%s\nVERSION=%s\nLEVEL=%s\n' "$env" "$version" "$slug" > ${data}/"$server"/modpack.env.tmp
    mv ${data}/"$server"/modpack.env.tmp ${data}/"$server"/modpack.env
    # a sleeping server takes the pack at its next start; a running one is restarted into it
    if systemctl is-active --quiet minecraft-"$server".service; then
      systemctl restart minecraft-"$server".service
      echo "modpack set to $arg (world: $slug); $server was restarted into it"
    else
      echo "modpack set to $arg (world: $slug); the next join boots it, the first start downloads the pack"
    fi
  '';

  mcMod = pkgs.writers.writeNuBin "mc-mod" {
    makeWrapperArgs = [
      "--set"
      "MC_MOD_SETTINGS"
      (pkgs.writeText "mc-mod-settings.json" (
        builtins.toJSON {
          inherit data;
          extraMods = extraModsDir;
          owner = serverUid;
          group = serverGroup;
          servers = map (name: {
            inherit name;
            unit = unitOf name;
            version = servers.${name}.version or null;
          }) names;
        }
      ))
      "--prefix"
      "PATH"
      ":"
      (lib.makeBinPath [
        pkgs.coreutils
        pkgs.unzip
      ])
    ];
  } ./lib/mc-mod.nu;

  # only works while the server runs: rcon lives in its container
  mcRcon = pkgs.writeShellScriptBin "mc-rcon" ''
    set -euo pipefail
    server=""
    if [ "''${1:-}" = "-s" ]; then
      server="''${2:-}"; shift 2
      [ -n "$server" ] || { echo "mc-rcon: -s takes a server; the servers are ${serverList}" >&2; exit 1; }
    fi
    if [ -z "$server" ]; then
      for name in ${serverList}; do
        if systemctl is-active --quiet minecraft-"$name".service; then server="$name"; break; fi
      done
      [ -n "$server" ] || { echo "mc-rcon: no server runs; wake one by joining, or name one with -s" >&2; exit 1; }
    fi
    exec ${podman} exec minecraft-"$server" rcon-cli "$@"
  '';

  mcState = pkgs.writeShellScriptBin "mc-state" ''
    set -euo pipefail
    [ -s ${stateFile} ] || { echo "mc-state: no ${stateFile}; is mc-gate running?" >&2; exit 1; }
    exec ${jq} . ${stateFile}
  '';
in
{
  homelab.nasMounts = nasMount data "minecraft" // nasMount modpacksDir "minecraft-modpacks";

  sops.secrets.minecraft-rcon-password = { };
  sops.secrets.minecraft-cf-api-key = { };
  sops.templates."minecraft-server.env" = {
    content = ''
      RCON_PASSWORD=${config.sops.placeholder.minecraft-rcon-password}
      CF_API_KEY=${config.sops.placeholder.minecraft-cf-api-key}
    '';
    # no restartUnits: switch-to-configuration starts a stopped unit it is told to restart, so a rotated password
    # would wake every server at once; the next start reads the new file anyway
  };

  virtualisation.podman.enable = true;

  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  homelab.textfiles = [ gateMetricsName ];

  environment.systemPackages = [
    mcMod
    mcModpack
    mcRcon
    mcState
  ];
  environment.etc."mc-gate/settings.json".source = gateSettingsFile;

  users.users.${gateUser} = {
    isSystemUser = true;
    group = gateUser;
  };
  users.groups.${gateUser} = { };
  users.groups.${serverGroup}.gid = lib.toInt serverUid;

  # the gate may start and stop the declared servers, by their exact names: a pattern would also match a unit that
  # is no server (instances/core/107-internal-swarm/lib/app-builder.nix)
  security.polkit.enable = true;
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      var units = ${builtins.toJSON (map unitOf names)};
      if (action.id == "org.freedesktop.systemd1.manage-units" && subject.user == "${gateUser}"
          && (action.lookup("verb") == "start" || action.lookup("verb") == "stop")
          && units.indexOf(action.lookup("unit")) >= 0) {
        return polkit.Result.YES;
      }
    });
  '';

  systemd.services = {
    mc-layout = {
      description = "mc-layout: move the one old Minecraft data dir into its server's dir, once";
      wantedBy = [ "multi-user.target" ];
      # a restart would carry over to a running server through its Requires=; the move happens once anyway
      restartIfChanged = false;
      requires = [ dataAutomount ];
      after = [ dataAutomount ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = layoutScript;
      };
    };

    mc-gate = {
      description = "mc-gate: the Minecraft port, one server awake at a time";
      wantedBy = [ "multi-user.target" ];
      wants = [
        layoutUnit
        "network-online.target"
      ];
      after = [
        layoutUnit
        "network-online.target"
      ];
      # a restart cuts every player, since every connection is relayed through it: a new binary waits for the owner
      restartIfChanged = false;
      reloadTriggers = [ gateSettingsFile ];
      serviceConfig = {
        ExecStart = "${lib.getExe mcGate.package} -settings ${gateSettingsPath}";
        # a changed server list reaches the gate without closing a connection
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        Restart = "always";
        RestartSec = 5;
        User = gateUser;
        Group = gateUser;
        SupplementaryGroups = [ serverGroup ];
        StateDirectory = baseNameOf gateStateDir;
        StateDirectoryMode = "0755";
        RuntimeDirectory = baseNameOf gateRuntimeDir;
        # it answers on one port, asks systemd over the system bus, and reads its settings and the store
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        SystemCallFilter = [ "@system-service" ];
      };
    };
  }
  // lib.listToAttrs (map (name: lib.nameValuePair "minecraft-${name}" (serverUnit name)) names);

  systemd.tmpfiles.rules = [
    # the exporter reads the gate's own file: a link, so no timer copies it and no scrape sees a stale copy
    "L+ ${config.homelab.textfileDir}/${gateMetricsName}.prom - - - - ${gateMetricsFile}"
    "d ${data} 0750 ${serverUid} ${serverUid} -"
    "d ${modpacksDir} 0750 ${serverUid} ${serverUid} -"
  ];
}
