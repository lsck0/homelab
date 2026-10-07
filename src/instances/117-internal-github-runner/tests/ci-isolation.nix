# ci isolation on the real ci vm (../main.nix): every trust level is a user of its own (ci for the forgejo runner,
# gh-<repo> per github repo), none of them root, each reaching the internet and exactly its own lab services, from the
# host and from a container on its own rootless docker alike; nobody reads another's credentials or daemon; an
# ephemeral user starts each job from nothing; the egress rules survive a firewall restart and a stopped firewall
# (fail closed).
#
# Flat: vm-117 at its inventory address and `world`, which owns every address the probes go to (the gateway and
# dns, the lab services, the house lan, the internet) and answers on each with a labprobe sink. The runners are off
# (they would mint tokens from github); their users and daemons run as in the lab. The app builder is vm-140's.
# Every "refused" probe has its "open" twin from root, which reaches every sink: the refusal is the owner match.
{ pkgs, lib, specialArgs, seed ? 1, ... }:
let
  lab = import ../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };

  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  self = lab.inventory."117".ip;
  ghUser = "gh-nyangine";
  users = {
    ci = 2000;
    ${ghUser} = 2010;
  };
  # the oracle: what each identity may reach, written as the policy, not computed from the module
  internet = { ip = "198.51.100.7"; port = 443; };
  destinations = {
    dnsUdp = { ip = "10.100.0.1"; port = 53; proto = "udp"; who = [ "ci" ghUser ]; };
    dnsTcp = { ip = "10.100.0.1"; port = 53; who = [ "ci" ghUser ]; };
    ingress = { ip = "10.100.0.100"; port = 443; who = [ "ci" ]; };
    ingressHttp = { ip = "10.100.0.100"; port = 80; who = [ ]; };
    ingressSsh = { ip = "10.100.0.100"; port = 22; who = [ ]; };
    sccache = { ip = "10.100.0.110"; port = 6379; who = [ "ci" ]; };
    manager = { ip = "10.100.0.140"; port = 22; who = [ ]; };
    nfs = { ip = "10.100.0.109"; port = 2049; who = [ ]; };
    loki = { ip = "10.100.0.105"; port = 3100; who = [ ]; };
    authelia = { ip = "10.100.0.101"; port = 9091; who = [ ]; };
    proxmox = { ip = "192.168.178.200"; port = 8006; who = [ ]; };
    fritzbox = { ip = "192.168.178.1"; port = 80; who = [ ]; };
    edge = { ip = "10.200.0.200"; port = 443; who = [ ]; };
    worker = { ip = "10.250.0.250"; port = 20100; who = [ ]; };
    tailnet = { ip = "100.64.0.1"; port = 443; who = [ ]; };
    dockerNet = { ip = "172.16.5.5"; port = 80; who = [ ]; };
    internet = internet // { who = lib.attrNames users; };
  };
  tcpPorts = lib.unique (map (d: d.port) (lib.filter (d: (d.proto or "tcp") == "tcp") (lib.attrValues destinations)));
  worldAddresses = [ "10.100.0.1/8" ] ++ map (d: "${d.ip}/32") (lib.filter (d: d.ip != "10.100.0.1") (lib.attrValues destinations));
  dockerHost = uid: "unix:///run/user/${toString uid}/docker.sock";
  asUser = user: "runuser -u ${user} --";
  asContainer = user: "${asUser user} env DOCKER_HOST=${dockerHost users.${user}} docker run --rm --entrypoint '' -v /var/lib/labprobe:/var/lib/labprobe labprobe:test";
