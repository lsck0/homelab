# ci runners for github and forgejo, rootless: a job owns the ci user, never the vm
{ ... }: {
  vm = {
    bootPhase = "dev";
    needs = [ "containers" "nfs" ];
    # always on, the app stacks build here: five .net listeners, the forgejo runner and ci's docker; jobs fit below
    memoryMiB = 4096;
    balloonMiB = 2048;
    cores = 4;
    diskGiB = 40;
  };

  secrets = { github-runner-token = "manual"; };
}
