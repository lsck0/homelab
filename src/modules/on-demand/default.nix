# idle deployments (the `idle` property): an ingress's local proxy wakes a sleeping deployment on its first
# connection, holds it until the backend answers, and stops the deployment after its idle time without connections
#
# One mechanism, two backends: a vm (an instance with idle set) is powered through the proxmox api, a swarm app
# through its manager's controller (POST /wake/<app>, POST /sleep/<app>, GET /state/<app>, modules/swarm). Every
# script below speaks to either through the same power_* shell functions.
#
# The proxmox api is called with the side's own token (scripts/pve-install.sh: wake-<side>@pve, VM.Audit and
# VM.PowerMgmt on each of the side's onDemand guests, granted per guest by terraform/lib.tf), read by curl from a header
# file sops renders, never from a command line, over tls verified against the proxmox root ca.
{ config, lib, pkgs, inventory, site, ... }:
let
  cfg = config.homelab.onDemand;
  net = import ../net.nix { inherit lib inventory site; };
  loopback = "127.0.0.1";
  authHeaderTemplate = "ondemand-proxmox-auth";
  tokenSecret = "proxmox-wake-token-${cfg.side}";
  # the proxmox root ca (/etc/pve/pve-root-ca.pem) the api's certificate must chain to
  caSecret = "proxmox-ca";
  # the activation proxies' loopback ports, from here in the order of the service names
  portBase = 20000;

  # what a service wakes: a guest, or an app on its cluster; `key` names it in units and logs
  vmOf = svc: inventory.${toString svc.vmid};
  targetOf = svc:
    if svc.app == null then {
      key = "vm-${toString svc.vmid}";
      inherit (vmOf svc) ip cooldown;
      sleeps = (vmOf svc).enabled == "onDemand";
    } else {
      key = "app-${svc.app}";
      ip = svc.host;
      cooldown = svc.idleAfter;
      sleeps = true;
    };
  active = lib.filterAttrs (_: svc: (targetOf svc).sleeps) cfg.services;
  # every service of a deployment names its wake time; one wake per deployment, under its first service's name
  firstServiceOf = key: lib.head (lib.attrNames (lib.filterAttrs (_: s: (targetOf s).key == key) active));
  scheduled = lib.filterAttrs (name: svc: svc.wakeAt != null && name == firstServiceOf (targetOf svc).key) active;

  # several routes can share one deployment
  siblingsBusy = svc: lib.concatStrings (lib.mapAttrsToList (n: s:
    lib.optionalString ((targetOf s).key == (targetOf svc).key) ''
      systemctl is-active --quiet ondemand-${n}.service && exit 0
    '') active);

  # "15m" -> 900, the shape modules/service.nix types idle.stopAfter to
  toSeconds = s:
    let m = builtins.match "([0-9]+)(s|m|h|d)" s;
        unit = { s = 1; m = 60; h = 3600; d = 86400; };
    in assert lib.assertMsg (m != null) "on-demand cooldown '${s}' must look like 30s, 15m, 2h or 1d";
    lib.toInt (builtins.elemAt m 0) * unit.${builtins.elemAt m 1};

  # power_status (running, stopped or unknown), power_uptime (seconds), power_start, power_stop
  powerEnv = svc: if svc.app == null then ''
    API="${cfg.apiUrl}/nodes/${cfg.node}/${if (vmOf svc).kind or "vm" == "lxc" then "lxc" else "qemu"}/${toString svc.vmid}"
    pve() {
      curl -sf --max-time ${toString apiTimeoutSeconds} --cacert ${config.sops.secrets.${caSecret}.path} \
        -H @${config.sops.templates.${authHeaderTemplate}.path} "$@"
    }
    power_status() { pve "$API/status/current" | jq -r '.data.status // "unknown"'; }
    power_uptime() { pve "$API/status/current" | jq -r '.data.uptime // 0'; }
    power_start() { pve -X POST "$API/status/start" >/dev/null; }
    power_stop() { pve -X POST "$API/status/shutdown" >/dev/null; }
  '' else ''
    CONTROLLER="${svc.manager}"
    power_status() { curl -sf --max-time ${toString apiTimeoutSeconds} "$CONTROLLER/state/${svc.app}" || echo unknown; }
    # the controller keeps no uptime: an app is stopped by idle time alone
    power_uptime() { echo ${toString silentBusyUptimeMax}; }
    power_start() { curl -sf --max-time ${toString apiTimeoutSeconds} -X POST "$CONTROLLER/wake/${svc.app}" >/dev/null; }
    power_stop() { curl -sf --max-time ${toString apiTimeoutSeconds} -X POST "$CONTROLLER/sleep/${svc.app}" >/dev/null; }
  '';

  # silence from a saturated build counts as busy until this uptime; 21h stays clear of the next daily wakeAt
  silentBusyUptimeMax = 21 * 3600;
  # an api call on the house lan answers in milliseconds; this only bounds a hung one
  apiTimeoutSeconds = 20;

  # from portBase in service-name order: adding one renumbers the later ones, read only by their ingress (same attrset)
  listenPorts = lib.listToAttrs (lib.imap0 (i: name: lib.nameValuePair name (portBase + i)) (lib.attrNames cfg.services));

  # busy is the guest's: every route to it, a sibling without busyPath included, asks the one route that has it
  busyRouteOf = svc: lib.findFirst (s: (targetOf s).key == (targetOf svc).key && s.busyPath != null) null (lib.attrValues cfg.services);

  # exits the calling script while the vm reports work that must not be cut off; needs $uptime
  busyCheck = svc: let busy = busyRouteOf svc; in lib.optionalString (busy != null) ''
    busy=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://${(targetOf svc).ip}:${toString busy.targetPort}${busy.busyPath}" || true)
    [ "$busy" = 200 ] && { echo "${(targetOf svc).key} reports busy, leaving it up"; exit 0; }
    if [ "''${busy:-000}" = 000 ] && [ "$uptime" -lt ${toString silentBusyUptimeMax} ]; then
      echo "${(targetOf svc).key} does not answer its busy check, leaving it up"; exit 0
    fi
  '';

  pauseCheck = ''
    pause=$(cat ${cfg.pauseFile} 2>/dev/null || echo 0)
    [ "$(date +%s)" -lt "$pause" ] 2>/dev/null && { echo "paused by a deploy until $(date -d "@$pause")"; exit 0; }
  '';

  wakeScript = name: svc: pkgs.writeShellScript "ondemand-wake-${name}" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.netcat-gnu ]}"
    ${powerEnv svc}

    # two good checks: a shutting-down vm still accepts briefly (502)
    good=0
    for i in $(seq 1 ${toString svc.bootTimeout}); do
      # recheck power state every 10s; api errors retry
      if [ $((i % 10)) -eq 1 ]; then
        STATUS=$(power_status || echo unknown)
        if [ "$STATUS" = "stopped" ]; then
          echo "${(targetOf svc).key} is stopped, starting for ${name}"
          power_start || echo "start request failed, retrying"
          # earlier answers came from the dying instance
          good=0
        fi
      fi
      if nc -z -w 2 ${(targetOf svc).ip} ${toString svc.targetPort}; then
        ${if svc.httpCheck then ''
        code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://${(targetOf svc).ip}:${toString svc.targetPort}/" 2>/dev/null || echo 000)
        case "$code" in 000|5??) good=0 ;; *) good=$((good + 1)) ;; esac
        '' else "good=$((good + 1))"}
      else
        good=0
      fi
      [ "$good" -ge 2 ] && exit 0
      sleep 1
    done

    echo "${(targetOf svc).key} not ready at ${(targetOf svc).ip}:${toString svc.targetPort} in ${toString svc.bootTimeout}s"
    exit 1
  '';

  sleepScript = name: svc: pkgs.writeShellScript "ondemand-sleep-${name}" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.systemd ]}"

    # only after a clean idle exit, never on crash
    [ "''${SERVICE_RESULT:-}" = "success" ] || exit 0
    ${pauseCheck}
    ${siblingsBusy svc}
    ${powerEnv svc}
    ${lib.optionalString (busyRouteOf svc != null) "uptime=$(power_uptime || echo 0)"}
    ${busyCheck svc}

    echo "${name} idle for ${(targetOf svc).cooldown}, stopping ${(targetOf svc).key}"
    power_stop
  '';

  # powers off vms the proxy never served, and re-arms proxies orphaned by an external stop (terraform apply, crash, manual stop)
  reaperScript = pkgs.writeShellScript "ondemand-reaper" ''
    set -uo pipefail
    export PATH="${lib.makeBinPath [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.systemd ]}"
    now=$(date +%s)
    ${pauseCheck}
    ${lib.concatStrings (lib.mapAttrsToList (name: svc: ''
      (
        ${powerEnv svc}
        cooldown=${toString (toSeconds (targetOf svc).cooldown)}
        status=$(power_status)
        # a proxy whose guest was stopped behind its back never re-activates its socket: stop it to re-arm, before
        # siblingsBusy, which would exit on this proxy itself
        if systemctl is-active --quiet ondemand-${name}.service && [ "$status" = stopped ]; then
          echo "${(targetOf svc).key} (${name}) stopped while its proxy runs, re-arming the socket"
          systemctl stop ondemand-${name}.service
          exit 0
        fi
        ${siblingsBusy svc}
        [ "$status" = running ] || exit 0
        uptime=$(power_uptime || echo 0)
        ${busyCheck svc}
        last=$(systemctl show -p InactiveEnterTimestamp --value ondemand-${name}.service)
        last=$([ -n "$last" ] && date -d "$last" +%s 2>/dev/null || echo 0)
        if [ "$uptime" -ge "$cooldown" ] && [ $((now - last)) -ge "$cooldown" ]; then
          echo "${(targetOf svc).key} (${name}) up ''${uptime}s without connections, stopping"
          power_stop
        fi
      )
    '') active)}
  '';

  serviceType = lib.types.submodule ({ name, ... }: {
    options = {
      vmid = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "A guest's vmid: its address, idle state and idle time come from the inventory. null: an app.";
      };
      app = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "A swarm app, woken through its manager."; };
      manager = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "The app's controller, http://<manager>:<port>."; };
      host = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "The app's backend address (a node)."; };
      idleAfter = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "The app's idle.stopAfter."; };

      targetPort = lib.mkOption { type = lib.types.port; description = "Port on the VM to forward to."; };
      listenPort = lib.mkOption {
        type = lib.types.port;
        default = listenPorts.${name};
        defaultText = "portBase + the service's index among the service names";
        description = "Local port of the activation proxy, unique per host.";
      };
      bootTimeout = lib.mkOption { type = lib.types.int; default = 180; description = "Seconds the VM may take to answer the held client."; };
      busyPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "HTTP path on targetPort answering 200 while the VM must stay up (a running build); idle shutdowns skip it then.";
      };
      wakeAt = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "OnCalendar time to wake it at."; };
      httpCheck = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Wait for a non-5xx HTTP answer, not just an open port, before releasing the held client; false for non-HTTP backends.";
      };
    };
  });
