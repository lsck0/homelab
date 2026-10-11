# the edge (200-external-traefik.nix) in front of the swarm apps and the internal ingress (100), both real, with the
# crowdsec stand-in: anubis, the metrics block, body limits, methods, compression, security headers, the client-header
# strip, cloudflare-only, the real client behind cloudflare, rate limits, health-checked balancing, the relays, the
# bot defences and crowdsec's bans and waf
#
# The fixture is the real `wat` app (src/apps/wat), enabled for this test (every edge feature: anubis on /, a direct
# /api with its metrics on the same port, an upload path without the waf and a 100 MiB limit, an internal route).
# Its reservation here needs three swarm workers (modules/limits workerCountOf); `appnodes` serves its ports on
# two of their addresses (the third is absent: the health check must drop it), the terminal's feed (vm-104) and authelia's forwardauth (vm-101, lib/authelia_stub.py: no session
# here, every gated host is sent to the portal); `world` owns the flat lab's gateways and the outside clients.
{ pkgs, lib, specialArgs, ... }:
let
  lab = import ../../../tests/lib/lab.nix {
    inherit pkgs lib specialArgs;
    # its reservation needs three workers beside hello's (modules/limits workerCountOf)
    apps = apps: lib.recursiveUpdate apps { wat = { enable = true; reservation.memoryMiB = 1024; }; };
  };
  net = import ../../../modules/net.nix { inherit lib; inherit (specialArgs) inventory site; };
  ip = id: lab.inventory.${id}.ip;
  # the internal routes (the instances') the edge relays, and the fixture app as src/apps/wat states it
  internalRoutes = lab.routes.internal;
  wat = assert lib.assertMsg (lib.length lab.appsCatalog.swarm.workers == 3) "edge-apps: the fixture needs three workers";
    lab.appsCatalog.apps.wat;
  # an app's routes answer at its name unless a route names another host (modules/apps-catalog)
  watHost = "wat";
  echoBackend = pkgs.writers.writePython3Bin "echo-backend" { flakeIgnore = [ "E501" ]; } (builtins.readFile ../../../tests/lib/echo_backend.py);
  autheliaStub = pkgs.writers.writePython3Bin "authelia-stub" { flakeIgnore = [ "E501" ]; } (builtins.readFile ../../../tests/lib/authelia_stub.py);
  authelia = internalRoutes.authelia;

  appPorts = lib.unique (map (p: p.port) (lib.attrValues wat.routes ++ lib.attrValues wat.metrics));
  feed = internalRoutes.calendar;
  outside = { internet = "198.51.100.7"; cloudflare = "104.16.0.10"; lan = net.wan.workstation; };
  realClient = "203.0.113.9";
  bannedClient = "203.0.113.66";
  bodyLimit = 1024 * 1024;
  uploadLimit = wat.routes.wat-user-files.bodyLimitBytes;
  # a few seconds per transfer, long enough to look at /tmp while it runs
  transferRate = "1M";

  guest = vmid: instance: memory: {
    imports = [ (lab.guest vmid { flat = true; inherit instance; }) ../../../tests/lib/offline-traefik.nix ];
    virtualisation.memorySize = memory;
  };
