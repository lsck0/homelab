# the swarm's capacity, the apps' reservations and the lab-wide sums (modules/limits), table by table at
# evaluation time: each case states its numbers by hand, so the oracle is arithmetic, not the module. Then the same
# limits as modules/swarm/lib/swarm-render.py renders and admits them at deploy (tests/render_limits_test.py).
{ pkgs, lib, ... }:
let
  # -----------------------------------------------------------------------------
  # INTERNAL
  # -----------------------------------------------------------------------------

  # the typed defaults an app gets from modules/apps-catalog, restated
  taskDefaults = { memoryMiB = 512; cpus = 1.0; pids = 512; };
  app = { memoryMiB ? 1024, cpus ? 0.5, resources ? { } }: {
    reservation = { inherit memoryMiB cpus; };
    resources = lib.mapAttrs (_: r: taskDefaults // r) resources;
  };
  # a capped worker: 2560 MiB, 2 cores, a 1.5 core cap (the math takes fractions; the vm schema only whole cores)
  worker = { memoryMiB = 2560; cores = 2; cpuLimitCores = 1.5; };
  three = { "150" = worker; "151" = worker; "152" = worker; };

  limits = import ../default.nix { inherit lib; };
  limitsOf = { apps, workers ? three }: limits.clusterOf { inherit apps workers taskDefaults; };

  # -----------------------------------------------------------------------------
  # TABLES
  # -----------------------------------------------------------------------------

  # case -> attribute path of the result -> the value it must have
  derived = {
    allocatable-per-worker = {
      input = { apps = { }; };
      # 2560 - 512 MiB; 1.5 cores capped by proxmox - 0.5 kept by the node
      expect = { workers."150" = { memoryMiB = 2048; cpuMillis = 1000; }; capacity = { memoryMiB = 6144; cpuMillis = 3000; }; };
    };
    uncapped-worker-uses-its-cores = {
      input = { apps = { }; workers = { "150" = { memoryMiB = 2560; cores = 2; }; }; };
      expect = { workers."150".cpuMillis = 1500; };
    };
    sums-and-surge = {
      input = { apps = { a = app { }; b = app { memoryMiB = 2048; cpus = 1.0; }; }; };
      expect = { reserved = { memoryMiB = 3072; cpuMillis = 1500; }; surge = { memoryMiB = 2048; cpuMillis = 1000; }; problems = [ ]; };
    };
    reservations-round-up = {
      input = { apps = { a = app { cpus = 0.0005; }; }; };
      expect = { reserved.cpuMillis = 1; };
    };
    task-defaults-apply = {
      input = { apps = { a = app { resources.db = { memoryMiB = 768; cpus = 2.0; }; }; }; };
      # every task reserves the same 100 millicores
      expect = { tasks = { db = { memoryMiB = 768; cpuMillis = 100; cpus = 2.0; pids = 512; }; web = { memoryMiB = 512; cpuMillis = 100; cpus = 1.0; pids = 512; }; }; };
    };
  };

  # case -> a problem must contain this
  refused = {
    memory-over-capacity = {
      input = { apps = { a = app { memoryMiB = 2048; }; b = app { memoryMiB = 2048; }; c = app { memoryMiB = 2048; }; }; };
      expect = "the apps reserve 6144 MiB plus 2048 MiB for a rolling deploy, the workers hold 6144 MiB";
    };
    cpu-over-capacity = {
      input = { apps = { a = app { cpus = 1.5; }; b = app { cpus = 1.0; }; }; };
      expect = "the apps reserve 2500 millicores plus 1500 millicores for a rolling deploy, the workers hold 3000 millicores";
    };
    names-the-largest = {
      input = { apps = { small = app { memoryMiB = 1024; }; huge = app { memoryMiB = 4096; }; }; };
      expect = "(the largest: huge)";
    };
    task-larger-than-a-worker = {
      input = { apps = { a = app { memoryMiB = 4096; resources.db.memoryMiB = 3000; }; }; };
      expect = "apps.a.resources.db.memoryMiB 3000 is more than a worker holds for apps (2048 MiB)";
    };
    reservation-holds-no-task = {
      input = { apps = { a = app { memoryMiB = 256; }; }; };
      expect = "apps.a.reservation.memoryMiB 256 holds no task";
    };
    worker-too-small = {
      input = { apps = { a = app { }; }; workers = { "150" = { memoryMiB = 512; cores = 2; }; }; };
      expect = "worker vm-150 keeps 512 MiB";
    };
    no-workers = {
      input = { apps = { a = app { }; }; workers = { }; };
      expect = "the swarm has no worker";
    };
  };

  # -----------------------------------------------------------------------------
  # RESULTS
  # -----------------------------------------------------------------------------

  # the result's view the derived table compares: `tasks` is every service of the case's only app
  viewOf = input: let l = limitsOf input; in l // {
    tasks = let a = lib.head (lib.attrNames input.apps); in
      lib.genAttrs (lib.attrNames input.apps.${a}.resources ++ [ "web" ]) (l.taskOf a);
  };
  mismatches = name: expect: actual: lib.concatLists (lib.mapAttrsToList (key: want:
    if lib.isAttrs want && want != { } then mismatches "${name}.${key}" want actual.${key}
    else lib.optional (actual.${key} != want) "derived.${name}.${key}: ${builtins.toJSON actual.${key}}, expected ${builtins.toJSON want}"
  ) expect);

  failures =
    lib.concatLists (lib.mapAttrsToList (name: c: mismatches name c.expect (viewOf c.input)) derived)
    ++ lib.concatLists (lib.mapAttrsToList (name: c: let problems = (limitsOf c.input).problems; in
      lib.optional (!(lib.any (lib.hasInfix c.expect) problems))
        "refused.${name}: no problem says \"${c.expect}\"; problems: ${builtins.toJSON problems}") refused);
  count = attrs: toString (lib.length (lib.attrNames attrs));
in
pkgs.runCommand "limits" { nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.pyyaml ])) ]; } (if failures == [ ] then ''
  echo "limits: ${count derived} derivations and ${count refused} refusals hold"
  python3 ${./render_limits_test.py} ${../../swarm/lib/swarm-render.py}
  touch $out
'' else ''
  echo "limits: ${toString (lib.length failures)} failure(s):" >&2
  cat ${pkgs.writeText "limits-failures" (lib.concatLines failures)} >&2
  exit 1
'')
