# the deploy controller: the apps swarm's manager (drained of tasks) and the app builder
{ ... }: {
  vm = {
    bootPhase = "dev";
    needs = [ "containers" "nfs" ];
    # raft and the deploys beside appbuild's rootless docker and buildkit, the builds 117 used to run
    memoryMiB = 4096;
    balloonMiB = 2048;
    cores = 4;
    # images, the buildkit cache and the raft
    diskGiB = 40;
  };

  tokens = [ "swarm-worker-token" ];

  services.deploy = {
    path = "/redeploy";
    # the controller's redeploy listener (socket activated, one token per app)
    port = (import ../../apps/swarm.nix).controllerPort;
    zone = "external";
    methods = [ "POST" ];
    # a bearer token and an empty body
    bodyLimitBytes = 1024;
    off = {
      sso = "ci jobs call it with the app's own bearer token";
      anubis = "ci jobs run no proof of work";
      homepage = "an endpoint, no page";
      probe = "POST only; socket activated, idle costs nothing";
    };
  };

  secrets = {
    app-deploy-key = "manual"; # ssh-keygen -t ed25519; public half in modules/swarm
  };
}
