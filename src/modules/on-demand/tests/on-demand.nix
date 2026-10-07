# on-demand guests (modules/on-demand) against a fake proxmox api: wake on connect, sleep after the cooldown,
# the reaper, sibling routes on one guest, an lxc, a non-http backend, a boot past its timeout, the deploy pause, an
# orphaned proxy, each proxy's port fixed by its own guest, and the api call itself: its token from a header file
# (never in an argv) over tls pinned to the proxmox ca, a failed call an error the reaper exports
#
# `backend` stands in for proxmox and the guests: each fake guest is a unit there the fake api starts and stops.
# Nothing waits on the clock but the guest's own cooldown, observed through the fake api's call log and uptime.
{ pkgs, lib, ... }:
let
  cooldownSeconds = 20;
  cooldown = "${toString cooldownSeconds}s";
  apiPort = 8006;
  apiName = "pve";
  token = "test@pve!t=secret";
  bootTimeoutSeconds = 30;
  # a boot that never answers within this fails the held connection
  slowBootTimeoutSeconds = 5;

  # the guests: vmid -> the unit that "is" the guest on the backend, and its kind
  guests = {
    "150" = { unit = "nginx"; kind = "vm"; };
    "160" = { unit = "ct-app"; kind = "lxc"; };
    "170" = { unit = "slow-app"; kind = "vm"; };
  };
  ports = { app = 80; app2 = 81; ct = 7000; slow = 7001; };

  inventoryFor = ip: lib.mapAttrs (id: g: {
    name = "${id}-internal-test"; type = "internal"; inherit ip; powered = true; idle = cooldown; inherit (g) kind;
  }) guests;
  # the ca the proxy pins, a file the test swaps
  caFile = "/run/pve-ca.pem";
  # portBase + vmid x portsPerGuest + the slot in name order (modules/on-demand)
  listenPorts = { app = 21500; app2 = 21501; ct = 21600; slow = 21700; };

  pki = pkgs.runCommand "fake-pve-pki" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out && cd $out
    for ca in ca other-ca; do
      openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 -subj "/CN=$ca" \
        -keyout $ca.key -out $ca.pem
    done
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj /CN=${apiName} -keyout key.pem -out req.csr
    printf 'subjectAltName=DNS:${apiName}\n' > ext
    openssl x509 -req -in req.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 3650 -extfile ext -out cert.pem
  '';

  fakePve = pkgs.writers.writePython3 "fake-pve" { flakeIgnore = [ "E501" ]; } ''
    import http.server
    import json
    import ssl
    import subprocess
    import time

    UNITS = json.loads('${builtins.toJSON (lib.mapAttrs (_: g: g.unit) guests)}')
    KINDS = json.loads('${builtins.toJSON (lib.mapAttrs (_: g: g.kind) guests)}')
    booted = {}


    def running(vmid):
        return subprocess.run(["systemctl", "is-active", "--quiet", UNITS[vmid]]).returncode == 0


    class H(http.server.BaseHTTPRequestHandler):
        def reply(self, status, data):
            body = json.dumps({"data": data}).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def guest(self):
            # /api2/json/nodes/<node>/<qemu|lxc>/<vmid>/status/<action>
            parts = self.path.split("/")
            kind, vmid = parts[5], parts[6]
            if self.headers.get("Authorization") != "PVEAPIToken=${token}":
                return None, "unauthorized"
            if vmid not in UNITS or kind != {"vm": "qemu", "lxc": "lxc"}[KINDS[vmid]]:
                return None, "no such guest"
            return vmid, None

        def do_GET(self):
            vmid, error = self.guest()
            if error:
                return self.reply(401, error)
            up = running(vmid)
            self.reply(200, {"status": "running" if up else "stopped", "uptime": int(time.time() - booted.get(vmid, 0)) if up else 0})

        def do_POST(self):
            with open("/tmp/pve-calls", "a") as f:
                f.write(self.path + "\n")
            vmid, error = self.guest()
            if error:
                return self.reply(401, error)
            if self.path.endswith("/status/start"):
                booted[vmid] = time.time()
                subprocess.Popen(["systemctl", "start", UNITS[vmid]])
                self.reply(200, "UPID:start")
            elif self.path.endswith("/status/shutdown"):
                subprocess.Popen(["systemctl", "stop", UNITS[vmid]])
                self.reply(200, "UPID:shutdown")
            else:
                self.reply(404, "no such action")

        def log_message(self, *args):
            pass


    srv = http.server.ThreadingHTTPServer(("0.0.0.0", ${toString apiPort}), H)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain("${pki}/cert.pem", "${pki}/key.pem")
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    srv.serve_forever()
  '';

  # a guest that speaks no http: a greeting and close
  greeter = pkgs.writers.writePython3 "greeter" { } ''
    import socketserver


    class H(socketserver.BaseRequestHandler):
        def handle(self):
            self.request.sendall(b"hello from the container\n")


    socketserver.ThreadingTCPServer.allow_reuse_address = True
    socketserver.ThreadingTCPServer(("0.0.0.0", ${toString ports.ct}), H).serve_forever()
  '';

  # a guest that answers only once the test says it booted
  slowApp = pkgs.writeShellScript "slow-app" ''
    while [ ! -e /run/slow-ready ]; do ${pkgs.coreutils}/bin/sleep 0.2; done
    exec ${pkgs.python3}/bin/python3 -m http.server ${toString ports.slow}
  '';

  # every command line on the proxy while a wake runs; the brackets keep its own grep out of what it finds
  leakSampler = pkgs.writeShellScript "leak-sampler" ''
    export PATH=${lib.makeBinPath [ pkgs.procps pkgs.gnugrep pkgs.coreutils ]}
    for _ in $(seq 400); do ps -eo args; done | grep -E 'PVEAPI[T]oken|t=secre[t]' > /tmp/leak
    touch /tmp/leak-done
  '';
  # a client holding one connection open: port, seconds
  holdConnection = pkgs.writeShellScript "hold-connection" ''
    exec 3<>/dev/tcp/127.0.0.1/$1
    ${pkgs.coreutils}/bin/sleep "$2"
  '';