in
pkgs.testers.runNixOSTest {
  name = "edge-apps";
  node.specialArgs = lab.specialArgs;

  nodes.vm-200 = guest "200" ../main.nix 1536;
  nodes.vm-100 = guest "100" ../../100-internal-traefik/main.nix 1024;
  nodes.appnodes = {
    imports = [ (lab.multi { addresses = map (a: "${a}/8") [ (ip "250") (ip "251") (ip "104") (ip "101") ]; }) ];
    systemd.services.echo-backend = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${echoBackend}/bin/echo-backend --ports ${lib.concatMapStringsSep "," toString (appPorts ++ [ feed.port ])} --log /run/echo/requests.jsonl";
    };
    systemd.services.authelia-stub = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${autheliaStub}/bin/authelia-stub --port ${toString authelia.port} --portal ${net.fqdn authelia.host} --session authelia_session=never-issued --log-dir /run";
    };
  };
  nodes.world = {
    imports = [ (lab.multi { addresses = [ "10.100.0.1/8" "10.200.0.1/8" "10.250.0.1/8" "${outside.internet}/24" "${outside.cloudflare}/13" "${outside.lan}/24" ]; }) ];
    environment.systemPackages = [ pkgs.curl pkgs.python3 ];
  };

  testScript = { nodes, ... }: let
    # past this a buffered body spills to a temp-multibuf file in traefik's /tmp
    spillBytes = (lib.findFirst (m: m ? buffering) null
      (lib.attrValues nodes.vm-200.services.traefik.dynamicConfigOptions.http.middlewares)).buffering.memRequestBodyBytes;
  in lab.driverPython + ''

    EDGE, INTERNAL = "${ip "200"}", "${ip "100"}"
    CF, NET, LAN = "${outside.cloudflare}", "${outside.internet}", "${outside.lan}"
    WAT = "https://${net.fqdn watHost}"
    API_PORT = ${toString wat.routes.wat-api.port}

    def get(path, src=CF, host=WAT, address=EDGE, method="GET", headers=None, xff="${realClient}"):
        h = dict(headers or {})
        if src == CF and xff:
            h.setdefault("X-Forwarded-For", xff)
        return http_request(world, host + path, address=address, src=src, method=method, headers=h)

    # the requests the edge proxied; its own health checks name no forwarded client
    def backend_log():
        entries = [json.loads(l) for l in appnodes.succeed("cat /run/echo/requests.jsonl").splitlines() if l]
        return [e for e in entries if "x-forwarded-for" in e["headers"]]

    def backend_reset():
        appnodes.succeed(": > /run/echo/requests.jsonl")

    def upload(path, size, chunked=False):
        world.succeed(f"head -c {size} /dev/zero > /tmp/upload")
        extra = "-H 'Transfer-Encoding: chunked'" if chunked else ""
        return int(world.succeed(
            f"curl -s -o /dev/null -w '%{{http_code}}' --interface {CF} --resolve ${watHost}.${net.domain}:443:{EDGE} "
            f"-H 'X-Forwarded-For: ${realClient}' {extra} --data-binary @/tmp/upload {WAT}{path}"))

    start_all()
    for machine in (vm_200, vm_100):
        machine.wait_for_unit("traefik.service")
        machine.wait_for_open_port(443)
        machine.wait_for_file("/var/lib/crowdsec/data/stub-ready")
    appnodes.wait_for_file("/run/echo/requests.jsonl.ready")
    appnodes.wait_for_open_port(${toString authelia.port})
    # the health check drops the absent third worker before the first request counts
    world.wait_until_succeeds(f"[ $(curl -s -o /dev/null -w '%{{http_code}}' --interface {CF} -H 'X-Forwarded-For: ${realClient}' "
                              f"--resolve ${watHost}.${net.domain}:443:{EDGE} {WAT}/api/health) = 200 ]", timeout=120)

    with subtest("anubis challenges a browser on / and lets apis and uploads through"):
        backend_reset()
        r = get("/", headers={"User-Agent": "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"})
        assert r["status"] == 200 and "within.website" in r["body"], r["status"]
        assert not [e for e in backend_log() if e["path"] == "/"], "the challenge page reached the app"
        r = get("/api/health")
        assert r["status"] == 200 and json.loads(r["body"])["port"] == API_PORT, r
        r = get("/user-files/x")
        assert r["status"] == 200 and json.loads(r["body"])["port"] == ${toString wat.routes.wat-user-files.port}, r

    with subtest("the app's metrics never leave, however the path is spelled"):
        backend_reset()
        for path in ("/api/metrics", "/api/metrics/", "/api/metrics/x", "/api/metrics?format=prometheus", "/api//metrics",
                     "//api/metrics", "/api/./metrics", "/api/x/../metrics", "/api/%6detrics", "/API/Metrics", "/api/METRICS"):
            r = get(path)
            assert r["status"] >= 400, f"{path}: {r['status']}"
        assert not [e for e in backend_log() if "etrics" in e["path"].lower()], backend_log()
        # positive control: a sibling path is the app's
        assert get("/api/metricsx")["status"] == 200

    with subtest("bodies are limited where the app's catalog says"):
        backend_reset()
        assert upload("/api/upload", ${toString bodyLimit}) == 200
        assert upload("/api/upload", ${toString (bodyLimit + 1)}) == 413
        assert upload("/api/upload", ${toString (bodyLimit + 1)}, chunked=True) == 413
        assert upload("/user-files/u", ${toString uploadLimit}) == 200
        assert upload("/user-files/u", ${toString (uploadLimit + 1)}) == 413
        proxied = backend_log()
        sizes = sorted(e["body_len"] for e in proxied)
        assert sizes == [${toString bodyLimit}, ${toString uploadLimit}], [(e["method"], e["path"], e["body_len"]) for e in proxied]

    with subtest("a download streams past the body limit's buffer, a body method's answer spools to /tmp"):
        spooled = "find /tmp -type f -name 'temp-multibuf-*' | grep -q ."

        def transfer_start(name, args):
            world.succeed(f"rm -f /tmp/{name}.status; (curl -s -o /tmp/{name} -w '%{{http_code}} %{{size_download}}' "
                          f"--limit-rate ${transferRate} --interface {CF} --resolve ${watHost}.${net.domain}:443:{EDGE} "
                          f"-H 'X-Forwarded-For: ${realClient}' {args} > /tmp/{name}.part; mv /tmp/{name}.part /tmp/{name}.status) "
                          ">/dev/null 2>&1 &")

        def transfer_wait(name):
            world.wait_until_succeeds(f"[ -s /tmp/{name}.status ]", timeout=60)
            return world.succeed(f"cat /tmp/{name}.status").split()

        # positive control: the buffer spools a POST's answer past its memory to a named file while it streams (a
        # request body it spools to a file it unlinks at once, which no name shows)
        transfer_start("posted", f"-X POST --data-binary x {WAT}/api/blob")
        vm_200.wait_until_succeeds(spooled, timeout=30)
        assert transfer_wait("posted")[0] == "200"
        vm_200.wait_until_fails(spooled, timeout=30)
        transfer_start("blob", f"{WAT}/api/blob")
        world.wait_until_succeeds("[ $(stat -c %s /tmp/blob 2>/dev/null || echo 0) -gt ${toString spillBytes} ]", timeout=30)
        vm_200.fail(spooled)
        status, size = transfer_wait("blob")
        assert status == "200" and int(size) > ${toString spillBytes}, (status, size)
        vm_200.fail(spooled)

    with subtest("methods a browser app does not use reach nothing, not even the internal ingress"):
        backend_reset()
        vm_100.succeed(": > /var/log/traefik/access.log")
        for method in ("TRACE", "PROPFIND", "MKCOL", "LOCK", "FOO"):
            for path in ("/", "/api/x"):
                r = get(path, method=method)
                assert r["status"] >= 400, f"{method} {path}: {r['status']}"
        assert backend_log() == [], backend_log()
        vm_100.fail("grep -q PROPFIND /var/log/traefik/access.log")

    with subtest("compression for browsers, security headers on every answer"):
        r = get("/api/big", headers={"Accept-Encoding": "gzip"})
        assert r["headers"].get("content-encoding") == "gzip", r["headers"]
        for path, status in (("/api/health", 200), ("/api/metrics", 403)):
            r = get(path)
            assert r["status"] == status, r
            for header, value in (("strict-transport-security", "max-age=31536000; includeSubDomains; preload"),
                                  ("x-content-type-options", "nosniff"), ("x-frame-options", "DENY")):
                assert r["headers"].get(header) == value, f"{path} {header}: {r['headers'].get(header)}"

    with subtest("client-sent identity and target headers never reach the app"):
        r = get("/api/x", headers={"Remote-User": "admin", "Remote-Groups": "admins", "X-Forwarded-Host": "auth.${net.domain}"})
        seen = json.loads(r["body"])["headers"]
        # the strip drops the forged target; a route without the anubis hop gets none back, the host header says it
        assert "remote-user" not in seen and "remote-groups" not in seen, seen
        assert seen["host"] == seen.get("x-forwarded-host", seen["host"]) == "${watHost}.${net.domain}", seen

    with subtest("a proxied host answers cloudflare and the house, not the internet directly"):
        assert get("/api/health", src=NET)["status"] == 403
        assert get("/api/health", src=NET, headers={"X-Forwarded-For": "${realClient}"})["status"] == 403
        assert get("/api/health", src=LAN)["status"] == 200
        assert get("/api/health")["status"] == 200

    with subtest("the app sees the client cloudflare saw, never a forged one"):
        # straight and through anubis's hop: X-Forwarded-For is the client alone, what a backend trusting its ingress reads
        for path in ("/api/x", "/page"):
            r = get(path, headers={"X-Real-Ip": "6.6.6.6", "X-Forwarded-For": "1.2.3.4, ${realClient}"}, xff=None)
            seen = json.loads(r["body"])["headers"]
            assert seen.get("x-real-ip") == seen.get("x-forwarded-for") == "${realClient}", (path, seen)

    with subtest("the rate limit counts per client behind cloudflare"):
        # 20 connections of 20 requests each: one tls handshake per connection keeps the flood above the limit's
        # average on a loaded host, where 400 handshakes took 11 s; each connection forges another X-Real-Ip
        codes = world.succeed(
            "mkdir -p /tmp/flood && seq 20 | xargs -P 20 -I@ curl -s -o '/tmp/flood/@-#1' -w '%{http_code}\\n' "
            f"--interface {CF} --resolve ${watHost}.${net.domain}:443:{EDGE} -H 'X-Forwarded-For: 203.0.113.10' "
            f"-H 'X-Real-Ip: 10.9.0.@' '{WAT}/api/health?[1-20]'").split()
        assert "429" in codes, sorted(set(codes))
        assert get("/api/health", xff="203.0.113.11")["status"] == 200

    with subtest("a stopped node leaves the rotation"):
        appnodes.succeed("echo ${ip "250"}:${toString wat.routes.wat-api.port} > /run/echo/stopped")
        world.wait_until_succeeds(
            f"for i in $(seq 20); do curl -sf --interface {CF} -H 'X-Forwarded-For: 203.0.113.12' --resolve ${watHost}.${net.domain}:443:{EDGE} "
            f"{WAT}/api/health | grep -q '\"${ip "251"}\"' || exit 1; done", timeout=60)
        appnodes.succeed("rm /run/echo/stopped")

    with subtest("internal hosts are relayed under their own names, token-only ones to private sources only"):
        r = get("/", host="https://${net.fqdn internalRoutes.grafana.host}")
        assert r["status"] == 302 and "auth.${net.domain}" in r["headers"].get("location", ""), r
        for host in ${builtins.toJSON (map (name: "https://${net.fqdn internalRoutes.${name}.host}") [ "attic" "registry-api" ])}:
            assert get("/", host=host)["status"] == 403
            assert get("/", host=host, src=NET)["status"] == 403
            # positive control: the house is relayed
            assert get("/", host=host, src=LAN)["status"] != 403
        r = get("/", host="https://${net.fqdn feed.host}", src=NET)
        assert r["status"] == 200 and json.loads(r["body"])["node"] == "${ip "104"}", r
        vm_100.succeed(": > /var/log/traefik/access.log")
        assert get("/", host="https://unknown.${net.domain}")["status"] == 404
        vm_100.fail("grep -q unknown /var/log/traefik/access.log")

    with subtest("robots.txt everywhere, the labyrinth for crawlers and honeypot paths"):
        backend_reset()
        r = get("/robots.txt")
        assert "User-agent: GPTBot" in r["body"] and "Disallow: /internal/export" in r["body"], r["body"]
        for path, headers in (("/api/x", {"User-Agent": "GPTBot/1.0"}), ("/.env", {}), ("/wp-login.php", {})):
            r = get(path, headers=headers)
            assert r["status"] == 200 and "{" not in r["body"][:1], path
        assert backend_log() == [], backend_log()

    with subtest("crowdsec bans and the waf answer at the edge"):
        vm_200.succeed("echo ${bannedClient} >> /var/lib/crowdsec/data/stub-bans")
        assert get("/api/health", xff="${bannedClient}")["status"] == 403
        assert get("/", host="https://${net.fqdn internalRoutes.grafana.host}", xff="${bannedClient}")["status"] == 403
        assert get("/api/health", xff="203.0.113.13")["status"] == 200
        assert get("/api/x", headers={"X-Test-Attack": "1"}, xff="203.0.113.14")["status"] == 403
        # the upload path has the waf off
        assert get("/user-files/x", headers={"X-Test-Attack": "1"}, xff="203.0.113.15")["status"] == 200
  '';
}
