# the deception on the real edge (200-external-traefik) with the real crowdsec (its pinned image, the ladder's
# scenarios and profiles) and the deceive window shortened to a minute: a forged search crawler on a bot-defended
# route gets fakes once dns denies its name, a crowdsec decision, and the ban page after the window though it keeps
# the name; a scanner hitting the honeypot's /.env gets a fake with canaries, fakes for the window, then the ban; a
# crawler from its published ranges still reads the indexable route, one from outside them that its reverse dns
# verifies is never deceived, a browser still gets anubis' challenge, and a backend answering the forged-crawler status
# itself trips no decision
#
# The fixture is math-crawlers' (math, the indexable route, served by `appnodes`), with crowdsec itself in place of its
# stub. Every client arrives through `world`'s cloudflare address with X-Forwarded-For, as the internet does; `world`
# is the edge's resolver too, a dnsmasq knowing googlebot's one address outside the snapshot and no other name.
{
  pkgs,
  lib,
  specialArgs,
  ...
}:
let
  lab = import ../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
  net = import ../../net.nix {
    inherit lib;
    inherit (specialArgs) inventory site;
  };
  inherit (lab.catalog.external) math;
  inherit (import ../lib/gate.nix { inherit pkgs lib; }) statusForgedCrawler;
  echoBackend = pkgs.writers.writePython3Bin "echo-backend" {
    flakeIgnore = [
      "E501"
      "E203"
      "W503"
    ];
  } (builtins.readFile ../../../tests/lib/echo_backend.py);
  cloudflare = "104.16.0.10";
  # googlebot's own address and user agent (anubis data/crawlers/googlebot.yaml), and its name from elsewhere
  googlebot = {
    userAgent = "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)";
    address = "66.249.64.1";
    # a live googlebot address outside anubis 1.25.0's snapshot, and its reverse name
    newAddress = "192.178.4.1";
    newName = "crawl-192-178-4-1.googlebot.com";
  };
  reverseName = address: lib.concatStringsSep "." (lib.reverseList (lib.splitString "." address)) + ".in-addr.arpa";
  forger = "203.0.113.40";
  scanner = "203.0.113.41";
  # hits the house address itself, past cloudflare
  directScanner = "198.51.100.41";
  backendClient = "203.0.113.42";
  residentialClient = "203.0.113.9";
  browserUserAgent = "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0";
  scannerUserAgent = "curl/8.5.0";
  deceiveWindow = "1m";
  # the window, the gate's decision cache and crowdsec's own pace, with room
  banTimeoutS = 180;
