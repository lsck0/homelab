# the edge's anti-bot defence with the real crowdsec (its pinned image, its scenarios and the ladder's profiles): the
# gate's captcha, one try per puzzle, the cookie, the ban after too many wrong answers with its remaining time, the
# honeypot's ban, the tarpit, the anonymous limit, and the sources it never stops
#
# The fixture is edge-apps' (the real `wat` app on `appnodes`, the internal ingress for the relayed session check,
# authelia's stand-in answering /api/state), with crowdsec itself in place of its stub on the edge; the internal
# ingress keeps the stub. Clients come through `world`'s cloudflare address with X-Forwarded-For, as the internet
# does, or straight from the house lan and wireguard. The gate logs each puzzle's answer (captcha.answerLog, a test
# hook tests/policy forbids on a lab host), so the script answers as a person would.
{ pkgs, lib, specialArgs, ... }:
let
  lab = import ../../../../tests/lib/lab.nix {
    inherit pkgs lib specialArgs;
    # its reservation needs three workers beside hello's (modules/limits workerCountOf)
    apps = apps: lib.recursiveUpdate apps { wat = { enable = true; reservation.memoryMiB = 1024; }; };
  };
  net = import ../../../../modules/net.nix { inherit lib; inherit (specialArgs) inventory site; };
  ip = id: lab.inventory.${id}.ip;
  wat = lab.appsCatalog.apps.wat;
  authelia = lab.routes.internal.authelia;
  echoBackend = pkgs.writers.writePython3Bin "echo-backend" { flakeIgnore = [ "E501" ]; } (builtins.readFile ../../../../tests/lib/echo_backend.py);
  autheliaStub = pkgs.writers.writePython3Bin "authelia-stub" { flakeIgnore = [ "E501" ]; } (builtins.readFile ../../../../tests/lib/authelia_stub.py);
  appPorts = lib.unique (map (p: p.port) (lib.attrValues wat.routes ++ lib.attrValues wat.metrics));
  session = "${net.autheliaSessionCookie}=valid";
  # the house lan, a wireguard peer, cloudflare and the internet, all on `world`
  outside = { lan = net.wan.workstation; wireguard = "10.0.0.7"; cloudflare = "104.16.0.10"; };
  # lib/gate tarpit.go tarpitPerClientMax
  tarpitPerClientMax = 2;

  guest = vmid: instance: memory: extra: {
    imports = [ (lab.guest vmid { flat = true; inherit instance; }) ../../../../tests/lib/offline-traefik.nix extra ];
    virtualisation.memorySize = memory;
  };
  # crowdsec as the lab runs it, without the community api the test vm cannot reach
  realCrowdsec = {
    virtualisation.oci-containers.containers.crowdsec = {
      image = lib.mkOverride 10 "crowdsecurity/crowdsec:v1.7.7";
      imageFile = lib.mkOverride 10 lab.images.crowdsec;
      environment.DISABLE_ONLINE_API = lib.mkOverride 10 "true";
    };
    homelab.traefik.gate.captcha.answerLog = true;
  };
