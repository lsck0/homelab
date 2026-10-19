# the apps swarm end to end: a manager and two workers build the cluster from the inventory over the nas, the
# manager deploys an app through swarm-apply, the workers serve it, the policy, the rollback check and the autolock
# hold, the reconcile follows the workers' events and not the manager's own, a task stuck pending is replaced by the
# next converge and a failed converge is tried again, a tcp and a udp route answer a client from anywhere on every
# worker (the router forwards to each, asserted from flows.nix), and a catalog edit reaches the running app without a
# commit: a changed port and env roll out, a disabled app's stack is removed.
# Lab guests at their real addresses on one flat network (tests/lib/lab.nix): the real modules mount the real
# shares (homelab.nasMounts) from a test nas that exports them by the real rules (104-internal-nas's lib/nas-exports.nix). The
# apps are the test's own, one app, so the production catalog can change without touching this test.
{
  pkgs,
  lib,
  specialArgs,
  ...
}:
let
  lab = import ../../../tests/lib/lab.nix {
    inherit pkgs lib specialArgs;
    apps = _: { inherit demo; };
  };
  net = import ../../net.nix {
    inherit lib;
    inherit (lab) inventory site;
  };
  flows = import ../../flows.nix {
    inherit lib net;
    inherit (lab) inventory catalog;
    inherit (lab.specialArgs) lab;
    nasClients = throw "the test reads the port forwards only";
  };

  app =
    version:
    pkgs.dockerTools.buildLayeredImage {
      name = "registry.lsck0.dev/demo/web";
      tag = version;
      contents = [
        pkgs.busybox
        pkgs.curl
        pkgs.socat
        (pkgs.writeTextDir "www/index.html" "demo ${version}\n")
      ];
      config.Cmd = [
        "httpd"
        "-f"
        "-p"
        "8000"
        "-h"
        "/www"
      ];
    };

  inherit (lab) profiles;
  # the router caps and logs a forward's clients
  forwarded = [
    "inflightLimit"
    "accessLog"
    "probe"
  ];
  port = 20130;
  portChanged = 20131;
  tcpPort = 20132;
  udpPort = 20133;
  # the echo service's datagram port in its container
  echoPort = 9000;
  # a client on the internet, as the router's forward hands it to a worker (source kept)
  client = "198.51.100.7";
  demo = {
    enable = true;
    repo = "lsck0/demo";
    branch = "master";
    routes = {
      demo = {
        service = "web";
        targetPort = 8000;
        inherit port;
        on = profiles.hardenedExternal ++ [ "probe" ];
      };
      demo-tcp = {
        protocol = "tcp";
        service = "web";
        targetPort = 8000;
        port = tcpPort;
        publicPort = tcpPort;
        on = forwarded;
      };
      demo-udp = {
        protocol = "udp";
        service = "echo";
        targetPort = echoPort;
        port = udpPort;
        publicPort = udpPort;
        on = forwarded;
      };
    };
    resources = {
      web.memoryMiB = 256;
      echo.memoryMiB = 128;
    };
    # stays up: its tcp and udp routes go from the router straight to the workers, past every wake proxy
    on =
      profiles.observed
      ++ profiles.traced
      ++ [
        "frontend"
        "homepage"
      ];
    # more than one worker holds beside a deploy's surge: the swarm gets two (modules/limits workerCountOf)
    reservation.memoryMiB = 768;
  };
  # a catalog edit as sync.nu deploys it: the lab collected again with the demo changed
  catalogWith = change: lib.mkForce (lab.withApps (apps: lib.recursiveUpdate apps { demo = change; })).catalog;

  w1 =
    assert lib.assertMsg (
      lab.appsCatalog.swarm.workers == [
        250
        251
      ]
    ) "swarm: the fixture needs two workers";
    lab.inventory."250".ip;
  w2 = lab.inventory."251".ip;

  # the router forwards each l4 route to every worker, by its own protocol
  forwards = lib.filter (
    f:
    lib.elem f.port [
      tcpPort
      udpPort
    ]
  ) flows.portForwards;
  forwardsWrong = lib.filter (
    f:
    f.addresses != [
      w1
      w2
    ]
    || f.proto != (if f.port == tcpPort then "tcp" else "udp")
  ) forwards;
  # registry.lsck0.dev resolves to the internal ingress; here the registry itself answers there
  registryAddress = lab.inventory."100".ip;

  swarmNode =
    vmid:
    { lib, ... }:
    {
      imports = [
        (lab.guest vmid {
          flat = true;
          nas = true;
        })
      ];
      virtualisation.memorySize = 1536;
      virtualisation.diskSize = 4096;
      environment.systemPackages = [ pkgs.curl ];
      networking.hosts.${registryAddress} = [ "registry.lsck0.dev" ];
      # no collector (vm-103) here: a failing upload would fail every switch below
      services.journald.upload.enable = lib.mkForce false;
      # what sync.nu does after an edit of an app, on every node at once
      specialisation.edited.configuration._module.args.catalog = catalogWith {
        routes.demo.port = portChanged;
        env.web.GREETING = "edited";
      };
      specialisation.disabled.configuration._module.args.catalog = catalogWith { enable = false; };
    };
