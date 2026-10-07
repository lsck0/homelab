# the product, end to end: a commit on an app's branch becomes a running, routed app, and every way it can go wrong
# leaves the running version alone and says so
#
# Every lab node with its real instance: vm-100 (internal ingress: the registry's push and pull routes), vm-118 (the
# registry), vm-140 (the deploy controller: the shared swarm's manager and the builder, as appbuild on its rootless
# docker), vm-250 and vm-251 (workers), vm-200 (the edge: the apps' public routes and the controller's redeploy
# route), vm-109 (the nas exports their shares). The facts are the real lab's plus one app (tests/lib/lab.nix `apps`,
# as in modules/swarm/tests/app-placement.nix): `hello` (lsck0/homelab, watching its own folder) runs on the shared
# swarm, reserving here what two workers hold, plus `own` (lsck0/own) placed on its own guest vm-220, a swarm of one
# the builder deploys to over its forced command. `world` is everything outside: the gateways, github.com and api.github.com (git over smart http and the
# commits api, from bare repos, with the test ca's certificate), cloudflare, the dashboard's and the workstation's
# addresses. Nothing in app-builder.py changes for the test; the test only shortens the builder's backoff (a module
# input) and pins the guest's host key.
#
# The fixture images are built FROM scratch around a static busybox httpd, so `docker build --pull` needs no
# registry; hello's real one (alpine plus apk) cannot build offline, which is accepted here.
#
# Faults: the registry down, the guest's manager partitioned, the controller partitioned from its workers, the
# worker running the task crashed (the seed picks it), a worker rejoining, an image whose task dies (the swarm rolls
# back), the builder killed mid-build.
{ pkgs, lib, specialArgs, seed ? 1, ... }:
let
  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  placedId = "220";
  ownPort = 20170;
  guestMemoryMiB = 1536;
  # the app on its own guest; small enough that its admission fits the guest
  ownApp = {
    enable = true;
    repo = "lsck0/own";
    branch = "master";
    routes.own = { port = ownPort; health = "/"; off = { sso = "the fixture is public"; anubis = "no browser here"; }; };
    resources.web = { memoryMiB = 192; cpus = 0.5; pids = 96; };
    reservation = { memoryMiB = 256; cpus = 0.5; };
    placement = { zone = "external"; vmid = lib.toInt placedId; vm.memoryMiB = guestMemoryMiB; };
  };

  githubAddress = "140.82.112.3";
  cloudflare = "104.16.0.10";
  realClient = "198.51.100.1";
  # seconds: a failed commit is retried this soon, so the test sees the retry without waiting minutes
  backoff = { baseS = 2; maxS = 4; };
  # a run against a partitioned guest ends within ssh's connect timeout plus the builds
  partitionRunMaxS = 60;
  requestTimeoutS = 10;
  gitRoot = "/srv/git";
  workRoot = "/root/work";
  forgeLog = "/var/log/forge-api.log";
  apiPort = 8081;

  # -----------------------------------------------------------------------------
  # INTERNAL
  # -----------------------------------------------------------------------------

  lab = import ../../../tests/lib/lab.nix {
    inherit pkgs lib specialArgs;
    # more than one worker holds beside a deploy's surge: the shared swarm gets two (modules/limits workerCountOf)
    apps = folders: lib.recursiveUpdate folders { hello.reservation.memoryMiB = 768; } // { own = ownApp; };
  };
  collected = lab.specialArgs.lab;
  net = import ../../../modules/net.nix { inherit lib; inherit (collected) inventory site; };
  ip = id: collected.inventory.${id}.ip;

  hello = lab.appsCatalog.apps.hello;
  helloPort = hello.routes.hello.port;
  # where hello's commits go: its build context, its watched folder
  context = hello.build.web.context;
  watched = lib.head hello.watch;
  targetPort = hello.routes.hello.targetPort;
  registry = net.fqdn lab.routes.internal.registry-api.host;
  # the swarms' credential: the read route's user the write route lacks (modules/swarm)
  pull = lib.head (lib.mapAttrsToList (user: secret: { inherit user secret; })
    (removeAttrs lab.routes.internal.registry-api.basicAuth (lib.attrNames lab.routes.internal.registry-push.basicAuth)));
  deployHost = net.fqdn collected.routes.deploy.host;
  deployPath = collected.routes.deploy.path;

  ingress = ip "100";
  edge = ip "200";
  guest = ip placedId;
  homepage = ip "103";
  workstation = lab.site.lan.workstation;
  workers = assert lib.assertMsg (lab.appsCatalog.swarm.workers == [ 250 251 ]) "app-pipeline: the fixture needs two workers";
    { "250" = ip "250"; "251" = ip "251"; };
  stateDir = "/var/lib/app-builder";

  # the guest's host key, pinned on the builder like production's (homelab.appBuilder.knownHosts)
  guestHostKey = pkgs.runCommand "guest-host-key" { nativeBuildInputs = [ pkgs.openssh ]; } ''
    mkdir $out
    ssh-keygen -q -t ed25519 -N "" -C vm-${placedId} -f $out/key
  '';
  knownHosts = pkgs.writeText "known_hosts" "${guest} ${builtins.readFile "${guestHostKey}/key.pub"}";

  # GET /repos/<owner>/<repo>/commits?sha=<branch>&path=<p>&per_page=1, github's shape, from the bare repo
  forgeApi = pkgs.writers.writePython3 "forge-api" { flakeIgnore = [ "E501" ]; } ''
    import http.server
    import json
    import re
    import subprocess
    import urllib.parse

    COMMITS = re.compile(r"/repos/([^/]+/[^/]+)/commits")


    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            url = urllib.parse.urlsplit(self.path)
            query = urllib.parse.parse_qs(url.query)
            with open("${forgeLog}", "a") as f:
                f.write(self.path + "\n")
            match = COMMITS.fullmatch(url.path)
            if not match:
                self.send_response(404)
                self.end_headers()
                return
            out = subprocess.run(["${pkgs.git}/bin/git", "-C", "${gitRoot}/" + match.group(1), "log", "-1", "--format=%H %cI",
                                  query["sha"][0], "--", query["path"][0]], capture_output=True, text=True).stdout.split()
            body = json.dumps([{"sha": out[0], "commit": {"committer": {"date": out[1]}}}] if out else []).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass


    http.server.ThreadingHTTPServer(("127.0.0.1", ${toString apiPort}), H).serve_forever()
  '';

  common = {
    # production resolves the registry through the router's split horizon
    networking.hosts.${ingress} = [ registry ];
    # no collector (vm-105) here
    services.journald.upload.enable = lib.mkForce false;
    environment.systemPackages = [ pkgs.curl ];
  };
  swarmNode = vmid: {
    imports = [ (lab.guest vmid { flat = true; nas = true; }) common ];
    virtualisation.memorySize = 1536;
    virtualisation.diskSize = 4096;
  };
