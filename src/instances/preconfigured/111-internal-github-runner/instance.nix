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
    # 762 MiB peak over 35d; the rest is a heavier job's headroom
    memoryMiB = 1536;
    cores = 4;
    diskGiB = 40;
  };

  secrets = {
    github-runner-token = "manual";
  };

  tokenReads = [ "forgejo-runner" ];

}
