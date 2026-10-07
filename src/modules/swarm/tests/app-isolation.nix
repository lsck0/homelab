# one app driven to saturation does not take the lab down: the other app, the edge and the monitoring stack keep
# answering, and the noisy app meets its own limits, each one checked where it bites
#
# Two apps of one image on the real swarm (manager vm-140, workers vm-250 and vm-251, nas vm-109), behind the real
# edge (vm-200, offline crowdsec) and watched by the real collector (vm-105). `quiet` is the positive control of
# every subtest: it must answer, ship its lines, its spans and its profiles while `noisy` floods. Floods: cpu,
# memory, processes, requests, log lines, metric series, spans, profiles, browser beacons. Then the platform's own
# guarantees: admission against the app's reservation, capabilities, the workers' advertised capacity, and the
# boards and datasources each app gets. The seed picks the flood order and the flooding clients' addresses.
{ pkgs, lib, specialArgs, seed ? 7, ... }:
let
  lab = import ../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
  net = import ../../net.nix { inherit lib; inherit (specialArgs) inventory site; };
  telemetry = import ../../telemetry.nix { inherit lib; inherit (lab) inventory; };
  limits = import ../../limits { inherit lib; };
  # the builder's import of an app's own boards (140-internal-swarm)
  dashboardsImport = ../../../instances/140-internal-swarm/lib/dashboards-import.py;
  ip = id: lab.inventory.${id}.ip;

  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  workers = [ "250" "251" ];
  registryAddress = ip "100";
  collector = ip telemetry.collectorVmid;
  edge = ip "200";
  cloudflare = "104.16.0.10";
  ports = { quiet = 20140; noisy = 20150; };
  # each task: small enough that both apps and a rolling deploy fit two workers
  task = { memoryMiB = 256; cpus = 0.5; pids = 128; };
  # the quiet app's answers through the edge while the noisy one floods: every request, within this
  quietLatencyS = 2;
  floodS = 20;
  # no request of the test waits longer; one that would is an answer of its own (curl's 000)
  requestTimeoutS = 10;
  requestFlood = { count = 2000; concurrency = 64; };
  # the noisy app's spans: three times its burst, back to back, which no refill keeps up with
  spanFlood = rec { bytes = 600000; count = 3 * limits.tenant.traceBurstBytes / bytes; };
  # the noisy app's exporter: more series than one scrape may hold
  bigSeries = limits.tenant.scrapeSamples + 1000;

  www = pkgs.runCommand "fixture-www" { } ''
    mkdir -p $out/www
    echo app > $out/www/index.html
    printf 'fixture_up 1\n' > $out/www/metrics.txt
    for i in $(seq 1 ${toString bigSeries}); do echo "fixture_series{n=\"$i\"} 1"; done > $out/www/big.txt
  '';
  image = pkgs.dockerTools.buildLayeredImage {
    name = "fixture";
    tag = "v1";
    contents = [ pkgs.busybox pkgs.curl www ];
    config.Cmd = [ "httpd" "-f" "-p" "8000" "-h" "/www" ];
  };

  appOf = name: metricsPath: {
    enable = true;
    repo = "lsck0/${name}";
    branch = "master";
    # anubis is instances/200-external-traefik/tests/edge-apps.nix's subject; a flood here must reach the app's own limits, not a challenge
    routes.${name} = { port = ports.${name}; health = "/"; off = { sso = "the fixture is public"; anubis = "no browser here"; }; };
    metrics.web = { service = "web"; targetPort = 8000; port = ports.${name} + 1; path = metricsPath; };
    resources.web = task;
  };
  catalog = lab.appsCatalog // { apps = { quiet = appOf "quiet" "/metrics.txt"; noisy = appOf "noisy" "/big.txt"; }; };

  common = { lib, ... }: {
    homelab.appsCatalog = catalog;
    networking.hosts.${registryAddress} = [ "registry.lsck0.dev" ];
    environment.systemPackages = [ pkgs.curl pkgs.jq ];
  };
  swarmNode = vmid: memory: {
    imports = [ (lab.guest vmid { flat = true; nas = true; }) common ];
    virtualisation.memorySize = memory;
    virtualisation.diskSize = 6144;
  };
