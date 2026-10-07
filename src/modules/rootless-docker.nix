# users with a rootless docker of their own, for work that must never own the vm
#
# Docker socket access is root on the vm, whether through the docker group or a socket mounted into a job. Each
# user here instead runs its own rootless dockerd: container root maps to an unprivileged subuid, so the worst a
# job or a build can do is what that user can do, and one user's daemon, images and caches are out of another's
# reach. A trust boundary is a user: the forgejo runner (`ci`), each github repo's runner (`gh-<repo>`, jobs from
# strangers' pull requests among them) and the app builder (`appbuild`, the registry credential) are three.
#
# Per user:
# - egress: its processes and containers reach the internet, the host's resolvers and exactly its `labAccess` inside
#   the lab; every other private address is refused. The rules are replaced in one transaction and never removed, so a firewall
#   restart or stop opens no window (fail closed), and the user's manager starts only after them.
# - ephemeral: `resetScript` wipes the user's home, images, volumes and caches and restarts its daemon; a runner
#   runs it before every job, so nothing one job leaves (a retagged base image, a user unit, a poisoned cache)
#   reaches the next.
# - storage: the subuid range follows the uid, so adding a user moves nobody's range; a home whose docker storage
#   was made for another range (a renumbered user) is wiped before the daemon starts instead of failing on it.
#   Docker storage here is a cache, never state.
{ config, lib, pkgs, inventory, site, retry, ... }:
let
  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  cfg = config.homelab.rootlessDocker;
  # rootlesskit maps a user's container uids into its own 65536-wide range, one range per uid from uidMin up
  uidMin = 2000;
  uidSlots = 100;
  subIdBase = 100000;
  subIdCount = 65536;
  egressChain = "rootless-egress";
  privateRanges = import ./private-ranges.nix { inherit lib inventory site; };
  net = import ./net.nix { inherit lib inventory site; };
  # half the default weight: builds and jobs yield to the vm's own services
  sliceWeight = 50;
  # images and stopped containers older than this go in the daily prune
  pruneAge = "48h";
  # a restarted user manager has its daemon's socket up within this
  socketWait = { attempts = 60; intervalS = 1; };
  storageStamp = ".rootless-subid-range";
  dockerData = ".local/share/docker";

  # -----------------------------------------------------------------------------
  # TYPES
  # -----------------------------------------------------------------------------

  userType = lib.types.submodule ({ name, config, ... }: {
    options = {
      uid = lib.mkOption {
        type = lib.types.ints.between uidMin (uidMin + uidSlots - 1);
        description = "Fixed uid: the docker socket path and the subuid range follow it.";
      };
      memoryHigh = lib.mkOption { type = lib.types.str; default = "2G"; description = "Throttle point of the user's slices."; };
      memoryMax = lib.mkOption { type = lib.types.str; default = "2560M"; description = "Hard cap of the user's slices."; };
      buildCacheKeep = lib.mkOption { type = lib.types.str; default = "15GB"; description = "Build cache kept by the daily prune."; };
      labAccess = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            ip = lib.mkOption { type = lib.types.str; };
            port = lib.mkOption { type = lib.types.port; };
            proto = lib.mkOption { type = lib.types.enum [ "tcp" "udp" ]; default = "tcp"; };
          };
        });
        default = [ ];
        description = ''
          The lab addresses this user's processes and containers may reach besides the host's resolvers; the internet
          stays open, every other private address is refused. A job from a fork runs as its runner's user, so the list
          is all it can touch.
        '';
      };
      ephemeral = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Nothing of the user survives `resetScript`, which its units run before each job.";
      };

      subIdStart = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default = subIdBase + (config.uid - uidMin) * subIdCount;
        description = "First subuid and subgid of the user's range.";
      };
      dockerHost = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "unix:///run/user/${toString config.uid}/docker.sock";
        description = "DOCKER_HOST of the user's rootless daemon.";
      };
      userUnit = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "user@${toString config.uid}.service";
        description = "The user's manager, which runs the daemon; services using it order after it.";
      };
      slice = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "${name}.slice";
        description = "Slice for the user's system services (runners, the builder).";
      };
      resetScript = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        default = resetScriptOf name config;
        description = "Run as root (ExecStartPre = \"+...\"): the user's home and daemon start from nothing.";
      };
    };
  });

  # -----------------------------------------------------------------------------
  # INTERNAL
  # -----------------------------------------------------------------------------

  homeOf = name: "/var/lib/${name}";
  rangeOf = u: "${toString u.subIdStart}:${toString subIdCount}";
  systemctl = "${config.systemd.package}/bin/systemctl";

  resetScriptOf = name: u: pkgs.writeShellScript "rootless-docker-reset-${name}" ''
    set -euo pipefail
    # the manager takes the daemon and every process the user started (user units included) with it
    ${systemctl} stop ${u.userUnit}
    ${pkgs.findutils}/bin/find ${homeOf name} -mindepth 1 -delete
    ${systemctl} restart rootless-docker-prepare-${name}.service
    ${systemctl} start ${u.userUnit}
    ${retry} ${toString socketWait.attempts} ${toString socketWait.intervalS} test -S /run/user/${toString u.uid}/docker.sock
  '';

  # before the user's manager: storage made for another subuid range cannot be read by the daemon
  prepareScriptOf = name: u: pkgs.writeShellScript "rootless-docker-prepare-${name}" ''
    set -euo pipefail
    stamp=${homeOf name}/${storageStamp}
    if [ "$(cat "$stamp" 2>/dev/null)" != ${rangeOf u} ]; then
      echo "${name}: docker storage belongs to another subuid range, starting it afresh"
      rm -rf ${homeOf name}/${dockerData}
      printf '%s\n' ${rangeOf u} > "$stamp"
    fi
  '';

  # every user resolves names through the host's resolvers
  dnsAccess = lib.concatMap (ip: [ { inherit ip; port = net.ports.dns; proto = "udp"; } { inherit ip; port = net.ports.dns; proto = "tcp"; } ])
    config.networking.nameservers;

  # one iptables-restore transaction: the chain is flushed and refilled atomically, the OUTPUT jump added once
  egressRules = pkgs.writeText "rootless-egress.rules" (lib.concatLines ([
    "*filter"
    ":${egressChain} - [0:0]"
  ] ++ lib.concatLists (lib.mapAttrsToList (_: u:
    map (a: "-A ${egressChain} -m owner --uid-owner ${toString u.uid} -d ${a.ip}/32 -p ${a.proto} --dport ${toString a.port} -j RETURN")
      (dnsAccess ++ u.labAccess)
    ++ map (range: "-A ${egressChain} -m owner --uid-owner ${toString u.uid} -d ${range} -j REJECT") privateRanges
  ) cfg) ++ [ "COMMIT" ]));

  sliceConfig = u: { MemoryHigh = u.memoryHigh; MemoryMax = u.memoryMax; CPUWeight = sliceWeight; IOWeight = sliceWeight; };
