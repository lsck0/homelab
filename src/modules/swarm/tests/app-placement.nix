# an app on its own guest is the same app as one on the shared swarm: same render, same deploy, same limits,
# capabilities and tenant, reached the same way through the edge
#
# A fixture tree (the real src plus two apps) collected by modules/lab: `level` runs on the shared swarm
# (manager vm-140, worker vm-250), `own` is placed on its own guest, a swarm of one. Every property is checked by
# one function over both apps, so a difference between the two placements is a failure of that property.
{ pkgs, lib, specialArgs, ... }:
let
  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  placedId = "220";
  ports = { level = 20160; own = 20170; };
  task = { memoryMiB = 192; cpus = 0.5; pids = 96; };
  cloudflare = "104.16.0.10";
  requestTimeoutS = 10;
  guestMemoryMiB = 1536;

  appOf = name: extra: {
    enable = true;
    repo = "lsck0/${name}";
    branch = "master";
    routes.${name} = { port = ports.${name}; health = "/"; off = { sso = "the fixture is public"; anubis = "no browser here"; }; };
    resources.web = task;
    reservation = { memoryMiB = 256; cpus = 0.5; };
  } // extra;
  apps = {
    level = appOf "level" { };
    own = appOf "own" { placement = { zone = "external"; vmid = lib.toInt placedId; vm.memoryMiB = guestMemoryMiB; }; };
  };

  # -----------------------------------------------------------------------------
  # INTERNAL
  # -----------------------------------------------------------------------------

  tree = pkgs.runCommand "lab-placement" { } (''
    cp -r ${../../..} $out
    chmod -R u+w $out/apps
  '' + lib.concatStrings (lib.mapAttrsToList (name: a: ''
    mkdir -p $out/apps/${name}
    cp ${pkgs.writeText "app.nix" (lib.generators.toPretty { } a)} $out/apps/${name}/app.nix
  '') apps));
  collected = import ../../lab { inherit lib; root = tree; };
  facts = specialArgs // { inherit (collected) inventory site; lab = collected; };
  lab = assert lib.assertMsg (collected.problems == [ ]) (lib.concatLines collected.problems);
    import ../../../tests/lib/lab.nix { inherit pkgs lib; specialArgs = facts; };
  net = import ../../net.nix { inherit lib; inherit (collected) inventory site; };
  telemetry = import ../../telemetry.nix { inherit lib; inherit (collected) inventory; };
  ip = id: collected.inventory.${id}.ip;
  registryAddress = ip "100";
  edge = ip "200";

  image = pkgs.dockerTools.buildLayeredImage {
    name = "fixture";
    tag = "v1";
    contents = [ pkgs.busybox (pkgs.writeTextDir "www/index.html" "app\n") ];
    config.Cmd = [ "httpd" "-f" "-p" "8000" "-h" "/www" ];
  };
  common = {
    networking.hosts.${registryAddress} = [ "registry.lsck0.dev" ];
    services.journald.upload.enable = lib.mkForce false;
    virtualisation.diskSize = 4096;
  };
  swarmNode = vmid: {
    imports = [ (lab.guest vmid { flat = true; nas = true; }) common ];
    virtualisation.memorySize = guestMemoryMiB;
  };
