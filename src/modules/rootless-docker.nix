# users with a rootless docker of their own, for work that must never own the vm
#
# Docker socket access is root on the vm, whether through the docker group or a socket mounted into a job. Each
# user here instead runs its own rootless dockerd: container root maps to an unprivileged subuid, so the worst a
# job or a build can do is what that user can do. `ci` runs every github and forgejo job (117); `appbuild` builds
# the app catalog's images and holds the registry push credential, which no job ever sees.
{ config, lib, pkgs, ... }:
let
  cfg = config.homelab.rootlessDocker;
  # rootlesskit maps a user's container uids into its own 65536-wide range, one range per user
  subIdBase = 100000;
  subIdCount = 65536;

  userType = lib.types.submodule ({ name, config, ... }: {
    options = {
      uid = lib.mkOption { type = lib.types.int; description = "Fixed uid: the docker socket path carries it."; };
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
          The lab addresses this user's processes and containers may reach; the internet stays open, every other
          private address is refused. A job from a fork runs as this user, so the list is all it can touch inside.
        '';
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
    };
  });

  names = lib.attrNames cfg;
  egressChain = "rootless-egress";
  privateRanges = [ "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "100.64.0.0/10" ];
  subIdStart = name: subIdBase + subIdCount * lib.lists.findFirstIndex (n: n == name) 0 names;
in {
  options.homelab.rootlessDocker = lib.mkOption {
    type = lib.types.attrsOf userType;
    default = { };
    description = "Users with a rootless docker daemon, keyed by user name.";
  };

  config = lib.mkIf (cfg != { }) {
    virtualisation.docker.rootless.enable = true;

    users.users = lib.mapAttrs (name: u: {
      isSystemUser = true;
      inherit (u) uid;
      group = name;
      home = "/var/lib/${name}";
      createHome = true;
      # starts the user manager, and so the daemon, at boot without a login
      linger = true;
      subUidRanges = [{ startUid = subIdStart name; count = subIdCount; }];
      subGidRanges = [{ startGid = subIdStart name; count = subIdCount; }];
    }) cfg;
    users.groups = lib.mapAttrs (_: _: { }) cfg;

    zramSwap = { enable = true; memoryPercent = 50; };

    # rootless containers reach the network through slirp, as their user: an owner match covers jobs and builds alike
    networking.firewall.extraCommands = ''
      iptables -N ${egressChain} 2>/dev/null || iptables -F ${egressChain}
      iptables -D OUTPUT -j ${egressChain} 2>/dev/null || true
      iptables -I OUTPUT -j ${egressChain}
      ${lib.concatStrings (lib.mapAttrsToList (name: u: ''
        ${lib.concatMapStrings (a: ''
          iptables -A ${egressChain} -m owner --uid-owner ${toString u.uid} -d ${a.ip} -p ${a.proto} --dport ${toString a.port} -j RETURN
        '') u.labAccess}
        ${lib.concatMapStrings (range: ''
          iptables -A ${egressChain} -m owner --uid-owner ${toString u.uid} -d ${range} -j REJECT
        '') privateRanges}
      '') cfg)}
    '';
    networking.firewall.extraStopCommands = ''
      iptables -D OUTPUT -j ${egressChain} 2>/dev/null || true
    '';

    systemd.slices = lib.mapAttrs' (name: u: lib.nameValuePair name {
      description = "System services running as ${name}";
      sliceConfig = { MemoryHigh = u.memoryHigh; MemoryMax = u.memoryMax; CPUWeight = 50; IOWeight = 50; };
    }) cfg
    # the daemon and every container live in the user's own slice
    // lib.mapAttrs' (_: u: lib.nameValuePair "user-${toString u.uid}" {
      sliceConfig = { MemoryHigh = u.memoryHigh; MemoryMax = u.memoryMax; CPUWeight = 50; IOWeight = 50; };
    }) cfg;

    # docker.autoPrune drives the system daemon only
    systemd.services = lib.mapAttrs' (name: u: lib.nameValuePair "${name}-docker-prune" {
      description = "Prune ${name}'s images and build cache";
      startAt = "daily";
      after = [ u.userUnit ];
      environment.DOCKER_HOST = u.dockerHost;
      path = [ config.virtualisation.docker.package ];
      serviceConfig = { Type = "oneshot"; User = name; };
      script = ''
        docker system prune --all --force --filter until=48h
        docker builder prune --force --keep-storage ${u.buildCacheKeep}
      '';
    }) cfg;
  };
}