in
assert lib.assertMsg math.indexable "deception: the fixture route is no longer indexable";
assert lib.assertMsg (lib.elem "botDefense" math.on) "deception: the fixture route lost its bot defence";
pkgs.testers.runNixOSTest {
  name = "deception";
  node.specialArgs = lab.specialArgs;

  nodes.vm-200 = {
    imports = [
      (lab.guest "200" {
        flat = true;
        instance = ../../../instances/core/200-external-traefik/main.nix;
      })
      ../../../tests/lib/offline-traefik.nix
    ];
    virtualisation.memorySize = 2560;
    # crowdsec as the lab runs it, without the community api the test vm cannot reach
    virtualisation.oci-containers.containers.crowdsec = {
      image = lib.mkOverride 10 "crowdsecurity/crowdsec:v1.7.7";
      imageFile = lib.mkOverride 10 lab.images.crowdsec;
      environment.DISABLE_ONLINE_API = lib.mkOverride 10 "true";
    };
    homelab.traefik.crowdsecBouncer.deceiveWindow = deceiveWindow;
  };
  nodes.appnodes = {
    imports = [ (lab.multi { addresses = map (a: "${a}/8") math.nodes; }) ];
    systemd.services.echo-backend = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${echoBackend}/bin/echo-backend --ports ${toString math.port} --log /run/echo/requests.jsonl";
    };
  };
  nodes.world = {
    imports = [
      (lab.multi {
        addresses = [
          "10.100.0.1/8"
          "10.200.0.1/8"
          "10.250.0.1/8"
          "${cloudflare}/13"
          "${directScanner}/24"
        ];
      })
    ];
    environment.systemPackages = [ pkgs.curl ];
    # authoritative for every reverse name and googlebot's domains, so any other address's name is nxdomain
    services.dnsmasq = {
      enable = true;
      resolveLocalQueries = false;
      settings = {
        no-resolv = true;
        no-hosts = true;
        local = [
          "/in-addr.arpa/"
          "/googlebot.com/"
          "/google.com/"
        ];
        ptr-record = "${reverseName googlebot.newAddress},${googlebot.newName}";
        host-record = "${googlebot.newName},${googlebot.newAddress}";
      };
    };
    networking.firewall.allowedUDPPorts = [ 53 ];
  };

  testScript =
    { nodes, ... }:
    lab.driverPython
    + ''
      import re
      import time

      EDGE, CF = "${lab.inventory."200".ip}", "${cloudflare}"
      HOST = "${net.fqdn math.host}"
      MATH = f"https://{HOST}"

      def get(path, client, user_agent):
          return http_request(world, MATH + path, address=EDGE, src=CF,
                              headers={"User-Agent": user_agent, "X-Forwarded-For": client})

      def decisions(client):
          alerts = json.loads(vm_200.succeed(f"podman exec crowdsec cscli decisions list --ip {client} -o json") or "null") or []
          return [d for a in alerts for d in a.get("decisions", [])]

      def wait_for_decision(client, kind, scenario):
          vm_200.wait_until_succeeds(
              f"podman exec crowdsec cscli decisions list --ip {client} -o json | ${pkgs.jq}/bin/jq -e "
              f"'[.[].decisions[] | select(.type == \"{kind}\" and .scenario == \"{scenario}\")] | length > 0'", timeout=120)

      def passed(r):
          return r["status"] == 200 and r["body"].startswith("{") and json.loads(r["body"])["port"] == ${toString math.port}

      def challenged(r):
          return r["status"] == 200 and "within.website" in r["body"]

      def fake(r):
          return r["status"] == 200 and "within.website" not in r["body"] and HOST not in r["body"] and "lsck0" not in r["body"]

      start_all()
      vm_200.wait_for_unit("traefik.service")
      vm_200.wait_for_open_port(443)
      # the real crowdsec loads the hub, the waf's rules and the ladder before its api answers
      vm_200.wait_until_succeeds("podman exec crowdsec cscli lapi status", timeout=600)
      vm_200.wait_for_unit("lab-gate.service")
      vm_200.wait_for_unit("anubis-ingress.service")
      appnodes.wait_for_file("/run/echo/requests.jsonl.ready")
      # traefik listens on 443 before it has loaded math's router and certificate
      world.wait_until_succeeds(f"curl -sS -o /dev/null --interface {CF} --resolve {HOST}:443:{EDGE} {MATH}/robots.txt", timeout=60)

      with subtest("crowdsec runs the deception ladder: its scenarios loaded"):
          names = [s["name"] for s in json.loads(vm_200.succeed("podman exec crowdsec cscli scenarios list -o json"))["scenarios"]]
          for scenario in ("homelab/forged-crawler", "homelab/honeypot", "homelab/labyrinth"):
              assert scenario in names, (scenario, names)

      with subtest("a crawler from its published ranges reads the indexable route, undecided"):
          r = get("/", "${googlebot.address}", "${googlebot.userAgent}")
          assert passed(r), (r["status"], r["body"][:200])

      with subtest("a browser gets anubis' challenge, not the deception"):
          r = get("/", "${residentialClient}", "${browserUserAgent}")
          assert challenged(r), (r["status"], r["body"][:200])

      with subtest("a backend answering the forged-crawler status itself gets the deception's refusal"):
          r = get("/status/${toString statusForgedCrawler}", "${backendClient}", "${scannerUserAgent}")
          # the errors middleware rewrites the refusal's bad gateway to a 200 that still shows it
          assert r["status"] == 200 and "Bad Gateway" in r["body"], (r["status"], r["body"][:200])

      with subtest("a forged search crawler gets a fake once dns denies its name, and a crowdsec decision"):
          # its first request starts the lookup and is judged like any other's
          forged = []
          def forged_fake(_):
              forged.append(get("/api/v1/users", "${forger}", "${googlebot.userAgent}"))
              return fake(forged[-1])
          retry(forged_fake, timeout=30)
          r = forged[-1]
          storage = json.loads(r["body"])["data"]["storage"]
          assert storage["access_key_id"].startswith("AKIA"), storage
          wait_for_decision("${forger}", "deceive", "homelab/forged-crawler")
          assert any(d["type"] == "ban" for d in decisions("${forger}")), decisions("${forger}")
          # the canary in the journal names its fetcher
          vm_200.succeed(f"journalctl -u lab-gate -o cat | grep 'deception canary' | grep '${forger}' | grep -q '{storage['access_key_id']}'")
          assert decisions("${googlebot.address}") == [], decisions("${googlebot.address}")
          # crowdsec read the backend's line before the forger's: it named no forged crawler
          assert decisions("${backendClient}") == [], decisions("${backendClient}")

      with subtest("a crawler outside its snapshot ranges that its reverse dns verifies is never deceived"):
          get("/api/v1/users", "${googlebot.newAddress}", "${googlebot.userAgent}")
          # the lookup the first request started has settled well within this
          time.sleep(3)
          r = get("/api/v1/users", "${googlebot.newAddress}", "${googlebot.userAgent}")
          assert challenged(r), (r["status"], r["body"][:200])
          assert decisions("${googlebot.newAddress}") == [], decisions("${googlebot.newAddress}")

      with subtest("a scanner's /.env gets a fake with canaries, fakes for the window, then the ban"):
          first = get("/.env", "${scanner}", "${scannerUserAgent}")
          assert fake(first) and "AWS_ACCESS_KEY_ID=AKIA" in first["body"], (first["status"], first["body"][:300])
          wait_for_decision("${scanner}", "deceive", "homelab/honeypot")
          # deceived through the route's own router once the gate's cached verdict expires: plausible, the same fake
          # for the same path
          world.wait_until_succeeds(
              f"curl -s --interface {CF} -H 'X-Forwarded-For: ${scanner}' -A '${scannerUserAgent}' --resolve {HOST}:443:{EDGE} "
              f"{MATH}/phpinfo.php | grep -q 'PHP Version'", timeout=30)
          r = get("/phpinfo.php", "${scanner}", "${scannerUserAgent}")
          assert fake(r) and "PHP Version" in r["body"], (r["status"], r["body"][:300])
          assert get("/.env", "${scanner}", "${scannerUserAgent}")["body"] == first["body"]
          world.wait_until_succeeds(
              f"curl -s --interface {CF} -H 'X-Forwarded-For: ${scanner}' -A '${scannerUserAgent}' --resolve {HOST}:443:{EDGE} "
              f"{MATH}/phpinfo.php | grep -q 'You have been banned for'", timeout=${toString banTimeoutS})

      with subtest("a scanner hitting the house address directly gets the fake, a canary and a decision"):
          # positive control: the real route refuses a direct caller
          r = http_request(world, MATH + "/", address=EDGE, src="${directScanner}", headers={"User-Agent": "${scannerUserAgent}"})
          assert r["status"] == 403, (r["status"], r["body"][:200])
          r = http_request(world, MATH + "/.env", address=EDGE, src="${directScanner}", headers={"User-Agent": "${scannerUserAgent}"})
          assert fake(r) and "AWS_ACCESS_KEY_ID=AKIA" in r["body"], (r["status"], r["body"][:300])
          key = re.search(r"AWS_ACCESS_KEY_ID=(AKIA\w+)", r["body"])
          assert key, r["body"][:300]
          vm_200.succeed(f"journalctl -u lab-gate -o cat | grep 'deception canary' | grep '${directScanner}' | grep -q '{key.group(1)}'")
          wait_for_decision("${directScanner}", "deceive", "homelab/honeypot")

      with subtest("the forger keeps its crawler's name past the window and gets the ban page"):
          world.wait_until_succeeds(
              f"curl -s --interface {CF} -H 'X-Forwarded-For: ${forger}' -A '${googlebot.userAgent}' --resolve {HOST}:443:{EDGE} "
              f"{MATH}/api/v1/users | grep -q 'You have been banned for'", timeout=${toString banTimeoutS})

      with subtest("deceptions and canaries are counted, the deceive decisions once each"):
          vm_200.succeed("systemctl start lab-gate-metrics.service")
          metrics = vm_200.succeed("cat ${nodes.vm-200.homelab.textfileDir}/lab_gate.prom")
          deceives = re.search(r"^homelab_gate_deceives_total (\d+)$", metrics, re.M)
          assert deceives and int(deceives.group(1)) >= 1, metrics
          for target in ("env", "api", "phpinfo"):
              assert re.search(rf'^homelab_gate_canaries_total{{target="{target}"}} [1-9]', metrics, re.M), metrics
          assert re.search(r'^homelab_gate_verdicts_total{verdict="forged-crawler"} [1-9]', metrics, re.M), metrics
    '';
}
