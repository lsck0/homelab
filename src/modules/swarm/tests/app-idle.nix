# an idle app sleeps and the edge wakes it, an app without idle never sleeps
#
# The real swarm (manager vm-140, worker vm-250, nas vm-109) behind the real edge (vm-200, offline crowdsec), whose
# on-demand proxy wakes an app through the manager's controller (lib/controller-api.py). `lazy` stops after its
# idle window, `steady` has none. A request to a sleeping app is held until the app answers; a deploy of a
# sleeping app updates it asleep.
{ pkgs, lib, specialArgs, ... }:
let
  lab = import ../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
  net = import ../../net.nix { inherit lib; inherit (specialArgs) inventory site; };
  ip = id: lab.inventory.${id}.ip;
  registryAddress = ip "100";
  edge = ip "200";
  cloudflare = "104.16.0.10";
  controller = "http://${ip "140"}:${toString lab.appsCatalog.controllerPort}";
  # short enough to watch it pass, long enough for a request's round trip
  idleWindow = "1m";
  requestTimeoutS = 120;

  image = pkgs.dockerTools.buildLayeredImage {
    name = "fixture";
    tag = "v1";
    contents = [ pkgs.busybox pkgs.curl (pkgs.writeTextDir "www/index.html" "awake\n") ];
    config.Cmd = [ "httpd" "-f" "-p" "8000" "-h" "/www" ];
  };
  appOf = name: port: extra: lib.recursiveUpdate {
    enable = true;
    repo = "lsck0/${name}";
    branch = "master";
    routes.${name} = { inherit port; health = "/"; off = { sso = "the fixture is public"; anubis = "no browser here"; }; };
  } extra;
  catalog = lab.appsCatalog // {
    apps = { lazy = appOf "lazy" 20180 { idle.stopAfter = idleWindow; }; steady = appOf "steady" 20190 { }; };
  };
  common = {
    homelab.appsCatalog = catalog;
    networking.hosts.${registryAddress} = [ "registry.lsck0.dev" ];
    environment.systemPackages = [ pkgs.curl ];
  };
  swarmNode = vmid: {
    imports = [ (lab.guest vmid { flat = true; nas = true; }) common ];
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
    services.journald.upload.enable = lib.mkForce false;
  };
in
pkgs.testers.runNixOSTest {
  name = "app-idle";

  node.specialArgs = lab.specialArgs;
  nodes.vm-109 = lab.nas { flat = true; };
  nodes.registry = {
    imports = [ (lab.multi { addresses = [ "${registryAddress}/8" ]; }) ];
    services.dockerRegistry = {
      enable = true;
      listenAddress = "0.0.0.0";
      port = 443;
      extraConfig.http.tls = { certificate = lab.pki.lsck0.cert; key = lab.pki.lsck0.key; };
    };
    systemd.services.docker-registry.serviceConfig.AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
  };
  nodes.vm-140 = swarmNode "140";
  nodes.vm-250 = swarmNode "250";
  nodes.vm-200 = {
    imports = [ (lab.guest "200" { flat = true; instance = ../../../instances/200-external-traefik/main.nix; }) ../../../tests/lib/offline-traefik.nix common ];
    virtualisation.memorySize = 1536;
    services.journald.upload.enable = lib.mkForce false;
  };
  nodes.world = {
    imports = [ (lab.multi { addresses = [ "10.100.0.1/8" "10.200.0.1/8" "10.250.0.1/8" "${cloudflare}/13" ]; }) ];
    environment.systemPackages = [ pkgs.curl ];
  };

  testScript = ''
    import json
    import shlex

    def request_command(app, timeout_s):
        """one request through the edge, as cloudflare relays a client; prints its status"""
        return (f"curl -s -m {timeout_s} -o /dev/null -w '%{{http_code}}' --interface ${cloudflare} "
                f"--resolve {app}.${net.domain}:443:${edge} -H 'X-Forwarded-For: 198.51.100.1' https://{app}.${net.domain}/")

    def request(app):
        return world.succeed(request_command(app, ${toString requestTimeoutS})).strip()

    def state(app):
        return vm_200.succeed(f"curl -s ${controller}/state/{app}").strip()

    def tasks(app):
        return int(vm_140.succeed(f"docker service ls --filter name={app}_web --format '{{{{.Replicas}}}}'").split("/")[0])

    def deploy(app):
        ref = f"registry.lsck0.dev/{app}/web"
        vm_140.succeed(f"docker tag fixture:v1 {ref}:v1 && docker push -q {ref}:v1")
        digest = vm_140.succeed(f"docker image inspect --format '{{{{range .RepoDigests}}}}{{{{println .}}}}{{{{end}}}}' {ref}:v1 | grep -F {ref}@").strip()
        stack = {"services": {"web": {"image": digest}}}
        vm_140.succeed(f"echo {shlex.quote(json.dumps(stack))} > /tmp/{app}.json && swarm-apply {app} < /tmp/{app}.json")

    start_all()
    vm_109.wait_for_unit("nfs-exports-reload.service")
    registry.wait_for_open_port(443)
    vm_140.wait_until_succeeds("[ $(docker node ls -q | wc -l) = 2 ]", timeout=300)
    vm_200.wait_for_unit("traefik.service")
    vm_140.succeed("docker load -i ${image}")
    for app in ("lazy", "steady"):
        deploy(app)
    world.wait_until_succeeds(f"[ $({request_command('steady', 10)}) = 200 ]", timeout=240)

    with subtest("an idle app nobody asked for goes to sleep, an app without idle stays up"):
        assert state("lazy") == "running"
        # the reaper's turn, as its timer would take it: no connection in the idle window
        vm_200.wait_until_succeeds("systemctl start ondemand-reaper && [ \"$(curl -s ${controller}/state/lazy)\" = stopped ]", timeout=240)
        vm_140.wait_until_succeeds("[ \"$(docker service ls --filter name=lazy_web --format '{{.Replicas}}' | cut -d/ -f1)\" = 0 ]", timeout=120)
        vm_140.succeed("grep -q 'homelab_app_idle_stopped{app=\"lazy\"} 1' /var/lib/node-exporter-textfile/swarm_idle_lazy.prom")
        assert tasks("steady") == 1
        vm_200.fail("curl -sf -X POST ${controller}/sleep/steady")

    with subtest("a deploy of a sleeping app updates it asleep"):
        deploy("lazy")
        assert tasks("lazy") == 0 and state("lazy") == "stopped"

    with subtest("a request wakes the sleeping app and is answered once it is up"):
        assert request("lazy") == "200"
        assert state("lazy") == "running" and tasks("lazy") == 1
        vm_140.succeed("grep -q 'homelab_app_idle_stopped{app=\"lazy\"} 0' /var/lib/node-exporter-textfile/swarm_idle_lazy.prom")

    with subtest("after its window without requests it sleeps again; steady never did"):
        vm_200.wait_until_succeeds("[ \"$(curl -s ${controller}/state/lazy)\" = stopped ]", timeout=300)
        assert tasks("steady") == 1 and request("steady") == "200"
  '';
}
