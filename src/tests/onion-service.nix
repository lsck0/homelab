# lab-wide: an onion route (modules/service.nix `onion`) across the router's tor and the edge
# the router's tor publishes the route from its key's seed at the address src/generated/onions.json names, and the
# edge serves that address on its onion entrypoint with the route's chain (anubis, the waf) and backend, to the
# router alone. Tor reaches no relay here, so the visitor's last hop is played by the router itself, as tor would be:
# a request to the edge's onion entrypoint naming the address.
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
    testing.secretValues.${service.onionKeyOf routeName} = seed;
    virtualisation.memorySize = 1024;
  };
  nodes.vm-200 = {
    imports = [ (lab.guest "200" { instance = ../core/200-external-traefik/main.nix; }) ./lib/offline-traefik.nix ];
    virtualisation.memorySize = 1536;
  };
  nodes.backend = {
    imports = [ (lab.multi { vlan = lab.vlans.external; addresses = [ "${ip (toString route.vmid)}/24" ]; gateway = net.zones.external.routerIp; }) tools ];
    systemd.services.echo-backend = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${echoBackend}/bin/echo-backend --ports ${toString route.port} --log /run/echo/requests.jsonl";
    };
  };

  testScript = ''
    import json

    ADDRESS = "${address}"
    ONION = "http://${ip "200"}:${toString torPorts.onionIngress}"

    def onion_get(machine, path, user_agent="curl/8", headers=""):
        out = machine.succeed(f"curl -s -m 10 -A '{user_agent}' {headers} -H 'Host: {ADDRESS}' -w '\\n%{{http_code}}' {ONION}{path}")
        body, _, status = out.rpartition("\n")
        return int(status), body

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