in
pkgs.testers.runNixOSTest {
  name = "ci-isolation";
  passthru.regressionSeeds = [ ];

  node.specialArgs = lab.specialArgs;

  nodes.vm-117 = { lib, ... }: {
    imports = [ (lab.guest "117" { flat = true; instance = ../main.nix; }) ];
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
    testing.honorSecretPermissions = true;
    # the runners mint tokens from api.github.com, forgejo's waits for vm-115
    services.github-runners = lib.mkForce { };
    systemd.services.forgejo-runner.wantedBy = lib.mkForce [ ];
    environment.systemPackages = [ pkgs.iproute2 ];
  };

  nodes.world = lab.multi { addresses = worldAddresses; };

  testScript = { nodes, ... }: lab.driverPython + ''
    SEED = ${toString seed}
    print(f"seed={SEED}")
    USERS = ${builtins.toJSON users}
    DESTINATIONS = ${builtins.toJSON destinations}
    RUNNERS = {}
    for user in USERS:
        RUNNERS[user] = "${asUser "USER"}".replace("USER", user)
    RUNNERS.update({f"{user}-container": cmd for user, cmd in ${builtins.toJSON (lib.mapAttrs (u: _: asContainer u) users)}.items()})

    def plan_for(via, src, seen):
        plan = []
        user = via.removesuffix("-container") if via else None
        # the owner match rejects; a container's slirp turns that rejection into silence, so it only must not arrive
        denied = "closed" if via and via.endswith("-container") else "refused"
        for name, d in sorted(DESTINATIONS.items()):
            allowed = user is None or user in d["who"]
            plan.append({"src": src, "dst": d["ip"], "proto": d.get("proto", "tcp"), "port": d["port"],
                         "expect": "open" if allowed else denied, "seen_src": seen, **({"via": via} if via else {})})
        return plan

    start_all()
    world.wait_for_unit("multi-user.target")
    vm_117.wait_for_unit("multi-user.target")
    for user, uid in USERS.items():
        vm_117.wait_for_file(f"/run/user/{uid}/docker.sock", timeout=120)
        vm_117.succeed(f"runuser -u {user} -- env DOCKER_HOST=unix:///run/user/{uid}/docker.sock docker load -i ${lab.images.labprobe}")
    probe_sinks_start([world], tcp=tuple(${builtins.toJSON tcpPorts}), udp=(53,))

    with subtest("each identity reaches the internet and its own lab services, host process and container alike"):
        plan = plan_for(None, "${self}", "${self}")
        for user in USERS:
            plan += plan_for(user, "${self}", "${self}")
            plan += plan_for(f"{user}-container", "0.0.0.0", "${self}")
        probe_check(plan, sources={"${self}": vm_117, "0.0.0.0": vm_117}, sinks=[world], seed=SEED, runners=RUNNERS)

    with subtest("nobody is root: no system docker socket, no root group, no sudo, no nix daemon"):
        vm_117.fail("test -e /run/docker.sock")
        for user in USERS:
            groups = vm_117.succeed(f"id -nG {user}").split()
            assert not {"wheel", "docker", "root"} & set(groups), (user, groups)
            vm_117.fail(f"runuser -u {user} -- sudo -n true")
            vm_117.fail(f"runuser -u {user} -- nix store ping --store daemon")
        # positive control: root talks to the daemon
        vm_117.succeed("nix store ping --store daemon")

    with subtest("each daemon is its user's alone"):
        for user, uid in USERS.items():
            for other, other_uid in USERS.items():
                cmd = f"runuser -u {user} -- env DOCKER_HOST=unix:///run/user/{other_uid}/docker.sock docker info"
                (vm_117.succeed if user == other else vm_117.fail)(cmd)

    with subtest("each credential has one reader"):
        readers = {
            "/run/secrets/github-runner-token": set(),
            "/run/secrets/rendered/github-runner-auth": set(),
            "/run/secrets/rendered/sccache-redis.env": {"ci"},
        }
        for path, allowed in readers.items():
            vm_117.succeed(f"test -s {path}")
            for user in USERS:
                (vm_117.succeed if user in allowed else vm_117.fail)(f"runuser -u {user} -- cat {path}")
        # a container sees what its user sees, nothing more
        vm_117.fail("${asUser ghUser} env DOCKER_HOST=${dockerHost users.${ghUser}} docker run --rm --entrypoint ''' -v /run:/h labprobe:test cat /h/secrets/rendered/sccache-redis.env")
        vm_117.succeed("${asUser "ci"} env DOCKER_HOST=${dockerHost users.ci} docker run --rm --entrypoint ''' -v /run:/h labprobe:test cat /h/secrets/rendered/sccache-redis.env")

    with subtest("subuid ranges follow the uid"):
        subuid = vm_117.succeed("cat /etc/subuid")
        for user, uid in USERS.items():
            assert f"{user}:{100000 + (uid - 2000) * 65536}:65536" in subuid, (user, subuid)

    with subtest("only sshd and node-exporter listen: a new listener is a deliberate change"):
        ports = {line.split()[3].rsplit(":", 1)[1] for line in vm_117.succeed("ss -Hltn").splitlines()}
        assert ports == {"22", "9100"}, ports

    with subtest("an ephemeral user starts every job from nothing"):
        uid = USERS["${ghUser}"]
        docker = f"runuser -u ${ghUser} -- env DOCKER_HOST=unix:///run/user/{uid}/docker.sock docker"
        vm_117.succeed(f"{docker} tag labprobe:test rust:1.80-bookworm")
        vm_117.succeed("runuser -u ${ghUser} -- sh -c 'mkdir -p ~/.config/systemd/user && echo poison > ~/.config/systemd/user/evil.service && echo x > ~/.bashrc'")
        # what the runner runs before every job (ExecStartPre)
        vm_117.succeed("${nodes.vm-117.homelab.rootlessDocker.${ghUser}.resetScript}")
        vm_117.succeed(f"test -S /run/user/{uid}/docker.sock")
        assert vm_117.succeed(f"{docker} image ls -q").strip() == "", "images survived the reset"
        vm_117.fail("test -e /var/lib/${ghUser}/.config/systemd/user/evil.service")
        vm_117.fail("test -e /var/lib/${ghUser}/.bashrc")
        # positive control: a non-ephemeral user keeps its images
        vm_117.succeed("${asUser "ci"} env DOCKER_HOST=${dockerHost users.ci} docker image inspect labprobe:test")

    with subtest("the runners' state root is traversable whoever made it, and boot clears dropped runners"):
        vm_117.succeed("chown 994:993 /var/lib/github-runner && chmod 0750 /var/lib/github-runner")
        vm_117.succeed("mkdir /var/lib/github-runner/dropped-1")
        vm_117.succeed("systemd-tmpfiles --create --remove --boot --prefix=/var/lib/github-runner")
        vm_117.succeed("runuser -u ${ghUser} -- test -x /var/lib/github-runner")
        vm_117.fail("test -e /var/lib/github-runner/dropped-1")

    def loop_successes(user, dst, port):
        """Connections that got through while the firewall restarted ten times."""
        vm_117.succeed(f"rm -f /tmp/loop-{user}; (runuser -u {user} -- bash -c 'for i in $(seq 1 400); do "
                       f"timeout 0.2 bash -c \"echo > /dev/tcp/{dst}/{port}\" 2>/dev/null && echo open; sleep 0.02; done; echo finished' "
                       f"> /tmp/loop-{user} 2>&1 &)")
        for _ in range(10):
            # ten restarts in seconds is a test's pace, not a failure: clear systemd's start limit each time
            vm_117.succeed("systemctl reset-failed firewall; systemctl restart firewall")
        vm_117.wait_until_succeeds(f"grep -qx finished /tmp/loop-{user}", timeout=120)
        return vm_117.succeed(f"cat /tmp/loop-{user}").count("open")

    with subtest("a firewall restart opens no window"):
        assert loop_successes("ci", "10.100.0.109", 2049) == 0, "ci reached the nas while the firewall restarted"
        assert loop_successes("root", "10.100.0.109", 2049) > 0, "the positive control never got through"

    with subtest("a stopped firewall leaves the users as confined (fail closed)"):
        vm_117.succeed("systemctl stop firewall")
        plan = plan_for("ci", "${self}", "${self}") + plan_for(None, "${self}", "${self}")
        probe_check(plan, sources={"${self}": vm_117}, sinks=[world], seed=SEED, runners=RUNNERS)
        vm_117.succeed("systemctl start firewall")
  '';
}