in
pkgs.testers.runNixOSTest {
  name = "app-placement";

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
  nodes."vm-${placedId}" = swarmNode placedId;
  nodes.vm-200 = {
    imports = [ (lab.guest "200" { flat = true; instance = ../../../instances/200-external-traefik/main.nix; }) ../../../tests/lib/offline-traefik.nix common ];
    virtualisation.memorySize = 1536;
  };
  nodes.world = {
    imports = [ (lab.multi { addresses = [ "10.100.0.1/8" "10.200.0.1/8" "10.250.0.1/8" "${cloudflare}/13" ]; }) ];
    environment.systemPackages = [ pkgs.curl ];
  };

  testScript = ''
    import json
    import shlex

    MANAGER = {"level": vm_140, "own": vm_${placedId}}
    WORKERS = {"vm-250": vm_250, "vm-${placedId}": vm_${placedId}}

    def deploy(app):
        manager = MANAGER[app]
        ref = f"registry.lsck0.dev/{app}/web"
        manager.succeed(f"docker load -i ${image} && docker tag fixture:v1 {ref}:v1 && docker push -q {ref}:v1")
        digest = manager.succeed(f"docker image inspect --format '{{{{range .RepoDigests}}}}{{{{println .}}}}{{{{end}}}}' {ref}:v1 | grep -F {ref}@").strip()
        stack = {"services": {"web": {"image": digest}}}
        manager.succeed(f"echo {shlex.quote(json.dumps(stack))} > /tmp/{app}.json && swarm-apply {app} < /tmp/{app}.json")

    def container_of(app):
        """the worker running the app's one task, and the container's inspect"""
        manager = MANAGER[app]
        running = f"docker service ps {app}_web --filter desired-state=running --format '{{{{.Node}}}} {{{{.CurrentState}}}}'"
        manager.wait_until_succeeds(f"{running} | grep -q ' Running'", timeout=180)
        machine = WORKERS[manager.succeed(f"{running} | grep ' Running' | head -n1").split()[0]]
        task = f"docker ps -q --filter label=com.docker.swarm.service.name={app}_web --filter status=running"
        machine.wait_until_succeeds(f"[ -n \"$({task})\" ]", timeout=60)
        cid = machine.succeed(f"{task} | head -n1").strip()
        return machine, json.loads(machine.succeed(f"docker inspect {cid}"))[0]

    def through_edge(app):
        return world.succeed(f"curl -s -m ${toString requestTimeoutS} -o /dev/null -w '%{{http_code}}' --interface ${cloudflare} "
                             f"--resolve {app}.${net.domain}:443:${edge} -H 'X-Forwarded-For: 198.51.100.1' https://{app}.${net.domain}/").strip()

    start_all()
    vm_109.wait_for_unit("nfs-exports-reload.service")
    registry.wait_for_open_port(443)
    vm_140.wait_until_succeeds("[ $(docker node ls -q | wc -l) = 2 ]", timeout=300)
    vm_${placedId}.wait_until_succeeds("docker node ls --format '{{.ManagerStatus}}' | grep -qx Leader", timeout=300)
    vm_200.wait_for_unit("traefik.service")

    with subtest("the guest is a swarm of its own, apart from the shared one"):
        assert vm_${placedId}.succeed("docker node ls -q | wc -l").strip() == "1"
        assert "vm-${placedId}" not in vm_140.succeed("docker node ls --format '{{.Hostname}}'")

    for app in ("level", "own"):
        deploy(app)

    for app in ("level", "own"):
        with subtest(f"{app}: limits, capabilities, cgroup and tenant as its catalog entry says"):
            machine, c = container_of(app)
            host = c["HostConfig"]
            assert host["Memory"] == ${toString task.memoryMiB} * 1024 * 1024, host["Memory"]
            assert host["NanoCpus"] == int(${toString task.cpus} * 10**9), host["NanoCpus"]
            assert host["PidsLimit"] == ${toString task.pids}, host["PidsLimit"]
            assert "ALL" in (host["CapDrop"] or []), host["CapDrop"]
            pid = c["State"]["Pid"]
            cgroup = machine.succeed(f"cut -d: -f3 /proc/{pid}/cgroup").strip()
            assert cgroup.startswith("/apps.slice/"), cgroup
            tenant = "${telemetry.tenantHeader}=" + "${telemetry.tenantOf "APP"}".replace("APP", app)
            assert any(e.endswith(tenant) for e in c["Config"]["Env"]), c["Config"]["Env"]

        with subtest(f"{app}: answers through the edge"):
            world.wait_until_succeeds(f"[ \"$(curl -s -m ${toString requestTimeoutS} -o /dev/null -w '%{{http_code}}' --interface ${cloudflare} "
                                      f"--resolve {app}.${net.domain}:443:${edge} -H 'X-Forwarded-For: 198.51.100.1' "
                                      f"https://{app}.${net.domain}/)\" = 200 ]", timeout=240)
  '';
}