in
pkgs.testers.runNixOSTest {
  name = "edge-antibot";
  node.specialArgs = lab.specialArgs;

  nodes.vm-200 = guest "200" ../main.nix 2560 realCrowdsec;
  nodes.vm-100 = guest "100" ../../100-internal-traefik/main.nix 1024 { };
  nodes.appnodes = {
    imports = [ (lab.multi { addresses = map (a: "${a}/8") [ (ip "250") (ip "251") (ip "101") ]; }) ];
    systemd.services.echo-backend = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${echoBackend}/bin/echo-backend --ports ${lib.concatMapStringsSep "," toString appPorts} --log /run/echo/requests.jsonl";
    };
    systemd.services.authelia-stub = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${autheliaStub}/bin/authelia-stub --port ${toString authelia.port} --portal ${net.fqdn authelia.host} --session ${session} --log-dir /run";
    };
  };
  nodes.world = {
    imports = [ (lab.multi { addresses = [ "10.100.0.1/8" "10.200.0.1/8" "10.250.0.1/8" "${outside.wireguard}/8" "${outside.cloudflare}/13" "${outside.lan}/24" ]; }) ];
    environment.systemPackages = [ pkgs.curl ];
  };

  testScript = { nodes, ... }: let gate = nodes.vm-200.homelab.traefik.gate.settings; in lab.driverPython + ''
    import re

    EDGE = "${ip "200"}"
    CF, LAN, WG = "${outside.cloudflare}", "${outside.lan}", "${outside.wireguard}"
    WAT = "https://${net.fqdn "wat"}"
    ANSWERS = "/run/lab-gate/answers"
    FORM = {"Content-Type": "application/x-www-form-urlencoded"}

    def get(path, client=None, src=CF, headers=None):
        h = dict(headers or {})
        if client:
            h["X-Forwarded-For"] = client
        return http_request(world, WAT + path, address=EDGE, src=src, headers=h)

    def answer(client, text, cookie=None):
        h = dict(FORM, **{"X-Forwarded-For": client})
        return http_request(world, WAT + "${gate.captcha.answerPath}?return=%2Fapi%2Fx", address=EDGE, src=CF,
                            method="POST", headers=h, body=f"answer={text}")

    def cscli(args):
        return vm_200.succeed(f"podman exec crowdsec cscli {args}")

    def flag(client, kind, duration="1h"):
        cscli(f"decisions add --ip {client} --type {kind} --duration {duration}")

    def answer_of(client):
        lines = [l.split() for l in vm_200.succeed(f"cat {ANSWERS}").splitlines() if l.startswith(client + " ")]
        return lines[-1][1]

    def decisions(client):
        return json.loads(cscli(f"decisions list --ip {client} -o json") or "null") or []

    start_all()
    vm_200.wait_for_unit("traefik.service")
    vm_200.wait_for_open_port(443)
    vm_100.wait_for_file("/var/lib/crowdsec/data/stub-ready")
    # the real crowdsec loads the hub, the waf's rules and the ladder before its api answers
    vm_200.wait_until_succeeds("podman exec crowdsec cscli lapi status", timeout=600)
    vm_200.wait_for_unit("lab-gate.service")
    appnodes.wait_for_file("/run/echo/requests.jsonl.ready")
    appnodes.wait_for_open_port(${toString authelia.port})
    world.wait_until_succeeds(f"[ $(curl -s -o /dev/null -w '%{{http_code}}' --interface {CF} -H 'X-Forwarded-For: 203.0.113.1' "
                              f"--resolve ${net.fqdn "wat"}:443:{EDGE} {WAT}/api/health) = 200 ]", timeout=180)

    with subtest("crowdsec runs the ladder: its scenarios and profiles loaded"):
        names = [s["name"] for s in json.loads(cscli("scenarios list -o json"))["scenarios"]]
        for scenario in ("homelab/captcha-failed", "homelab/honeypot", "homelab/labyrinth", "homelab/anubis-failed", "homelab/rate-limited"):
            assert scenario in names, (scenario, names)

    with subtest("a flagged client gets the captcha: one picture, one text box, no script, no answer"):
        flag("203.0.113.21", "captcha")
        r = get("/api/x", "203.0.113.21")
        assert r["status"] == 429 and r["headers"].get("x-lab-gate") == "captcha", r["status"]
        page = r["body"]
        assert "<script" not in page.lower() and page.count("<input") == 1 and 'src="data:image/png;base64,' in page, page[:400]
        assert answer_of("203.0.113.21") not in page.lower()
        assert "default-src 'none'" in r["headers"]["content-security-policy"]
        # a reload shows the same puzzle: reloading earns nothing
        get("/api/x", "203.0.113.21")
        assert vm_200.succeed(f"grep -c '^203.0.113.21 ' {ANSWERS}").strip() == "1"

    with subtest("a wrong answer regenerates the puzzle"):
        first = answer_of("203.0.113.21")
        r = answer("203.0.113.21", first[::-1] if first[::-1] != first else "000000")
        assert r["status"] == 303 and r["headers"]["location"] == "/api/x" and r["headers"].get("x-lab-gate") == "wrong", r
        assert "set-cookie" not in r["headers"], r["headers"]
        r = get("/api/x", "203.0.113.21")
        assert r["status"] == 429 and "not right" in r["body"], r["status"]
        assert answer_of("203.0.113.21") != first

    with subtest("the right answer sets a cookie that lets its client, and only it, through"):
        r = answer("203.0.113.21", "0x" + answer_of("203.0.113.21").upper())
        assert r["status"] == 303 and r["headers"].get("x-lab-gate") == "solved", r
        cookie = r["headers"]["set-cookie"]
        assert "Domain=${net.domain}" in cookie and "Secure" in cookie and "HttpOnly" in cookie, cookie
        value = cookie.split(";")[0]
        r = get("/api/x", "203.0.113.21", headers={"Cookie": value})
        assert r["status"] == 200 and json.loads(r["body"])["path"] == "/api/x", r
        # positive control: the cookie is bound to its client's address
        flag("203.0.113.22", "captcha")
        assert get("/api/x", "203.0.113.22", headers={"Cookie": value})["status"] == 429

    with subtest("too many wrong answers ban the client, the ban page says for how long"):
        flag("203.0.113.23", "captcha")
        for _ in range(${toString (gate.captcha.regenerationsMax + 1)}):
            get("/api/x", "203.0.113.23")
            assert answer("203.0.113.23", "000000" if answer_of("203.0.113.23") != "000000" else "111111")["headers"].get("x-lab-gate") == "wrong"
        vm_200.wait_until_succeeds("podman exec crowdsec cscli decisions list --ip 203.0.113.23 -o json | grep -q captcha-failed", timeout=120)
        bans = [d for a in decisions("203.0.113.23") for d in a.get("decisions", []) if d["type"] == "ban"]
        assert bans and bans[0]["scenario"] == "homelab/captcha-failed", bans
        world.wait_until_succeeds(
            f"curl -s --interface {CF} -H 'X-Forwarded-For: 203.0.113.23' --resolve ${net.fqdn "wat"}:443:{EDGE} {WAT}/api/x "
            "| grep -q 'You have been banned for 59 minutes'", timeout=30)
        r = get("/api/x", "203.0.113.23")
        assert r["status"] == 403 and 3000 < int(r["headers"]["retry-after"]) <= 3600, r["headers"]
        assert "<script" not in r["body"].lower()

    with subtest("a honeypot hit is banned for minutes (the ladder's strong signal, first rung)"):
        world.execute(f"curl -s --max-time 3 --interface {CF} -H 'X-Forwarded-For: 203.0.113.24' "
                      f"--resolve ${net.fqdn "wat"}:443:{EDGE} {WAT}/.env")
        vm_200.wait_until_succeeds("podman exec crowdsec cscli decisions list --ip 203.0.113.24 -o json | grep -q homelab/honeypot", timeout=120)
        world.wait_until_succeeds(
            f"curl -s --interface {CF} -H 'X-Forwarded-For: 203.0.113.24' --resolve ${net.fqdn "wat"}:443:{EDGE} {WAT}/api/x "
            "| grep -q 'You have been banned for 1[0-4] minutes'", timeout=30)

    with subtest("the labyrinth trickles, two at a time per client"):
        received = world.execute(f"curl -s --max-time 4 -o /tmp/trickle -w '%{{size_download}}' --interface {CF} -A GPTBot/1.0 "
                                 f"-H 'X-Forwarded-For: 203.0.113.25' --resolve ${net.fqdn "wat"}:443:{EDGE} {WAT}/api/x")[1]
        assert 0 < int(received) <= 4 * 32 + 16, received
        for i in range(${toString tarpitPerClientMax}):
            world.succeed(f"(curl -s --max-time 30 -o /dev/null --interface {CF} -A GPTBot/1.0 -H 'X-Forwarded-For: 203.0.113.26' "
                          f"--resolve ${net.fqdn "wat"}:443:{EDGE} {WAT}/api/held{i} >/dev/null 2>&1 &)")
        vm_200.wait_until_succeeds("curl -s http://${gate.listen}/metrics | grep -qx 'homelab_gate_tarpit_active ${toString tarpitPerClientMax}'", timeout=20)
        r = get("/api/third", "203.0.113.26", headers={"User-Agent": "GPTBot/1.0"})
        assert r["status"] == 429 and r["headers"].get("retry-after") == "60", r

    with subtest("anonymous clients are limited below logged-in ones"):
        def flood(client, cookie=""):
            extra = f"-H 'Cookie: {cookie}'" if cookie else ""
            return world.succeed(
                "seq 6 | xargs -P 6 -I@ curl -s -o /dev/null -w '%{http_code}\\n' "
                f"--interface {CF} --resolve ${net.fqdn "wat"}:443:{EDGE} -H 'X-Forwarded-For: {client}' {extra} "
                f"'{WAT}/api/health?@-[1-15]'").split()
        codes = flood("203.0.113.27")
        assert "429" in codes and "200" in codes, sorted(set(codes))
        codes = flood("203.0.113.28", "${session}")
        assert set(codes) == {"200"}, sorted(set(codes))

    with subtest("the house lan, wireguard and a logged-in user are never stopped, whatever crowdsec says"):
        for client in (LAN, WG, "203.0.113.29"):
            flag(client, "ban")
        assert get("/api/health", src=LAN)["status"] == 200
        assert get("/api/health", src=WG)["status"] == 200
        assert get("/api/health", "203.0.113.29", headers={"Cookie": "${session}"})["status"] == 200
        # positive control: a cookie authelia does not know is no session
        r = get("/api/health", "203.0.113.29", headers={"Cookie": "${net.autheliaSessionCookie}=forged"})
        assert r["status"] == 403 and "You have been banned for" in r["body"], r["status"]

    with subtest("bans and answers are counted for grafana"):
        vm_200.succeed("systemctl start lab-gate-metrics.service")
        metrics = vm_200.succeed("cat ${nodes.vm-200.homelab.textfileDir}/lab_gate.prom")
        for series in ('homelab_gate_answers_total{outcome="solved"} 1', 'homelab_gate_answers_total{outcome="wrong"} 7'):
            assert series in metrics, metrics
        bans_total = re.search(r"^homelab_gate_bans_total (\d+)$", metrics, re.M)
        assert bans_total and int(bans_total.group(1)) >= 3, metrics
  '';
}
