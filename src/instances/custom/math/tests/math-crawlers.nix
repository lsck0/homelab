# math, the indexable route, on the real edge (200-external-traefik) with the crowdsec stand-in: anubis lets a search
# crawler through only from its published ranges, behind cloudflare as the client cloudflare saw; the user agent of a
# crawler publishing a list alone, from anywhere else, gets the challenge, like a browser does. The name of a crawler the
# gate verifies by reverse dns, from an address whose name dns denies, gets the deception's fakes and no challenge
# (the decision and the ban after it: modules/traefik tests/deception.nix).
#
# `appnodes` serves the route's port at its swarm worker's address, `world` owns the flat lab's gateways and
# cloudflare's address and is the edge's resolver, which knows no reverse name; every client arrives through cloudflare
# with X-Forwarded-For, as the internet does.
{
  pkgs,
  lib,
  specialArgs,
  ...
}:
let
  lab = import ../../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
  net = import ../../../../modules/net.nix {
    inherit lib;
    inherit (specialArgs) inventory site;
  };
  inherit (lab.catalog.external) math;
  echoBackend = pkgs.writers.writePython3Bin "echo-backend" {
    flakeIgnore = [
      "E501"
      "E203"
      "W503"
    ];
  } (builtins.readFile ../../../../tests/lib/echo_backend.py);
  cloudflare = "104.16.0.10";
  residentialClient = "203.0.113.9";
  forger = "203.0.113.10";
  # a fake trickles at 1 KiB/s (lib/gate deception.go): the first request starts the lookup, a later one gets the fake
  forgedTimeoutS = 30;
  # each crawler's user agent as it sends it, and an address of its published ranges (anubis data/crawlers/<name>.yaml)
  crawlers = {
    googlebot = {
      userAgent = "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)";
      address = "66.249.64.1";
    };
    bingbot = {
      userAgent = "Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)";
      address = "157.55.39.1";
    };
    duckduckbot = {
      userAgent = "DuckDuckBot/1.1; (+http://duckduckgo.com/duckduckbot.html)";
      address = "57.152.72.128";
    };
    applebot = {
      userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.1.1 Safari/605.1.15 (Applebot/0.1; +http://www.apple.com/go/applebot)";
      address = "17.241.208.161";
    };
  };
  browserUserAgent = "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0";
in
assert lib.assertMsg math.indexable "math-crawlers: the fixture route is no longer indexable";
pkgs.testers.runNixOSTest {
  name = "math-crawlers";
  node.specialArgs = lab.specialArgs;

  nodes.vm-200 = {
    imports = [
      (lab.guest "200" {
        flat = true;
        instance = ../../../core/200-external-traefik/main.nix;
      })
      ../../../../tests/lib/offline-traefik.nix
    ];
    virtualisation.memorySize = 1536;
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
        ];
      })
    ];
    environment.systemPackages = [ pkgs.curl ];
    # authoritative for every reverse name, so the gate's lookup of any address is nxdomain
    services.dnsmasq = {
      enable = true;
      resolveLocalQueries = false;
      settings = {
        no-resolv = true;
        no-hosts = true;
        local = [ "/in-addr.arpa/" ];
      };
    };
    networking.firewall.allowedUDPPorts = [ 53 ];
  };

  testScript =
    { nodes, ... }:
    let
      gateCrawlers = map (c: c.name) nodes.vm-200.homelab.traefik.gate.settings.crawlers;
    in
    lab.driverPython
    + ''
      EDGE, CF = "${lab.inventory."200".ip}", "${cloudflare}"
      MATH = "https://${net.fqdn math.host}/"
      CRAWLERS = json.loads(${builtins.toJSON (builtins.toJSON crawlers)})
      LIST_ONLY = [name for name in CRAWLERS if name not in ${builtins.toJSON gateCrawlers}]

      def get(user_agent, client, path=""):
          return http_request(world, MATH + path, address=EDGE, src=CF,
                              headers={"User-Agent": user_agent, "X-Forwarded-For": client})

      def passed(r):
          return r["status"] == 200 and r["body"].startswith("{") and json.loads(r["body"])["port"] == ${toString math.port}

      def challenged(r):
          return r["status"] == 200 and "within.website" in r["body"]

      start_all()
      vm_200.wait_for_unit("traefik.service")
      vm_200.wait_for_open_port(443)
      vm_200.wait_for_file("/var/lib/crowdsec/data/stub-ready")
      vm_200.wait_for_unit("anubis-ingress.service")
      appnodes.wait_for_file("/run/echo/requests.jsonl.ready")
      # traefik listens on 443 before it has loaded math's router and certificate
      world.wait_until_succeeds(f"curl -sS -o /dev/null --interface {CF} --resolve ${net.fqdn math.host}:443:{EDGE} {MATH}robots.txt", timeout=60)

      with subtest("a crawler from its published ranges reaches the page"):
          for name, crawler in CRAWLERS.items():
              r = get(crawler["userAgent"], crawler["address"])
              assert passed(r), (name, r["status"], r["body"][:200])

      with subtest("a list-only crawler's user agent from anywhere else is challenged"):
          assert LIST_ONLY, CRAWLERS
          for name in LIST_ONLY:
              r = get(CRAWLERS[name]["userAgent"], "${residentialClient}")
              assert challenged(r), (name, r["status"], r["body"][:200])

      with subtest("a browser is challenged, from a crawler's address too"):
          for client in ("${residentialClient}", CRAWLERS["googlebot"]["address"]):
              r = get("${browserUserAgent}", client)
              assert challenged(r), (client, r["status"], r["body"][:200])

      with subtest("a verified crawler's name from an address dns denies gets the deception's fake, no challenge"):
          verified = [name for name in CRAWLERS if name in ${builtins.toJSON gateCrawlers}]
          assert verified, CRAWLERS
          forged = []
          def forged_fake(_):
              forged.append(get(CRAWLERS[verified[0]]["userAgent"], "${forger}", "api/x"))
              return forged[-1]["status"] == 200 and forged[-1]["body"].startswith("{") and "data" in json.loads(forged[-1]["body"])
          retry(forged_fake, timeout=${toString forgedTimeoutS})
          r = forged[-1]
          assert not challenged(r) and "${net.fqdn math.host}" not in r["body"], r["body"][:300]
          assert json.loads(r["body"])["data"]["storage"]["access_key_id"].startswith("AKIA"), r["body"][:300]
    '';
}