in
pkgs.testers.runNixOSTest {
  name = "on-demand";

  nodes.backend = {
    networking.firewall.allowedTCPPorts = lib.attrValues ports ++ [ apiPort ];
    # the "vm", started only via the fake api
    services.nginx = {
      enable = true;
      virtualHosts.default = {
        listen = [ { addr = "0.0.0.0"; port = ports.app; } ];
        locations."/".return = "200 'hello from the app\\n'";
        # busy while the test holds the flag
        locations."= /busy".extraConfig = "if (-f /run/busy) { return 200; } return 404;";
      };
      virtualHosts.second = {
        listen = [ { addr = "0.0.0.0"; port = ports.app2; } ];
        locations."/".return = "200 'hello from the second route\\n'";
      };
    };
    systemd.services.nginx.wantedBy = lib.mkForce [ ];
    systemd.services.ct-app.serviceConfig.ExecStart = greeter;
    systemd.services.slow-app.serviceConfig.ExecStart = slowApp;
    systemd.services.fake-pve = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = fakePve;
    };
  };

  nodes.proxy = { config, nodes, ... }: {
    imports = [ ../default.nix ../../textfile.nix ../../../tests/stubs/sops.nix ];
    _module.args = { inventory = inventoryFor nodes.backend.networking.primaryIPAddress; site = { }; };
    environment.systemPackages = [ pkgs.curl pkgs.netcat-gnu pkgs.jq ];
    networking.hosts.${nodes.backend.networking.primaryIPAddress} = [ apiName ];
    testing.secretValues.proxmox-wake-token-internal = token;
    systemd.tmpfiles.rules = [ "C ${caFile} 0644 root root - ${pki}/ca.pem" "d ${config.homelab.textfileDir} 0755 root root -" ];
    homelab.onDemand = {
      enable = true;
      side = "internal";
      apiUrl = "https://${apiName}:${toString apiPort}/api2/json";
      inherit caFile;
      node = "pve";
      services = {
        app = { vmid = 150; targetPort = ports.app; bootTimeout = bootTimeoutSeconds; busyPath = "/busy"; wakeAt = "03:00"; };
        app2 = { vmid = 150; targetPort = ports.app2; bootTimeout = bootTimeoutSeconds; };
        ct = { vmid = 160; targetPort = ports.ct; bootTimeout = bootTimeoutSeconds; httpCheck = false; };
        slow = { vmid = 170; targetPort = ports.slow; bootTimeout = slowBootTimeoutSeconds; };
      };
    };
  };

  testScript = { nodes, ... }: let
    port = name: toString nodes.proxy.homelab.onDemand.services.${name}.listenPort;
    pauseFile = nodes.proxy.homelab.onDemand.pauseFile;
    metrics = "${nodes.proxy.homelab.textfileDir}/ondemand.prom";
  in ''
    API = "https://${apiName}:${toString apiPort}/api2/json/nodes/pve"

    def calls():
        return backend.succeed("cat /tmp/pve-calls 2>/dev/null || true")

    def wait_past_cooldown(path):
        # the guest's own clock, read from the api: no fixed sleep
        proxy.wait_until_succeeds(f"[ $(curl -sf --cacert ${pki}/ca.pem -H 'Authorization: PVEAPIToken=${token}' {API}/{path}/status/current | jq .data.uptime) -ge ${toString cooldownSeconds} ]", timeout=90)

    def reap():
        proxy.succeed("systemctl start ondemand-reaper.service")

    def hold(name, port, seconds):
        # a client keeping one connection open, in its own unit so it outlives the driver's command
        proxy.succeed(f"systemd-run --unit=hold-{name}-{seconds} ${holdConnection} {port} {seconds}")

    start_all()
    backend.wait_for_unit("fake-pve.service")
    backend.wait_for_open_port(${toString apiPort})
    proxy.wait_for_unit("sockets.target")
    backend.fail("systemctl is-active nginx")

    with subtest("each route listens on the port its own guest fixes"):
        for name, expected in ${builtins.toJSON listenPorts}.items():
            proxy.succeed(f"systemctl is-active ondemand-{name}.socket")
            proxy.succeed(f"ss -Hltn 'sport = :{expected}' | grep -q LISTEN")

    with subtest("first request boots the guest and is answered; the token is never on a command line"):
        # the brackets keep the sampler's own grep out of what it finds
        proxy.succeed("systemd-run --unit=leak-sampler ${leakSampler}")
        out = proxy.succeed("curl -sf --max-time 90 http://127.0.0.1:${port "app"}/")
        assert "hello from the app" in out, out
        backend.succeed("systemctl is-active nginx")
        assert "/qemu/150/status/start" in calls()
        proxy.wait_for_file("/tmp/leak-done")
        proxy.succeed("[ ! -s /tmp/leak ]")

    with subtest("the guest powers off after the cooldown without connections"):
        backend.wait_until_fails("systemctl is-active nginx", timeout=120)
        assert "/qemu/150/status/shutdown" in calls()

    with subtest("a proxmox answering with a certificate of another ca gets no call, and the reaper says so"):
        backend.succeed("rm -f /tmp/pve-calls")
        proxy.succeed("cp ${pki}/other-ca.pem ${caFile}")
        proxy.fail("curl -sf --max-time 20 http://127.0.0.1:${port "app2"}/")
        assert calls() == "", calls()
        backend.fail("systemctl is-active nginx")
        proxy.fail("systemctl start ondemand-reaper.service")
        proxy.succeed("grep -qx 'homelab_ondemand_api_ok{service=\"app2\",target=\"vm-150\"} 0' ${metrics}")
        # positive control: with the proxmox ca back, the reaper's calls answer and the same request wakes it
        proxy.succeed("cp ${pki}/ca.pem ${caFile}")
        reap()
        proxy.succeed("grep -qx 'homelab_ondemand_api_ok{service=\"app2\",target=\"vm-150\"} 1' ${metrics}")
        out = proxy.succeed("curl -sf --max-time 90 http://127.0.0.1:${port "app2"}/")
        assert "hello from the second route" in out, out
        backend.wait_until_fails("systemctl is-active nginx", timeout=120)

    with subtest("a sibling route keeps the shared guest up while it serves"):
        proxy.succeed("curl -sf --max-time 90 http://127.0.0.1:${port "app"}/")
        # app2 holds a connection well past the cooldown; app's proxy idles out meanwhile
        hold("app2", ${port "app2"}, 60)
        proxy.wait_until_succeeds("systemctl is-active ondemand-app2.service")
        proxy.wait_until_fails("systemctl is-active ondemand-app.service", timeout=90)
        backend.succeed("systemctl is-active nginx")
        # positive control: once the sibling idles out too, the guest goes
        backend.wait_until_fails("systemctl is-active nginx", timeout=150)

    with subtest("the reaper stops a guest started without any connection, never a young one"):
        backend.succeed("rm -f /tmp/pve-calls")
        proxy.succeed(f"curl -sf -X POST --cacert ${pki}/ca.pem -H 'Authorization: PVEAPIToken=${token}' {API}/qemu/150/status/start")
        backend.wait_for_unit("nginx.service")
        reap()
        backend.succeed("systemctl is-active nginx")
        wait_past_cooldown("qemu/150")
        reap()
        backend.wait_until_fails("systemctl is-active nginx", timeout=30)
        assert "/qemu/150/status/shutdown" in calls()

    with subtest("a deploy's pause holds both the reaper and the idle shutdown"):
        proxy.succeed("echo $(( $(date +%s) + 3600 )) > ${pauseFile}")
        proxy.succeed("curl -sf --max-time 90 http://127.0.0.1:${port "app"}/")
        proxy.wait_until_fails("systemctl is-active ondemand-app.service", timeout=90)
        wait_past_cooldown("qemu/150")
        reap()
        backend.succeed("systemctl is-active nginx")
        # positive control: the pause lifted, the reaper takes it
        proxy.succeed("rm ${pauseFile}")
        reap()
        backend.wait_until_fails("systemctl is-active nginx", timeout=30)

    with subtest("an orphaned proxy is re-armed after its guest was stopped behind its back"):
        proxy.succeed("curl -sf --max-time 90 http://127.0.0.1:${port "app"}/")
        hold("app", ${port "app"}, 30)
        proxy.succeed(f"curl -sf -X POST --cacert ${pki}/ca.pem -H 'Authorization: PVEAPIToken=${token}' {API}/qemu/150/status/shutdown")
        backend.wait_until_fails("systemctl is-active nginx", timeout=30)
        proxy.succeed("systemctl is-active ondemand-app.service")
        reap()
        proxy.fail("systemctl is-active ondemand-app.service")
        out = proxy.succeed("curl -sf --max-time 90 http://127.0.0.1:${port "app"}/")
        assert "hello from the app" in out, out
        backend.wait_until_fails("systemctl is-active nginx", timeout=150)

    # the reaper also walks app2, the sibling without a busyPath: busy is the guest's, not the route's
    with subtest("a busy guest outlives its idle proxy and the reaper, and goes once the work is done"):
        proxy.succeed("curl -sf --max-time 90 http://127.0.0.1:${port "app"}/")
        backend.succeed("touch /run/busy")
        proxy.wait_until_fails("systemctl is-active ondemand-app.service", timeout=90)
        wait_past_cooldown("qemu/150")
        reap()
        backend.succeed("systemctl is-active nginx")
        backend.succeed("rm /run/busy")
        reap()
        backend.wait_until_fails("systemctl is-active nginx", timeout=30)

    with subtest("an lxc guest is woken through the lxc api, a non-http one by its open port"):
        out = proxy.succeed("nc -w 10 127.0.0.1 ${port "ct"} </dev/null")
        assert "hello from the container" in out, out
        assert "/lxc/160/status/start" in calls()
        backend.wait_until_fails("systemctl is-active ct-app", timeout=120)

    with subtest("a boot past its timeout fails the connection, the next one retries"):
        proxy.fail("curl -sf --max-time 60 http://127.0.0.1:${port "slow"}/")
        backend.succeed("touch /run/slow-ready")
        proxy.wait_until_succeeds("curl -sf --max-time 60 http://127.0.0.1:${port "slow"}/", timeout=120)

    with subtest("wakeAt boots the guest without a request"):
        proxy.succeed("systemctl list-timers --all | grep -q ondemand-wakeat-app.timer")
        proxy.succeed("systemctl start ondemand-wakeat-app.service")
        backend.succeed("systemctl is-active nginx")
  '';
}
