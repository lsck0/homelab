# external traefik -> internal traefik -> authelia forwardauth, on the real modules/traefik: no client header may
# pick the auth decision or the client identity the limits key on
#
# Nodes: `edge` (cloudflare trusted, relays every host to `internal` over tls verified for the host), `internal`
# (trusts the edge's hops), `auth` (an authelia stand-in deciding like the real access_control, and an echo backend
# reporting what a trusting app sees), `client` (a direct internet client) and `cf` (a cloudflare edge address,
# appending the client it saw to X-Forwarded-For, as cloudflare does).
{ pkgs, lib, specialArgs, ... }:
let
  lab = import ../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
  net = import ../../net.nix { inherit lib; inherit (specialArgs) inventory site; };

  portalHost = net.fqdn "auth";
  gatedHost = net.fqdn "backup";
  # no forwardauth in front, like forgejo or headscale
  ownHost = net.fqdn "git";
  sessionCookie = "authelia_session=valid";
  stubPort = 9091;
  backendPort = 8000;
  # inside cloudflare's 104.16.0.0/13, on the test lan
  cloudflareAddress = "104.16.0.10";
  cloudflarePrefix = 13;
  # clients cloudflare forwards for
  realClient = "203.0.113.9";
  otherClient = "203.0.113.10";
  # more requests in one go than the limit's burst (modules/traefik rateLimitBurst)
  floodRequests = 300;

  # authelia's decision as the real access_control makes it: the portal is bypass, the rest needs a session
  autheliaStub = pkgs.writers.writePython3Bin "authelia-stub" { flakeIgnore = [ "E501" ]; } (builtins.readFile ../../../tests/lib/authelia_stub.py);

  # echoes what a trusting app would see
  backend = pkgs.writers.writePython3 "echo-backend" { flakeIgnore = [ "E501" ]; } ''
    import http.server


    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = "user=%s host=%s client=%s xff=%s\n" % (self.headers.get("Remote-User", "-"), self.headers.get("X-Forwarded-Host", "-"), self.headers.get("X-Real-Ip", "-"), self.headers.get("X-Forwarded-For", "-"))
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body.encode())

        def log_message(self, *args):
            pass


    http.server.ThreadingHTTPServer(("0.0.0.0", ${toString backendPort}), H).serve_forever()
  '';

  traefikNode = extra: { config, ... }: {
    imports = [ ../../retry.nix ../default.nix ../../../tests/stubs.nix ../../../tests/lib/offline-traefik.nix extra ];
    options.homelab.acmeEmail = lib.mkOption { type = lib.types.str; default = "test@example.invalid"; };
    config = {
      # the crowdsec log parser needs an image, none of it is under test here (edge-apps runs the bouncer)
      virtualisation.oci-containers.containers = lib.mkForce { };
      security.pki.certificateFiles = [ lab.pki.ca ];
    };
  };

  hostRule = host: "Host(`${host}`)";
