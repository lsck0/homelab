# the apps swarm end to end: a manager and two workers build the cluster from the inventory over the nas, the
# manager deploys an app through swarm-apply, the workers serve it, the policy and the autolock hold.
# nodes carry their lab hostnames, which the driver turns into vm_140, vm_150, vm_151
{ pkgs, lib, ... }:
let
  app = version: pkgs.dockerTools.buildLayeredImage {
    name = "registry.lsck0.dev/hello/web";
    tag = version;
    contents = [ pkgs.busybox pkgs.curl (pkgs.writeTextDir "www/index.html" "hello ${version}\n") ];
    config.Cmd = [ "httpd" "-f" "-p" "8000" "-h" "/www" ];
  };

  # tls like the real registry
  certs = pkgs.runCommand "registry-certs" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out && cd $out
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=test-ca -keyout ca.key -out ca.crt
    openssl req -newkey rsa:2048 -nodes -subj /CN=registry.lsck0.dev -keyout tls.key -out tls.csr
    printf 'subjectAltName=DNS:registry.lsck0.dev\n' > san.ext
    openssl x509 -req -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 3650 -extfile san.ext -out tls.crt
  '';

  helloPort = (import ../modules/apps.nix).apps.hello.paths."/".port;

  # the lab's view, with the test network's addresses: vm-140 manages, vm-150 and vm-151 work
  inventoryOf = nodes: {
    "140" = { name = "140-internal-swarm"; type = "internal"; ip = nodes.vm-140.networking.primaryIPAddress; prefix = 24; gateway = "192.168.1.254"; enabled = "true"; };
    "150" = { name = "150-apps-swarm"; type = "apps"; ip = nodes.vm-150.networking.primaryIPAddress; prefix = 24; gateway = "192.168.1.254"; enabled = "true"; };
    "151" = { name = "151-apps-swarm"; type = "apps"; ip = nodes.vm-151.networking.primaryIPAddress; prefix = 24; gateway = "192.168.1.254"; enabled = "true"; };
  };

  # the nas share the test's nas node exports, like vm-109
  nfs = options: mountpoint: name: {
    ${mountpoint} = {
      device = "nas:/srv/nas/data/${name}";
      fsType = "nfs";
      options = [ "nfsvers=4" "x-systemd.automount" "x-systemd.mount-timeout=60" ] ++ options;
    };
  };

  # a test vm mounts only virtualisation.fileSystems, so the shares the modules ask for are spelled out here
  swarmNode = id: { nodes, ... }: {
    imports = [ ../modules/retry.nix ../modules/tokens.nix ../modules/swarm.nix ./stubs.nix ];
    networking.hostName = "vm-${id}";
    virtualisation.fileSystems = nfs [ (if id == "140" then "rw" else "ro") ] "/var/lib/lab-tokens.d/vm-140" "tokens/vm-140"
      // lib.optionalAttrs (id == "140") (nfs [ "rw" ] "/var/lib/swarm-manager-nas" "swarm-manager");
    # network.nix would address eth0 from the inventory; the test network is eth1, as the driver set it up
    networking.interfaces.eth0.ipv4.addresses = lib.mkForce [ ];
    networking.defaultGateway = lib.mkForce null;
    networking.nameservers = lib.mkForce [ ];
    virtualisation.memorySize = 1536;
    virtualisation.diskSize = 4096;
    _module.args.inventory = inventoryOf nodes;
    environment.systemPackages = [ pkgs.curl ];
    networking.hosts.${nodes.registry.networking.primaryIPAddress} = [ "registry.lsck0.dev" ];
    environment.etc."docker/certs.d/registry.lsck0.dev/ca.crt".source = "${certs}/ca.crt";
  };
