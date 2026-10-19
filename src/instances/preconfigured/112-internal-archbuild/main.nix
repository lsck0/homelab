{
  config,
  lib,
  pkgs,
  utils,
  inventory,
  nasPath,
  catalog,
  lab,
  instance,
  upstream,
  ...
}:
let
  inherit (instance.config) vm;
  route = catalog.internal.archbuild;
  # pushed to vm-210, which serves mirror.lsck0.dev
  repoDir = "/var/lib/archrepo";
  repoAutomount = "${utils.escapeSystemdPath repoDir}.automount";
  # pacman cache, sources, cargo and go caches: what makes a nightly build incremental; the build container's alone
  cacheDir = "/var/lib/archbuild/cache";
  # the build container's proposal to the publish container: unsigned packages, staged db, state, report
  outboxDir = "/var/lib/archbuild/outbox";
  # the verified arch-dotfiles checkout, written by the host only, read-only in every container
  dotfilesDir = "/var/lib/archbuild/dotfiles";
  # the iso container's output, publish's input: the night's iso, its .sha256 and the run id
  isoOutDir = "/var/lib/archbuild/iso";
  # mkarchiso's root and image, about 10 GB while it builds, emptied after
  isoWorkDir = "/var/lib/archbuild/iso-work";
  # vm-104's lan mirror of the official repos (104-internal-nas main.nix archrepoPort): mkarchiso's packages
  isoMirror = "http://${inventory.${lab.roles.nas}.ip}:8090/archlinux/$repo/os/$arch";
  # the status page: build.log, logs/<base>.log, status.{txt,json}; publish pushes the logs to the mirror
  publicDir = "/var/lib/archbuild/public";
  # the on-demand reaper leaves the vm up while the busy endpoint finds it
  busyFlag = "/run/archbuild.busy";
  # a build started at the nightly wake stays fresh until the next one
  staleMinutes = 20 * 60;
  # the whole run's bound (TimeoutStartSec); the recipes get it less the snapshot, the iso and the publish after them
  runTimeoutS = 20 * 3600;
  publishReserveS = 3 * 3600;
  # mkarchiso takes about 10 minutes; a hung one is killed before it eats the publish's time
  isoTimeoutS = 3600;
  buildBudgetS = runTimeoutS - publishReserveS - isoTimeoutS;
  # rolling like the distro, pulled per run so the in-container -Syu stays small (--pull=newer keeps the present
  # image through a registry outage); the build holds no secret
  buildImage = "docker.io/library/archlinux:base-devel";
  # the publish container holds the signing and push keys: a reviewed index digest of the same tag, bumped by hand
  publishImage = "${buildImage}@sha256:996c3a1d6b0d87b01242f6fcd8cfa3ad3eece1a67ab5c8f108e20af1d7b97bdd";
  # the push checks vm-210 against the lab's host keys, no trust on first use
  knownHosts = ../../../generated/known_hosts;
  # arch-dotfiles bootstrap.sh SIGNING_KEY_FINGERPRINT: only commits this primary key signed get built and signed
  dotfilesSigningKey = "E7501F533316E9AFC6AAE907122F2CB527D1EFE3";
  dotfilesSource = "https://github.com/lsck0/arch-dotfiles";
  dotfilesRef = "master";
  buildScript = ./lib/archrepo-build.nu;
  # the package list of the checkout; publish gates the snapshot on it
  listScript = ./lib/archrepo-list.nu;
  # archrepo-build.nu's PACMAN_TRANSFER_TIMEOUT_S: a whole night's official downloads, several GiB after a gap
  pacmanTransferTimeoutS = 7200;
  # the image has no nushell: the entry readies pacman (arch's keyring, multilib; for the build a cache and whole
  # packages, the image strips docs and locales), runs the night's only sync with nushell in it, then hands over.
  # An archlinux outage ends the night like one inside the script (modules/upstream)
  containerEntry = ''
    set -eu
    pacman-key --init >/dev/null
    pacman-key --populate archlinux >/dev/null
    printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
    if [ "$1" = build ]; then
      mkdir -p /cache/pacman
      sed -i -e '/^NoExtract/d' -e 's|^#\?CacheDir.*|CacheDir = /cache/pacman/|' /etc/pacman.conf
    fi
    status=0
    UPSTREAM_TIMEOUT_S=${toString pacmanTransferTimeoutS} bash /upstream archlinux \
      pacman -Syu --noconfirm --needed nushell >/dev/null || status=$?
    if [ "$status" -eq ${toString upstream.unavailable} ]; then
      echo "archlinux unavailable, skipping the night"
      echo archlinux > ${unavailableFile}
    fi
    [ "$status" -eq 0 ] || exit "$status"
    exec nu --no-config-file /build.nu "$1"
  '';
  entry = mode: "bash -c ${lib.escapeShellArg containerEntry} archbuild ${mode}";
  # the gate before every night: only a head the pinned key signed is built
  fetch = pkgs.writers.writeNu "archrepo-fetch" {
    makeWrapperArgs = [
      "--prefix"
      "PATH"
      ":"
      (lib.makeBinPath [
        pkgs.git
        pkgs.gnupg
      ])
    ];
  } ./lib/archrepo-fetch.nu;
  skip = pkgs.writers.writeNu "archrepo-skip" {
    makeWrapperArgs = [
      "--prefix"
      "PATH"
      ":"
      (lib.makeBinPath [ pkgs.coreutils ])
    ];
  } ./lib/archrepo-skip.nu;
  containerBuild = "archbuild-build";
  containerIso = "archbuild-iso";
  containerPublish = "archbuild-publish";
  # memory one compile job may take: c++ with lto peaks near 2 GiB
  buildJobMemoryMiB = 2048;
  # nginx, sshd, conmon, node-exporter and the kernel stay outside the build container's limit
  systemReserveMiB = 768;
  # jobs from the balloon floor, which the host cannot take back mid-build
  buildJobs =
    let
      jobs = lib.min vm.cores ((vm.balloonMiB - systemReserveMiB) / buildJobMemoryMiB);
    in
    assert lib.assertMsg (
      jobs >= 1
    ) "the balloon floor (instance.nix) leaves no ${toString buildJobMemoryMiB} MiB compile job";
    jobs;
  # the limit is the ceiling: a build may use what the host leaves it, and a squeeze kills the build first
  buildMemoryMiB = vm.memoryMiB - systemReserveMiB;
  oomScoreAdjMax = 1000;
  oomScoreAdjMin = -1000;
  # the third parties a night needs, probed before it in this order (modules/upstream)
  upstreams = [
    "github"
    "aur"
    "archlinux"
  ];
  # the upstream that ended the night, written by whichever step met the outage
  unavailableFile = "/run/archbuild.unavailable";
  containerStopTimeoutS = 30;
  # podman rm of a 4 GiB build (conmon, overlay, memory) takes longer than the kill grace
  containerRemoveSlackS = 60;
  # status.json is on the hard-mounted nas: a hung read must not hold the stop
  metricsTimeoutS = 20;
  # systemd's 90 s default is shorter than this path
  stopTimeoutS = metricsTimeoutS + containerStopTimeoutS + containerRemoveSlackS;
  # what both containers get of the run: the verified commit, the run id and the outage primitive
  runEnv =
    "-e ARCHBUILD_SOURCE -e ARCHBUILD_REF -e ARCHBUILD_COMMIT -e ARCHBUILD_RUN_STARTED -e ARCHBUILD_BUILD_BUDGET_S"
    + " -v ${upstream.run}:/upstream:ro -v ${unavailableFile}:${unavailableFile}"
    + " -v ${buildScript}:/build.nu:ro -v ${listScript}:/list.nu:ro";
  metricsName = "archrepo";
  metricsFile = "${config.homelab.textfileDir}/${metricsName}.prom";
  # the served status after every run, a failed one included: what a client installing now lacks
  metricsWrite = pkgs.writeShellScript "archbuild-metrics" ''
    set -euo pipefail
    ${pkgs.coreutils}/bin/timeout -k ${toString metricsTimeoutS} ${toString metricsTimeoutS} ${pkgs.jq}/bin/jq -r '"# TYPE homelab_archrepo_missing_packages gauge",
      "homelab_archrepo_missing_packages \(.missing // [] | length)",
      "# TYPE homelab_archrepo_held_back gauge",
      "homelab_archrepo_held_back \(if .held_back then 1 else 0 end)",
      "# TYPE homelab_archrepo_unavailable gauge",
      "homelab_archrepo_unavailable{upstream=\"\(.unavailable // "")\"} \(if .unavailable then 1 else 0 end)"' \
      ${repoDir}/status.json > ${metricsFile}.tmp
    ${pkgs.coreutils}/bin/mv -f ${metricsFile}.tmp ${metricsFile}
  '';