in
pkgs.testers.runNixOSTest {
  name = "auth-chain";
  node.specialArgs = lab.specialArgs;

  nodes.auth = {
    networking.firewall.allowedTCPPorts = [ stubPort backendPort ];
    systemd.services.authelia-stub = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${autheliaStub}/bin/authelia-stub --port ${toString stubPort} --portal ${portalHost} --session ${sessionCookie}";
    };
    systemd.services.echo-backend = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = backend;
    };
  };

  # vm-100: gates sso routes, believes the edge's hops and, behind them, cloudflare's
  nodes.internal = { nodes, ... }: {
    imports = [ (traefikNode {
      homelab.traefik = let backendUrl = "http://${nodes.auth.networking.primaryIPAddress}:${toString backendPort}"; in {
        enable = true;
        trustedProxies = [ "${nodes.edge.networking.primaryIPAddress}/32" ];
        trustCloudflare = true;
        authelia.address = "http://${nodes.auth.networking.primaryIPAddress}:${toString stubPort}/api/authz/forward-auth";
        routers = {
          portal-tls = { rule = hostRule portalHost; service = "app"; entryPoints = [ "websecure" ]; };
          gated-tls = { rule = hostRule gatedHost; service = "app"; entryPoints = [ "websecure" ]; middlewares = [ "authelia" ]; };
          own-tls = { rule = hostRule ownHost; service = "app"; entryPoints = [ "websecure" ]; };
        };
        services.app.loadBalancer.servers = [{ url = backendUrl; }];
      };
    }) ];
  };

  # vm-200: believes cloudflare's hops, relays every host to internal, verifying its certificate
  nodes.edge = { nodes, ... }: {
    imports = [ (traefikNode {
      homelab.traefik = {
        enable = true;
        trustCloudflare = true;
        routers = lib.genAttrs [ "portal-relay" "gated-relay" "own-relay" ] (name: {
          rule = hostRule ({ portal-relay = portalHost; gated-relay = gatedHost; own-relay = ownHost; }.${name});
          service = "internal-relay";
          entryPoints = [ "websecure" ];
        });
        services.internal-relay.loadBalancer = {
          servers = [{ url = "https://${nodes.internal.networking.primaryIPAddress}:443"; }];
          serversTransport = "internal-relay";
          passHostHeader = true;
        };
        # any name the internal ingress's wildcard certificate covers
        serversTransports.internal-relay.serverName = net.fqdn "relay";
      };
    }) ];
  };

  nodes.client = { environment.systemPackages = [ pkgs.curl ]; security.pki.certificateFiles = [ lab.pki.ca ]; };
  nodes.cf = { environment.systemPackages = [ pkgs.curl ]; security.pki.certificateFiles = [ lab.pki.ca ]; };

  testScript = { nodes, ... }: let
    edgeIp = nodes.edge.networking.primaryIPAddress;
    internalIp = nodes.internal.networking.primaryIPAddress;
    clientIp = nodes.client.networking.primaryIPAddress;
  in ''
    def get(machine, ip, host, *headers, src=None):
        flags = " ".join(f"-H '{h}'" for h in headers) + (f" --interface {src}" if src else "")
        return machine.succeed(
            f"curl -s -o /tmp/body -w '%{{http_code}}' --resolve {host}:443:{ip} {flags} https://{host}/ ; echo; cat /tmp/body"
        )

    def expect(result, code, body=None):
        status, _, rest = result.partition("\n")
        assert status == code, f"expected {code}, got {status}: {rest}"
        if body is not None:
            assert body in rest, f"expected {body!r} in {rest!r}"

    def flood(xff, count):
        # one request per forged X-Real-Ip, all for one real client behind cloudflare, from one curl at 64 in flight,
        # so the requests arrive far faster than the limit's average; the status codes
        entries = "next\n".join(
            f'url = "https://${ownHost}/"\nresolve = "${ownHost}:443:${edgeIp}"\ninterface = "${cloudflareAddress}"\n'
            f'header = "X-Forwarded-For: {xff}"\nheader = "X-Real-Ip: 10.9.{i // 250}.{i % 250}"\n'
            f'output = "/dev/null"\nwrite-out = "%{{http_code}}\\n"\n'
            for i in range(count))
        with open("/tmp/flood.curl", "w") as f:
            f.write(entries)
        cf.copy_from_host("/tmp/flood.curl", "/tmp/flood.curl")
        return cf.succeed("curl -s --parallel --parallel-max 64 -K /tmp/flood.curl").split()

    start_all()
    auth.wait_for_open_port(${toString stubPort})
    auth.wait_for_open_port(${toString backendPort})
    for node in (internal, edge):
        node.wait_for_unit("traefik.service")
        node.wait_for_open_port(443)
    # a cloudflare edge address on the test lan, and the edge's way back to it
    cf.wait_for_unit("network.target")
    cf.succeed("ip addr add ${cloudflareAddress}/${toString cloudflarePrefix} dev eth1")
    edge.succeed("ip route add 104.16.0.0/${toString cloudflarePrefix} dev eth1")

    with subtest("gated host needs a session"):
        expect(get(client, "${edgeIp}", "${gatedHost}"), "302")
        expect(get(client, "${internalIp}", "${gatedHost}"), "302")

    with subtest("forged X-Forwarded-Host cannot borrow the portal's bypass"):
        for ip in ("${edgeIp}", "${internalIp}"):
            expect(get(client, ip, "${gatedHost}", "X-Forwarded-Host: ${portalHost}"), "302")
            expect(get(client, ip, "${gatedHost}", "X-Forwarded-Host: ${portalHost}", "X-Forwarded-Uri: /"), "302")

    with subtest("authelia sees the host traefik routed"):
        auth.succeed("grep -qx '${gatedHost}' /tmp/forward-auth-hosts")
        auth.fail("grep -qx '${portalHost}' /tmp/forward-auth-hosts")

    with subtest("a session passes, with authelia's identity only"):
        expect(get(client, "${edgeIp}", "${gatedHost}", "Cookie: ${sessionCookie}", "Remote-User: admin"), "200", "user=alice")

    with subtest("no client-sent identity reaches an ungated app"):
        expect(get(client, "${edgeIp}", "${ownHost}", "Remote-User: admin"), "200", "user=-")
        expect(get(client, "${internalIp}", "${ownHost}", "Remote-User: admin"), "200", "user=-")

    with subtest("a forged X-Forwarded-Host reaches no backend"):
        for ip in ("${edgeIp}", "${internalIp}"):
            status, _, body = get(client, ip, "${ownHost}", "X-Forwarded-Host: evil.example").partition("\n")
            assert status == "200" and "evil.example" not in body, body

    with subtest("a direct client is its own client, whatever it claims"):
        expect(get(client, "${edgeIp}", "${ownHost}", "X-Real-Ip: 6.6.6.6", "X-Forwarded-For: 7.7.7.7"), "200", "client=${clientIp} xff=${clientIp}\n")
        expect(get(client, "${internalIp}", "${ownHost}", "X-Real-Ip: 6.6.6.6", "X-Forwarded-For: 7.7.7.7"), "200", "client=${clientIp} xff=${clientIp}\n")

    with subtest("through cloudflare and the relay, the backend and authelia see cloudflare's client"):
        # X-Forwarded-For is the client alone: a backend trusting its ingress needs no list of the hops before it
        expect(get(cf, "${edgeIp}", "${ownHost}", "X-Real-Ip: 6.6.6.6", "X-Forwarded-For: 1.2.3.4, ${realClient}", src="${cloudflareAddress}"),
               "200", "client=${realClient} xff=${realClient}\n")
        get(cf, "${edgeIp}", "${gatedHost}", "X-Forwarded-For: ${realClient}", src="${cloudflareAddress}")
        auth.succeed("grep -qx '${realClient}' /tmp/forward-auth-clients")
        # positive control: a lan source claiming cloudflare's hops is believed by nobody
        expect(get(client, "${edgeIp}", "${ownHost}", "X-Forwarded-For: ${realClient}"), "200", "client=${clientIp}")

    with subtest("a rotating forged X-Real-Ip does not dodge the per-client limit"):
        codes = flood("${realClient}", ${toString floodRequests})
        assert "429" in codes, f"no 429 in {len(codes)} answers: {sorted(set(codes))}"
        # positive control: another client behind cloudflare has its own bucket
        expect(get(cf, "${edgeIp}", "${ownHost}", "X-Forwarded-For: ${otherClient}", src="${cloudflareAddress}"), "200", "client=${otherClient}")

    with subtest("the portal itself stays open"):
        expect(get(client, "${edgeIp}", "${portalHost}"), "200")
  '';
}
