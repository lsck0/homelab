# the registry behind the internal ingress, as shipped: the real vm-100 (traefik, push and pull credentials, the
# apps-zone refusal) in front of the real vm-106 (registry and ui, guarded so only the ingress reaches them)
#
# Who may do what, written as the policy:
# - reads and writes are separate routes on disjoint methods: a host that both pulls and pushes (the deploy
#   controller vm-107) reaches each with its own credential
# - pushers (the deploy controller, the ci vm, the workstation) push with `ci` or `builder`, and read what they push;
#   nobody deletes through the ingress (the ui's cleanup on vm-106 does)
# - the swarms (workers, managers) pull with `puller` and write nothing; the apps zone reaches no other internal route
# - every other source gets nothing, the edge relaying a forged X-Forwarded-For included
# - the backend answers the ingress only, the prober goes through it; ssh and node-exporter stay reachable (the
#   recovery path)
# - a rotated password takes effect on restart, the old one stops working
# - a firewall restart on vm-106 opens no window to the backend (desired; finding F7 of the e2e design)
# Flat: vm-100, vm-106 and `world`, which owns the gateways and every source address.
{ pkgs, lib, specialArgs, ... }:
let
  lab = import ../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
  net = import ../../../modules/net.nix { inherit lib; inherit (specialArgs) inventory site; };
  inherit (lab) routes;

  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  registry = net.fqdn routes.internal.registry-api.host;
  ingress = lab.inventory."100".ip;
  backend = lab.inventory."106".ip;
  backendPorts = { api = 5000; ui = 80; };
  sources = {
    ciVm = lab.inventory."111".ip;
    workstation = lab.site.lan.workstation;
    worker = lab.inventory."250".ip;
    # the shared swarm's manager and the builder
    controller = lab.inventory."107".ip;
    prober = lab.inventory."103".ip;
    dmz = lab.inventory."211".ip;
    edge = lab.inventory."200".ip;
    houseDevice = "192.168.178.50";
  };
  # the stub's value of every secret is test-<name> (tests/stubs/sops.nix)
  credentials = {
    ci = "test-registry-push-password";
    builder = "test-registry-builder-password";
    puller = "test-registry-pull-password";
  };
  rotated = "rotated-builder-password";
  # modules/traefik renders each route's users here, one file per route
  authDir = "/run/traefik-auth";
  image = pkgs.dockerTools.buildImage { name = "probe"; tag = "v1"; config.Cmd = [ "/probe" ]; };
  repository = "t4/probe";
  # firewall restarts and connection attempts in the window test
  restarts = 10;
  attempts = 300;