in
{
  homelab.textfiles = [ metricsName ];
  homelab.nasMounts = nasPath repoDir "archrepo";

  sops.secrets.archrepo-signing-key = { };
  # rsync push to the always-on dmz mirror (vm-210)
  sops.secrets.archrepo-push-key = { };

  virtualisation.podman.enable = true;

  # 5-6 GiB of ram and no swap; a parallel rust build peaked at all of it
  zramSwap = {
    enable = true;
    memoryPercent = 100;
  };

  # build runs the recipes without secrets, publish holds the keys and signs only what it can vouch for (archrepo-build.nu)
  systemd.services.archbuild = {
    description = "Snapshot and build every package arch-dotfiles lists into the lsck0 pacman repo";
    wants = [ "network-online.target" ];
    # the automount, not the mount (RequiresMountsFor): an idle expiry or a restart of the mount would stop the build
    requires = [ repoAutomount ];
    after = [
      "network-online.target"
      repoAutomount
    ];
    path = [
      pkgs.podman
      pkgs.coreutils
    ];
    # a deploy must not kill a running build
    restartIfChanged = false;
    environment = {
      ARCHBUILD_SOURCE = dotfilesSource;
      ARCHBUILD_REF = dotfilesRef;
      ARCHBUILD_BUILD_BUDGET_S = toString buildBudgetS;
      # relative: the key on vm-210 runs rrsync rooted at the repo
      ARCHBUILD_PUSH_TARGET = "archrepo@${inventory.${toString lab.routes.mirror.vmid}.ip}:.";
      # the tree the edge shows the internet: the mirror route's publicPrefix
      ARCHBUILD_INTERNET_PREFIX = lab.routes.mirror.publicPrefix;
      ARCHBUILD_ISO_MIRROR = isoMirror;
    };
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = runTimeoutS;
      # a night skipped for an outage is no failure: the next one recovers
      SuccessExitStatus = [ upstream.unavailable ];
      ExecStartPre = "${pkgs.coreutils}/bin/touch ${busyFlag}";
      # bounded steps, the metrics first: an overrun kills what is left, never the gauges
      TimeoutStopSec = stopTimeoutS;
      ExecStopPost = [
        # a first run has no status yet
        "-${metricsWrite}"
        # conmon lives outside this unit's cgroup, a stop would leave the build running unflagged
        "${pkgs.podman}/bin/podman rm --force --ignore --time ${toString containerStopTimeoutS} ${containerBuild} ${containerIso} ${containerPublish}"
        "${pkgs.coreutils}/bin/rm -f ${busyFlag}"
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
      # run is called inside `run | tee || status=$?`, where bash ignores set -e: every step returns its own failure
      run() {
        export ARCHBUILD_RUN_STARTED ARCHBUILD_COMMIT
        ARCHBUILD_RUN_STARTED=$(date +%s)
        for name in ${toString upstreams}; do
          ${upstream.run} "$name" || unavailable_note "$name" "$?" || return
        done
        # an unsigned or foreign-signed head stops here: nothing builds, the published snapshot stays
        ARCHBUILD_COMMIT=$(${fetch} ${dotfilesSource} ${dotfilesRef} ${dotfilesDir} \
          ${dotfilesSigningKey} ${upstream.run} github) || { unavailable_note github "$?"; return; }
        podman run --rm --init --replace --pull=newer --name ${containerBuild} \
          --memory ${toString buildMemoryMiB}m --oom-score-adj ${toString oomScoreAdjMax} \
          --cpuset-cpus 0-${toString (buildJobs - 1)} \
          ${runEnv} -e ARCHBUILD_JOBS=${toString buildJobs} \
          -v ${repoDir}:/repo:ro \
          -v ${dotfilesDir}:/dotfiles:ro \
          -v ${cacheDir}:/cache \
          -v ${outboxDir}:/outbox \
          -v ${publicDir}:/public \
          ${buildImage} ${entry "build"} || return
        # mkarchiso mounts: privileged, so it holds no key and runs only the signed checkout and arch's
        # packages; its failure leaves the served iso and fails the unit after the publish (archrepo-build.nu)
        podman run --rm --init --replace --pull=missing --name ${containerIso} --privileged \
          --timeout ${toString isoTimeoutS} --memory ${toString buildMemoryMiB}m --oom-score-adj ${toString oomScoreAdjMax} \
          ${runEnv} -e ARCHBUILD_ISO_MIRROR \
          -v ${dotfilesDir}:/dotfiles:ro \
          -v ${isoWorkDir}:/iso-work \
          -v ${isoOutDir}:/iso \
          ${buildImage} ${entry "iso"} || echo "the iso build failed"
        # the host's address: the push to the dmz mirror is admitted from vm-112 alone, never from podman's bridge
        podman run --rm --init --replace --pull=missing --name ${containerPublish} --network host \
          ${runEnv} -e ARCHBUILD_PUSH_TARGET -e ARCHBUILD_INTERNET_PREFIX \
          -v ${repoDir}:/repo \
          -v ${dotfilesDir}:/dotfiles:ro \
          -v ${outboxDir}:/outbox:ro \
          -v ${publicDir}:/public:ro \
          -v ${isoOutDir}:/iso:ro \
          -v ${config.sops.secrets.archrepo-signing-key.path}:/run/signing.asc:ro \
          -v ${config.sops.secrets.archrepo-push-key.path}:/run/push-key:ro \
          -v ${knownHosts}:/run/known_hosts:ro \
          ${publishImage} ${entry "publish"}
      }
      # the build container writes publicDir too, so the log is opened once, before it runs
      rm -f ${publicDir}/build.log
      : > ${unavailableFile}
      status=0
      run 2>&1 | tee ${publicDir}/build.log || status=$?
      if [ "$status" -eq "$unavailable" ]; then
        ${skip} ${repoDir} "$(cat ${unavailableFile})" ${toString upstreams} || status=$?
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
    path = [
      pkgs.findutils
      pkgs.systemd
    ];
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
    timerConfig = {
      OnActiveSec = "3min";
      OnUnitActiveSec = "1h";
    };
  };

  # the reaper reads the busy flag through it: a squeeze's oom takes the build, never the answer keeping the guest up
  systemd.services.nginx.serviceConfig.OOMScoreAdjust = oomScoreAdjMin;
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

  systemd.tmpfiles.rules = map (dir: "d ${dir} 0755 root root -") [
    cacheDir
    outboxDir
    dotfilesDir
    publicDir
    isoOutDir
    isoWorkDir
  ];
}
