{ config, pkgs, inventory, nasPath, catalog, ... }:
let
  route = catalog.internal.archbuild;
  # pushed to vm-210, which serves mirror.lsck0.dev
  repoDir = "/var/lib/archrepo";
  # pacman cache, sources, cargo and go caches: what makes a nightly build incremental; the build container's alone
  cacheDir = "/var/lib/archbuild/cache";
  # the build container's proposal to the publish container: unsigned packages, staged db, state, report
  outboxDir = "/var/lib/archbuild/outbox";
  # the verified arch-dotfiles checkout, written by the host only, read-only in both containers
  dotfilesDir = "/var/lib/archbuild/dotfiles";
  # the status page: build.log, logs/<base>.log, status.{txt,json}; publish pushes the logs to the mirror
  publicDir = "/var/lib/archbuild/public";
  # flag the busy endpoint answers from, the on-demand reaper leaves the vm up while it exists
  busyFlag = "/run/archbuild.busy";
  # a build started at the nightly wake stays fresh until the next one
  staleMinutes = 20 * 60;
  # rolling like the distro; pulled per run so the in-container -Syu stays small
  image = "docker.io/library/archlinux:base-devel";
  # arch-dotfiles bootstrap.sh SIGNING_KEY_FINGERPRINT: only commits this primary key signed get built and signed
  dotfilesSigningKey = "E7501F533316E9AFC6AAE907122F2CB527D1EFE3";
  dotfilesSource = "https://github.com/lsck0/arch-dotfiles";
  dotfilesRef = "master";
  buildScript = ./lib/archrepo-build.sh;
  # the package list of the checkout; publish gates the snapshot on it
  listScript = ./lib/archrepo-list.sh;
  containerBuild = "archbuild-build";
  containerPublish = "archbuild-publish";
  # memory one compile job may take: c++ with lto peaks near 2 GiB; ninja ignores MAKEFLAGS and runs nproc + 2 jobs,
  # which on the ballooned vm stalled the guest until the night died (wivrn-server), so the cpus follow the memory
  buildJobMemoryKiB = 2 * 1024 * 1024;
  # podman rm grace before it kills a container
  containerStopTimeoutS = 30;
  # what both containers get of the run: the verified commit and the run id
  runEnv = "-e ARCHBUILD_SOURCE -e ARCHBUILD_REF -e ARCHBUILD_COMMIT -e ARCHBUILD_RUN_STARTED";
  # node-exporter's textfile collector (modules/base)
  metricsFile = "${config.homelab.textfileDir}/archrepo.prom";
  # the served status after every run, a failed one included: what a client installing now lacks
  metricsWrite = pkgs.writeShellScript "archbuild-metrics" ''
    set -euo pipefail
    ${pkgs.jq}/bin/jq -r '"# TYPE homelab_archrepo_missing_packages gauge",
      "homelab_archrepo_missing_packages \(.missing // [] | length)",
      "# TYPE homelab_archrepo_held_back gauge",
      "homelab_archrepo_held_back \(if .held_back then 1 else 0 end)"' ${repoDir}/status.json > ${metricsFile}.tmp
    ${pkgs.coreutils}/bin/mv -f ${metricsFile}.tmp ${metricsFile}
  '';
