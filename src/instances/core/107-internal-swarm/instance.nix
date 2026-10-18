# the deploy controller: the apps swarm's manager (drained of tasks) and the app builder
{ lib, profiles, ... }: {
  roles = [ "swarm-manager" "app-builder" ];
  on = [ "swarmManager" ];

  vm = {
    bootPhase = "dev";
    needs = [ "containers" "nfs" ];
    # the floor holds the manager; a build takes what the host has free
    memoryMiB = 3072;
    balloonMiB = 1024;
    cores = 4;
    # images, the buildkit cache and the raft
    diskGiB = 40;
  };

  tokens = [ "swarm-worker-token" "swarm-images" ];

  services.deploy = {
    path = "/redeploy";
    # the controller's redeploy listener (socket activated, one token per app)
    port = (import ../swarm.nix).controllerPort;
    zone = "external";
    methods = [ "POST" ];
    # a bearer token and an empty body
    bodyLimitBytes = 1024;
    # ci jobs call it with the app's own bearer token, which is nobody else's to decrypt, and solve no captcha
    on = lib.subtractLists [ "anubis" "captcha" "cloudflare" ] profiles.hardenedExternal ++ profiles.observed;
  };

  secrets = {
    app-deploy-key = "manual"; # ssh-keygen -t ed25519; the public half is app-deploy-key.pub here
  };

  shares = {
    "data/app-dashboards" = { };
    "data/swarm-manager" = { };
  };
}
