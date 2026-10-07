# ci runners for github and forgejo, rootless: a job owns the ci user, never the vm
{ ... }: {
  roles = [ "ci" ];

  vm = {
    bootPhase = "dev";
    needs = [ "containers" "nfs" ];
    # always on: the github listener, the forgejo runner and their rootless dockers, one job each at a time; the
    # floor holds the idle listeners, a job takes what the host has free
    memoryMiB = 4096;
    balloonMiB = 768;
    cores = 4;
    diskGiB = 40;
  };

  secrets = { github-runner-token = "manual"; };

  tokenReads = [ "forgejo-runner" ];

}
