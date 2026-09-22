{ config, lib, pkgs, ... }:
let
  # ───────────────────────────────────────────────────────────────────────────
  # ADD OR REMOVE A REPO HERE. Nothing else changes.
  # ───────────────────────────────────────────────────────────────────────────
  # <owner>/<repo> = how many jobs that repo may run at the same time. Each
  # replica is its own systemd unit and its own registered runner, so two
  # workflows in one repo (or two repos) run in parallel instead of queueing.
  #
  # Target them from a workflow with:
  #   runs-on: [self-hosted, nixos]
  repos = {
    "lsck0/homelab" = 2;
    "lsck0/arch-dotfiles" = 1;
    "lsck0/webapp-template" = 1;
  };

  # a fine-grained PAT with Administration: read and write on those repos
  # (sops: github-runner-token). The runner service exchanges it for a
  # registration token itself, and does so again after every job, which is what
  # makes `ephemeral` sustainable: a registration token would expire.
  tokenFile = config.sops.secrets.github-runner-token.path;

  slug = repo: lib.replaceStrings [ "/" ] [ "-" ] (lib.toLower repo);

  runners = lib.listToAttrs (lib.concatLists (lib.mapAttrsToList (repo: count:
    map (n: lib.nameValuePair "${slug repo}-${toString n}" {
      enable = true;
      url = "https://github.com/${repo}";
      name = "vm-117-${slug repo}-${toString n}";
      inherit tokenFile;

      # one job per runner process, then it de-registers, wipes its state
      # directory and registers again. A job therefore never sees another job's
      # checkout, credentials or leftover containers.
      ephemeral = true;

      # take over a stale registration with the same name instead of refusing to
      # start (happens after this VM is rebuilt or rolled back).
      replace = true;

      extraLabels = [ "nixos" "homelab" ];
      user = "github-runner";
      group = "github-runner";
      workDir = "/var/lib/github-runner/${slug repo}-${toString n}";

      # what a workflow can reasonably expect on the PATH without installing it.
      extraPackages = with pkgs; [
        bash coreutils findutils gnugrep gnused gnutar gzip xz which
        git gh curl jq
        docker docker-compose
        nix
        gnumake gcc pkg-config
        nodejs python3
      ];

      extraEnvironment = {
        # the internal registry and the Nix cache are reachable from this VM.
        DOCKER_BUILDKIT = "1";
      };

      serviceOverrides = {
        # CI is bursty and this VM is shared: keep one job from starving the rest
        # of the box, and stop a hung job from holding a runner forever.
        CPUWeight = 50;
        IOWeight = 50;
        MemoryHigh = "2G";
        MemoryMax = "3G";
        RuntimeMaxSec = "3h";
        SupplementaryGroups = [ "docker" ];
      };
    }) (lib.range 1 count)
  ) repos));
in {
  networking.hostName = "vm-117";

  # General-purpose GitHub Actions runners, one registration per repo replica.
  #
  # Why not Kubernetes with actions-runner-controller: ARC's value is elastic
  # capacity across a pool of nodes, and it buys that with a control plane to
  # run and upgrade. There is one node here. Ephemeral runners already give the
  # two properties that matter - a clean machine per job and N jobs in parallel -
  # for the price of N idle listener processes (tens of MB each), with no new
  # moving parts and no second scheduler to keep alive.
  #
  # Why this VM is always on: an on-demand VM is woken by the Traefik socket
  # proxy on an inbound request, and a queued GitHub job never touches our
  # ingress - the runner reaches out to GitHub. Waking it on demand would mean
  # a public webhook receiver in the DMZ that starts the VM on
  # `workflow_job.queued` and something to stop it again; until that exists,
  # this is a 4 GB VM whose idle cost is the listener processes above.

  users.users.github-runner = {
    isSystemUser = true;
    group = "github-runner";
    home = "/var/lib/github-runner";
    createHome = true;
    # docker for container jobs and `docker build`/`push` to vm-118.
    extraGroups = [ "docker" ];
  };
  users.groups.github-runner = { };

  virtualisation.docker = {
    enable = true;
    # a workflow that leaks images or layers must not fill the disk silently.
    autoPrune = {
      enable = true;
      dates = "daily";
      flags = [ "--all" "--filter" "until=48h" ];
    };
  };

  # the internal registry (vm-118) serves plain HTTP: allow it explicitly rather
  # than making every registry insecure.
  virtualisation.docker.daemon.settings.insecure-registries = [
    "10.100.0.118:5000"
    "registry.lsck0.dev"
  ];

  sops.secrets.github-runner-token = {
    owner = "github-runner";
    group = "github-runner";
    mode = "0400";
  };

  services.github-runners = runners;

  systemd.tmpfiles.rules = [
    "d /var/lib/github-runner 0750 github-runner github-runner -"
  ];

  # resolve the lab's own names without going out to Cloudflare.
  networking.hosts = {
    "10.100.0.118" = [ "registry.lsck0.dev" ];
    "10.100.0.115" = [ "git.lsck0.dev" ];
    "10.100.0.111" = [ "sccache.lsck0.dev" ];
  };

  # nothing listens here: the runners connect out to GitHub.
  networking.firewall.allowedTCPPorts = [ ];
}
