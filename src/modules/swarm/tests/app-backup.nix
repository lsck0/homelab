# an app's state comes back: a volume archived by the state worker restores into its volume, and an app asleep
# (idle) is woken for its dump instead of failing it
#
# The real swarm (manager vm-140, state worker vm-250, nas vm-109) with two stateful apps of one image: `keep`
# archives its volume nightly, `sleepy` dumps from its container and sleeps when idle. The controller's door
# (lib/controller-api.py) is the only way the state worker wakes an app.
{ pkgs, lib, specialArgs, ... }:
let
  lab = import ../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
  registryAddress = lab.inventory."100".ip;
  manager = lab.inventory."140".ip;
  controllerPort = lab.appsCatalog.controllerPort;

  image = pkgs.dockerTools.buildLayeredImage {
    name = "fixture";
    tag = "v1";
    contents = [ pkgs.busybox pkgs.curl ];
    config.Cmd = [ "httpd" "-f" "-p" "8000" "-h" "/data" ];
  };
  appOf = name: port: extra: lib.recursiveUpdate {
    enable = true;
    repo = "lsck0/${name}";
    branch = "master";
    routes.${name} = { inherit port; off.sso = "the fixture is public"; };
    stateful = [ "web" ];
    volumes.data.backup = true;
  } extra;
  catalog = lab.appsCatalog // {
    apps = {
      keep = appOf "keep" 20160 { };
      sleepy = appOf "sleepy" 20170 {
        volumes.data.backup = lib.mkForce false;
        dumps.page = { service = "web"; command = "cat /data/index.html"; };
        idle.stopAfter = "30m";
      };
    };
  };

  node = vmid: {
    imports = [ (lab.guest vmid { flat = true; nas = true; }) ];
    homelab.appsCatalog = catalog;
    networking.hosts.${registryAddress} = [ "registry.lsck0.dev" ];
    environment.systemPackages = [ pkgs.curl pkgs.zstd ];
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
    services.journald.upload.enable = lib.mkForce false;
  };
in
pkgs.testers.runNixOSTest {
  name = "app-backup";

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
  nodes.vm-140 = node "140";
  nodes.vm-250 = node "250";

  testScript = ''
    import json
    import shlex

    def deploy(app):
        ref = f"registry.lsck0.dev/{app}/web"
        vm_140.succeed(f"docker tag fixture:v1 {ref}:v1 && docker push -q {ref}:v1")
        digest = vm_140.succeed(f"docker image inspect --format '{{{{range .RepoDigests}}}}{{{{println .}}}}{{{{end}}}}' {ref}:v1 | grep -F {ref}@").strip()
        stack = {"services": {"web": {"image": digest, "volumes": ["data:/data"]}}, "volumes": {"data": {}}}
        vm_140.succeed(f"echo {shlex.quote(json.dumps(stack))} > /tmp/{app}.json && swarm-apply {app} < /tmp/{app}.json")

    def task(app):
        return vm_250.succeed(f"docker ps -q --filter label=com.docker.swarm.service.name={app}_web | head -n1").strip()

    def page(app):
        return vm_250.succeed(f"docker exec {task(app)} cat /data/index.html").strip()

    start_all()
    vm_109.wait_for_unit("nfs-exports-reload.service")
    registry.wait_for_open_port(443)
    vm_140.wait_until_succeeds("[ $(docker node ls -q | wc -l) = 2 ]", timeout=300)
    vm_140.wait_until_succeeds("docker node inspect vm-250 --format '{{index .Spec.Labels \"homelab.state\"}}' | grep -qx true", timeout=120)
    vm_140.succeed("docker load -i ${image}")
    for app in ("keep", "sleepy"):
        deploy(app)
        vm_250.wait_until_succeeds(f"[ -n \"$(docker ps -q --filter label=com.docker.swarm.service.name={app}_web)\" ]", timeout=120)
        vm_250.succeed(f"docker exec {task(app)} sh -c 'echo {app}-v1 > /data/index.html'")

    with subtest("a volume archived by the state worker restores into its volume"):
        vm_250.succeed("systemctl start db-backup-keep-volume-data")
        vm_250.succeed("ls /var/backup/db/keep-volume-data/*.tar.zst")
        vm_250.succeed(f"docker exec {task('keep')} sh -c 'echo lost > /data/index.html'")
        # positive control of the refusal below: the volume is in use while the task runs
        refusal = vm_250.fail("swarm-volume-restore keep data 2>&1")
        assert "in use" in refusal, refusal
        vm_140.succeed("docker service scale --detach keep_web=0")
        vm_250.wait_until_succeeds("[ -z \"$(docker ps -q --filter volume=keep_data)\" ]", timeout=60)
        vm_250.succeed("swarm-volume-restore keep data")
        vm_140.succeed("docker service scale --detach keep_web=1")
        vm_250.wait_until_succeeds("[ -n \"$(docker ps -q --filter label=com.docker.swarm.service.name=keep_web)\" ]", timeout=120)
        assert page("keep") == "keep-v1", page("keep")

    with subtest("an app asleep is woken for its dump, which then holds its data"):
        vm_250.succeed("curl -sf -X POST http://${manager}:${toString controllerPort}/sleep/sleepy")
        vm_250.wait_until_succeeds("[ -z \"$(docker ps -q --filter label=com.docker.swarm.service.name=sleepy_web)\" ]", timeout=120)
        assert vm_250.succeed("curl -sf http://${manager}:${toString controllerPort}/state/sleepy").strip() == "stopped"
        vm_140.succeed("grep -q 'homelab_app_idle_stopped{app=\"sleepy\"} 1' /var/lib/node-exporter-textfile/swarm_idle_sleepy.prom")
        vm_250.succeed("systemctl start db-backup-sleepy-page")
        dump = vm_250.succeed("zstd -dc $(ls -1 /var/backup/db/sleepy-page/*.zst | tail -n1)").strip()
        assert dump == "sleepy-v1", dump
        assert vm_250.succeed("curl -sf http://${manager}:${toString controllerPort}/state/sleepy").strip() == "running"

    with subtest("the door answers wakes only for idle apps and from its wakers, redeploys only with the app's token"):
        vm_250.fail("curl -sf -X POST http://${manager}:${toString controllerPort}/wake/keep")
        vm_140.fail("curl -sf -X POST http://127.0.0.1:${toString controllerPort}/wake/sleepy")
        code = vm_250.succeed("curl -s -o /dev/null -w '%{http_code}' -X POST http://${manager}:${toString controllerPort}/redeploy/keep")
        assert code == "401", code
  '';
}