in
pkgs.testers.runNixOSTest {
  name = "swarm";

  nodes.nas = {
    services.nfs.server = {
      enable = true;
      exports = "/srv/nas/data *(rw,sync,no_root_squash,no_subtree_check,insecure)";
    };
    # a fresh nfsd holds every open for its 90s grace period; the real nas has long left it when guests boot
    services.nfs.settings.nfsd = { grace-time = 10; lease-time = 10; };
    networking.firewall.enable = false;
    systemd.tmpfiles.rules = map (d: "d /srv/nas/data/${d} 0777 root root -")
      [ "tokens/vm-140" "swarm-manager" "db-dumps/vm-150" ];
  };

  nodes.registry = {
    services.dockerRegistry = {
      enable = true;
      listenAddress = "0.0.0.0";
      port = 443;
      extraConfig.http.tls = { certificate = "${certs}/tls.crt"; key = "${certs}/tls.key"; };
    };
    systemd.services.docker-registry.serviceConfig.AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
    networking.firewall.allowedTCPPorts = [ 443 ];
  };

  nodes.vm-140 = swarmNode "140";
  nodes.vm-150 = swarmNode "150";
  nodes.vm-151 = swarmNode "151";

  testScript = { nodes, ... }: let
    w1 = nodes.vm-150.networking.primaryIPAddress;
    w2 = nodes.vm-151.networking.primaryIPAddress;
  in ''
    import json

    def stack(image, **extra):
        web = {"image": image, "healthcheck": {"test": ["CMD", "curl", "-f", "http://localhost:8000/"],
               "interval": "2s", "retries": 3, "start_period": "2s"}}
        web.update(extra)
        vm_140.succeed(f"echo {json.dumps(json.dumps({'services': {'web': web}}))} > /tmp/stack.json")

    def push(path, version):
        vm_140.succeed(f"docker load -i {path}")
        vm_140.succeed(f"docker push -q registry.lsck0.dev/hello/web:{version}")
        return vm_140.succeed(
            f"docker image inspect --format '{{{{index .RepoDigests 0}}}}' registry.lsck0.dev/hello/web:{version}"
        ).strip()

    start_all()
    nas.wait_for_unit("nfs-server.service")
    registry.wait_for_open_port(443)

    with subtest("the cluster builds itself: one drained manager, two workers"):
        vm_140.wait_for_unit("swarm-cluster.service")
        for worker in (vm_150, vm_151):
            worker.wait_for_unit("swarm-cluster.service")
        vm_140.wait_until_succeeds("[ $(docker node ls -q | wc -l) = 3 ]", timeout=180)
        vm_140.succeed("docker node inspect vm-140 --format '{{.Spec.Availability}}' | grep -qx drain")
        vm_140.succeed("docker node inspect vm-150 --format '{{index .Spec.Labels \"homelab.state\"}}' | grep -qx true")
        # a worker holds no control: it cannot read the cluster
        vm_150.fail("docker node ls")

    with subtest("an app deploys through swarm-apply and runs on the workers only"):
        stack(push("${app "v1"}", "v1"))
        vm_140.succeed("swarm-apply hello < /tmp/stack.json")
        vm_140.wait_until_succeeds("docker service ls --filter name=hello_web --format '{{.Replicas}}' | grep -qx 1/1", timeout=180)
        vm_140.fail("docker service ps hello_web --filter desired-state=running --format '{{.Node}}' | grep -q vm-140")
        # the routing mesh answers on every worker
        vm_150.wait_until_succeeds("curl -sf http://${w1}:${toString helloPort}/ | grep -q 'hello v1'", timeout=60)
        vm_151.wait_until_succeeds("curl -sf http://${w2}:${toString helloPort}/ | grep -q 'hello v1'", timeout=60)

    with subtest("the app's overlay network is encrypted"):
        vm_140.succeed("docker network inspect hello_default --format '{{index .Options \"encrypted\"}}' | grep -qx true")

    with subtest("only the edge and the trusted sources reach a published port"):
        vm_140.fail("curl -sf -m 5 http://${w1}:${toString helloPort}/")

    with subtest("the policy refuses a privileged stack and leaves the app running"):
        stack(push("${app "v2"}", "v2"), privileged=True)
        vm_140.fail("swarm-apply hello < /tmp/stack.json")
        vm_150.succeed("curl -sf http://${w1}:${toString helloPort}/ | grep -q 'hello v1'")

    with subtest("a new commit rolls out"):
        stack(push("${app "v2"}", "v2"))
        vm_140.succeed("swarm-apply hello < /tmp/stack.json")
        vm_150.wait_until_succeeds("curl -sf http://${w1}:${toString helloPort}/ | grep -q 'hello v2'", timeout=180)

    with subtest("a rebooted manager unlocks its autolocked raft by itself"):
        vm_140.shutdown()
        vm_140.start()
        vm_140.wait_for_unit("swarm-cluster.service")
        vm_140.succeed("docker info --format '{{.Swarm.LocalNodeState}}' | grep -qx active")
        vm_140.succeed("docker service ls --filter name=hello_web --format '{{.Name}}' | grep -qx hello_web")
  '';
}
