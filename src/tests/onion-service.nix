# lab-wide: an onion route (modules/service.nix `onion`) across the router's tor and the edge
# the router's tor publishes the route from its key's seed at the address src/generated/onions.json names, and the
# edge serves that address on its onion entrypoint with the route's chain (anubis, the waf) and backend, to the
# router alone. Tor reaches no relay here, so the visitor's last hop is played by the router itself, as tor would be:
# a request to the edge's onion entrypoint naming the address. The gate asks each browser session its onion captcha
# first; it logs each puzzle's answer here (captcha.answerLog), so the script answers as a person would.
#
# No route is an onion route, so the test makes privatebin one: its key is a seed whose address tor 0.4.9 itself
# derived (scripts/lib/onion.sh, tests/secrets_sync_test.sh), and the catalog every node reads carries both. Nodes:
# the router, the edge (vm-200, offline), `backend` at privatebin's address.
{ pkgs, lib, specialArgs, ... }:
let
  lab = import ./lib/lab.nix { inherit pkgs lib specialArgs; };
  net = import ../modules/net.nix { inherit lib; inherit (specialArgs) inventory site; };
  service = import ../modules/service.nix { inherit lib; };
  torPorts = import ../modules/tor-ports.nix;
  secretValues = import ./lib/secret-values.nix { inherit pkgs; };
  ip = id: lab.inventory.${id}.ip;

  routeName = "privatebin";
  seed = "RCFGM1i8J76AFckn7Wjh3q8Plfq84CzNKRtKznH6BKk=";
  address = "22ymcrqdffp24cxrnkudyhxfy3hbfsmqqcfkra6p7u7r3nqykmaojmqd.onion";
  route = lab.catalog.external.${routeName} // { onion = true; onionAddress = address; };
  catalog = lab.catalog // { external = lab.catalog.external // { ${routeName} = route; }; };
  facts = lab.specialArgs // { lab = lab.specialArgs.lab // { inherit catalog; }; };

  echoBackend = pkgs.writers.writePython3Bin "echo-backend" { flakeIgnore = [ "E501" ]; } (builtins.readFile ./lib/echo_backend.py);
  # a browser's user agent, which anubis challenges
  browser = "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0";
  tools = { environment.systemPackages = [ pkgs.curl ]; };
