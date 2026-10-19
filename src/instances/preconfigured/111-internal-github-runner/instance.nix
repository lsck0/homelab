# ci runners for github and forgejo, rootless: a job owns the ci user, never the vm
_: {
  roles = [ "ci" ];

  vm = {
    # parked while unused; "on" brings it back
    power = "off";
    bootPhase = "dev";
    needs = [
      "containers"
      "nfs"
    ];
    # the floor holds the idle listeners; a job takes what the host has free
    memoryMiB = 4096;
    balloonMiB = 768;
    cores = 4;
    diskGiB = 40;
  };

  secrets = {
    github-runner-token = "manual";
  };

  tokenReads = [ "forgejo-runner" ];

}
