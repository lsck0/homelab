# the shared apps swarm: its state worker, its ports, and the one entry generating every worker
#
# The manager and the builder are the instances declaring the roles swarm-manager and app-builder (vm-140). The
# workers have no instance folder: modules/lab makes as many guests from `nodes.first` on as the enabled apps'
# reservations need (modules/limits workerCountOf, at least one), each with the vm shape `nodes.vm`
# (modules/instance-schema.nix `vm`) and nothing but modules/swarm as configuration.
{
  # the worker holding every stateful service's volumes, dumped and archived from there; moving it moves no data
  state = 250;

  # per-worker container metrics, scraped on every worker
  cadvisorPort = 9338;
  # the manager's controller: redeploys from ci, and an idle app's wake, sleep and state for the ingresses
  controllerPort = 8095;

  nodes = {
    first = 250;
    # the join token the manager mints (modules/swarm)
    tokenReads = [ "swarm-worker-token" ];
    vm = {
      bootPhase = "public";
      needs = [ "containers" "nfs" ];
      # dockerd, the swarm and a share of the stacks
      memoryMiB = 2560;
      # memory is the swarm's admission capacity (modules/limits): never reclaimed, never overcommitted
      balloonMiB = 0;
      cores = 2;
      # the swarm must never starve the lab: under host contention every lab guest outweighs a worker
      cpuUnits = 50;
      diskLimits = { readMBps = 100; writeMBps = 60; readIops = 2000; writeIops = 1000; };
      # ~320 Mbit/s: an app flood cannot fill the bridge the lab shares
      nicRateMBps = 40;
      # images of every stack plus the volumes placed here
      diskGiB = 64;
    };
  };
}