in
pkgs.testers.runNixOSTest {
  name = "onion-service";
  node.specialArgs = facts;

  nodes.luca-router = {
    imports = [ lab.router tools ];
    # the lab's own onion routes start beside it, each from a well-formed seed of its own
    testing.secretValues = lib.mapAttrs' (name: _: lib.nameValuePair (service.onionKeyOf name) (secretValues.onionSeedOf name))
      (lib.filterAttrs (_: r: r.onion) catalog.external) // { ${service.onionKeyOf routeName} = seed; };
    virtualisation.memorySize = 1024;
  };
  nodes.vm-200 = {
    imports = [ (lab.guest "200" { instance = ../core/200-external-traefik/main.nix; }) ./lib/offline-traefik.nix ];
    virtualisation.memorySize = 1536;
    # the script answers the onion captcha as a person would (tests/policy forbids it on a lab host)
    homelab.traefik.gate.captcha.answerLog = true;
  };
  nodes.backend = {
    imports = [ (lab.multi { vlan = lab.vlans.external; addresses = [ "${ip (toString route.vmid)}/24" ]; gateway = net.zones.external.routerIp; }) tools ];
    systemd.services.echo-backend = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${echoBackend}/bin/echo-backend --ports ${toString route.port} --log /run/echo/requests.jsonl";
    };
  };

  testScript = { nodes, ... }: let gate = nodes.vm-200.homelab.traefik.gate.settings; in ''
    import json

    ADDRESS = "${address}"
    ONION = "http://${ip "200"}:${toString torPorts.onionIngress}"
    ANSWERS = "${gate.captcha.answerLog}"
    # the onion session and its pass, once the captcha is solved
    COOKIES = ""

    def onion_request(path, user_agent="curl/8", headers="", cookies=None, data=None):
        cookie = f"-H 'Cookie: {COOKIES if cookies is None else cookies}'"
        body = f"--data-raw '{data}'" if data is not None else ""
        out = luca_router.succeed(f"curl -s -i -m 10 -A '{user_agent}' {headers} {cookie} {body} -H 'Host: {ADDRESS}' {ONION}{path}")
        head, _, content = out.partition("\r\n\r\n")
        lines = head.split("\r\n")
        fields = [line.split(":", 1) for line in lines[1:]]
        return int(lines[0].split()[1]), {k.strip().lower(): v.strip() for k, v in fields}, [v.strip() for k, v in fields if k.lower() == "set-cookie"], content

    def onion_get(machine, path, user_agent="curl/8", headers=""):
        assert machine == luca_router
        status, _, _, body = onion_request(path, user_agent, headers)
        return status, body

    def answer_of(session):
        lines = [l.split() for l in vm_200.succeed(f"cat {ANSWERS}").splitlines() if l.startswith(f"{ADDRESS}/{session} ")]
        return lines[-1][1]

    start_all()

    with subtest("the router's tor publishes the route at the address its seed names"):
        luca_router.wait_for_unit("tor.service")
        luca_router.succeed("systemctl is-active tor-onion-keys")
        luca_router.wait_for_file("/run/tor/onion/${routeName}/hostname")
        published = luca_router.succeed("cat /run/tor/onion/${routeName}/hostname").strip()
        assert published == ADDRESS, f"tor publishes {published}, the catalog names {ADDRESS}"

    vm_200.wait_for_unit("traefik.service")
    vm_200.wait_for_file("/var/lib/crowdsec/data/stub-ready")
    backend.wait_for_file("/run/echo/requests.jsonl.ready")

    with subtest("every onion visitor is asked the anti-phishing captcha first, per browser session"):
        status, headers, cookies, page = onion_request("/paste")
        assert status == 429 and headers.get("x-lab-gate") == "captcha", status
        assert "<script" not in page.lower() and page.count("<input") == 1 and "address bar" in page, page[:400]
        session = next(c for c in cookies if c.startswith("lab_gate_onion="))
        assert "secure" not in session.lower() and "domain" not in session.lower(), session
        session = session.split(";")[0]
        first = answer_of(session.split("=", 1)[1])
        assert ADDRESS not in page and first not in page
        # one try: a wrong label brings a new puzzle
        status, headers, _, _ = onion_request("${gate.captcha.answerPath}?return=%2Fpaste", cookies=session, data=f"answer={first[::-1]}")
        assert status == 303 and headers.get("x-lab-gate") == "wrong", (status, headers)
        status, _, _, page = onion_request("/paste", cookies=session)
        assert status == 429 and "not right" in page, status
        right = answer_of(session.split("=", 1)[1])
        assert right != first
        status, headers, cookies, _ = onion_request("${gate.captcha.answerPath}?return=%2Fpaste", cookies=session, data=f"answer={right}")
        assert status == 303 and headers.get("x-lab-gate") == "solved" and headers["location"] == "/paste", (status, headers)
        passing = next(c for c in cookies if c.startswith("lab_gate="))
        assert "secure" not in passing.lower() and "domain" not in passing.lower(), passing
        COOKIES = session + "; " + passing.split(";")[0]
        # another browser behind the same router is still asked
        assert onion_request("/paste", cookies="")[0] == 429

    with subtest("the edge serves the onion address with the route's chain and backend"):
        status, body = onion_get(luca_router, "/paste")
        assert status == 200 and json.loads(body)["port"] == ${toString route.port}, (status, body)
        assert json.loads(body)["headers"]["host"] == ADDRESS, body
        # anubis challenges a browser, the waf refuses an attack: the route's chain runs for onion visitors
        status, body = onion_get(luca_router, "/", user_agent="${browser}")
        assert status == 200 and "within.website" in body, status
        status, _ = onion_get(luca_router, "/paste", headers="-H 'X-Test-Attack: 1'")
        assert status == 403, status
        # another name on the onion entrypoint matches no router
        status = int(luca_router.succeed(f"curl -s -o /dev/null -m 10 -w '%{{http_code}}' -H 'Host: other.onion' {ONION}/paste"))
        assert status == 404, status

    with subtest("the onion entrypoint answers the router alone"):
        backend.fail(f"curl -s -m 5 -H 'Host: {ADDRESS}' {ONION}/paste")
        # positive control: the router, right after
        assert onion_get(luca_router, "/paste")[0] == 200
  '';
}