in
pkgs.testers.runNixOSTest {
  name = "app-isolation";

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
  nodes.vm-140 = swarmNode "140" 1536;
  # the production worker shape: its memory is what the worker advertises and caps
  nodes.vm-250 = swarmNode "250" 2560;
  nodes.vm-251 = swarmNode "251" 2560;
  nodes.vm-105 = {
    imports = [ (lab.guest telemetry.collectorVmid { flat = true; nas = true; instance = ../../../instances/105-internal-grafana/main.nix; }) common ];
    virtualisation.memorySize = 3072;
  };
  nodes.vm-200 = {
    imports = [ (lab.guest "200" { flat = true; instance = ../../../instances/200-external-traefik/main.nix; }) ../../../tests/lib/offline-traefik.nix common ];
    virtualisation.memorySize = 1536;
  };
  nodes.world = {
    imports = [ (lab.multi { addresses = [ "10.100.0.1/8" "10.200.0.1/8" "10.250.0.1/8" "${cloudflare}/13" ]; }) ];
    environment.systemPackages = [ pkgs.curl ];
  };

  testScript = ''
    import collections
    import json
    import os
    import random
    import shlex
    import tempfile
    import time

    SEED = ${toString seed}
    print(f"seed={SEED}")
    rng = random.Random(SEED)
    WORKERS = {"vm-250": vm_250, "vm-251": vm_251}
    TENANT = {app: "${telemetry.tenantOf "APP"}".replace("APP", app) for app in ("quiet", "noisy")}
    PROM = "http://127.0.0.1:${toString telemetry.ports.prometheusLocal}"
    LOKI = "http://127.0.0.1:${toString telemetry.ports.lokiLocal}"
    TEMPO = "http://127.0.0.1:${toString telemetry.ports.tempo}"
    GRAFANA = "curl -sf -H 'Remote-User: admin' http://127.0.0.1:${toString telemetry.ports.grafana}"
    SHIPPER = "curl -s http://127.0.0.1:${toString telemetry.ports.promtail}/metrics"

    def url(app, path="/"):
        return f"https://{app}.${net.domain}{path}"

    def edge_request(app, client, out, path="/"):
        """one request through the edge, as cloudflare relays a client; curl prints `out`"""
        return (f"curl -s -m ${toString requestTimeoutS} -o /dev/null -w '{out}' --interface ${cloudflare} "
                f"--resolve {app}.${net.domain}:443:${edge} -H 'X-Forwarded-For: {client}' {url(app, path)}")

    def through_edge(app, client, path="/"):
        """status and seconds of one request through the edge"""
        code, seconds = world.succeed(edge_request(app, client, "%{http_code} %{time_total}", path)).split()
        return int(code), float(seconds)

    def prom_has(query):
        """a shell test for wait_until: the instant query returns a series"""
        return f"curl -sfG {PROM}/api/v1/query --data-urlencode {shlex.quote('query=' + query)} | jq -e '.data.result | length >= 1'"

    def tempo_has(tenant, trace_id):
        """a shell command that fails until the tenant holds the trace, and prints it"""
        return f"curl -sf -H 'X-Scope-OrgID: {tenant}' {TEMPO}/api/traces/{trace_id}"

    def body_on(machine, body):
        """a request body as a file on the machine: no argument of a command line may exceed 128 KiB"""
        path = os.path.join(tempfile.mkdtemp(), "body.json")
        with open(path, "w") as f:
            f.write(body)
        machine.copy_from_host(path, "/tmp/body.json")
        return "/tmp/body.json"

    def quiet_answers(where):
        for i in range(5):
            code, seconds = through_edge("quiet", f"198.51.100.{i + 1}")
            assert code == 200 and seconds < ${toString quietLatencyS}, f"{where}: quiet answered {code} in {seconds}s"

    def monitoring_answers(where):
        for path in ("127.0.0.1:${toString telemetry.ports.prometheusLocal}/-/ready",
                     # loki's, tempo's and pyroscope's /ready wait on parts a single binary may never report; an answer to
                     # a read is what a dashboard needs
                     "${collector}:${toString telemetry.ports.loki}/loki/api/v1/labels",
                     "127.0.0.1:${toString telemetry.ports.tempo}/api/echo",
                     "127.0.0.1:${toString telemetry.ports.grafana}/api/health"):
            vm_105.succeed(f"curl -sf -m 10 http://{path} >/dev/null")
        vm_105.succeed("curl -sf -m 10 -X POST -H 'Content-Type: application/json' -H 'X-Scope-OrgID: " + TENANT["quiet"] + "' "
                       "-d '{}' http://127.0.0.1:${toString telemetry.ports.pyroscope}/querier.v1.QuerierService/LabelNames >/dev/null")

    def task_of(app):
        """the worker machine running the app's task and the container's id there; a task the swarm replaces after a
        flood (its health check failing at its limits) is waited for: the app recovers on its own"""
        running = f"docker service ps {app}_web --filter desired-state=running --format '{{{{.Node}}}} {{{{.CurrentState}}}}'"
        vm_140.wait_until_succeeds(f"{running} | grep -q ' Running'", timeout=120)
        node = vm_140.succeed(f"{running} | grep ' Running' | head -n1").split()[0]
        machine = WORKERS[node]
        task = f"docker ps -q --filter label=com.docker.swarm.service.name={app}_web --filter status=running"
        machine.wait_until_succeeds(f"[ -n \"$({task})\" ]", timeout=60)
        return machine, machine.succeed(f"{task} | head -n1").strip()

    def in_task(app, command):
        machine, cid = task_of(app)
        return machine.succeed(f"docker exec {cid} sh -c {shlex.quote(command)}")

    def cgroup_of(app):
        """the task's machine, container and cgroup directory, which lives under the apps slice"""
        machine, cid = task_of(app)
        pid = machine.succeed(f"docker inspect --format '{{{{.State.Pid}}}}' {cid}").strip()
        path = machine.succeed(f"cut -d: -f3 /proc/{pid}/cgroup").strip()
        assert path.startswith("/apps.slice/"), f"{app}'s task runs in {path}, outside the apps slice"
        return machine, cid, f"/sys/fs/cgroup{path}"

    def prom(query):
        out = vm_105.succeed(f"curl -sfG {PROM}/api/v1/query --data-urlencode {shlex.quote('query=' + query)}")
        return json.loads(out)["data"]["result"]

    def loki_count(app, filter_):
        query = 'sum(count_over_time({swarm_stack="' + app + '"} |= "' + filter_ + '" [10m]))'
        out = vm_105.succeed(f"curl -sfG -H 'X-Scope-OrgID: {TENANT[app]}' {LOKI}/loki/api/v1/query --data-urlencode {shlex.quote('query=' + query)}")
        result = json.loads(out)["data"]["result"]
        return int(float(result[0]["value"][1])) if result else 0

    def loki_has(app, text):
        """an instant count of the app's lines holding text, from its own tenant; a shell test for wait_until"""
        query = shlex.quote(f'query=sum(count_over_time({{swarm_stack="{app}"}} |= "{text}" [10m]))')
        return (f"[ $(curl -sfG -H 'X-Scope-OrgID: {TENANT[app]}' {LOKI}"
                f"/loki/api/v1/query --data-urlencode {query} | jq -r '.data.result[0].value[1] // 0') -ge 1 ]")

    def span(trace_id, service, extra=None):
        attributes = [{"key": k, "value": {"stringValue": v}} for k, v in (extra or {}).items()]
        now = time.time_ns()
        return json.dumps({"resourceSpans": [{"resource": {"attributes": [{"key": "service.name", "value": {"stringValue": service}}]},
                           "scopeSpans": [{"spans": [{"traceId": trace_id, "spanId": rng.randbytes(8).hex(), "name": service,
                                                      "kind": 3, "startTimeUnixNano": str(now - 10**6), "endTimeUnixNano": str(now),
                                                      "attributes": attributes}]}]}]})

    def push_spans(app, body, count):
        """the body count times back to back from inside the app's task, with the tenant header render injected;
        the http statuses"""
        machine, cid = task_of(app)
        curl = ("curl -s -m ${toString requestTimeoutS} -o /dev/null -w '%{http_code}\\n' -X POST -H 'Content-Type: application/json' "
                "-H \"''${OTEL_EXPORTER_OTLP_HEADERS%%=*}: ''${OTEL_EXPORTER_OTLP_HEADERS#*=}\" "
                "--data-binary @- http://${collector}:${toString telemetry.ports.otlpHttp}/v1/traces")
        command = f'body=$(cat); for i in $(seq {count}); do printf %s "$body" | {curl}; done'
        out = machine.succeed(f"docker exec -i {cid} sh -c {shlex.quote(command)} < {body_on(machine, body)}")
        return [int(code) for code in out.split()]

    def push_span(app, body):
        return push_spans(app, body, 1)[0]

    def push_profile(app, size):
        """a folded profile of about size bytes from inside the app's task, every stack its own; the http status"""
        # pyroscope merges equal stacks before it counts bytes, so each line names its own long function; whole lines,
        # since pyroscope refuses a truncated last one, and they stream in: the image has no writable /tmp
        pad = "x" * 256
        lines = max(1, size // (len(pad) + 16))
        command = (f"now=$(date +%s); seq 1 {lines} | sed 's/.*/f&_{pad};g& 1/' | "
                   "curl -s -m ${toString requestTimeoutS} -o /dev/null -w '%{http_code}' -X POST --data-binary @- "
                   "-H \"X-Scope-OrgID: ''${OTEL_EXPORTER_OTLP_HEADERS#*=}\" "
                   f"\"http://${collector}:${toString telemetry.ports.pyroscope}/ingest?name={app}.cpu&from=$((now-10))&until=$now&format=folded\"")
        return int(in_task(app, command))


    start_all()
    vm_109.wait_for_unit("nfs-exports-reload.service")
    registry.wait_for_open_port(443)
    vm_140.wait_until_succeeds("[ $(docker node ls -q | wc -l) = 3 ]", timeout=300)
    vm_200.wait_for_unit("traefik.service")
    vm_105.wait_for_unit("grafana.service")

    with subtest("each worker advertises what it holds for apps, and caps its containers to it"):
        for name, machine in WORKERS.items():
            vm_140.wait_until_succeeds(f"docker node inspect {name} --format '{{{{.Status.State}}}}' | grep -qx ready", timeout=240)
            resources = vm_140.succeed(f"docker node inspect {name} --format '{{{{json .Description.Resources.GenericResources}}}}'")
            assert '"HOMELAB_MEMORY_MIB","Value":2048' in resources.replace(" ", ""), resources
            assert machine.succeed("systemctl show -p MemoryMax --value apps.slice").strip() == str(2048 * 1024 * 1024)

    with subtest("both apps deploy within their reservations; a stack beyond its reservation is refused"):
        vm_140.succeed("docker load -i ${image}")
        for app in ("quiet", "noisy"):
            ref = f"registry.lsck0.dev/{app}/web"
            vm_140.succeed(f"docker tag fixture:v1 {ref}:v1 && docker push -q {ref}:v1")
            digest = vm_140.succeed(f"docker image inspect --format '{{{{range .RepoDigests}}}}{{{{println .}}}}{{{{end}}}}' {ref}:v1 | grep -F {ref}@").strip()
            web = {"image": digest, "healthcheck": {"test": ["CMD", "curl", "-f", "http://localhost:8000/"], "interval": "2s"}}
            vm_140.succeed(f"echo {shlex.quote(json.dumps({'services': {'web': web}}))} > /tmp/{app}.json")
            # five tasks of ${toString task.memoryMiB} MiB are more than the default reservation holds
            big = dict(web, deploy={"replicas": 5})
            vm_140.succeed(f"echo {shlex.quote(json.dumps({'services': {'web': big}}))} > /tmp/{app}-big.json")
        refusal = vm_140.fail("swarm-apply noisy < /tmp/noisy-big.json 2>&1")
        assert "reservation.memoryMiB" in refusal, refusal
        for app in ("quiet", "noisy"):
            vm_140.succeed(f"swarm-apply {app} < /tmp/{app}.json")
        world.wait_until_succeeds(f"[ \"$({edge_request('quiet', '198.51.100.1', '%{http_code}')})\" = 200 ]", timeout=240)
        quiet_answers("deployed")

    with subtest("every capability is dropped and the tenant is injected"):
        assert in_task("noisy", "grep CapEff /proc/1/status").split()[1] == "0000000000000000"
        assert in_task("quiet", "echo $OTEL_EXPORTER_OTLP_HEADERS").strip() == f"X-Scope-OrgID={TENANT['quiet']}"

    with subtest("positive controls: both apps' metrics, lines, spans and profiles arrive"):
        vm_105.wait_until_succeeds(prom_has('up{job="app-quiet-web"} == 1'), timeout=180)
        traces = {}
        for app in ("quiet", "noisy"):
            in_task(app, f"echo control-{app} > /proc/1/fd/1")
            vm_105.wait_until_succeeds(loki_has(app, f"control-{app}"), timeout=120)
            traces[app] = rng.randbytes(16).hex()
            assert push_span(app, span(traces[app], app)) == 200
            vm_105.wait_until_succeeds(tempo_has(TENANT[app], traces[app]), timeout=120)
            assert push_profile(app, 64) == 200
        # one tenant cannot read another's
        vm_105.fail(tempo_has(TENANT["noisy"], traces["quiet"]))

    def flood_cpu():
        machine, cid, cgroup = cgroup_of("noisy")
        throttled = f"awk '/nr_throttled/ {{print $2}}' {cgroup}/cpu.stat"
        before = int(machine.succeed(throttled))
        machine.succeed(f"docker exec -d {cid} sh -c 'for i in 1 2 3 4; do timeout ${toString floodS} yes > /dev/null & done; wait'")
        machine.succeed(f"docker exec {cid} pgrep yes")
        # quiet is asked while noisy is held at its cpu limit
        machine.wait_until_succeeds(f"[ $({throttled}) -gt {before} ]", timeout=${toString floodS})
        quiet_answers("cpu flood")
        machine.succeed("timeout 10 docker info >/dev/null")

    def flood_memory():
        machine, cid, cgroup = cgroup_of("noisy")
        machine.execute(f"docker exec {cid} sh -c 'head -c 400m /dev/zero | tail' >/dev/null 2>&1")
        quiet_answers("memory flood")
        kills = int(machine.succeed(f"awk '/oom_kill / {{print $2}}' {cgroup}/memory.events"))
        assert kills >= 1, "noisy's own memory limit killed nothing"
        machine.succeed("timeout 10 docker info >/dev/null")

    def flood_pids():
        machine, cid, cgroup = cgroup_of("noisy")
        before = int(machine.succeed(f"cat {cgroup}/pids.current"))
        machine.execute(f"docker exec {cid} sh -c 'for i in $(seq 1 1000); do sleep ${toString floodS} & done; wait' >/dev/null 2>&1")
        assert int(machine.succeed(f"awk '/max/ {{print $2}}' {cgroup}/pids.events")) >= 1, "noisy was never held at its pids limit"
        # the node itself still starts processes
        machine.succeed("timeout 10 sh -c 'for i in 1 2 3; do true & done; wait'")
        quiet_answers("process flood")
        # noisy recovers on its own: its sleepers end, or the swarm replaces the task its health check gave up on
        machine.wait_until_succeeds(f"[ ! -e {cgroup}/pids.current ] || [ $(cat {cgroup}/pids.current) -le {before} ]",
                                    timeout=${toString floodS} * 3)
        world.wait_until_succeeds(f"curl -sf -m 10 -o /dev/null --interface ${cloudflare} --resolve noisy.${net.domain}:443:${edge} "
                                  f"-H 'X-Forwarded-For: 198.51.100.9' {url('noisy')}", timeout=${toString floodS} * 6)

    def flood_requests():
        """one curl, many connections: many clients, each under its own per-client limit, so only the route's budget
        for all of them together can refuse, and what it admits stays within that budget"""
        clients = [f"203.0.113.{rng.randrange(1, 255)}" for _ in range(32)]
        block = ('url = "{url}"\nresolve = "noisy.${net.domain}:443:${edge}"\ninterface = "${cloudflare}"\n'
                 'max-time = ${toString requestTimeoutS}\noutput = "/dev/null"\nwrite-out = "%{{http_code}}\\n"\n'
                 'header = "X-Forwarded-For: {client}"\n')
        config = "next\n".join(block.format(url=url("noisy"), client=rng.choice(clients)) for _ in range(${toString requestFlood.count}))
        world.succeed("rm -f /tmp/codes")
        start = time.time()
        world.succeed(f"(curl -s -Z --parallel-max ${toString requestFlood.concurrency} -K {body_on(world, config)} > /tmp/codes) >/dev/null 2>&1 &")
        world.wait_until_succeeds("[ -s /tmp/codes ]", timeout=60)
        quiet_answers("request flood")
        world.wait_until_succeeds("[ $(wc -l < /tmp/codes) -ge ${toString requestFlood.count} ]", timeout=300)
        elapsed = time.time() - start
        codes = collections.Counter(world.succeed("cat /tmp/codes").split())
        admitted = codes["200"]
        budget = ${toString limits.route.burst} + ${toString limits.route.average} * elapsed
        assert codes["429"] > 0, f"the route's budget never refused the flood: {codes}"
        assert admitted <= budget, f"the route admitted {admitted} in {elapsed:.0f}s, its budget is {budget:.0f}: {codes}"
        monitoring_answers("request flood")

    def flood_logs():
        machine, cid = task_of("noisy")
        start = time.time()
        machine.succeed(f"docker exec -d {cid} sh -c 'timeout ${toString floodS} yes noisy-flood > /proc/1/fd/1'")
        machine.succeed(f"docker exec {cid} pgrep yes")
        # while noisy floods, quiet's line arrives
        marker = f"marker-{rng.randrange(10**9)}"
        in_task("quiet", f"echo {marker} > /proc/1/fd/1")
        vm_105.wait_until_succeeds(loki_has("quiet", marker), timeout=60)
        # noisy's lines arrive too, never faster than its budget
        try:
            vm_105.wait_until_succeeds(loki_has("noisy", "noisy-flood"), timeout=180)
        except Exception:
            print(machine.succeed(f"{SHIPPER} | grep -E '^(logentry|promtail_(read|sent|dropped|request|batch|stream|targets|docker))'"))
            print(machine.succeed(f"docker logs --tail 3 {cid} 2>&1; journalctl -u promtail --no-pager | tail -30"))
            raise
        machine.wait_until_fails(f"docker exec {cid} pgrep yes", timeout=${toString floodS} * 3)
        bound = ${toString limits.tenant.logLinesPerSecond} * (time.time() - start) + ${toString limits.tenant.logBurstLines}
        shipped = loki_count("noisy", "noisy-flood")
        shipper = machine.succeed(f"{SHIPPER} | grep -E '^(logentry_dropped|promtail_(read|sent|dropped))'")
        assert 0 < shipped <= bound, f"noisy shipped {shipped} lines, its budget allows {bound:.0f}; shipper: {shipper}"
        assert "noisy" in shipper and "logentry_dropped_lines_by_label_total" in shipper, f"the shipper counted no drop for noisy: {shipper}"
        monitoring_answers("log flood")

    def flood_metrics():
        # noisy's exporter answers more series than its budget, so its own scrape fails on the limit (a task the swarm
        # is replacing refuses connections first: the scrape after it meets the limit again)
        targets = f"curl -sf {PROM}/api/v1/targets?state=active"
        vm_105.wait_until_succeeds(f"{targets} | jq -e '.data.activeTargets[] | select(.labels.job == \"app-noisy-web\")"
                                   " | .lastError | contains(\"sample limit\")'", timeout=120)
        assert prom('up{job="app-quiet-web"}')[0]["value"][1] == "1"
        quiet_error = vm_105.succeed(f"{targets} | jq -r '.data.activeTargets[] | select(.labels.job == \"app-quiet-web\") | .lastError'")
        assert not quiet_error.strip(), quiet_error
        assert not prom("fixture_series"), "the oversized scrape reached the tsdb"

    def flood_spans():
        big = span(rng.randbytes(16).hex(), "noisy", {"pad": "x" * ${toString spanFlood.bytes}})
        codes = push_spans("noisy", big, ${toString spanFlood.count})
        assert 429 in codes, f"noisy's spans met no budget: {codes}"
        trace_id = rng.randbytes(16).hex()
        assert push_span("quiet", span(trace_id, "quiet")) == 200
        vm_105.wait_until_succeeds(tempo_has(TENANT["quiet"], trace_id), timeout=120)

    def flood_profiles():
        codes = [push_profile("noisy", 3 * 1024 * 1024) for _ in range(6)]
        assert 429 in codes, f"noisy's profiles met no budget: {codes}"
        assert push_profile("quiet", 64) == 200

    def flood_frontend():
        """browser beacons as the edge relays them: allow-listed, each app in its own tenant, one trace with the backend"""
        trace_id = rng.randbytes(16).hex()
        beacon = span(trace_id, "quiet-browser", {"url.path": "/", "url.full": "https://quiet/?token=secret-query",
                                                    "http.request.header.cookie": "session=secret-cookie"})
        intake = "http://${collector}:${toString telemetry.ports.otlpFrontend}${telemetry.frontendPath}/v1/traces"

        def send(tenant, body):
            return int(vm_200.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' -X POST -H 'Content-Type: application/json' "
                                      f"-H 'X-Scope-OrgID: {tenant}' --data-binary @{body_on(vm_200, body)} {intake}"))

        assert send(TENANT["quiet"], beacon) == 200
        assert push_span("quiet", span(trace_id, "quiet")) == 200
        vm_105.wait_until_succeeds(f"{tempo_has(TENANT['quiet'], trace_id)} | grep -q quiet-browser", timeout=120)
        trace = vm_105.succeed(tempo_has(TENANT["quiet"], trace_id))
        assert "secret" not in trace and '"quiet"' in trace, trace
        world.fail(f"curl -sf -m 5 -X POST {intake}")
        # the intake accepts and batches; noisy's tenant refuses what is over its budget, quiet's beacon still lands
        big = span(rng.randbytes(16).hex(), "noisy-browser", {"url.path": "x" * 400000})
        for _ in range(12):
            send(TENANT["noisy"], big)
        late = rng.randbytes(16).hex()
        assert send(TENANT["quiet"], span(late, "quiet-browser")) == 200
        vm_105.wait_until_succeeds(tempo_has(TENANT["quiet"], late), timeout=120)
        vm_105.wait_until_succeeds(prom_has(f'sum(tempo_discarded_spans_total{{tenant="{TENANT["noisy"]}"}}) > 0'), timeout=180)

    floods = [flood_cpu, flood_memory, flood_pids, flood_requests, flood_logs, flood_metrics, flood_spans, flood_profiles, flood_frontend]
    rng.shuffle(floods)
    for flood in floods:
        with subtest(f"{flood.__name__}: noisy meets its own limit, quiet, the edge and the monitoring keep answering"):
            flood()
            quiet_answers(flood.__name__)
            monitoring_answers(flood.__name__)

    with subtest("each app has its board in its own folder, reading its own datasources, and the overview lists both"):
        boards = json.loads(vm_105.succeed(f"{GRAFANA}/api/search?type=dash-db"))
        by_uid = {b["uid"]: b for b in boards}
        for app in ("quiet", "noisy"):
            assert by_uid[f"service-{app}"]["folderTitle"] == app, by_uid
        assert "services" in by_uid
        sources = json.loads(vm_105.succeed(f"{GRAFANA}/api/datasources"))
        uids = {s["uid"] for s in sources}
        assert {"loki-quiet", "tempo-quiet", "pyroscope-quiet", "loki-noisy"} <= uids, uids
        assert not {"tempo", "pyroscope"} & uids, uids

    with subtest("an app's own dashboard lands in its folder, rewritten to its own datasources"):
        repo = "/tmp/quiet-repo"
        board = json.dumps({"uid": "own", "title": "Own", "panels": [{"type": "logs", "datasource": {"type": "loki", "uid": "loki-noisy"}}]})
        vm_140.succeed(f"mkdir -p {repo}/dash && echo {shlex.quote(board)} > {repo}/dash/own.json")
        share = "/var/lib/app-dashboards/${telemetry.appDashboardsDir}"
        vm_140.succeed(f"${pkgs.python3}/bin/python3 ${dashboardsImport} quiet {repo} {share} 'dash/*.json'")
        landed = '.meta.folderTitle == "quiet" and .dashboard.panels[0].datasource.uid == "loki-quiet"'
        vm_105.wait_until_succeeds(f"{GRAFANA}/api/dashboards/uid/quiet-own | jq -e {shlex.quote(landed)}", timeout=180)
  '';
}
