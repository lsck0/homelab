# Minecraft on vm-214: several servers, one at a time.
#
# mc-gate (lib/mc-gate, its header says what it does) owns the public port: it reads the name the player dialed
# (<server>.mc.lsck0.dev), answers status pings itself so an internet port scan never starts anything, and starts or
# stops servers through systemd. Each declared server is one unit of its own, and `Conflicts=` between them is what
# makes at most one run: the guest has one heap, one game port and one rcon port to give.
# Who may join and who is op lives in whitelist.json and ops.json beside the server dirs (`mc-rcon whitelist add`,
# `mc-rcon op`), shared by every server through a file bind mount, not in this public repo.
{ config, lib, pkgs, inventory, site, nasMount, catalog, ... }:
let
  net = import ../../../modules/net.nix { inherit lib inventory site; };
  mcGate = import ./lib/mc-gate.nix { inherit pkgs lib; };
  serverNames = import ./lib/servers.nix { inherit lib; };

  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  # the servers this guest offers; the key is the dns label below *.mc and the name of everything the server owns.
  # version and protocol answer a status ping for a server that never answered one itself (mc-gate R-042); image is
  # the server's java, since each minecraft release names the one it needs (the version manifest's javaVersion); pack
  # is the modpack.env a server starts with before mc-modpack ever wrote one (default: vanilla, newest release).
  # The lab runs the set below; the vm test passes its own as the module argument `mcServers`, because one declared
  # server can prove neither a `Conflicts=` nor a switch (tests/minecraft.nix). A formal with a default would still
  # be looked up in `_module.args` and fail wherever nothing defines it, so it is read from there by hand.
  servers = config._module.args.mcServers or {
    # the as-built world: the pack (all the mons, neoforge 21.1 for minecraft 1.21.1) runs on java 21
    cobblemon = { version = "1.21.1"; protocol = 767; };
    # the newest release (VERSION=LATEST, the default pack); 26.3 requires java 25
    vanilla = { image = imageJava25; };
    # All the Mons, the ATM team's cobblemon modpack: its server files (ServerFiles-<version>.zip from the pack's
    # curseforge page) sit in the modpack share, unpacked over the data dir by the image; neoforge pinned as its
    # startserver.sh pins it.
    atm = {
      version = "1.21.1";
      protocol = 767;
      pack = ''
        TYPE=NEOFORGE
        VERSION=1.21.1
        NEOFORGE_VERSION=21.1.249
        GENERIC_PACK=/modpacks/allthemons-serverfiles-1.3.0.zip
        LEVEL=allthemons
      '';
    };
  };

  data = "/var/lib/minecraft";
  modpacksDir = "/var/lib/minecraft-modpacks";
  gateStateDir = "/var/lib/mc-gate";
  gateRuntimeDir = "/run/mc-gate";
  gateUser = "mc-gate";
  gateSettingsPath = "/etc/mc-gate/settings.json";
  # the gate writes its metrics beside its state; the node exporter reads them through a link it owns (R-090, R-091)
  gateMetricsName = "mc-gate";
  gateMetricsFile = "${gateStateDir}/metrics.prom";
  # the server's secrets, rendered by sops under /run: never on the nas, never in a snapshot
  serverEnv = config.sops.templates."minecraft-server.env".path;
  imageJava21 = "itzg/minecraft-server:2026.9.1-java21";
  imageJava25 = "itzg/minecraft-server:2026.9.1-java25";
  # the image's uid and gid
  serverUid = "1000";

  publicPort = catalog.l4.minecraft.port;
  # the container's game port and rcon port, published on loopback for the gate and mc-rcon only; one server runs at
  # a time, so every server reuses them
  serverPort = 25566;
  rconPort = 25575;
  # instance.nix gives the guest 10 GiB unballooned: the heap plus ~2 GiB off-heap (375 mods) and the os; live data is
  # ~2.6 GiB with a few players (spark heapsummary), a 6 GiB heap in 8 GiB swapped, 5 GiB collected nonstop
  heapSize = "7G";
  containerDns = [ "1.1.1.1" "8.8.8.8" ];
  icon = "https://d.furaffinity.net/art/skullfugg/1697237475/1697237475.skullfugg_boykisser_ych_mdp_alt_for_frostywuff__1.png";
  motd = "nya~ minecwaft sewvew 🐾✨";

  # the world the guest ran before it had several (R-076): mc-layout moves it into its own dir once
  legacyServer = "cobblemon";
  layoutUnit = "mc-layout.service";
  # the whitelist and the ops, shared by every server (R-073); an empty json array is what the server expects
  sharedFiles = [ "whitelist.json" "ops.json" ];
  sharedEmpty = "[]";

  # what the gate gives a player and a server, every bound in one place
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

  # -----------------------------------------------------------------------------
  # INTERNAL
  # -----------------------------------------------------------------------------

  names = serverNames.check servers;
  unitOf = name: "minecraft-${name}.service";
  dirOf = name: "${data}/${name}";
  modpackEnvOf = name: "${dirOf name}/modpack.env";
  containerOf = name: "minecraft-${name}";
  # the units ordered before this one: `Conflicts=` stops the other, and ordering one way only keeps systemd from
  # finding a cycle and solving it by deleting a job (R-072)
  earlierThan = name: map unitOf (lib.filter (other: other < name) names);
  othersThan = name: map unitOf (lib.filter (other: other != name) names);

  podman = "${pkgs.podman}/bin/podman";
  jq = "${pkgs.jq}/bin/jq";
  serverList = lib.concatStringsSep " " names;
  stateFile = "${gateRuntimeDir}/state.json";

  # the files every server shares, as podman options: a file bind mount makes one server's write visible in all
  sharedMounts = lib.concatMapStringsSep " " (file: "-v ${data}/${file}:/data/${file}") sharedFiles;

  # a server's data dir, the shared files and its pack, before the container starts (R-071a)
  serverPreStart = name: pkgs.writeShellScript "minecraft-${name}-pre-start" ''
    set -euo pipefail
    install -d -m 0750 -o ${serverUid} -g ${serverUid} ${dirOf name}
    ${lib.concatMapStrings (file: ''
      [ -s ${data}/${file} ] || install -m 0640 -o ${serverUid} -g ${serverUid} \
        ${pkgs.writeText "minecraft-${file}" sharedEmpty} ${data}/${file}
    '') sharedFiles}
    [ -s ${modpackEnvOf name} ] || printf '%s' ${lib.escapeShellArg (servers.${name}.pack or defaultModpack)} \
      > ${modpackEnvOf name}
    ${podman} rm --force --ignore ${containerOf name}
  '';

  # distant horizons draws the far terrain, so the server sends and ticks less of it (view and simulation distance)
  serverStart = name: pkgs.writeShellScript "minecraft-${name}-start" ''
    set -euo pipefail
    exec ${podman} run --rm --name ${containerOf name} \
      ${lib.concatMapStringsSep " " (ip: "--dns=${ip}") containerDns} \
      -p 127.0.0.1:${toString serverPort}:${toString publicPort} \
      -p 127.0.0.1:${toString rconPort}:${toString rconPort} \
      -v ${dirOf name}:/data -v ${modpacksDir}:/modpacks:ro \
      ${sharedMounts} \
      --env-file ${serverEnv} --env-file ${modpackEnvOf name} \
      -e EULA=TRUE \
      -e MEMORY=${heapSize} \
      -e DIFFICULTY=hard \
      -e ICON=${icon} \
      -e OVERRIDE_ICON=TRUE \
      -e "MOTD=[${name}] ${motd}" \
      -e USE_AIKAR_FLAGS=true \
      -e VIEW_DISTANCE=12 \
      -e SIMULATION_DISTANCE=8 \
      -e SPAWN_PROTECTION=0 \
      -e MAX_PLAYERS=42069 \
      -e ENABLE_RCON=true \
      -e ENABLE_WHITELIST=true \
      -e ENFORCE_WHITELIST=true \
      -e REMOVE_OLD_MODS=TRUE \
      -e MAX_TICK_TIME=-1 \
      -e STOP_DURATION=90 \
      ${servers.${name}.image or imageJava21}
  '';

  # one server. The gate starts and stops it; nothing else does, so it has no wantedBy (R-071f).
  serverUnit = name: {
    description = "Minecraft server ${name}";
    requires = [ layoutUnit ];
    after = [ layoutUnit ] ++ earlierThan name;
    conflicts = othersThan name;
    path = [ pkgs.podman ];
    serviceConfig = {
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
    # a [Unit] key: systemd drops it from [Service] with a warning, and the world would be written into the
    # mountpoint instead of onto the nas
    unitConfig.RequiresMountsFor = data;
  };

  # -- the gate ---------------------------------------------------------------

  gateSettingsFile = pkgs.writeText "mc-gate-settings.json" (builtins.toJSON {
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
        { name = net.fqdn net.wan.publicHost; network = "ip4"; bits = ipv4AddressBits; }
        { name = net.fqdn net.wan.publicPrefixHost; network = "ip6"; bits = net.wan.publicPrefixLength; }
      ];
    };
  });

  # the one move of the as-built layout into the server dirs, through a temp dir so a crash halfway resumes (R-076)
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

  # -- the tools --------------------------------------------------------------

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
in {
  homelab.nasMounts = nasMount data "minecraft" // nasMount modpacksDir "minecraft-modpacks";

  sops.secrets.minecraft-rcon-password = { };
  sops.secrets.minecraft-cf-api-key = { };
  sops.templates."minecraft-server.env" = {
    content = ''
      RCON_PASSWORD=${config.sops.placeholder.minecraft-rcon-password}
      CF_API_KEY=${config.sops.placeholder.minecraft-cf-api-key}
    '';
    # no restartUnits: a server unit is normally stopped, and switch-to-configuration starts a stopped unit it is
    # told to restart. A rotated password would wake every server at once, which is what the gate exists to
    # prevent (R-071f); the next start reads the new file anyway.
  };

  # the servers run as raw `podman run`, not via oci-containers
  virtualisation.podman.enable = true;

  homelab.textfiles = [ gateMetricsName ];

  environment.systemPackages = [ mcModpack mcRcon mcState ];
  environment.etc."mc-gate/settings.json".source = gateSettingsFile;

  users.users.${gateUser} = { isSystemUser = true; group = gateUser; };
  users.groups.${gateUser} = { };

  # the gate may start and stop the declared servers, by their exact names: a pattern would also match a unit that
  # is no server (core/107-internal-swarm/lib/app-builder.nix)
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
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = layoutScript;
      };
      unitConfig.RequiresMountsFor = data;
    };

    mc-gate = {
      description = "mc-gate: the Minecraft port, one server awake at a time";
      wantedBy = [ "multi-user.target" ];
      wants = [ layoutUnit "network-online.target" ];
      after = [ layoutUnit "network-online.target" ];
      # a restart cuts every player, since every connection is relayed through it: a new binary waits for the owner
      restartIfChanged = false;
      reloadTriggers = [ gateSettingsFile ];
      serviceConfig = {
        ExecStart = "${lib.getExe mcGate.package} -settings ${gateSettingsPath}";
        # a changed server list reaches the gate without closing a connection (R-055b)
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        Restart = "always";
        RestartSec = 5;
        User = gateUser;
        Group = gateUser;
        StateDirectory = baseNameOf gateStateDir;
        StateDirectoryMode = "0755";
        RuntimeDirectory = baseNameOf gateRuntimeDir;
        # it answers on one port, asks systemd over the system bus, and reads its settings and the store
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        SystemCallFilter = [ "@system-service" ];
      };
    };
  } // lib.listToAttrs (map (name: lib.nameValuePair "minecraft-${name}" (serverUnit name)) names);

  systemd.tmpfiles.rules = [
    # the exporter reads the gate's own file: a link, so no timer copies it and no scrape sees a stale copy
    "L+ ${config.homelab.textfileDir}/${gateMetricsName}.prom - - - - ${gateMetricsFile}"
    "d ${data} 0750 ${serverUid} ${serverUid} -"
    "d ${modpacksDir} 0750 ${serverUid} ${serverUid} -"
  ];
}
