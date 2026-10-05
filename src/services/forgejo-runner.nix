# forgejo actions runner, as the ci user: job containers run on ci's rootless docker (modules/rootless-docker.nix)
{ config, lib, pkgs, retry, ... }:
let
  ci = config.homelab.rootlessDocker.ci;
  ciUser = "ci";
  package = pkgs.forgejo-runner;
  stateDir = "/var/lib/forgejo-runner";
  instance = "https://git.lsck0.dev";
  name = "${config.networking.hostName}-runner";

  # the job container image per label; changing them forces a re-registration
  labels = [
    "docker:docker://catthehacker/ubuntu:act-22.04"
    "ubuntu-latest:docker://catthehacker/ubuntu:act-22.04"
    "rust:docker://rust:1.80-bookworm"
  ];
  # job containers resolve the lab like the vm does
  addHosts = lib.concatLists (lib.mapAttrsToList (ip: names:
    map (h: "--add-host=${h}:${ip}") (lib.filter (lib.hasSuffix ".lsck0.dev") names)) config.networking.hosts);
  # one job at a time on a shared vm
  jobLimits = [ "--memory=1536m" "--cpus=1.5" ];

  configFile = (pkgs.formats.yaml { }).generate "forgejo-runner.yaml" {
    log.level = "info";
    runner = {
      file = "${stateDir}/.runner";
      capacity = 1;
      # jobs get the cache url with its password from here, never from a workflow
      env_file = config.sops.templates."forgejo-runner.env".path;
      timeout = "3h";
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
    token=${config.homelab.tokens.dir}/forgejo-runner.token
    ${retry} 30 5 test -s "$token" || { echo "no registration token at $token: did vm-115's forgejo-runner-token run?"; exit 1; }
    ${package}/bin/forgejo-runner register --no-interactive --config ${configFile} \
      --instance ${instance} --token "$(cat "$token")" --name ${name} --labels "$wanted"
    printf '%s' "$wanted" > "$labels_file"
  '';
in {
  # forgejo (vm-115) mints the one-use registration token
  homelab.tokens.reads = [ "forgejo-runner" ];

  sops.secrets.sccache-redis-pass = { };
  sops.templates."forgejo-runner.env" = {
    owner = ciUser;
    content = "SCCACHE_REDIS=redis://:${config.sops.placeholder.sccache-redis-pass}@sccache.lsck0.dev\n";
  };

  systemd.services.forgejo-runner = {
    description = "Forgejo Actions runner";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ci.userUnit ];
    after = [ "network-online.target" ci.userUnit ];
    unitConfig.RequiresMountsFor = config.homelab.tokens.mountPoints;
    environment.DOCKER_HOST = ci.dockerHost;
    serviceConfig = {
      User = ciUser;
      Group = ciUser;
      Slice = ci.slice;
      StateDirectory = "forgejo-runner";
      WorkingDirectory = stateDir;
      ExecStartPre = register;
      ExecStart = "${package}/bin/forgejo-runner daemon --config ${configFile}";
      Restart = "always";
      RestartSec = 10;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      PrivateTmp = true;
      # the rootless socket lives under /run/user
      ProtectHome = "read-only";
    };
  };
}
