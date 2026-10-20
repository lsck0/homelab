# the shared apps swarm: its state worker, its ports, and the one entry generating every worker
#
# the workers have no instance folder: modules/lab makes as many guests from `nodes.first` on as the enabled apps'
# reservations need (modules/limits workerCountOf), each with the vm shape `nodes.vm`
{
  # the worker holding every stateful service's volumes, dumped and archived from there; moving it moves no data
  state = 250;

  cadvisorPort = 9338;
  controllerPort = 8095;

  nodes = {
    first = 250;
    # the join token the manager mints, and the images its services name, which a worker's prune keeps (modules/swarm)
    tokenReads = [
      "swarm-worker-token"
      "swarm-images"
    ];
    on = [
      "swarmWorker"
      "appTelemetry"
    ];
    vm = {
      bootPhase = "public";
      needs = [
        "containers"
        "nfs"
      ];
      # memory is the swarm's admission capacity (modules/limits)
      memoryMiB = 896;
      cores = 2;
      # the swarm must never starve the lab: under host contention every lab guest outweighs a worker
      cpuUnits = 50;
      diskLimits = {
        readMBps = 100;
        writeMBps = 60;
        readIops = 2000;
        writeIops = 1000;
      };
      # ~320 Mbit/s: an app flood cannot fill the bridge the lab shares
      nicRateMBps = 40;
      diskGiB = 64;
    };
  };
}
