{ config, lib, pkgs, inventory, nasPath, catalog, lab, instance, upstream, ... }:
let
  inherit (instance.config) vm;
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
  # rolling like the distro, pulled per run so the in-container -Syu stays small (--pull=newer keeps the present
  # image through a registry outage); the build holds no secret
  buildImage = "docker.io/library/archlinux:base-devel";
  # the publish container holds the signing and push keys: a reviewed index digest of the same tag, bumped by hand
  publishImage = "${buildImage}@sha256:996c3a1d6b0d87b01242f6fcd8cfa3ad3eece1a67ab5c8f108e20af1d7b97bdd";
  # the push checks vm-210 against the lab's host keys, no trust on first use
  knownHosts = ../../generated/known_hosts;
  # arch-dotfiles bootstrap.sh SIGNING_KEY_FINGERPRINT: only commits this primary key signed get built and signed
  dotfilesSigningKey = "E7501F533316E9AFC6AAE907122F2CB527D1EFE3";
  dotfilesSource = "https://github.com/lsck0/arch-dotfiles";
  dotfilesRef = "master";
  buildScript = ./lib/archrepo-build.sh;
  # the package list of the checkout; publish gates the snapshot on it
  listScript = ./lib/archrepo-list.sh;
  containerBuild = "archbuild-build";
  containerPublish = "archbuild-publish";
  # memory one compile job may take: c++ with lto peaks near 2 GiB
  buildJobMemoryMiB = 2048;
  # nginx, sshd, conmon, node-exporter and the kernel stay outside the build container's limit
  systemReserveMiB = 768;
  # jobs from the balloon floor, which the host cannot take back mid-build
  buildJobs = let jobs = lib.min vm.cores ((vm.balloonMiB - systemReserveMiB) / buildJobMemoryMiB); in
    assert lib.assertMsg (jobs >= 1) "the balloon floor (instance.nix) leaves no ${toString buildJobMemoryMiB} MiB compile job"; jobs;
  # the limit is the ceiling: a build may use what the host leaves it, and a squeeze kills the build first
  buildMemoryMiB = vm.memoryMiB - systemReserveMiB;
  oomScoreAdjMax = 1000;
  # the third parties a night needs, probed before it in this order (modules/upstream)
  upstreams = [ "github" "aur" "archlinux" ];
  # the upstream that ended the night, written by whichever step met the outage
  unavailableFile = "/run/archbuild.unavailable";
  # podman rm grace before it kills a container
  containerStopTimeoutS = 30;
  # what both containers get of the run: the verified commit, the run id and the outage primitive
  runEnv = "-e ARCHBUILD_SOURCE -e ARCHBUILD_REF -e ARCHBUILD_COMMIT -e ARCHBUILD_RUN_STARTED"
    + " -v ${upstream.run}:/upstream:ro -v ${unavailableFile}:${unavailableFile}";
  # node-exporter's textfile collector (modules/base)
  metricsName = "archrepo";
  metricsFile = "${config.homelab.textfileDir}/${metricsName}.prom";
  # the served status after every run, a failed one included: what a client installing now lacks
  metricsWrite = pkgs.writeShellScript "archbuild-metrics" ''
    set -euo pipefail
    ${pkgs.jq}/bin/jq -r '"# TYPE homelab_archrepo_missing_packages gauge",
      "homelab_archrepo_missing_packages \(.missing // [] | length)",
      "# TYPE homelab_archrepo_held_back gauge",
      "homelab_archrepo_held_back \(if .held_back then 1 else 0 end)",
      "# TYPE homelab_archrepo_unavailable gauge",
      "homelab_archrepo_unavailable{upstream=\"\(.unavailable // "")\"} \(if .unavailable then 1 else 0 end)"' \
      ${repoDir}/status.json > ${metricsFile}.tmp
    ${pkgs.coreutils}/bin/mv -f ${metricsFile}.tmp ${metricsFile}
  '';