in {
  options.homelab.onDemand = {
    enable = lib.mkEnableOption "socket-activated VMs that boot on first request";

    side = lib.mkOption {
      type = lib.types.enum [ "internal" "external" ];
      description = "Which subnet's onDemand VMs this host fronts. Every onDemand VM on that side must have a service entry.";
    };

    # a test points both at its fake api
    apiUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://${site.lan.proxmox}:${toString net.ports.proxmoxApi}/api2/json";
      description = "Proxmox API base URL.";
    };
    node = lib.mkOption { type = lib.types.str; default = site.node; description = "Proxmox node name."; };

    pauseFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/ondemand-reaper-pause-until";
      readOnly = true;
      description = "sync.sh writes a deadline (unix seconds) here so no guest is shut down mid-deploy.";
    };

    services = lib.mkOption {
      type = lib.types.attrsOf serviceType;
      default = { };
      description = "Services that may run on demand, keyed by name. Only VMs with enabled = \"onDemand\" get a proxy.";
    };

    address = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      description = "host:port of each service: the local activation proxy while its deployment idles, else the backend itself.";
    };
  };

  config = lib.mkIf cfg.enable {
    homelab.onDemand.address = lib.mapAttrs (_: svc:
      if (targetOf svc).sleeps then "${loopback}:${toString svc.listenPort}"
      else "${(targetOf svc).ip}:${toString svc.targetPort}"
    ) cfg.services;

    sops.secrets.${tokenSecret} = { };
    sops.secrets.${caSecret} = { };
    sops.templates.${authHeaderTemplate}.content = "Authorization: PVEAPIToken=${config.sops.placeholder.${tokenSecret}}\n";

    assertions =
      [{
        assertion = lib.allUnique (lib.mapAttrsToList (_: svc: svc.listenPort) cfg.services);
        message = "homelab.onDemand.services: two services share a listenPort";
      }]
      ++ (lib.mapAttrsToList (name: svc: {
        assertion = if svc.app == null then svc.vmid != null && inventory ? ${toString svc.vmid}
          else svc.vmid == null && svc.manager != null && svc.host != null && svc.idleAfter != null;
        message = "homelab.onDemand.services.${name}: either a vm of the inventory, or an app with manager, host and idleAfter";
      }) cfg.services)
      ++ (lib.mapAttrsToList (id: vm: {
        assertion = vm.type != cfg.side || vm.enabled != "onDemand"
          || lib.any (svc: toString svc.vmid == id) (lib.attrValues cfg.services);
        message = "vm ${id} (${vm.name}) is onDemand but has no homelab.onDemand.services entry on the ${cfg.side} Traefik";
      }) inventory);

    # first connection queues while the vm boots
    systemd.sockets = lib.mapAttrs' (name: svc:
      lib.nameValuePair "ondemand-${name}" {
        description = "On-demand activation socket for ${name}";
        wantedBy = [ "sockets.target" ];
        socketConfig = {
          ListenStream = "${loopback}:${toString svc.listenPort}";
          # one proxy for all connections
          Accept = false;
        };
      }
    ) active;

    systemd.services = lib.mapAttrs' (name: svc:
      lib.nameValuePair "ondemand-${name}" {
        description = "On-demand proxy for ${name} (${(targetOf svc).key})";
        requires = [ "ondemand-${name}.socket" ];
        wants = [ "network-online.target" ];
        after = [ "ondemand-${name}.socket" "network-online.target" ];
        serviceConfig = {
          # default 90s is shorter than a boot
          TimeoutStartSec = svc.bootTimeout + 60;
          ExecStartPre = wakeScript name svc;
          ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd"
            + " --exit-idle-time=${(targetOf svc).cooldown}"
            + " ${(targetOf svc).ip}:${toString svc.targetPort}";
          ExecStopPost = sleepScript name svc;
          # next connection retries a failed wake
          Restart = "no";
        };
      }
    ) active // lib.mapAttrs' (name: svc:
      lib.nameValuePair "ondemand-wakeat-${name}" {
        description = "Scheduled wake of ${(targetOf svc).key} for ${name}";
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          TimeoutStartSec = svc.bootTimeout + 60;
          ExecStart = wakeScript name svc;
        };
      }
    ) scheduled // lib.optionalAttrs (active != { }) {
      ondemand-reaper = {
        description = "Shut down idle on-demand VMs that never got a connection";
        serviceConfig = { Type = "oneshot"; ExecStart = reaperScript; };
      };
    };

    systemd.timers = lib.optionalAttrs (active != { }) {
      ondemand-reaper = {
        wantedBy = [ "timers.target" ];
        timerConfig = { OnBootSec = "5m"; OnUnitActiveSec = "2m"; };
      };
    } // lib.mapAttrs' (name: svc: lib.nameValuePair "ondemand-wakeat-${name}" {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = svc.wakeAt; Persistent = true; };
    }) scheduled;
  };
}
