{ lib, pkgs, inventory, nasMount, retry, ... }:
let
  # one HTTP monitor per route (modules/routes.nix) whose VM is always on.
  # on-demand VMs sleep by design and disabled ones are off, so neither is
  # monitored (a probe would also wake nothing: it goes straight to the VM).
  routes = import ../modules/routes.nix;
  # a route with monitor = false is deliberately not probed (see routes.nix).
  alwaysOn = r: (inventory.${toString r.vmid}.enabled or "false") == "true"
    && (r.monitor or true);
  httpMonitors = lib.concatLists (lib.mapAttrsToList (_: side:
    lib.mapAttrsToList (_: r: {
      name = r.host;
      url = "${r.scheme or "http"}://${inventory.${toString r.vmid}.ip}:${toString r.port}";
    }) (lib.filterAttrs (_: alwaysOn) side)
  ) routes);
  monitors = lib.sort (a: b: a.name < b.name) httpMonitors ++ [
    { name = "traefik-internal"; url = "http://10.100.0.100:80"; }
    { name = "traefik-external"; url = "http://10.200.0.200:80"; }
    { name = "sccache"; url = "10.100.0.111"; type = "port"; port = 6379; }
  ];

  setupJs = pkgs.writeText "uptime-setup.js" ''
    const { io } = require("/app/node_modules/socket.io-client");
    const monitors = ${builtins.toJSON monitors};

    const socket = io("http://127.0.0.1:3001", { reconnection: false, timeout: 10000 });

    function send(event, ...args) {
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error("timeout")), 10000);
        socket.emit(event, ...args, (res) => {
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

      const password = process.env.KUMA_PASS;
      if (!password) throw new Error("KUMA_PASS is not set");
      try {
        await send("setup", "admin", password);
        console.log("Admin created");
      } catch (e) {
        console.log("Setup:", e.message);
      }

      try {
        await send("login", { username: "admin", password, token: "" });
      } catch (e) {
        // installs from before generated passwords still have the old default.
        const old = "changeme123!";
        await send("login", { username: "admin", password: old, token: "" });
        await send("changePassword", { currentPassword: old, newPassword: password });
        console.log("admin moved off the default password");
      }
      console.log("Logged in");

      const existing = await new Promise((resolve) => {
        socket.once("monitorList", resolve);
        send("getMonitorList", {}).catch(() => {});
        setTimeout(() => resolve({}), 5000);
      });

      const existingByName = {};
      for (const [id, mon] of Object.entries(existing)) {
        existingByName[mon.name] = { id: Number(id), ...mon };
      }

      for (const m of monitors) {
        const ex = existingByName[m.name];
        if (ex && ex.url === m.url) {
          console.log("Exists:", m.name);
          continue;
        }
        if (ex) {
          try {
            await send("editMonitor", { ...ex, url: m.url, hostname: m.url.replace(/https?:\/\//, "").replace(/:\d+$/, "") });
            console.log("Updated:", m.name, "->", m.url);
          } catch (e) {
            console.error("Update failed:", m.name, e.message);
          }
          continue;
        }
        try {
          await send("add", {
            type: m.type || "http",
            name: m.name,
            url: m.url,
            hostname: m.url.replace(/https?:\/\//, "").replace(/:\d+$/, ""),
            port: m.port || undefined,
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

      const configNames = new Set(monitors.map(m => m.name));
      for (const [id, mon] of Object.entries(existing)) {
        if (!configNames.has(mon.name)) {
          try {
            await send("deleteMonitor", Number(id));
            console.log("Deleted:", mon.name);
          } catch (e) {
            console.error("Delete failed:", mon.name, e.message);
          }
        }
      }

      // Create "homelab" status page with all monitors
      try {
        await send("addStatusPage", "Homelab", "homelab");
        console.log("Status page created");
      } catch (e) {
        console.log("Status page:", e.message);
      }

      // Re-fetch monitors to get all IDs
      const allMonitors = await new Promise((resolve) => {
        socket.once("monitorList", resolve);
        send("getMonitorList", {}).catch(() => {});
        setTimeout(() => resolve({}), 5000);
      });

      try {
        await send("saveStatusPage", "homelab", { title: "Homelab" }, null, [{
          name: "Services",
          monitorList: Object.keys(allMonitors).map(id => ({
            id: Number(id),
            name: allMonitors[id].name,
          })),
        }]);
        console.log("Status page updated with all monitors");
      } catch (e) {
        console.error("Status page update:", e.message);
      }

      socket.disconnect();
    }

    main().then(() => process.exit(0)).catch(e => { console.error(e); process.exit(1); });
  '';
in {
  networking.hostName = "vm-106";

  fileSystems = nasMount "/var/lib/uptime-kuma" "uptime-kuma";

  virtualisation.oci-containers.containers.uptime-kuma = {
    image = "louislam/uptime-kuma:1.23.17";
    ports = [ "80:3001" ];
    volumes = [ "/var/lib/uptime-kuma:/app/data" ];
  };

  systemd.services.uptime-kuma-monitors = {
    description = "Configure Uptime Kuma monitors";
    after = [ "podman-uptime-kuma.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "uptime-kuma-monitors" ''
        ${retry} 90 2 ${pkgs.curl}/bin/curl -sf http://127.0.0.1:80
        sleep 5

        pass=/var/lib/uptime-kuma/admin-pass
        [ -s $pass ] || ${pkgs.openssl}/bin/openssl rand -hex 16 | tr -d '\n' > $pass
        chmod 600 $pass

        ${pkgs.podman}/bin/podman cp ${setupJs} uptime-kuma:/tmp/setup.js
        ${pkgs.podman}/bin/podman exec -e KUMA_PASS="$(cat $pass)" uptime-kuma node /tmp/setup.js

        # disable built-in auth (authelia ForwardAuth handles access control)
        ${pkgs.podman}/bin/podman exec uptime-kuma sqlite3 /app/data/kuma.db \
          "INSERT OR REPLACE INTO setting (key, value) VALUES ('disableAuth', 'true');"
      '';
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/uptime-kuma 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];

  # built-in auth is switched off (disableAuth), so the only path in must be the
  # Authelia-gated Traefik route.
  homelab.ingressOnly.ports = [ 80 ];
}
