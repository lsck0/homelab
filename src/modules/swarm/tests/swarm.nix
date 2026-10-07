# the apps swarm end to end: a manager and two workers build the cluster from the inventory over the nas, the
# manager deploys an app through swarm-apply, the workers serve it, the policy, the rollback check and the autolock
# hold, and a catalog edit reaches the running app without a commit: a changed port and env roll out, a disabled
# app's stack is removed.
# Lab guests at their real addresses on one flat network (tests/lib/lab.nix): the real modules mount the real
# shares (homelab.nasMounts) from a test nas that exports them by the real rules (109-internal-nas's lib/nas-exports.nix). The
# apps are the test's own, one app, so the production catalog can change without touching this test.
{ pkgs, lib, specialArgs, ... }:
let
  lab = import ../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; apps = _: { inherit demo; }; };

  app = version: pkgs.dockerTools.buildLayeredImage {
    name = "registry.lsck0.dev/demo/web";
    tag = version;
    contents = [ pkgs.busybox pkgs.curl (pkgs.writeTextDir "www/index.html" "demo ${version}\n") ];
    config.Cmd = [ "httpd" "-f" "-p" "8000" "-h" "/www" ];
  };

  port = 20130;
  portChanged = 20131;
  demo = {
    enable = true;
    repo = "lsck0/demo";
    branch = "master";
    routes.demo = { service = "web"; targetPort = 8000; inherit port; off.sso = "the test's public fixture"; };
    # more than one worker holds beside a deploy's surge: the swarm gets two (modules/limits workerCountOf)
    reservation.memoryMiB = 768;
  };
  # a catalog edit as sync.sh deploys it: the lab collected again with the demo changed
  catalogWith = change: lib.mkForce (lab.withApps (apps: lib.recursiveUpdate apps { demo = change; })).catalog;

  w1 = assert lib.assertMsg (lab.appsCatalog.swarm.workers == [ 250 251 ]) "swarm: the fixture needs two workers";
    lab.inventory."250".ip;
  w2 = lab.inventory."251".ip;
  # registry.lsck0.dev resolves to the internal ingress; here the registry itself answers there
  registryAddress = lab.inventory."100".ip;

  swarmNode = vmid: { lib, ... }: {
    imports = [ (lab.guest vmid { flat = true; nas = true; }) ];
    virtualisation.memorySize = 1536;
    virtualisation.diskSize = 4096;
    environment.systemPackages = [ pkgs.curl ];
    networking.hosts.${registryAddress} = [ "registry.lsck0.dev" ];
    # no collector (vm-105) here: a failing upload would fail every switch below
    services.journald.upload.enable = lib.mkForce false;
    # what sync.sh does after an edit of an app, on every node at once
    specialisation.edited.configuration._module.args.catalog = catalogWith {
      routes.demo.port = portChanged;
      env.web.GREETING = "edited";
    };
    specialisation.disabled.configuration._module.args.catalog = catalogWith { enable = false; };
  };
