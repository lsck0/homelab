# forgejo actions runner, as the `ci` user: job containers run on ci's rootless docker (modules/rootless-docker.nix)
#
# git.lsck0.dev is the owner's forge: only the owner pushes, its mirrors follow branches the owner merged. Its
# jobs are trusted with the shared compile cache (sccache on vm-110) and the registry, as user `ci`, and with
# nothing else; the github runners, which take strangers' pull requests, are other users without either.
{ config, lib, pkgs, retry, inventory, site, catalog, ... }:
let
  net = import ../../../modules/net.nix { inherit lib inventory site; };

  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  user = "ci";
  uid = 2000;
  ci = config.homelab.rootlessDocker.${user};
  package = pkgs.forgejo-runner;
  stateDir = "/var/lib/forgejo-runner";
  forge = "git.${catalog.domain}";
  instance = "https://${forge}";
  name = "${config.networking.hostName}-runner";
  sccache = { host = "sccache.${catalog.domain}"; ip = net.ipOf "110"; port = net.ports.redis; };
  inherit (config.homelab.tokens) dir;

  # the job container image per label, pinned: an upstream tag push never changes what jobs run; changing them
  # forces a re-registration. Refill: skopeo inspect --raw docker://<image>:<tag> | sha256sum
  ubuntuImage = "docker://catthehacker/ubuntu:act-22.04@sha256:3488f78aa97770c8d5d835f2913c1a782d3121ad3f2aafb17054fb1d554ea4e1";
  labels = [
    "docker:${ubuntuImage}"
    "ubuntu-latest:${ubuntuImage}"
    "rust:docker://rust:1.80-bookworm@sha256:d22d8938f0403ee31c118b5bf2162b883313dd7f387f859d9f2accd7c884c385"
  ];
  # the lab names jobs use, at the internal ingress (git, the registry) and the cache
  hosts = {
    ${catalog.ingress.internal.ip} = [ forge catalog.registry ];
    ${sccache.ip} = [ sccache.host ];
  };
  # job containers resolve the lab like the vm does
  addHosts = lib.concatLists (lib.mapAttrsToList (ip: names: map (h: "--add-host=${h}:${ip}") names) hosts);
  # one job at a time on a shared vm
  jobLimits = [ "--memory=1536m" "--cpus=1.5" ];
  capacity = 1;
  jobTimeout = "3h";
  registrationWait = { attempts = 30; intervalS = 5; };
  restartDelayS = 10;

  # -----------------------------------------------------------------------------
  # INTERNAL
  # -----------------------------------------------------------------------------

  configFile = (pkgs.formats.yaml { }).generate "forgejo-runner.yaml" {
    log.level = "info";
    runner = {
      file = "${stateDir}/.runner";
      inherit capacity;
      # jobs get the cache url with its password from here, never from a workflow
      env_file = config.sops.templates."sccache-redis.env".path;
      timeout = jobTimeout;
      inherit labels;
    };
    cache = { enabled = true; dir = "${stateDir}/cache"; };
    container = {
      privileged = false;
      options = lib.concatStringsSep " " (addHosts ++ jobLimits);
      # mounts DOCKER_HOST, ci's rootless socket, into jobs that build images: root over ci's containers only
      docker_host = "automount";
      valid_volumes = [ ];
    };
    host.workdir_parent = "${stateDir}/work";
  };

  register = pkgs.writeShellScript "forgejo-runner-register" ''
    set -euo pipefail
    labels_file=${stateDir}/.labels
    wanted=${lib.escapeShellArg (lib.concatStringsSep "," labels)}
    # a registration outlives restarts; changed labels or a forgotten runner re-register
    if [ -s ${stateDir}/.runner ] && [ "$(cat "$labels_file" 2>/dev/null)" = "$wanted" ] \
       && ${package}/bin/forgejo-runner ping --config ${configFile} --instance ${instance} >/dev/null 2>&1; then
      exit 0
    fi
    rm -f ${stateDir}/.runner
    token=${dir}/forgejo-runner.token
    ${retry} ${toString registrationWait.attempts} ${toString registrationWait.intervalS} test -s "$token" \
      || { echo "no registration token at $token: did vm-115's forgejo-runner-token run?"; exit 1; }
    ${package}/bin/forgejo-runner register --no-interactive --config ${configFile} \
      --instance ${instance} --token "$(cat "$token")" --name ${name} --labels "$wanted"
    printf '%s' "$wanted" > "$labels_file"
  '';
in {
  homelab.rootlessDocker.${user} = {
    inherit uid;
    # git and the registry through the internal ingress, the compile cache; nothing else inside the lab
    labAccess = [ { ip = catalog.ingress.internal.ip; port = net.ports.https; } { inherit (sccache) ip port; } ];
  };
  # lab names without cloudflare; the ingress, not the services: traefik terminates https and gates pushes
  networking.hosts = hosts;

  sops.secrets.sccache-redis-pass = { };
  # the cache url carries a password, so it comes from sops, not the nix store; ci alone reads it
  sops.templates."sccache-redis.env" = {
    owner = user;
    content = "SCCACHE_REDIS=redis://:${config.sops.placeholder.sccache-redis-pass}@${sccache.host}\n";
  };

  systemd.services.forgejo-runner = {
    description = "Forgejo Actions runner";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ci.userUnit ];
    after = [ "network-online.target" ci.userUnit ];
    unitConfig.RequiresMountsFor = config.homelab.tokens.mountPoints;
    environment.DOCKER_HOST = ci.dockerHost;
    serviceConfig = {
      User = user;
      Group = user;
      Slice = ci.slice;
      StateDirectory = "forgejo-runner";
      WorkingDirectory = stateDir;
      ExecStartPre = register;
      ExecStart = "${package}/bin/forgejo-runner daemon --config ${configFile}";
      Restart = "always";
      RestartSec = restartDelayS;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      PrivateTmp = true;
      # the rootless socket lives under /run/user
      ProtectHome = "read-only";
    };
  };
}
