# ci runners for github and forgejo, rootless: a job owns the ci user, never the vm
{ ... }: {
  vm = {
    bootPhase = "dev";
    needs = [ "containers" "nfs" ];
    # always on: the github listener, the forgejo runner and their rootless dockers, one job each at a time
    memoryMiB = 4096;
    balloonMiB = 2048;
    cores = 4;
    diskGiB = 40;
  };

  secrets = { github-runner-token = "manual"; };

  tokenReads = [ "forgejo-runner" ];

}
