{ config, pkgs, nasPath, ... }:
let
  # served by vm-109 at mirror.lsck0.dev
  repoDir = "/var/lib/archrepo";
  # pacman cache, sources, cargo and go caches: what makes a nightly build incremental
  cacheDir = "/var/lib/archbuild/cache";
  # the status page: build.log, logs/<base>.log, status.txt
  publicDir = "/var/lib/archbuild/public";
  # flag the busy endpoint answers from, the on-demand reaper leaves the vm up while it exists
  busyFlag = "/run/archbuild.busy";
  # a build started at the nightly wake stays fresh until the next one
  staleMinutes = 20 * 60;
  # rolling like the distro; pulled per run so the in-container -Syu stays small
  image = "docker.io/library/archlinux:base-devel";
in {
  networking.hostName = "vm-119";

  fileSystems = nasPath repoDir "bulk/archrepo";

  sops.secrets.archrepo-signing-key = {};

  virtualisation.podman.enable = true;

  systemd.services.archbuild = {
    description = "Build mirror/packages.conf of arch-dotfiles into the lsck0 pacman repo";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = [ pkgs.podman pkgs.coreutils ];
    # a deploy must not kill a running build
    restartIfChanged = false;
    unitConfig.RequiresMountsFor = [ repoDir ];
    environment = {
      ARCHBUILD_SOURCE = "https://github.com/lsck0/arch-dotfiles";
      ARCHBUILD_REF = "master";
    };
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "20h";
      ExecStartPre = "${pkgs.coreutils}/bin/touch ${busyFlag}";
      # conmon lives outside this unit's cgroup, a stop would leave the build running unflagged
      ExecStopPost = [ "${pkgs.podman}/bin/podman rm -f -t 30 archbuild" "${pkgs.coreutils}/bin/rm -f ${busyFlag}" ];
    };
    script = ''
      set -o pipefail
      podman run --rm --init --replace --pull=newer --name archbuild \
        -e ARCHBUILD_SOURCE -e ARCHBUILD_REF \
        -v ${repoDir}:/repo \
        -v ${cacheDir}:/cache \
        -v ${publicDir}:/public \
        -v ${config.sops.secrets.archrepo-signing-key.path}:/run/signing.asc:ro \
        -v ${../scripts/archrepo-build.sh}:/build.sh:ro \
        ${image} bash /build.sh 2>&1 | tee ${publicDir}/build.log
    '';
  };

  # the nightly wake and a visit both boot the vm; a stale repo then builds
  systemd.services.archbuild-if-stale = {
    description = "Start the package build when the last finished one is stale";
    path = [ pkgs.findutils pkgs.systemd ];
    serviceConfig.Type = "oneshot";
    script = ''
      if [ -z "$(find ${repoDir}/status.txt -mmin -${toString staleMinutes} 2>/dev/null)" ]; then
        systemctl start --no-block archbuild.service
      fi
    '';
  };
  systemd.timers.archbuild-if-stale = {
    wantedBy = [ "timers.target" ];
    # after activation, not boot: a deploy starting the timer would build mid-switch, before dns is back
    timerConfig = { OnActiveSec = "3min"; OnUnitActiveSec = "1h"; };
  };

  services.nginx = {
    enable = true;
    virtualHosts.archbuild = {
      default = true;
      root = publicDir;
      extraConfig = ''
        autoindex on;
        default_type text/plain;
        charset utf-8;
      '';
      # busyPath of the on-demand service in 100-internal-traefik.nix
      locations."= /busy".extraConfig = ''
        if (-f ${busyFlag}) { return 200; }
        return 404;
      '';
    };
  };

  systemd.tmpfiles.rules = [
    "d ${cacheDir} 0755 root root -"
    "d ${publicDir} 0755 root root -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];

  # authelia gates the status page
  homelab.ingressOnly.ports = [ 80 ];
}