in
pkgs.testers.runNixOSTest {
  name = "app-pipeline";
  passthru.regressionSeeds = [ ];

  node.specialArgs = lab.specialArgs;
  nodes.vm-109 = lab.nas { flat = true; };

  nodes.world = { config, ... }: {
    imports = [ (lab.multi { addresses = [ "10.100.0.1/8" "10.200.0.1/8" "10.250.0.1/8" "${homepage}/32" "${workstation}/24"
                                           "${githubAddress}/32" "${cloudflare}/13" ]; }) ];
    virtualisation.memorySize = 1024;
    environment.systemPackages = [ pkgs.git pkgs.curl ];
    # http-backend runs as nginx's fcgiwrap user over root-owned repos
    environment.etc.gitconfig.text = "[safe]\n\tdirectory = *\n";
    services.fcgiwrap.instances.git = {
      process = { user = "nginx"; group = "nginx"; };
      socket = { user = "nginx"; group = "nginx"; };
    };
    services.nginx = {
      enable = true;
      virtualHosts."github.com" = {
        listen = [ { addr = githubAddress; port = 443; ssl = true; } ];
        onlySSL = true;
        sslCertificate = lab.pki.github.cert;
        sslCertificateKey = lab.pki.github.key;
        locations."/".extraConfig = ''
          fastcgi_pass unix:${config.services.fcgiwrap.instances.git.socket.address};
          include ${pkgs.nginx}/conf/fastcgi_params;
          fastcgi_param SCRIPT_FILENAME ${pkgs.git}/libexec/git-core/git-http-backend;
          fastcgi_param GIT_PROJECT_ROOT ${gitRoot};
          fastcgi_param GIT_HTTP_EXPORT_ALL "";
          fastcgi_param PATH_INFO $uri;
        '';
      };
      virtualHosts."api.github.com" = {
        listen = [ { addr = githubAddress; port = 443; ssl = true; } ];
        onlySSL = true;
        sslCertificate = lab.pki.github.cert;
        sslCertificateKey = lab.pki.github.key;
        locations."/".proxyPass = "http://127.0.0.1:${toString apiPort}";
      };
    };
    systemd.services.forge-api = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = forgeApi;
    };
  };

  nodes.vm-100 = {
    imports = [ (lab.guest "100" { flat = true; instance = ../../100-internal-traefik/main.nix; }) ../../../tests/lib/offline-traefik.nix common ];
    virtualisation.memorySize = 1536;
    testing.honorSecretPermissions = true;
  };

  nodes.vm-118 = {
    imports = [ (lab.guest "118" { flat = true; instance = ../../118-internal-registry/main.nix; }) common ];
    virtualisation.memorySize = 1024;
    virtualisation.diskSize = 4096;
    virtualisation.oci-containers.containers.registry.imageFile = lab.images.registry;
    virtualisation.oci-containers.containers.registry-ui.imageFile = lab.images.registry-ui;
  };

  nodes.vm-140 = { lib, ... }: {
    imports = [ (lab.guest "140" { flat = true; nas = true; instance = ../main.nix; }) common ];
    virtualisation.memorySize = 3072;
    virtualisation.diskSize = 6144;
    # ssh refuses a world-readable key; the controller reads its tokens as its own user
    testing.honorSecretPermissions = true;
    # the test starts the builder itself
    systemd.timers.app-builder.wantedBy = lib.mkForce [ ];
    # its runs follow each other faster than systemd's start limit (5 in 10s) allows a unit
    systemd.services.app-builder.startLimitIntervalSec = 0;
    networking.hosts.${githubAddress} = [ "github.com" "api.github.com" ];
    homelab.appBuilder = { inherit knownHosts backoff; };
  };
  nodes.vm-250 = swarmNode "250";
  nodes.vm-251 = swarmNode "251";
  nodes."vm-${placedId}" = {
    imports = [ (swarmNode placedId) ];
    homelab.swarm.deployKey = builtins.readFile lab.secretValues.public.app-deploy-key;
    environment.etc."ssh/ssh_host_ed25519_key" = { source = "${guestHostKey}/key"; mode = "0600"; };
    environment.etc."ssh/ssh_host_ed25519_key.pub".source = "${guestHostKey}/key.pub";
  };

  nodes.vm-200 = {
    imports = [ (lab.guest "200" { flat = true; instance = ../../200-external-traefik/main.nix; }) ../../../tests/lib/offline-traefik.nix common ];
    virtualisation.memorySize = 1536;
  };

  testScript = { nodes, ... }: ''
    import json
    import random
    import time
    SEED = ${toString seed}
    print(f"seed={SEED}")
    RNG = random.Random(SEED)
    WORKERS = {"250": vm_250, "251": vm_251}
    ADDRESSES = ${builtins.toJSON workers}
    REPOS = {"hello": "${hello.repo}", "own": "${ownApp.repo}"}
    BRANCHES = {"hello": "${hello.branch}", "own": "${ownApp.branch}"}
    DOCKERFILE = """FROM scratch
    COPY busybox /bin/busybox
    COPY www /www
    ENTRYPOINT ["/bin/busybox", "httpd", "-f", "-p", "${toString targetPort}", "-h", "/www"]
    """
    APPBUILD_DOCKER = "runuser -u appbuild -- env DOCKER_HOST=${nodes.vm-140.homelab.rootlessDocker.appbuild.dockerHost} docker"
    THROUGH_EDGE = "curl -s -m ${toString requestTimeoutS} --interface ${cloudflare} -H 'X-Forwarded-For: ${realClient}'"

    def commit(app, files, message, remove=()):
        """Commit to the app's branch on the forge; the new head."""
        work = f"${workRoot}/{app}"
        for path, text in files.items():
            world.succeed(f"mkdir -p $(dirname {work}/{path}) && cat > {work}/{path} <<'EOF'\n{text}EOF")
        for path in remove:
            world.succeed(f"rm -rf {work}/{path}")
        world.succeed(f"cd {work} && git add -A && git commit -q -m '{message}' && git push -q origin HEAD:{BRANCHES[app]}")
        return world.succeed(f"git -C {work} rev-parse HEAD").strip()

    def build(ok=True):
        """One run over every app; each app's state after it."""
        (vm_140.succeed if ok else vm_140.fail)("systemctl start app-builder")
        return {app: state(app) for app in REPOS}

    def state(app):
        return json.loads(vm_140.succeed(f"cat ${stateDir}/{app}.json"))

    def tags(app):
        out = vm_140.succeed(f"curl -sf -u ${pull.user}:$(cat /run/secrets/${pull.secret}) https://${registry}/v2/{app}/web/tags/list")
        return set(json.loads(out).get("tags") or [])

    def image(app, manager):
        return manager.succeed(f"docker service inspect {app}_web --format '{{{{.Spec.TaskTemplate.ContainerSpec.Image}}}}'").strip()

    def deploy_ok(app):
        return f'homelab_app_deploy_ok{{app="{app}"}} 1' in vm_140.succeed("cat ${stateDir}/metrics.prom")

    def serves(text, workers=("250", "251")):
        """hello on the shared swarm's routing mesh, as the edge reaches it."""
        for worker in workers:
            vm_200.wait_until_succeeds(f"curl -sf -m 5 http://{ADDRESSES[worker]}:${toString helloPort}/ | grep -qx '{text}'", timeout=240)

    def own_serves(text):
        """own on its guest, through the edge as a visitor reaches it."""
        world.wait_until_succeeds(f"{THROUGH_EDGE} --resolve own.${net.domain}:443:${edge} https://own.${net.domain}/ | grep -qx '{text}'", timeout=240)

    def redeploy(app, token):
        return world.succeed(f"{THROUGH_EDGE} -o /dev/null -w '%{{http_code}}' -X POST -H 'Authorization: Bearer {token}' "
                             f"--resolve ${deployHost}:443:${edge} https://${deployHost}${deployPath}/{app}").strip()

    start_all()
    vm_109.wait_for_unit("nfs-exports-reload.service")
    world.wait_for_unit("nginx.service")
    world.wait_for_unit("forge-api.service")

    with subtest("the forge holds the apps' repos, the clusters build themselves"):
        for app, repo in REPOS.items():
            world.succeed(f"git init -q --bare -b {BRANCHES[app]} ${gitRoot}/{repo} && git -C ${gitRoot}/{repo} config uploadpack.allowAnySHA1InWant true")
            world.succeed(f"git clone -q ${gitRoot}/{repo} ${workRoot}/{app} && git -C ${workRoot}/{app} config user.email t@t && git -C ${workRoot}/{app} config user.name t")
        world.succeed("mkdir -p ${workRoot}/hello/${context} && cp ${pkgs.pkgsStatic.busybox}/bin/busybox ${workRoot}/hello/${context}/busybox")
        world.succeed("cp ${pkgs.pkgsStatic.busybox}/bin/busybox ${workRoot}/own/busybox")
        vm_140.wait_for_unit("swarm-cluster.service")
        vm_140.wait_until_succeeds("[ $(docker node ls -q | wc -l) = 3 ]", timeout=240)
        vm_${placedId}.wait_until_succeeds("docker node ls --format '{{.ManagerStatus}}' | grep -qx Leader", timeout=240)
        vm_118.wait_for_unit("podman-registry.service")
        vm_100.wait_for_unit("traefik.service")
        vm_100.wait_for_open_port(443)
        vm_200.wait_for_unit("traefik.service")
        vm_140.wait_for_file("/run/user/${toString nodes.vm-140.homelab.rootlessDocker.appbuild.uid}/docker.sock", timeout=120)

    with subtest("a commit is built, parked by its content and deployed: locally on the shared swarm, over ssh on the guest"):
        sha_a = commit("hello", {"${context}/Dockerfile": DOCKERFILE, "${context}/www/index.html": "v1\n", "README.md": "hello\n"}, "v1")
        own_a = commit("own", {"Dockerfile": DOCKERFILE, "www/index.html": "own v1\n"}, "own v1")
        world.succeed("rm -f ${forgeLog}")
        states = build()
        assert states["hello"]["sha"] == sha_a and states["hello"]["failure"] is None, states
        assert states["own"]["sha"] == own_a and states["own"]["failure"] is None, states
        assert (states["hello"]["built"], states["hello"]["reused"]) == (1, 0), states["hello"]
        # only the app that watches a path asks the commits api, once per path
        api = world.succeed("cat ${forgeLog}")
        assert api.count("path=${watched}") == 1 and "${ownApp.repo}" not in api, api
        # tagged by content (lib/app-builder.py KEY_TAG_PREFIX), the live one `latest`
        for app in REPOS:
            assert "latest" in tags(app) and any(t.startswith("content-") for t in tags(app)), tags(app)
        for app, manager in (("hello", vm_140), ("own", vm_${placedId})):
            pinned = image(app, manager)
            assert pinned.startswith(f"${registry}/{app}/web@sha256:"), pinned
            manager.succeed(f"journalctl -t swarm-deploy | grep -q 'deploying {app}'")
        serves("v1")
        own_serves("own v1")
        assert deploy_ok("hello") and deploy_ok("own")

    with subtest("the published port answers the edge and the dashboard only"):
        world.succeed("curl -sf -m 5 --interface ${homepage} http://${workers."250"}:${toString helloPort}/")
        world.fail("curl -sf -m 5 --interface ${workstation} http://${workers."250"}:${toString helloPort}/")
        vm_140.fail("curl -sf -m 5 http://${workers."250"}:${toString helloPort}/")

    with subtest("a commit outside the watched path builds nothing"):
        before = tags("hello")
        sha_b = commit("hello", {"README.md": "hello again\n"}, "readme")
        hello_state = build()["hello"]
        assert hello_state["head"] == sha_b and hello_state["sha"] == sha_a, hello_state
        assert tags("hello") == before

    with subtest("a watched commit outside the build context reuses the image of the same content"):
        pinned = image("hello", vm_140)
        sha_n = commit("hello", {"${watched}/NOTES.md": "notes\n"}, "notes")
        hello_state = build()["hello"]
        assert hello_state["sha"] == sha_n and (hello_state["built"], hello_state["reused"]) == (0, 1), hello_state
        assert image("hello", vm_140) == pinned

    with subtest("a new commit rolls out start-first: no request fails during the update"):
        # the transient unit takes the shell's PATH (-E PATH): systemd's own holds no curl
        vm_200.succeed("systemd-run --unit poll -E PATH sh -c 'while true; do curl -s -m 2 -o /dev/null -w \"%{http_code}\\n\" "
                       "http://${workers."250"}:${toString helloPort}/; sleep 0.1; done > /tmp/poll'")
        sha_c = commit("hello", {"${context}/www/index.html": "v2\n"}, "v2")
        assert build()["hello"]["sha"] == sha_c
        serves("v2")
        vm_200.succeed("systemctl stop poll")
        codes = vm_200.succeed("cat /tmp/poll").split()
        assert codes and set(codes) == {"200"}, sorted(set(codes))

    def refused(files, why, remove=(), pushed=False):
        """A commit the builder or the manager must refuse: nothing deployed, the running version stays."""
        before = tags("hello")
        commit("hello", files, why, remove)
        hello_state = build(ok=False)["hello"]
        assert hello_state["sha"] == sha_c and hello_state["failure"] is not None, hello_state
        # the builder judges paths before it pushes; the manager judges policy after
        assert pushed or tags("hello") == before, tags("hello") - before
        assert not deploy_ok("hello")
        serves("v2")

    with subtest("a stack that reaches out of its checkout is refused before anything is pushed"):
        escapes = {
            "env_file a secret": "services:\n  web:\n    env_file: [/run/secrets/app-deploy-key]\n",
            "env_file through a symlink": "services:\n  web:\n    env_file: [leak]\n",
            "a build context above the repo": "services:\n  web: {}\n  evil:\n    build: {context: ../../../..}\n",
            "a dockerfile above the repo": "services:\n  web: {}\n  evil:\n    build: {context: ., dockerfile: ../../../etc/passwd}\n",
        }
        world.succeed("ln -sfn ${stateDir}/hello.json ${workRoot}/hello/leak")
        for i, (why, compose) in enumerate(escapes.items()):
            refused({"compose.yaml": compose, "${context}/www/index.html": f"escape {i}\n"}, why)
            # one refusal per case, each its own
            vm_140.succeed(f"[ $(journalctl -u app-builder | grep -c 'leaves the checkout') = {i + 1} ]")

    with subtest("the manager's policy refuses what the builder built"):
        refused({"compose.yaml": "services:\n  web: {privileged: true}\n", "${context}/www/index.html": "privileged\n"},
                "privileged", remove=("leak",), pushed=True)
        vm_140.succeed("journalctl -u swarm-deploy@hello | grep -q 'refused: web.privileged'")
        sha_c = commit("hello", {"${context}/www/index.html": "v2\n"}, "back to v2", remove=("compose.yaml",))
        assert build()["hello"]["sha"] == sha_c
        assert deploy_ok("hello")

    deploy = ("runuser -u appbuild -- ssh -i /run/secrets/app-deploy-key -o BatchMode=yes -o StrictHostKeyChecking=yes "
              "-o UserKnownHostsFile=${knownHosts} root@${guest}")
    with subtest("the deploy key does one thing: the guest's forced command, from the builder"):
        # the forced command reads its stack from stdin first: an empty one here
        out = vm_140.fail(f"{deploy} 'sh -c id' </dev/null 2>&1")
        assert "is no app name" in out, out
        vm_140.fail(f"{deploy} -W ${ip "109"}:2049 </dev/null")
        out = vm_140.fail(f"yes a | head -c 2097152 | {deploy} own 2>&1")
        assert "larger than" in out, out
        vm_140.copy_from_vm("/run/secrets/app-deploy-key", "")
        vm_100.copy_from_host(str(vm_140.out_dir / "app-deploy-key"), "/root/key")
        out = vm_100.fail("chmod 600 /root/key && ssh -i /root/key -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${guest} own </dev/null 2>&1")
        assert "Permission denied" in out, out

    with subtest("two deploys at once on the guest run one after the other"):
        # the stack the guest keeps is the last one the builder sent
        stack = vm_${placedId}.succeed("cat /var/lib/swarm-apply/own.yaml")
        vm_140.succeed(f"cat > /tmp/stack.yaml <<'EOF'\n{stack}EOF")
        since = vm_${placedId}.succeed("date +%s").strip()
        vm_140.succeed(f"({deploy} own < /tmp/stack.yaml > /tmp/d1 2>&1 & {deploy} own < /tmp/stack.yaml > /tmp/d2 2>&1; wait)")
        lines = vm_${placedId}.succeed(f"journalctl -t swarm-deploy -o cat --no-pager --since @{since}").splitlines()
        assert lines == ["deploying own", "own deployed", "deploying own", "own deployed"], lines

    with subtest("ci's redeploy through the edge: the right token only, once a minute, rebuilt from the registry's cache"):
        token = vm_140.succeed("cat /run/secrets/app-hello-redeploy-token").strip()
        assert redeploy("hello", "wrong") == "401"
        # a fresh builder: nothing local to build from, the registry holds the same content
        vm_140.succeed(f"{APPBUILD_DOCKER} image prune -af")
        since = vm_140.succeed("date +%s").strip()
        assert redeploy("hello", token) == "202"
        assert redeploy("hello", token) == "429"
        vm_140.wait_until_succeeds(f"journalctl -u app-builder@hello --since @{since} | grep -q 'hello: deployed .*: 0 built, 1 reused'", timeout=240)
        vm_140.fail(f"journalctl -u app-builder@hello --since @{since} | grep -q 'hello: building'")
        serves("v2")
        assert deploy_ok("hello")

    with subtest("the registry down: the deploy fails, the old version serves, the retry after the backoff lands"):
        vm_118.succeed("systemctl stop podman-registry")
        sha_d = commit("hello", {"${context}/www/index.html": "v3\n"}, "v3")
        hello_state = build(ok=False)["hello"]
        assert hello_state["sha"] == sha_c and hello_state["failure"]["sha"] == sha_d, hello_state
        serves("v2")
        vm_118.succeed("systemctl start podman-registry")
        vm_118.wait_for_open_port(5000)
        time.sleep(${toString backoff.maxS})  # the backoff is the claim: wall time is what the builder waits on
        assert build()["hello"]["sha"] == sha_d
        serves("v3")

    with subtest("the guest's manager partitioned: its app fails fast, the shared swarm's app lands, the retry lands"):
        vm_${placedId}.block()
        sha_e = commit("hello", {"${context}/www/index.html": "v4\n"}, "v4")
        own_b = commit("own", {"www/index.html": "own v2\n"}, "own v2")
        started = time.monotonic()
        states = build(ok=False)
        assert time.monotonic() - started < ${toString partitionRunMaxS}, "a dead manager stalled the builder"
        assert states["hello"]["sha"] == sha_e and states["hello"]["failure"] is None, states
        assert states["own"]["sha"] == own_a and states["own"]["failure"]["sha"] == own_b, states
        serves("v4")
        vm_${placedId}.unblock()
        time.sleep(${toString backoff.maxS})
        assert build()["own"]["sha"] == own_b
        own_serves("own v2")

    with subtest("the controller partitioned from its workers: the apps keep serving, the cluster heals"):
        vm_140.block()
        serves("v4")
        vm_140.unblock()
        vm_140.wait_until_succeeds("[ $(docker node ls --filter role=worker --format '{{.Status}}' | grep -c Ready) = 2 ]", timeout=240)

    with subtest("the worker running the task crashes: the task moves, the worker comes back"):
        nodes = vm_140.succeed("docker service ps hello_web --filter desired-state=running --format '{{.Node}}'").split()
        victim = RNG.choice(sorted(nodes)).removeprefix("vm-")
        survivor = "251" if victim == "250" else "250"
        WORKERS[victim].crash()
        serves("v4", workers=(survivor,))
        WORKERS[victim].start()
        WORKERS[victim].wait_for_unit("swarm-cluster.service")
        vm_140.wait_until_succeeds("[ $(docker node ls --filter role=worker --format '{{.Status}}' | grep -c Ready) = 2 ]", timeout=240)
        vm_140.succeed("[ $(docker node ls -q | wc -l) = 3 ]")

    with subtest("a worker that left rejoins, its old entry goes, the state label stays on the state worker"):
        vm_251.succeed("docker swarm leave --force && systemctl restart swarm-cluster")
        vm_140.wait_until_succeeds("journalctl -u swarm-reconcile | grep -q \"removing vm-251's stale entry\"", timeout=240)
        vm_140.wait_until_succeeds("[ $(docker node ls -q | wc -l) = 3 ]", timeout=240)
        vm_140.succeed("docker node inspect vm-250 --format '{{index .Spec.Labels \"homelab.state\"}}' | grep -qx true")
        vm_140.succeed("[ -z \"$(docker node inspect vm-251 --format '{{index .Spec.Labels \"homelab.state\"}}')\" ]")

    with subtest("an image whose task dies is rolled back by the swarm, and the builder says the deploy failed"):
        before = state("hello")
        sha_g = commit("hello", {"${context}/Dockerfile": DOCKERFILE.replace('"httpd"', '"false", "httpd"'), "${context}/www/index.html": "v5\n"}, "dies")
        hello_state = build(ok=False)["hello"]
        assert hello_state["sha"] == before["sha"] and hello_state["failure"]["sha"] == sha_g, hello_state
        assert not deploy_ok("hello")
        serves("v4")

    with subtest("the builder killed mid-build records nothing, the next run builds the same commit"):
        slow = DOCKERFILE.replace("COPY www /www", 'COPY www /www\nRUN ["/bin/busybox", "sleep", "20"]')
        sha_h = commit("hello", {"${context}/Dockerfile": slow, "${context}/www/index.html": "v6\n"}, "slow")
        since = vm_140.succeed("date +%s").strip()
        vm_140.succeed("systemctl start --no-block app-builder")
        vm_140.wait_until_succeeds(f"journalctl -u app-builder --since @{since} | grep -q 'hello: building web'", timeout=120)
        vm_140.succeed("systemctl kill app-builder")
        vm_140.wait_until_fails("systemctl is-active app-builder", timeout=60)
        assert state("hello")["sha"] == before["sha"]
        time.sleep(${toString backoff.maxS})
        assert build()["hello"]["sha"] == sha_h
        serves("v6")
        assert deploy_ok("hello")
  '';
}