in {
  homelab.textfiles = [ metricsName ];
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
    path = [ pkgs.podman pkgs.coreutils pkgs.git pkgs.gnupg pkgs.jq pkgs.gnugrep ];
    # a deploy must not kill a running build
    restartIfChanged = false;
    unitConfig.RequiresMountsFor = [ repoDir ];
    environment = {
      ARCHBUILD_SOURCE = dotfilesSource;
      ARCHBUILD_REF = dotfilesRef;
      # relative: the key on vm-210 runs rrsync rooted at the repo
      ARCHBUILD_PUSH_TARGET = "archrepo@${inventory.${toString lab.routes.mirror.vmid}.ip}:.";
    };
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "20h";
      # a night skipped for an outage is no failure: the next one recovers
      SuccessExitStatus = [ upstream.unavailable ];
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
      unavailable=${toString upstream.unavailable}
      # <upstream> <status>: the status, naming the upstream when it was down
      unavailable_note() {
        [ "$2" -ne "$unavailable" ] || echo "$1" > ${unavailableFile}
        return "$2"
      }
      run() {
        set -e
        export ARCHBUILD_RUN_STARTED ARCHBUILD_COMMIT
        ARCHBUILD_RUN_STARTED=$(date +%s)
        for name in ${toString upstreams}; do
          ${upstream.run} "$name" || unavailable_note "$name" "$?"
        done
        # an unsigned or foreign-signed head stops here: nothing builds, the published snapshot stays
        ARCHBUILD_COMMIT=$(${pkgs.bash}/bin/bash ${./lib/archrepo-fetch.sh} ${dotfilesSource} ${dotfilesRef} ${dotfilesDir} \
          ${dotfilesSigningKey} ${upstream.run} github) || unavailable_note github "$?"
        podman run --rm --init --replace --pull=newer --name ${containerBuild} \
          --memory ${toString buildMemoryMiB}m --oom-score-adj ${toString oomScoreAdjMax} \
          --cpuset-cpus 0-${toString (buildJobs - 1)} \
          ${runEnv} -e ARCHBUILD_JOBS=${toString buildJobs} \
          -v ${repoDir}:/repo:ro \
          -v ${dotfilesDir}:/dotfiles:ro \
          -v ${cacheDir}:/cache \
          -v ${outboxDir}:/outbox \
          -v ${publicDir}:/public \
          -v ${buildScript}:/build.sh:ro \
          -v ${listScript}:/list.sh:ro \
          ${buildImage} bash /build.sh build
        podman run --rm --init --replace --pull=missing --name ${containerPublish} \
          ${runEnv} -e ARCHBUILD_PUSH_TARGET \
          -v ${repoDir}:/repo \
          -v ${dotfilesDir}:/dotfiles:ro \
          -v ${outboxDir}:/outbox:ro \
          -v ${publicDir}:/public:ro \
          -v ${config.sops.secrets.archrepo-signing-key.path}:/run/signing.asc:ro \
          -v ${config.sops.secrets.archrepo-push-key.path}:/run/push-key:ro \
          -v ${knownHosts}:/run/known_hosts:ro \
          -v ${buildScript}:/build.sh:ro \
          -v ${listScript}:/list.sh:ro \
          ${publishImage} bash /build.sh publish
      }
      # the build container writes publicDir too, so the log is opened once, before it runs
      rm -f ${publicDir}/build.log
      : > ${unavailableFile}
      status=0
      run 2>&1 | tee ${publicDir}/build.log || status=$?
      if [ "$status" -eq "$unavailable" ]; then
        bash ${./lib/archrepo-skip.sh} ${repoDir} "$(cat ${unavailableFile})" ${toString upstreams} || status=$?
      fi
      if [ "$status" -eq 0 ] || [ "$status" -eq "$unavailable" ]; then
        # -P onto fresh names: the build container may have left links here
        rm -f ${publicDir}/status.txt ${publicDir}/status.json
        cp -P ${repoDir}/status.txt ${repoDir}/status.json ${publicDir}/
      fi
      exit "$status"
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
}
