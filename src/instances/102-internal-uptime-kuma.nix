{ pkgs, ... }:
let
  monitors = [
    { name = "Traefik (internal)"; url = "http://10.100.0.100:80"; }
    { name = "Authentik";          url = "http://10.100.0.101:80"; }
    { name = "Uptime Kuma";        url = "http://10.100.0.102:80"; }
    { name = "Forgejo";            url = "http://10.100.0.103:80"; }
    { name = "Forgejo Runner";     url = "http://10.100.0.104:80"; type = "ping"; }
    { name = "Registry";           url = "http://10.100.0.106:80"; }
    { name = "Homepage";           url = "http://10.100.0.108:80"; }
    { name = "Vaultwarden";        url = "http://10.100.0.109:8080"; }
    { name = "Taskchampion";       url = "http://10.100.0.110:8080"; }
    { name = "Nextcloud";          url = "http://10.100.0.111:80"; }
    { name = "Paperless";          url = "http://10.100.0.112:8080"; }
    { name = "Jellyfin";           url = "http://10.100.0.113:80"; }
    { name = "Huginn";             url = "http://10.100.0.114:80"; }
    { name = "Home Assistant";     url = "http://10.100.0.115:80"; }
    { name = "Traefik (external)"; url = "http://10.200.0.200:80"; }
    { name = "Shlink";             url = "http://10.200.0.201:80"; }
    { name = "PrivateBin";         url = "http://10.200.0.202:80"; }
    { name = "Share";              url = "http://10.200.0.203:80"; }
    { name = "Grafana";            url = "http://10.100.0.141:3000"; }
  ];

  setupJs = pkgs.writeText "uptime-setup.js" ''
    const { io } = require("socket.io-client");
    const monitors = ${builtins.toJSON monitors};

    const socket = io("http://127.0.0.1:3001", { reconnection: false, timeout: 10000 });

    function send(event, data) {
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error("timeout")), 10000);
        socket.emit(event, data, (res) => {
          clearTimeout(timer);
          if (res.ok) resolve(res);
          else reject(new Error(res.msg || JSON.stringify(res)));
        });
      });
    }

    async function main() {
      await new Promise((resolve, reject) => {
        socket.on("connect", resolve);
        socket.on("connect_error", reject);
        setTimeout(() => reject(new Error("connect timeout")), 15000);
      });

      try {
        await send("setup", { username: "admin", password: "changeme123!" });
        console.log("Admin created");
      } catch (e) {
        if (!e.message.includes("setup")) console.log("Setup:", e.message);
      }

      await send("login", { username: "admin", password: "changeme123!", token: "" });
      console.log("Logged in");

      const existing = await new Promise((resolve) => {
        socket.once("monitorList", resolve);
        send("getMonitorList", {}).catch(() => {});
        setTimeout(() => resolve({}), 5000);
      });

      const existingNames = new Set(Object.values(existing).map(m => m.name));

      for (const m of monitors) {
        if (existingNames.has(m.name)) {
          console.log("Exists:", m.name);
          continue;
        }
        try {
          await send("add", {
            type: m.type || "http",
            name: m.name,
            url: m.url,
            hostname: m.url.replace(/https?:\/\//, "").replace(/:\d+$/, ""),
            interval: 60,
            retryInterval: 30,
            maxretries: 3,
            accepted_statuscodes: ["200-499"],
            ignoreTls: true,
          });
          console.log("Added:", m.name);
        } catch (e) {
          console.error("Failed:", m.name, e.message);
        }
      }

      socket.disconnect();
    }

    main().then(() => process.exit(0)).catch(e => { console.error(e); process.exit(1); });
  '';
in {
  networking.hostName = "vm-102";

  virtualisation.oci-containers.containers.uptime-kuma = {
    image = "louislam/uptime-kuma:latest";
    ports = [ "80:3001" ];
    volumes = [ "/var/lib/uptime-kuma:/app/data" ];
  };

  # Run setup script inside container (has socket.io-client already)
  systemd.services.uptime-kuma-monitors = {
    description = "Configure Uptime Kuma monitors";
    after = [ "podman-uptime-kuma.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "uptime-kuma-monitors" ''
        # Wait for Uptime Kuma to be ready
        for i in $(seq 1 90); do
          if ${pkgs.curl}/bin/curl -sf http://127.0.0.1:3001 >/dev/null 2>&1; then break; fi
          sleep 2
        done
        sleep 5

        # Copy setup script into container and run with its Node.js
        ${pkgs.podman}/bin/podman cp ${setupJs} uptime-kuma:/tmp/setup.js
        ${pkgs.podman}/bin/podman exec uptime-kuma node /tmp/setup.js
      '';
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/uptime-kuma 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