in {
  networking.hostName = "vm-119";

  homelab.nasMounts = nasPath repoDir "bulk/archrepo";

  sops.secrets.archrepo-signing-key = {};
  # rsync push to the always-on dmz mirror (vm-210)
  sops.secrets.archrepo-push-key = {};

  virtualisation.podman.enable = true;

  # 5-6 GiB of ram and no swap; a parallel rust build peaked at all of it
  zramSwap = { enable = true; memoryPercent = 100; };

  # build runs the recipes without secrets, publish holds the keys and signs only what it can vouch for (archrepo-build.sh)
  systemd.services.archbuild = {
    description = "Snapshot and build every package arch-dotfiles lists into the lsck0 pacman repo";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = [ pkgs.podman pkgs.coreutils pkgs.git pkgs.gnupg pkgs.gawk ];
    # a deploy must not kill a running build
    restartIfChanged = false;
    unitConfig.RequiresMountsFor = [ repoDir ];
    environment = {
      ARCHBUILD_SOURCE = dotfilesSource;
      ARCHBUILD_REF = dotfilesRef;
      # relative: the key on vm-210 runs rrsync rooted at the repo
      ARCHBUILD_PUSH_TARGET = "archrepo@${inventory."210".ip}:.";
    };
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "20h";
      # one compile the kernel kills for memory fails its package, not the night
      OOMPolicy = "continue";
      ExecStartPre = "${pkgs.coreutils}/bin/touch ${busyFlag}";
      # conmon lives outside this unit's cgroup, a stop would leave the build running unflagged
      ExecStopPost = [
        "${pkgs.podman}/bin/podman rm -f -t ${toString containerStopTimeoutS} ${containerBuild} ${containerPublish}"
        "${pkgs.coreutils}/bin/rm -f ${busyFlag}"
        # a first run has no status yet
        "-${metricsWrite}"
      ];
    };
    script = ''
      set -o pipefail
      run() {
        set -e
        export ARCHBUILD_RUN_STARTED ARCHBUILD_COMMIT
        ARCHBUILD_RUN_STARTED=$(date +%s)
        # an unsigned or foreign-signed head stops here: nothing builds, the published snapshot stays
        ARCHBUILD_COMMIT=$(${pkgs.bash}/bin/bash ${./lib/archrepo-fetch.sh} ${dotfilesSource} ${dotfilesRef} ${dotfilesDir} ${dotfilesSigningKey})
        jobs=$(( $(awk '/^MemTotal:/ { print $2 }' /proc/meminfo) / ${toString buildJobMemoryKiB} ))
        (( jobs > $(nproc) )) && jobs=$(nproc)
        (( jobs < 1 )) && jobs=1
        podman run --rm --init --replace --pull=newer --name ${containerBuild} \
          --cpuset-cpus "0-$(( jobs - 1 ))" \
          ${runEnv} \
          -v ${repoDir}:/repo:ro \
          -v ${dotfilesDir}:/dotfiles:ro \
          -v ${cacheDir}:/cache \
          -v ${outboxDir}:/outbox \
          -v ${publicDir}:/public \
          -v ${buildScript}:/build.sh:ro \
          -v ${listScript}:/list.sh:ro \
          ${image} bash /build.sh build
        podman run --rm --init --replace --pull=never --name ${containerPublish} \
          ${runEnv} -e ARCHBUILD_PUSH_TARGET \
          -v ${repoDir}:/repo \
          -v ${dotfilesDir}:/dotfiles:ro \
          -v ${outboxDir}:/outbox:ro \
          -v ${publicDir}:/public:ro \
          -v ${config.sops.secrets.archrepo-signing-key.path}:/run/signing.asc:ro \
          -v ${config.sops.secrets.archrepo-push-key.path}:/run/push-key:ro \
          -v ${buildScript}:/build.sh:ro \
          -v ${listScript}:/list.sh:ro \
          ${image} bash /build.sh publish
        # -P onto fresh names: the build container may have left links here
        rm -f ${publicDir}/status.txt ${publicDir}/status.json
        cp -P ${repoDir}/status.txt ${repoDir}/status.json ${publicDir}/
      }
      # the build container writes publicDir too, so the log is opened once, before it runs
      rm -f ${publicDir}/build.log
      run 2>&1 | tee ${publicDir}/build.log
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
      # the build container writes here: no link leads out of the tree and nothing renders as html
      extraConfig = ''
        autoindex on;
        disable_symlinks on;
        types { }
        default_type text/plain;
        charset utf-8;
        add_header X-Content-Type-Options nosniff;
      '';
      locations."= ${route.busyPath}".extraConfig = ''
        if (-f ${busyFlag}) { return 200; }
        return 404;
      '';
    };
  };

  systemd.tmpfiles.rules = map (dir: "d ${dir} 0755 root root -") [ cacheDir outboxDir dotfilesDir publicDir ];

  networking.firewall.allowedTCPPorts = [ route.port ];

  # authelia gates the status page
  homelab.ingressOnly.ports = [ route.port ];
}
