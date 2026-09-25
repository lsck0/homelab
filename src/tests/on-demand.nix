# On-demand VMs: wake on first connection, power off after the cooldown
{ pkgs, lib, ... }:
let
  inventory = {
    "150" = { name = "150-internal-app"; type = "internal"; ip = "192.168.1.1"; enabled = "onDemand"; cooldown = "20s"; };
  };

  cert = pkgs.runCommand "fake-pve-cert" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=pve \
      -keyout $out/key.pem -out $out/cert.pem
  '';

  fakePve = pkgs.writers.writePython3 "fake-pve" { flakeIgnore = [ "E501" ]; } ''
    import http.server
    import json
    import ssl
    import subprocess
    import time

    booted = [0.0]


    def running():
        return subprocess.run(["systemctl", "is-active", "--quiet", "nginx"]).returncode == 0


    class H(http.server.BaseHTTPRequestHandler):
        def reply(self, data):
            body = json.dumps({"data": data}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path.endswith("/status/current"):
                up = running()
                self.reply({"status": "running" if up else "stopped",
                            "uptime": int(time.time() - booted[0]) if up else 0})
            else:
                self.send_error(404)

        def do_POST(self):
            with open("/tmp/pve-calls", "a") as f:
                f.write(self.path + "\n")
            if self.path.endswith("/status/start"):
                booted[0] = time.time()
                subprocess.Popen(["systemctl", "start", "nginx"])
                self.reply("UPID:start")
            elif self.path.endswith("/status/shutdown"):
                subprocess.Popen(["systemctl", "stop", "nginx"])
                self.reply("UPID:shutdown")
            else:
                self.send_error(404)


    srv = http.server.HTTPServer(("0.0.0.0", 8006), H)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain("${cert}/cert.pem", "${cert}/key.pem")
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    srv.serve_forever()
  '';
in
pkgs.testers.runNixOSTest {
  name = "on-demand";

  nodes.backend = {
    networking.firewall.allowedTCPPorts = [ 80 8006 ];
    # the "VM": not started at boot, only through the fake Proxmox API.
    services.nginx = {
      enable = true;
      virtualHosts.default.locations."/".return = "200 'hello from the app\\n'";
    };
    systemd.services.nginx.wantedBy = lib.mkForce [ ];
    systemd.services.fake-pve = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = fakePve;
    };
  };

  nodes.proxy = {
    imports = [ ../modules/on-demand.nix ];
    _module.args.inventory = inventory;
    environment.systemPackages = [ pkgs.curl ];
    environment.etc."pve-token".text = "test@pve!t=secret";
    homelab.onDemand = {
      enable = true;
      side = "internal";
      apiUrl = "https://backend:8006/api2/json";
      node = "pve";
      tokenFile = "/etc/pve-token";
      services.app = { vmid = 150; targetPort = 80; listenPort = 20000; bootTimeout = 60; };
    };
  };

  testScript = ''
    start_all()
    backend.wait_for_unit("fake-pve.service")
    backend.wait_for_open_port(8006)
    proxy.wait_for_unit("sockets.target")
    backend.fail("systemctl is-active nginx")

    with subtest("address points Traefik at the local wake proxy"):
        proxy.succeed("systemctl is-active ondemand-app.socket")

    with subtest("first request boots the VM and is answered"):
        out = proxy.succeed("curl -sf --max-time 90 http://127.0.0.1:20000/")
        assert "hello from the app" in out, out
        backend.succeed("systemctl is-active nginx")
        backend.succeed("grep -q /status/start /tmp/pve-calls")

    with subtest("VM powers off after the cooldown without connections"):
        backend.wait_until_fails("systemctl is-active nginx", timeout=120)
        backend.succeed("grep -q /status/shutdown /tmp/pve-calls")

    with subtest("next request wakes it again"):
        out = proxy.succeed("curl -sf --max-time 90 http://127.0.0.1:20000/")
        assert "hello from the app" in out, out
        backend.wait_until_fails("systemctl is-active nginx", timeout=120)

    with subtest("reaper stops a VM started without any connection"):
        backend.succeed("rm -f /tmp/pve-calls")
        proxy.succeed("curl -sfk -X POST https://backend:8006/api2/json/nodes/pve/qemu/150/status/start")
        backend.wait_for_unit("nginx.service")
        proxy.succeed("systemctl start ondemand-reaper.service")
        backend.succeed("systemctl is-active nginx")  # younger than the cooldown: kept
        proxy.sleep(25)
        proxy.succeed("systemctl start ondemand-reaper.service")
        backend.wait_until_fails("systemctl is-active nginx", timeout=30)
        backend.succeed("grep -q /status/shutdown /tmp/pve-calls")

    with subtest("reaper leaves a VM alone while its proxy is serving"):
        proxy.succeed("curl -sf --max-time 90 http://127.0.0.1:20000/")
        # hold a connection open past the cooldown
        proxy.succeed("(exec 3<>/dev/tcp/127.0.0.1/20000; sleep 40) >/dev/null 2>&1 &")
        proxy.sleep(25)
        proxy.succeed("systemctl start ondemand-reaper.service")
        backend.succeed("systemctl is-active nginx")
  '';
}