in
assert lib.assertMsg (
  lib.length forwards == 2 && forwardsWrong == [ ]
) "the router's l4 forwards: ${builtins.toJSON forwards}";
pkgs.testers.runNixOSTest {
  name = "swarm";

  node.specialArgs = lab.specialArgs;
  nodes.vm-104 = lab.nas { flat = true; };

  # tls like the real registry, with the lab's *.lsck0.dev certificate every lab node trusts
  nodes.registry = {
    imports = [ (lab.multi { addresses = [ "${registryAddress}/8" ]; }) ];
    services.dockerRegistry = {
      enable = true;
      listenAddress = "0.0.0.0";
      port = 443;
      extraConfig.http.tls = {
        certificate = lab.pki.lsck0.cert;
        inherit (lab.pki.lsck0) key;
      };
    };
    systemd.services.docker-registry.serviceConfig.AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
  };

  # the internet behind the router: the workers' gateway, so their answers to the client come back here
  nodes.world = {
    imports = [
      (lab.multi {
        addresses = [
          "${client}/24"
          "${lab.inventory."250".gateway}/8"
        ];
      })
    ];
    environment.systemPackages = [
      pkgs.curl
      pkgs.socat
    ];
  };

  nodes.vm-107 = swarmNode "107";
  nodes.vm-250 = swarmNode "250";
  nodes.vm-251 = swarmNode "251";

  testScript = ''
    import json

    def stack(image, **extra):
        web = {"image": image, "healthcheck": {"test": ["CMD", "curl", "-f", "http://localhost:8000/"],
               "interval": "2s", "retries": 3, "start_period": "2s"}}
        web.update(extra)
        echo = {"image": image, "command": ["socat", "-T1", "UDP4-RECVFROM:${toString echoPort},fork", "EXEC:cat"]}
        vm_107.succeed(f"echo {json.dumps(json.dumps({'services': {'web': web, 'echo': echo}}))} > /tmp/stack.json")

    def push(path, version):
        ref = "registry.lsck0.dev/demo/web"
        vm_107.succeed(f"docker load -i {path}")
        vm_107.succeed(f"docker push -q {ref}:{version}")
        # an image pushed under several names lists a digest per repo, in no fixed order: this repo's own
        return vm_107.succeed(
            f"docker image inspect --format '{{{{range .RepoDigests}}}}{{{{println .}}}}{{{{end}}}}' {ref}:{version} | grep -F {ref}@"
        ).strip()

    def serves(port, text):
        for node, ip in ((vm_250, "${w1}"), (vm_251, "${w2}")):
            node.wait_until_succeeds(f"curl -sf http://{ip}:{port}/ | grep -q '{text}'", timeout=180)

    def deploy_ok():
        return vm_107.succeed("cat /var/lib/node-exporter-textfile/swarm_app_demo.prom")

    def switch(name):
        for node in (vm_107, vm_250, vm_251):
            node.succeed(f"/run/booted-system/specialisation/{name}/bin/switch-to-configuration test")

    start_all()
    vm_104.wait_for_unit("nfs-exports-reload.service")
    registry.wait_for_open_port(443)

    with subtest("the nas exports exactly what the swarm nodes mount"):
        exports = vm_104.succeed("exportfs -v")
        for share in ("tokens/vm-107", "swarm-manager"):
            assert f"/srv/nas/data/{share}" in exports, f"{share} is not exported"

    with subtest("the cluster builds itself: one drained manager, two workers"):
        vm_107.wait_for_unit("swarm-cluster.service")
        for worker in (vm_250, vm_251):
            worker.wait_for_unit("swarm-cluster.service")
        vm_107.wait_until_succeeds("[ $(docker node ls -q | wc -l) = 3 ]", timeout=180)
        vm_107.succeed("docker node inspect vm-107 --format '{{.Spec.Availability}}' | grep -qx drain")
        vm_107.wait_until_succeeds("docker node inspect vm-250 --format '{{index .Spec.Labels \"homelab.state\"}}' | grep -qx true", timeout=60)
        vm_107.succeed("[ -z \"$(docker node inspect vm-251 --format '{{index .Spec.Labels \"homelab.state\"}}')\" ]")
        # a worker holds no control: it cannot read the cluster
        vm_250.fail("docker node ls")
        # nothing kept yet: converge has nothing to apply
        vm_107.wait_for_unit("swarm-converge-demo.service")

    with subtest("the reconcile ignores the manager's own updates and follows a worker's"):
        vm_107.succeed("docker node update --label-add homelab.probe=manager vm-107")
        vm_107.succeed("docker node update --label-add homelab.probe=worker vm-251")
        vm_107.wait_until_succeeds("journalctl -u swarm-reconcile | grep -q 'node event: update vm-251'", timeout=30)
        vm_107.fail("journalctl -u swarm-reconcile | grep -q 'node event: update vm-107'")

    with subtest("an app deploys through swarm-apply, runs on the workers only, and is kept for converge"):
        v1 = push("${app "v1"}", "v1")
        stack(v1)
        vm_107.succeed("swarm-apply demo < /tmp/stack.json")
        vm_107.fail("docker service ps demo_web --filter desired-state=running --format '{{.Node}}' | grep -q vm-107")
        serves(${toString port}, "demo v1")
        assert 'homelab_swarm_deploy_ok{app="demo"} 1' in deploy_ok(), deploy_ok()
        vm_107.succeed("grep -q 'demo/web@sha256' /var/lib/swarm-apply/demo.yaml")

    with subtest("the app's overlay network is encrypted"):
        vm_107.succeed("docker network inspect demo_default --format '{{index .Options \"encrypted\"}}' | grep -qx true")

    with subtest("only the edge and the trusted sources reach a published port"):
        vm_107.fail("curl -sf -m 5 http://${w1}:${toString port}/")

    with subtest("a tcp and a udp route answer a client from anywhere on every worker"):
        for ip in ("${w1}", "${w2}"):
            world.wait_until_succeeds(f"curl -sf -m 5 --interface ${client} http://{ip}:${toString tcpPort}/ | grep -q 'demo v1'", timeout=120)
            world.wait_until_succeeds(f"echo ping | socat -T2 - UDP4:{ip}:${toString udpPort},bind=${client} | grep -qx ping", timeout=120)
        # positive control: the same client on the http route's port, which only the edge's grant opens
        world.fail("curl -sf -m 5 --interface ${client} http://${w1}:${toString port}/")

    with subtest("the policy refuses a privileged stack and leaves the app running"):
        stack(push("${app "v2"}", "v2"), privileged=True)
        vm_107.fail("swarm-apply demo < /tmp/stack.json")
        vm_250.succeed("curl -sf http://${w1}:${toString port}/ | grep -q 'demo v1'")
        assert 'homelab_swarm_deploy_ok{app="demo"} 0' in deploy_ok(), deploy_ok()
        # the kept stack is still the last good one
        kept = v1.split("@")[1]
        vm_107.succeed(f"grep -q {kept} /var/lib/swarm-apply/demo.yaml")

    with subtest("an update the swarm rolls back is a failed deploy, and the old version keeps serving"):
        stack(push("${app "v3"}", "v3"), command=["sh", "-c", "exit 1"])
        vm_107.fail("swarm-apply demo < /tmp/stack.json")
        vm_107.succeed("docker service inspect demo_web --format '{{.UpdateStatus.State}}' | grep -q rollback")
        serves(${toString port}, "demo v1")
        assert 'homelab_swarm_deploy_ok{app="demo"} 0' in deploy_ok(), deploy_ok()

    with subtest("a new commit rolls out"):
        v2 = push("${app "v2"}", "v2")
        stack(v2)
        vm_107.succeed("swarm-apply demo < /tmp/stack.json")
        serves(${toString port}, "demo v2")
        assert 'homelab_swarm_deploy_ok{app="demo"} 1' in deploy_ok(), deploy_ok()

    with subtest("a rebooted worker keeps its membership"):
        before = vm_251.succeed("docker info --format '{{.Swarm.NodeID}}'").strip()
        vm_251.shutdown()
        vm_251.start()
        vm_251.wait_for_unit("swarm-cluster.service")
        vm_251.wait_until_succeeds("docker info --format '{{.Swarm.LocalNodeState}}' | grep -qx active", timeout=120)
        assert vm_251.succeed("docker info --format '{{.Swarm.NodeID}}'").strip() == before
        vm_107.wait_until_succeeds("[ $(docker node ls -q | wc -l) = 3 ]", timeout=120)

    with subtest("a rebooted manager unlocks its autolocked raft by itself"):
        vm_107.shutdown()
        vm_107.start()
        vm_107.wait_for_unit("swarm-cluster.service")
        vm_107.succeed("docker info --format '{{.Swarm.LocalNodeState}}' | grep -qx active")
        vm_107.succeed("docker service ls --filter name=demo_web --format '{{.Name}}' | grep -qx demo_web")
        vm_107.wait_for_unit("swarm-converge-demo.service")
        serves(${toString port}, "demo v2")

    with subtest("a task stuck pending is replaced by the next converge, not waited on"):
        def forced():
            return vm_107.succeed("docker service inspect demo_web --format '{{.Spec.TaskTemplate.ForceUpdate}}'").strip()
        # pending with every worker ready: a reservation no worker holds, which the next deploy's spec drops
        vm_107.succeed("docker service update --detach --reserve-memory 64G demo_web")
        vm_107.wait_until_succeeds("docker service ps demo_web --filter desired-state=running --format '{{.CurrentState}}' | grep -q ^Pending", timeout=60)
        before = forced()
        vm_107.succeed("systemctl restart swarm-converge-demo.service")
        vm_107.succeed("journalctl -b -u swarm-converge-demo | grep -q 'rescheduling demo_web'")
        assert forced() != before, before
        serves(${toString port}, "demo v2")

    with subtest("a failed converge is tried again and clears its mark once it lands"):
        registry.succeed("systemctl stop docker-registry.service")
        vm_107.fail("systemctl restart swarm-converge-demo.service")
        vm_107.succeed("test -e /run/swarm-converge-pending/demo")
        registry.succeed("systemctl start docker-registry.service")
        registry.wait_for_open_port(443)
        vm_107.succeed("systemctl start swarm-converge-retry.service")
        vm_107.wait_until_succeeds("systemctl is-active swarm-converge-demo.service", timeout=300)
        vm_107.fail("test -e /run/swarm-converge-pending/demo")
        serves(${toString port}, "demo v2")

    with subtest("a catalog edit reaches the running app without a commit"):
        switch("edited")
        serves(${toString portChanged}, "demo v2")
        vm_107.succeed("docker service inspect demo_web --format '{{json .Spec.TaskTemplate.ContainerSpec.Env}}' | grep -q GREETING=edited")
        vm_250.fail("curl -sf -m 5 http://${w1}:${toString port}/")

    with subtest("a disabled app's stack is removed and its port answers nothing"):
        switch("disabled")
        vm_107.wait_until_succeeds("! docker stack ls --format '{{.Name}}' | grep -qx demo", timeout=60)
        vm_107.fail("test -e /var/lib/swarm-apply/demo.yaml")
        vm_250.wait_until_fails("curl -sf -m 5 http://${w1}:${toString portChanged}/", timeout=60)
        vm_107.fail("swarm-apply demo < /tmp/stack.json")
  '';
}
