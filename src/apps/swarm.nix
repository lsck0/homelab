# the apps swarm: its fixed roles and the worker nodes, one entry generating every worker
#
# The builder (`builder`, instances/140-internal-swarm/lib/app-builder.nix) watches each enabled app's branch (src/apps/<name>/app.nix),
# builds the images of a new commit in the lab, parks them in the registry pinned by digest, and deploys the stack
# on the manager (modules/swarm), which layers the homelab on top: published ports, secrets from sops,
# encrypted overlay networks, state pinned to one node, limits, and a policy check that refuses anything privileged.
# The ingress of each route's zone routes it behind its protections, vm-105 scrapes `metrics`, and the router opens
# exactly these ports. Editing an app and running sync.sh redeploys it with the new settings; no app commit needed.
#
# The workers have no instance folder: modules/lab makes `nodes.count` guests from `nodes.first` on, each with
# the vm shape `nodes.vm` (modules/instance-schema.nix `vm`) and nothing but modules/swarm as configuration. Grow
# the cluster by raising the count.
{
  # the deploy controller: builds every app, pushes it and deploys it (140-internal-swarm imports app-builder.nix)
  builder = 140;

  # the swarm's manager, an instance of the internal zone by decision: the raft and the stacks' secrets stay inside
  manager = 140;
  # the worker holding every stateful service's volumes, dumped and archived from there; moving it moves no data
  state = 250;

  # per-worker container metrics, scraped on every worker
  cadvisorPort = 9338;
  # the manager's controller: redeploys from ci, and an idle app's wake, sleep and state for the ingresses
  controllerPort = 8095;

  nodes = {
    first = 250;
    count = 3;
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