in
pkgs.testers.runNixOSTest {
  name = "swarm";

  node.specialArgs = lab.specialArgs;
  nodes.vm-109 = lab.nas { flat = true; };

  # tls like the real registry, with the lab's *.lsck0.dev certificate every lab node trusts
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
  nodes.vm-251 = swarmNode "251";

  testScript = ''
    import json

    def stack(image, **extra):
        web = {"image": image, "healthcheck": {"test": ["CMD", "curl", "-f", "http://localhost:8000/"],
               "interval": "2s", "retries": 3, "start_period": "2s"}}
        web.update(extra)
        vm_140.succeed(f"echo {json.dumps(json.dumps({'services': {'web': web}}))} > /tmp/stack.json")

    def push(path, version):
        ref = "registry.lsck0.dev/demo/web"
        vm_140.succeed(f"docker load -i {path}")
        vm_140.succeed(f"docker push -q {ref}:{version}")
        # an image pushed under several names lists a digest per repo, in no fixed order: this repo's own
        return vm_140.succeed(
            f"docker image inspect --format '{{{{range .RepoDigests}}}}{{{{println .}}}}{{{{end}}}}' {ref}:{version} | grep -F {ref}@"
        ).strip()

    def serves(port, text):
        for node, ip in ((vm_250, "${w1}"), (vm_251, "${w2}")):
            node.wait_until_succeeds(f"curl -sf http://{ip}:{port}/ | grep -q '{text}'", timeout=180)

    def deploy_ok():
        return vm_140.succeed("cat /var/lib/node-exporter-textfile/swarm_app_demo.prom")

    def switch(name):
        for node in (vm_140, vm_250, vm_251):
            node.succeed(f"/run/booted-system/specialisation/{name}/bin/switch-to-configuration test")

    start_all()
    vm_109.wait_for_unit("nfs-exports-reload.service")
    registry.wait_for_open_port(443)

    with subtest("the nas exports exactly what the swarm nodes mount"):
        exports = vm_109.succeed("exportfs -v")
        for share in ("tokens/vm-140", "swarm-manager"):
            assert f"/srv/nas/data/{share}" in exports, f"{share} is not exported"

    with subtest("the cluster builds itself: one drained manager, two workers"):
        vm_140.wait_for_unit("swarm-cluster.service")
        for worker in (vm_250, vm_251):
            worker.wait_for_unit("swarm-cluster.service")
        vm_140.wait_until_succeeds("[ $(docker node ls -q | wc -l) = 3 ]", timeout=180)
        vm_140.succeed("docker node inspect vm-140 --format '{{.Spec.Availability}}' | grep -qx drain")
        vm_140.wait_until_succeeds("docker node inspect vm-250 --format '{{index .Spec.Labels \"homelab.state\"}}' | grep -qx true", timeout=60)
        vm_140.succeed("[ -z \"$(docker node inspect vm-251 --format '{{index .Spec.Labels \"homelab.state\"}}')\" ]")
        # a worker holds no control: it cannot read the cluster
        vm_250.fail("docker node ls")
        # nothing kept yet: converge has nothing to apply
        vm_140.wait_for_unit("swarm-converge.service")

    with subtest("an app deploys through swarm-apply, runs on the workers only, and is kept for converge"):
        v1 = push("${app "v1"}", "v1")
        stack(v1)
        vm_140.succeed("swarm-apply demo < /tmp/stack.json")
        vm_140.fail("docker service ps demo_web --filter desired-state=running --format '{{.Node}}' | grep -q vm-140")
        serves(${toString port}, "demo v1")
        assert 'homelab_swarm_deploy_ok{app="demo"} 1' in deploy_ok(), deploy_ok()
        vm_140.succeed("grep -q 'demo/web@sha256' /var/lib/swarm-apply/demo.yaml")

    with subtest("the app's overlay network is encrypted"):
        vm_140.succeed("docker network inspect demo_default --format '{{index .Options \"encrypted\"}}' | grep -qx true")

    with subtest("only the edge and the trusted sources reach a published port"):
        vm_140.fail("curl -sf -m 5 http://${w1}:${toString port}/")

    with subtest("the policy refuses a privileged stack and leaves the app running"):
        stack(push("${app "v2"}", "v2"), privileged=True)
        vm_140.fail("swarm-apply demo < /tmp/stack.json")
        vm_250.succeed("curl -sf http://${w1}:${toString port}/ | grep -q 'demo v1'")
        assert 'homelab_swarm_deploy_ok{app="demo"} 0' in deploy_ok(), deploy_ok()
        # the kept stack is still the last good one
        kept = v1.split("@")[1]
        vm_140.succeed(f"grep -q {kept} /var/lib/swarm-apply/demo.yaml")

    with subtest("an update the swarm rolls back is a failed deploy, and the old version keeps serving"):
        stack(push("${app "v3"}", "v3"), command=["sh", "-c", "exit 1"])
        vm_140.fail("swarm-apply demo < /tmp/stack.json")
        vm_140.succeed("docker service inspect demo_web --format '{{.UpdateStatus.State}}' | grep -q rollback")
        serves(${toString port}, "demo v1")
        assert 'homelab_swarm_deploy_ok{app="demo"} 0' in deploy_ok(), deploy_ok()

    with subtest("a new commit rolls out"):
        stack(push("${app "v2"}", "v2"))
        vm_140.succeed("swarm-apply demo < /tmp/stack.json")
        serves(${toString port}, "demo v2")
        assert 'homelab_swarm_deploy_ok{app="demo"} 1' in deploy_ok(), deploy_ok()

    with subtest("a rebooted worker keeps its membership"):
        before = vm_251.succeed("docker info --format '{{.Swarm.NodeID}}'").strip()
        vm_251.shutdown()
        vm_251.start()
        vm_251.wait_for_unit("swarm-cluster.service")
        vm_251.wait_until_succeeds("docker info --format '{{.Swarm.LocalNodeState}}' | grep -qx active", timeout=120)
        assert vm_251.succeed("docker info --format '{{.Swarm.NodeID}}'").strip() == before
        vm_140.wait_until_succeeds("[ $(docker node ls -q | wc -l) = 3 ]", timeout=120)

    with subtest("a rebooted manager unlocks its autolocked raft by itself"):
        vm_140.shutdown()
        vm_140.start()
        vm_140.wait_for_unit("swarm-cluster.service")
        vm_140.succeed("docker info --format '{{.Swarm.LocalNodeState}}' | grep -qx active")
        vm_140.succeed("docker service ls --filter name=demo_web --format '{{.Name}}' | grep -qx demo_web")
        vm_140.wait_for_unit("swarm-converge.service")
        serves(${toString port}, "demo v2")

    with subtest("a catalog edit reaches the running app without a commit"):
        switch("edited")
        serves(${toString portChanged}, "demo v2")
        vm_140.succeed("docker service inspect demo_web --format '{{json .Spec.TaskTemplate.ContainerSpec.Env}}' | grep -q GREETING=edited")
        vm_250.fail("curl -sf -m 5 http://${w1}:${toString port}/")

    with subtest("a disabled app's stack is removed and its port answers nothing"):
        switch("disabled")
        vm_140.wait_until_succeeds("! docker stack ls --format '{{.Name}}' | grep -qx demo", timeout=60)
        vm_140.fail("test -e /var/lib/swarm-apply/demo.yaml")
        vm_250.wait_until_fails("curl -sf -m 5 http://${w1}:${toString portChanged}/", timeout=60)
        vm_140.fail("swarm-apply demo < /tmp/stack.json")
  '';
}