in
pkgs.testers.runNixOSTest {
  name = "registry-auth";

  node.specialArgs = lab.specialArgs;

  nodes.vm-100 = {
    imports = [ (lab.guest "100" { flat = true; instance = ../../100-internal-traefik/main.nix; }) ../../../tests/lib/offline-traefik.nix ];
    virtualisation.memorySize = 1536;
    testing.honorSecretPermissions = true;
  };

  nodes.vm-106 = {
    imports = [ (lab.guest "106" { flat = true; instance = ../main.nix; }) ];
    virtualisation.memorySize = 1536;
    virtualisation.diskSize = 4096;
    testing.honorSecretPermissions = true;
    virtualisation.oci-containers.containers.registry.imageFile = lab.images.registry;
    virtualisation.oci-containers.containers.registry-ui.imageFile = lab.images.registry-ui;
  };

  nodes.world = {
    imports = [ (lab.multi { addresses = [ "10.100.0.1/8" "192.168.178.1/24" ] ++ map (ip: "${ip}/32") (lib.attrValues sources); }) ];
    environment.systemPackages = [ pkgs.skopeo pkgs.netcat pkgs.jq ];
    # skopeo refuses every copy without /etc/containers/policy.json; this writes nixpkgs' default (accept anything)
    virtualisation.containers.enable = true;
    networking.hosts.${ingress} = [ registry (net.fqdn "grafana") (net.fqdn "git") (net.fqdn "auth") ];
  };

  testScript = lab.driverPython + ''
    import base64
    SOURCES = ${builtins.toJSON sources}
    CREDENTIALS = ${builtins.toJSON credentials}
    REGISTRY = "${registry}"

    def basic(user, password):
        return {"Authorization": "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()}

    def request(src, path="/v2/", method="GET", user=None, password=None, headers=None, host=REGISTRY):
        auth = basic(user, password if password is not None else CREDENTIALS[user]) if user else {}
        return http_request(world, f"https://{host}{path}", address="${ingress}", src=SOURCES[src], method=method,
                            headers={**auth, **(headers or {})})

    def expect(rows):
        failures = []
        for row in rows:
            src, method, path, user, want = row[:5]
            r = request(src, path, method, user, headers=row[5] if len(row) > 5 else None)
            if r["status"] != want:
                failures.append(f"{src} {method} {path} as {user}: {r['status']}, want {want}")
        assert not failures, "\n".join(failures)

    def via(src):
        """Route the world's traffic to the ingress from this source, for clients that cannot pick one."""
        world.succeed(f"ip route replace ${ingress}/32 dev eth1 src {SOURCES[src]}")

    start_all()
    vm_106.wait_for_unit("podman-registry.service")
    vm_106.wait_for_unit("podman-registry-ui.service")
    vm_106.wait_for_open_port(${toString backendPorts.api})
    vm_100.wait_for_unit("traefik.service")
    vm_100.wait_for_open_port(443)
    # the bouncer refuses every request until the crowdsec stub listens (lib/offline-traefik.nix)
    vm_100.wait_for_file("/var/lib/crowdsec/data/stub-ready")
    world.wait_for_unit("multi-user.target")

    manifest = "/v2/${repository}/manifests/v1"
    uploads = "/v2/${repository}/blobs/uploads/"
    with subtest("pushers: a credential for every request, ci and builder accepted, the pull credential writes nothing"):
        r = request("ciVm")
        assert r["status"] == 401 and r["headers"].get("www-authenticate") == 'Basic realm="registry-api"', r
        expect([
            ("workstation", "GET", "/v2/", None, 401),
            ("ciVm", "GET", "/v2/", "ci", 200),
            ("workstation", "GET", "/v2/", "builder", 200),
            ("controller", "GET", "/v2/", "builder", 200),
            ("ciVm", "GET", "/v2/", "ci", 401, basic("ci", "wrong")),
            ("ciVm", "HEAD", manifest, None, 401),
            ("ciVm", "POST", uploads, None, 401),
            ("ciVm", "POST", uploads, "puller", 401),
            ("controller", "POST", uploads, "puller", 401),
        ])

    with subtest("a push lands and reads back by digest"):
        via("ciVm")
        world.succeed(f"skopeo copy --dest-creds ci:{CREDENTIALS['ci']} docker-archive:${image} docker://{REGISTRY}/${repository}:v1")
        via("worker")
        digest = world.succeed(f"skopeo inspect --creds puller:{CREDENTIALS['puller']} --format '{{{{.Digest}}}}' docker://{REGISTRY}/${repository}:v1").strip()
        assert digest.startswith("sha256:"), digest
        expect([
            ("ciVm", "DELETE", f"/v2/${repository}/manifests/{digest}", "ci", 404),
            ("workstation", "DELETE", f"/v2/${repository}/manifests/{digest}", "builder", 404),
        ])
        via("ciVm")
        world.succeed(f"skopeo inspect --creds ci:{CREDENTIALS['ci']} docker://{REGISTRY}/${repository}:v1")
        # the controller pulls for its swarm and pushes for its builds, each with its own credential
        via("controller")
        world.succeed(f"skopeo inspect --creds puller:{CREDENTIALS['puller']} docker://{REGISTRY}/${repository}:v1")
        world.succeed(f"skopeo copy --dest-creds builder:{CREDENTIALS['builder']} docker-archive:${image} docker://{REGISTRY}/${repository}:v2")

    with subtest("the swarm pulls with its own credential and pushes nothing"):
        expect([
            ("worker", "GET", "/v2/", None, 401),
            ("controller", "GET", "/v2/", None, 401),
            ("worker", "GET", "/v2/", "puller", 200),
            ("controller", "HEAD", manifest, "puller", 200),
            ("worker", "POST", uploads, "puller", 404),
            ("worker", "POST", uploads, "ci", 404),
        ])
        via("worker")
        world.fail(f"skopeo copy --dest-creds puller:{CREDENTIALS['puller']} docker-archive:${image} docker://{REGISTRY}/${repository}:evil")

    with subtest("the apps zone reaches no other internal route"):
        # the positive control is the pull above: the worker reaches the ingress, and the registry route only
        for host in ("${net.fqdn "grafana"}", "${net.fqdn "git"}", "${net.fqdn "auth"}"):
            r = request("worker", "/", host=host)
            assert r["status"] in (403, 404), (host, r["status"])

    with subtest("every other source gets nothing, a relayed forgery included"):
        # a route's sources are part of its rule (modules/traefik): a source it does not admit matches no router
        expect([
            ("prober", "GET", "/v2/", "puller", 404),
            ("dmz", "GET", "/v2/", "puller", 404),
            ("houseDevice", "GET", "/v2/", "ci", 404),
            ("edge", "GET", "/v2/", "ci", 404, {"X-Forwarded-For": SOURCES["ciVm"]}),
            ("edge", "GET", "/v2/", "puller", 404, {"X-Forwarded-For": SOURCES["worker"]}),
        ])

    with subtest("the backend answers the ingress only; ssh and node-exporter stay open"):
        for port in (${toString backendPorts.api}, ${toString backendPorts.ui}):
            for src in ("ciVm", "worker", "workstation", "prober"):
                world.fail(f"curl -sS -m 5 --interface {SOURCES[src]} http://${backend}:{port}/")
            vm_100.succeed(f"curl -sS -m 5 -o /dev/null http://${backend}:{port}/")
        world.succeed(f"nc -z -w 5 -s {SOURCES['workstation']} ${backend} 22")
        world.succeed(f"curl -sf -m 5 --interface {SOURCES['workstation']} -o /dev/null http://${backend}:9100/metrics")

    with subtest("the credentials files: traefik's alone, bcrypt, exactly the users"):
        vm_100.succeed("[ \"$(stat -c '%a %U %G' ${authDir})\" = '750 root traefik' ]")
        for path, users in (("${authDir}/registry-push", ["builder", "ci"]), ("${authDir}/registry-api", ["builder", "ci", "puller"])):
            vm_100.succeed(f"[ \"$(stat -c '%a %U %G' {path})\" = '640 root traefik' ]")
            lines = vm_100.succeed(f"cat {path}").split()
            assert sorted(line.split(":")[0] for line in lines) == users, lines
            assert all(line.split(":", 1)[1].startswith("$2y$") for line in lines), lines

    with subtest("a rotated password replaces the old one"):
        # both checks hold the users: the ingress's basic auth and the backend's own htpasswd
        vm_100.succeed("printf %s ${rotated} > /run/secrets/registry-builder-password")
        vm_100.succeed("systemctl restart traefik-basic-auth traefik")
        vm_106.succeed("printf %s ${rotated} > /run/secrets/registry-builder-password")
        vm_106.succeed("systemctl restart registry-auth")
        vm_100.wait_for_open_port(443)
        vm_106.wait_for_open_port(${toString backendPorts.api})
        expect([
            ("controller", "GET", "/v2/", "builder", 401),
            ("controller", "GET", "/v2/", "builder", 200, basic("builder", "${rotated}")),
        ])

    def window_answers(machine, name, source=""):
        """Requests from machine (from source, if given) that the backend answered while its firewall restarted."""
        interface = f"--interface {source}" if source else ""
        # the driver's shell exports errexit: without set +e the first refused attempt (curl exit 28) ends the loop
        machine.succeed(f"rm -f /tmp/window-{name}; (set +e; for i in $(seq 1 ${toString attempts}); do curl -s -m 0.3 -o /dev/null "
                        f"-w '%{{http_code}}\\n' {interface} http://${backend}:${toString backendPorts.api}/v2/; sleep 0.02; "
                        f"done > /tmp/window-{name} &)")
        for _ in range(${toString restarts}):
            vm_106.succeed("systemctl reset-failed firewall; systemctl restart firewall")
        machine.wait_until_succeeds(f"[ $(wc -l < /tmp/window-{name}) -ge ${toString attempts} ]", timeout=180)
        # curl writes 000 for a request nothing answered; the backend answers 401 without credentials
        return len([code for code in machine.succeed(f"cat /tmp/window-{name}").split() if code != "000"])

    with subtest("a firewall restart on the backend opens no window"):
        assert window_answers(world, "ciVm", SOURCES["ciVm"]) == 0, "the backend answered a pusher directly while its firewall restarted"
        assert window_answers(vm_100, "ingress") > 0, "the positive control never got through"
  '';
}
