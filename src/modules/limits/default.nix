# the lab's shared budgets: what a swarm worker holds, what the apps reserve of it, what every service may send
#
# Every consumer applies these numbers and none derives its own:
#
#   limits = import ./default.nix { inherit lib; };
#   limits.tenant           what one service may send: log lines, trace and profile bytes, scrape samples
#   limits.route            what one route admits from all its clients together (traefik.nix), beside the per-client
#                           limits
#   limits.frontend         what one browser beacon may carry, at the edge and at the intake on vm-105
#   limits.allocatableOf vm { memoryMiB; cpuMillis; } what a worker of this vm shape holds for apps: swarm advertises
#                           it as generic resources, apps.slice caps the containers to it (swarm.nix)
#   limits.lab              what the lab's own journals and access logs may send to loki, one tenant
#   limits.clusterOf { apps; workers; taskDefaults; }   one swarm (the shared one, or an app's own guest):
#     .workers.<vmid>       allocatableOf each worker
#     .capacity, .reserved, .surge   { memoryMiB; cpuMillis; } over the workers, the apps' sums, the largest single
#                           reservation (a deploy's transient extra)
#     .taskOf app service   { memoryMiB; cpus; pids; cpuMillis; } one task of an app's service, defaults applied
#     .problems             what does not fit, one line each naming the numbers and the knob
#
# Admission: a catalog fits when sum(reservations) + max(reservation) <= sum(allocatable), memory and cpu each.
# Deploys run one at a time (swarm-apply holds a lock on the manager), and a start-first update runs at most one
# extra task per stateless service, which is at most the deploying app's own reservation again. Render
# (modules/swarm/lib/swarm-render.py) holds each app inside its reservation at deploy; swarm holds each worker inside its
# allocatable at scheduling, so a task that fits no worker stays pending and fails its deploy, never a neighbour.
# Memory is reserved at its limit and never overcommitted; cpu reserves a fixed share per task and shares the rest.
#
# Every service gets the same telemetry budget; a service that needs more gets its own field the day one does.
#
# Rejected: admission against the workers' whole ram, as docker reports it. With dockerd and the node's services on
# top, a full worker ran into global out of memory, and the kernel killed whichever app was largest.
{ lib }:
let
  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  # a worker's own share: dockerd (image pulls, log copies), gossip, cadvisor, the log shipper, node exporter, sshd
  nodeReserveMiB = 512;
  nodeReserveCpuMillis = 500;
  millisPerCpu = 1000;
  # every task's guaranteed cpu share; its `cpus` limit lets it use idle cycles above that
  taskCpuMillis = 100;

  mib = 1024 * 1024;
  tenant = {
    # a startup burst or a stack trace passes, a loop logging every iteration does not
    logLinesPerSecond = 100;
    logBurstLines = 1000;
    # a json line with a stack trace fits; a longer one is cut at the shipper and in loki, never dropped
    logLineBytes = 16 * 1024;
    # the otlp exporters' batch of 512 spans and a pprof push every 10s fit the burst several times over
    traceBytesPerSecond = mib;
    traceBurstBytes = 4 * mib;
    profileBytesPerSecond = mib;
    profileBurstBytes = 4 * mib;
    # an exporter with a cardinality bug fails its own scrape long before it costs the tsdb
    scrapeSamples = 10000;
  };
  # a browser's beacon: a batch of spans or web vitals is a few KiB; an unauthenticated public input is cut here
  frontend.bodyBytes = 256 * 1024;
  # twice a busy client's per-client limit: one client cannot use a route's budget alone, a crowd is cut at the door
  route = { average = 100; burst = 200; inFlight = 200; };
  # loki's own defaults, under which the lab's journals and the edge's access log always ran
  lab = { logBytesPerSecond = 4 * mib; logBurstBytes = 6 * mib; };

  # -----------------------------------------------------------------------------
  # INTERNAL
  # -----------------------------------------------------------------------------

  # reservations round up and capacities down, so rounding never admits what does not fit
  cpuMillisUp = cpus: let m = cpus * millisPerCpu; f = builtins.floor m; in if m > f then f + 1 else f;
  cpuMillisDown = cpus: builtins.floor (cpus * millisPerCpu);
  sumOf = key: sets: lib.foldl' (acc: s: acc + s.${key}) 0 sets;
  maxOf = key: sets: lib.foldl' (acc: s: lib.max acc s.${key}) 0 sets;
  minOf = key: sets: lib.foldl' (acc: s: lib.min acc s.${key}) (lib.head sets).${key} sets;

  # proxmox's cpu limit, when set, is what the guest can use of its cores
  allocatableOf = vm: {
    memoryMiB = vm.memoryMiB - nodeReserveMiB;
    cpuMillis = cpuMillisDown (if (vm.cpuLimitCores or null) == null then vm.cores else vm.cpuLimitCores)
      - nodeReserveCpuMillis;
  };

  # -----------------------------------------------------------------------------
  # FUNCTIONS
  # -----------------------------------------------------------------------------

  clusterOf = { apps, workers, taskDefaults }: let
    allocatable = lib.mapAttrs (_: allocatableOf) workers;

    reservations = lib.mapAttrs (_: a: { inherit (a.reservation) memoryMiB; cpuMillis = cpuMillisUp a.reservation.cpus; })
      apps;
    totalsOf = sets: { memoryMiB = sumOf "memoryMiB" sets; cpuMillis = sumOf "cpuMillis" sets; };
    capacity = totalsOf (lib.attrValues allocatable);
    reserved = totalsOf (lib.attrValues reservations);
    surge = lib.genAttrs [ "memoryMiB" "cpuMillis" ] (key: maxOf key (lib.attrValues reservations));

    taskOf = a: service: (a.resources.${service} or taskDefaults) // { cpuMillis = taskCpuMillis; };

    largestOf = key:
      lib.head (lib.sort (x: y: reservations.${x}.${key} > reservations.${y}.${key}) (lib.attrNames reservations));
    fitProblem = key: unit: knob:
      lib.optional (apps != { } && reserved.${key} + surge.${key} > capacity.${key})
        ("the apps reserve ${toString reserved.${key}} ${unit} plus ${toString surge.${key}} ${unit} for a rolling deploy, "
          + "the workers hold ${toString capacity.${key}} ${unit}: lower apps.<app>.reservation.${knob} "
          + "(the largest: ${largestOf key}) or add a worker (apps/swarm.nix nodes.count)");

    # the smallest worker bounds a task: a larger one finds no worker once another is down
    taskProblems = app: a: let smallest = minOf "memoryMiB" (lib.attrValues allocatable); in
      map (service: "apps.${app}.resources.${service}.memoryMiB ${toString a.resources.${service}.memoryMiB} "
        + "is more than a worker holds for apps (${toString smallest} MiB)")
        (lib.filter (service: a.resources.${service}.memoryMiB > smallest) (lib.attrNames a.resources))
      ++ lib.optional (a.reservation.memoryMiB < taskDefaults.memoryMiB && a.resources == { })
        ("apps.${app}.reservation.memoryMiB ${toString a.reservation.memoryMiB} holds no task at "
          + "swarm.taskDefaults.memoryMiB ${toString taskDefaults.memoryMiB}: raise it or set resources");

    problems =
      if apps == { } then [ ]
      else if workers == { } then [ "apps are enabled, but the swarm has no worker (apps/swarm.nix nodes.count)" ]
      else map (id: "worker vm-${id} keeps ${toString nodeReserveMiB} MiB and ${toString nodeReserveCpuMillis} "
          + "millicores for itself and has nothing left for apps")
          (lib.attrNames (lib.filterAttrs (_: w: w.memoryMiB <= 0 || w.cpuMillis <= 0) allocatable))
        ++ fitProblem "memoryMiB" "MiB" "memoryMiB"
        ++ fitProblem "cpuMillis" "millicores" "cpus"
        ++ lib.concatLists (lib.mapAttrsToList taskProblems apps);
  in {
    inherit capacity reserved surge problems;
    workers = allocatable;
    taskOf = app: taskOf apps.${app};
    taskDefaults = taskDefaults // { cpuMillis = taskCpuMillis; };
    reservationOf = app: reservations.${app};
  };
in
{
  inherit tenant route frontend lab clusterOf allocatableOf taskCpuMillis cpuMillisUp;
}