in {
  options.homelab.rootlessDocker = lib.mkOption {
    type = lib.types.attrsOf userType;
    default = { };
    description = "Users with a rootless docker daemon, keyed by user name.";
  };

  config = lib.mkIf (cfg != { }) {
    assertions = [{
      assertion = lib.allUnique (map (u: u.uid) (lib.attrValues cfg));
      message = "homelab.rootlessDocker: two users share a uid, and so a subuid range and a daemon socket";
    }];

    virtualisation.docker.rootless.enable = true;

    users.users = lib.mapAttrs (name: u: {
      isSystemUser = true;
      inherit (u) uid;
      group = name;
      home = homeOf name;
      createHome = true;
      # starts the user manager, and so the daemon, at boot without a login
      linger = true;
      subUidRanges = [{ startUid = u.subIdStart; count = subIdCount; }];
      subGidRanges = [{ startGid = u.subIdStart; count = subIdCount; }];
    }) cfg;
    users.groups = lib.mapAttrs (_: _: { }) cfg;

    zramSwap = { enable = true; memoryPercent = 50; };

    # slirp connects as the user, so an owner match covers jobs and containers alike; nothing removes it on stop
    networking.firewall.extraCommands = ''
      iptables-restore --noflush < ${egressRules}
      iptables -C OUTPUT -j ${egressChain} 2>/dev/null || iptables -I OUTPUT -j ${egressChain}
    '';

    systemd.slices = lib.mapAttrs' (name: u: lib.nameValuePair name {
      description = "System services running as ${name}";
      sliceConfig = sliceConfig u;
    }) cfg
    # the daemon and every container live in the user's own slice
    // lib.mapAttrs' (_: u: lib.nameValuePair "user-${toString u.uid}" { sliceConfig = sliceConfig u; }) cfg;

    # an ephemeral user's storage is wiped before every job: nothing to prune
    systemd.services = lib.mapAttrs' (name: u: lib.nameValuePair "${name}-docker-prune" {
      description = "Prune ${name}'s images and build cache";
      startAt = "daily";
      after = [ u.userUnit ];
      environment.DOCKER_HOST = u.dockerHost;
      path = [ config.virtualisation.docker.package ];
      serviceConfig = { Type = "oneshot"; User = name; };
      script = ''
        docker system prune --all --force --filter until=${pruneAge}
        docker builder prune --force --keep-storage ${u.buildCacheKeep}
      '';
    }) (lib.filterAttrs (_: u: !u.ephemeral) cfg)
    // lib.mapAttrs' (name: u: lib.nameValuePair "rootless-docker-prepare-${name}" {
      description = "Check ${name}'s docker storage against its subuid range";
      before = [ u.userUnit ];
      requiredBy = [ u.userUnit ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; ExecStart = prepareScriptOf name u; };
    }) cfg
    # the egress rules exist before anything runs as the user
    // lib.mapAttrs' (_: u: lib.nameValuePair "user@${toString u.uid}" {
      overrideStrategy = "asDropin";
      after = [ "firewall.service" ];
      wants = [ "firewall.service" ];
    }) cfg;
  };
}
