# external traefik -> internal traefik -> authelia forwardauth: no client header may pick the auth decision
{ pkgs, lib, ... }:
let
  portalHost = "auth.lsck0.dev";
  gatedHost = "backup.lsck0.dev";
  # no forwardauth in front, like forgejo or headscale
  ownHost = "git.lsck0.dev";
  sessionCookie = "authelia_session=valid";
  stubPort = 9091;
  backendPort = 8000;

  # authelia's decision as the real access_control makes it: the portal is bypass, the rest needs a session
  autheliaStub = pkgs.writers.writePython3 "authelia-stub" { flakeIgnore = [ "E501" ]; } ''
    import http.server


    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            host = self.headers.get("X-Forwarded-Host", "")
            with open("/tmp/forward-auth-hosts", "a") as f:
                f.write(host + "\n")
            with open("/tmp/forward-auth-clients", "a") as f:
                f.write(self.headers.get("X-Forwarded-For", "") + "\n")
            if host == "${portalHost}":
                self.send_response(200)
            elif "${sessionCookie}" in self.headers.get("Cookie", ""):
                self.send_response(200)
                self.send_header("Remote-User", "alice")
                self.send_header("Remote-Groups", "users")
            else:
                self.send_response(302)
                self.send_header("Location", "https://${portalHost}/")
            self.send_header("Content-Length", "0")
            self.end_headers()


    http.server.HTTPServer(("0.0.0.0", ${toString stubPort}), H).serve_forever()
  '';

  # echoes what a trusting app would see
  backend = pkgs.writers.writePython3 "echo-backend" { flakeIgnore = [ "E501" ]; } ''
    import http.server


    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = "user=%s host=%s\n" % (self.headers.get("Remote-User", "-"), self.headers.get("X-Forwarded-Host", "-"))
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body.encode())


    http.server.HTTPServer(("0.0.0.0", ${toString backendPort}), H).serve_forever()
  '';

  traefikNode = extra: { config, ... }: {
    imports = [ ../modules/retry.nix ../modules/traefik.nix ./stubs.nix extra ];
    options.homelab.acmeEmail = lib.mkOption { type = lib.types.str; default = "test@example.invalid"; };
    config = {
      # the crowdsec log parser needs an image pull, none of it is under test
      virtualisation.oci-containers.containers = lib.mkForce { };
      # traefik waits for the nas-held acme store otherwise; offline it serves its default cert
      systemd.tmpfiles.rules = [ "f /var/lib/traefik/acme/acme.json 0600 traefik traefik -" ];
    };
  };

  hostRule = host: "Host(`${host}`)";
in
pkgs.testers.runNixOSTest {
  name = "auth-chain";

  nodes.auth = {
    networking.firewall.allowedTCPPorts = [ stubPort backendPort ];
    systemd.services.authelia-stub = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = autheliaStub;
    };
    systemd.services.echo-backend = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = backend;
    };
  };

  # vm-100: gates sso routes, trusts forwarded headers from the edge only
  nodes.internal = { nodes, ... }: {
    imports = [ (traefikNode {
      homelab.traefik = let backendUrl = "http://${nodes.auth.networking.primaryIPAddress}:${toString backendPort}"; in {
        enable = true;
        trustedProxies = [ "${nodes.edge.networking.primaryIPAddress}/32" ];
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

  # vm-200: trusts cloudflare and private ranges, relays every host to internal
  nodes.edge = { nodes, ... }: {
    imports = [ (traefikNode {
      homelab.traefik = {
        enable = true;
        trustCloudflare = true;
        routers.internal-relay = {
          rule = "HostRegexp(`^[a-z0-9-]+\\.lsck0\\.dev$`)";
          service = "internal-relay";
          entryPoints = [ "websecure" ];
          priority = 1;
        };
        services.internal-relay.loadBalancer = {
          servers = [{ url = "https://${nodes.internal.networking.primaryIPAddress}:443"; }];
          serversTransport = "internal-relay";
          passHostHeader = true;
        };
        serversTransports.internal-relay.insecureSkipVerify = true;
      };
    }) ];
  };

  nodes.client = { environment.systemPackages = [ pkgs.curl ]; };

  testScript = { nodes, ... }: let
    edgeIp = nodes.edge.networking.primaryIPAddress;
    internalIp = nodes.internal.networking.primaryIPAddress;
    clientIp = nodes.client.networking.primaryIPAddress;
  in ''
    def get(ip, host, *headers):
        flags = " ".join(f"-H '{h}'" for h in headers)
        return client.succeed(
            f"curl -sk -o /tmp/body -w '%{{http_code}}' --resolve {host}:443:{ip} {flags} https://{host}/ ; echo; cat /tmp/body"
        )

    def expect(result, code, body=None):
        status, _, rest = result.partition("\n")
        assert status == code, f"expected {code}, got {status}: {rest}"
        if body is not None:
            assert body in rest, f"expected {body!r} in {rest!r}"

    start_all()
    auth.wait_for_open_port(${toString stubPort})
    auth.wait_for_open_port(${toString backendPort})
    for node in (internal, edge):
        node.wait_for_unit("traefik.service")
        node.wait_for_open_port(443)

    with subtest("gated host needs a session"):
        expect(get("${edgeIp}", "${gatedHost}"), "302")
        expect(get("${internalIp}", "${gatedHost}"), "302")

    with subtest("forged X-Forwarded-Host cannot borrow the portal's bypass"):
        for ip in ("${edgeIp}", "${internalIp}"):
            expect(get(ip, "${gatedHost}", "X-Forwarded-Host: ${portalHost}"), "302")
            expect(get(ip, "${gatedHost}", "X-Forwarded-Host: ${portalHost}", "X-Forwarded-Uri: /"), "302")

    with subtest("authelia sees the host traefik routed"):
        auth.succeed("grep -qx '${gatedHost}' /tmp/forward-auth-hosts")
        auth.fail("grep -qx '${portalHost}' /tmp/forward-auth-hosts")

    with subtest("a session passes, with authelia's identity only"):
        expect(get("${edgeIp}", "${gatedHost}", "Cookie: ${sessionCookie}", "Remote-User: admin"), "200", "user=alice")

    with subtest("no client-sent identity reaches an ungated app"):
        expect(get("${edgeIp}", "${ownHost}", "Remote-User: admin"), "200", "user=-")
        expect(get("${internalIp}", "${ownHost}", "Remote-User: admin"), "200", "user=-")

    with subtest("a forged X-Forwarded-Host reaches no backend"):
        for ip in ("${edgeIp}", "${internalIp}"):
            status, _, body = get(ip, "${ownHost}", "X-Forwarded-Host: evil.example").partition("\n")
            assert status == "200" and "evil.example" not in body, body

    with subtest("authelia sees the real client, not the relay"):
        auth.succeed("grep -q '^${clientIp}' /tmp/forward-auth-clients")
        auth.fail("grep -qx '${edgeIp}' /tmp/forward-auth-clients")

    with subtest("the portal itself stays open"):
        expect(get("${edgeIp}", "${portalHost}"), "200")
  '';
}
