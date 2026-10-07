# idle deployments (the `idle` property): an ingress's local proxy wakes a sleeping deployment on its first
# connection, holds it until the backend answers, and stops the deployment after its idle time without connections
#
# One mechanism, two backends: a vm (an instance with idle set) is powered through the proxmox api, a swarm app
# through its manager's controller (POST /wake/<app>, POST /sleep/<app>, GET /state/<app>, modules/swarm). Every
# script below speaks to either through the same power_* shell functions, and a failed call is an error: the reaper
# fails and exports homelab_ondemand_api_ok 0 for the service, a wake says why it gave up.
#
# The proxmox api is called with the side's own token (scripts/pve-install.sh: wake-<side>@pve, VM.Audit and
# VM.PowerMgmt on each of the side's idle guests, granted per guest by terraform/lib.tf), read by curl from a header
# file sops renders, never from a command line, over tls verified against the proxmox root ca (site.json).
#
# Each proxy listens on loopback at a port its own deployment fixes: a guest's services from portBase + vmid x
# portsPerGuest on, in name order; an app's at its published port, unique in the lab already. Adding a service
# renumbers no other deployment's proxy, so no unrelated socket restarts.
{ config, lib, pkgs, inventory, site, ... }:
let
  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  cfg = config.homelab.onDemand;
  net = import ../net.nix { inherit lib inventory site; };
  loopback = "127.0.0.1";
  authHeaderTemplate = "ondemand-proxmox-auth";
  tokenSecret = "proxmox-wake-token-${cfg.side}";
  # vmids end below 300 and app ports start at 20100 (apps-catalog portRange): 21000..22999 holds every guest's slots
  portBase = 20000;
  # the most routes one guest serves (the arr guest has five)
  portsPerGuest = 10;
  metricsFile = "${config.homelab.textfileDir}/ondemand.prom";

  # silence from a saturated build counts as busy until this uptime; 21h stays clear of the next daily wakeAt
  silentBusyUptimeMax = 21 * 3600;
  # an api call on the house lan answers in milliseconds; this only bounds a hung one
  apiTimeoutS = 20;
  # a busy check, a backend's first http answer, a port probe: each on the lab's own network
  busyTimeoutS = 5;
  httpCheckTimeoutS = 3;
  portCheckTimeoutS = 2;
  # a wake asks for the power state this often while it waits for the backend
  statusEveryS = 10;
  # the time a proxy may take to answer beyond its backend's boot
  startSlackS = 60;
  reaperFirstAfter = "5m";
  reaperEvery = "2m";

  # -----------------------------------------------------------------------------
  # INTERNAL
  # -----------------------------------------------------------------------------

  # what a service wakes: a guest, or an app on its cluster; `key` names it in units, logs and metrics
  vmOf = svc: inventory.${toString svc.vmid};
  targetOf = svc:
    if svc.app == null then {
      key = "vm-${toString svc.vmid}";
      inherit (vmOf svc) ip;
      stopAfter = (vmOf svc).idle;
      sleeps = (vmOf svc).powered && (vmOf svc).idle != null;
    } else {
      key = "app-${svc.app}";
      ip = svc.host;
      stopAfter = svc.idleAfter;
      sleeps = true;
    };
  active = lib.filterAttrs (_: svc: (targetOf svc).sleeps) cfg.services;
  # every service of a deployment names its wake time; one wake per deployment, under its first service's name
  firstServiceOf = key: lib.head (lib.attrNames (lib.filterAttrs (_: s: (targetOf s).key == key) active));
  scheduled = lib.filterAttrs (name: svc: svc.wakeAt != null && name == firstServiceOf (targetOf svc).key) active;

  # a guest's service: its slot among the guest's services, in name order
  slotOf = name: svc: lib.lists.findFirstIndex (n: n == name) null
    (lib.attrNames (lib.filterAttrs (_: s: s.app == null && s.vmid == svc.vmid) cfg.services));
  listenPortOf = name: svc: if svc.app != null then svc.targetPort else portBase + svc.vmid * portsPerGuest + slotOf name svc;

  # several routes can share one deployment
  siblingsBusy = svc: lib.concatStrings (lib.mapAttrsToList (n: s:
    lib.optionalString ((targetOf s).key == (targetOf svc).key) ''
      systemctl is-active --quiet ondemand-${n}.service && exit 0
    '') active);

  # "15m" -> 900, the shape modules/service.nix types idle.stopAfter to
  toSeconds = s:
    let m = builtins.match "([0-9]+)(s|m|h|d)" s;
        unit = { s = 1; m = 60; h = 3600; d = 86400; };
    in assert lib.assertMsg (m != null) "on-demand stopAfter '${s}' must look like 30s, 15m, 2h or 1d";
    lib.toInt (builtins.elemAt m 0) * unit.${builtins.elemAt m 1};

  # power_status (running or stopped), power_uptime (seconds), power_start, power_stop; each fails with the api
  powerOf = svc: if svc.app == null then {
    setup = ''
      api="${cfg.apiUrl}/nodes/${cfg.node}/${if (vmOf svc).kind == "lxc" then "lxc" else "qemu"}/${toString svc.vmid}"
      pve() {
        curl -sf --max-time ${toString apiTimeoutS} --cacert ${cfg.caFile} \
          -H @${config.sops.templates.${authHeaderTemplate}.path} "$@"
      }
    '';
    status = ''power_status() { pve "$api/status/current" | jq -er '.data.status'; }'';
    uptime = ''power_uptime() { pve "$api/status/current" | jq -er '.data.uptime'; }'';
    start = ''power_start() { pve -X POST "$api/status/start" >/dev/null; }'';
    stop = ''power_stop() { pve -X POST "$api/status/shutdown" >/dev/null; }'';
  } else {
    setup = ''controller="${svc.manager}"'';
    status = ''power_status() { curl -sf --max-time ${toString apiTimeoutS} "$controller/state/${svc.app}"; }'';
    # the controller keeps no uptime: an app is stopped by idle time alone
    uptime = "power_uptime() { echo ${toString silentBusyUptimeMax}; }";
    start = ''power_start() { curl -sf --max-time ${toString apiTimeoutS} -X POST "$controller/wake/${svc.app}" >/dev/null; }'';
    stop = ''power_stop() { curl -sf --max-time ${toString apiTimeoutS} -X POST "$controller/sleep/${svc.app}" >/dev/null; }'';
  };
  # the setup and the named functions only: a script defines what it calls
  powerEnv = svc: ops: lib.concatMapStringsSep "\n" (op: (powerOf svc).${op}) ([ "setup" ] ++ ops);

  # busy is the guest's: every route to it, a sibling without busyPath included, asks the one route that has it
  busyRouteOf = svc: lib.findFirst (s: (targetOf s).key == (targetOf svc).key && s.busyPath != null) null (lib.attrValues cfg.services);

  # exits the calling script while the deployment reports work that must not be cut off; needs $uptime
  busyCheck = svc: let busy = busyRouteOf svc; target = targetOf svc; in lib.optionalString (busy != null) ''
    # no answer at all is 000
    busy=$(curl -s -o /dev/null -w '%{http_code}' -m ${toString busyTimeoutS} "http://${target.ip}:${toString busy.targetPort}${busy.busyPath}") || busy=000
    if [ "$busy" = 200 ]; then echo "${target.key} reports busy, leaving it up"; exit 0; fi
    if [ "$busy" = 000 ] && [ "$uptime" -lt ${toString silentBusyUptimeMax} ]; then
      echo "${target.key} does not answer its busy check, leaving it up"; exit 0
    fi
  '';

  pauseCheck = ''
    pause=$(cat ${cfg.pauseFile} 2>/dev/null) || pause=0
    if [ "$(date +%s)" -lt "$pause" ]; then echo "paused by a deploy until $(date -d "@$pause")"; exit 0; fi
  '';

  wakeScript = name: svc: let target = targetOf svc; in pkgs.writeShellApplication {
    name = "ondemand-wake-${name}";
    runtimeInputs = [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.netcat-gnu ];
    text = ''
      ${powerEnv svc [ "status" "start" ]}
      api_error=""
      # two good checks: a shutting-down vm still accepts briefly (502)
      good=0
      for i in $(seq 1 ${toString svc.bootTimeout}); do
        if [ $((i % ${toString statusEveryS})) -eq 1 ]; then
          if ! status=$(power_status); then
            api_error="the power api failed"
            echo "${target.key}: $api_error, asking again in ${toString statusEveryS}s" >&2
          elif [ "$status" = stopped ]; then
            echo "${target.key} is stopped, starting for ${name}"
            power_start || { api_error="the start request failed"; echo "${target.key}: $api_error" >&2; }
            # earlier answers came from the dying instance
            good=0
          fi
        fi
        if nc -z -w ${toString portCheckTimeoutS} ${target.ip} ${toString svc.targetPort}; then
          ${if svc.httpCheck then ''
          code=$(curl -s -o /dev/null -w '%{http_code}' -m ${toString httpCheckTimeoutS} "http://${target.ip}:${toString svc.targetPort}/") || code=000
          case "$code" in 000|5??) good=0 ;; *) good=$((good + 1)) ;; esac
          '' else "good=$((good + 1))"}
        else
          good=0
        fi
        [ "$good" -lt 2 ] || exit 0
        sleep 1
      done
      echo "${target.key} not ready at ${target.ip}:${toString svc.targetPort} in ${toString svc.bootTimeout}s''${api_error:+; $api_error}" >&2
      exit 1
    '';
  };

  sleepScript = name: svc: let target = targetOf svc; in pkgs.writeShellApplication {
    name = "ondemand-sleep-${name}";
    runtimeInputs = [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.systemd ];
    text = ''
      # only after a clean idle exit, never on crash
      [ "''${SERVICE_RESULT:-}" = "success" ] || exit 0
      ${pauseCheck}
      ${siblingsBusy svc}
      ${powerEnv svc ([ "stop" ] ++ lib.optional (busyRouteOf svc != null) "uptime")}
      ${lib.optionalString (busyRouteOf svc != null) "uptime=$(power_uptime)"}
      ${busyCheck svc}
      echo "${name} idle for ${target.stopAfter}, stopping ${target.key}"
      power_stop
    '';
  };

  # powers off deployments the proxy never served, and re-arms proxies orphaned by an external stop (terraform
  # apply, crash, manual stop); one service's failed call fails the run, the others still get their turn (each in a
  # subshell whose status `||` reads, where errexit does not hold: every call is checked by hand)
  reaperScript = pkgs.writeShellApplication {
    name = "ondemand-reaper";
    runtimeInputs = [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.systemd ];
    bashOptions = [ "nounset" "pipefail" ];
    text = ''
      now=$(date +%s)
      ${pauseCheck}
      metrics=$(mktemp "${metricsFile}.XXXXXX")
      echo '# TYPE homelab_ondemand_api_ok gauge' > "$metrics"
      failed=0
      ${lib.concatStrings (lib.mapAttrsToList (name: svc: let target = targetOf svc; in ''
        (
          api_ok() { echo "homelab_ondemand_api_ok{service=\"${name}\",target=\"${target.key}\"} $1" >> "$metrics"; }
          ${powerEnv svc [ "status" "uptime" "stop" ]}
          stop_after=${toString (toSeconds target.stopAfter)}
          if ! status=$(power_status); then
            echo "${target.key} (${name}): the power api failed" >&2
            api_ok 0
            exit 1
          fi
          api_ok 1
          # a proxy whose deployment was stopped behind its back never re-activates its socket: stop it to re-arm,
          # before siblingsBusy, which would exit on this proxy itself
          if systemctl is-active --quiet ondemand-${name}.service && [ "$status" = stopped ]; then
            echo "${target.key} (${name}) stopped while its proxy runs, re-arming the socket"
            systemctl stop ondemand-${name}.service || exit 1
            exit 0
          fi
          ${siblingsBusy svc}
          [ "$status" = running ] || exit 0
          uptime=$(power_uptime) || { echo "${target.key} (${name}): the power api failed for its uptime" >&2; exit 1; }
          ${busyCheck svc}
          last=$(systemctl show -p InactiveEnterTimestamp --value ondemand-${name}.service)
          last_s=0
          if [ -n "$last" ]; then last_s=$(date -d "$last" +%s); fi
          if [ "$uptime" -ge "$stop_after" ] && [ $((now - last_s)) -ge "$stop_after" ]; then
            echo "${target.key} (${name}) up ''${uptime}s without connections, stopping"
            power_stop || { echo "${target.key} (${name}): the stop request failed" >&2; exit 1; }
          fi
        ) || failed=1
      '') active)}
      chmod 0644 "$metrics"
      mv "$metrics" ${metricsFile}
      exit "$failed"
    '';
  };

  serviceType = lib.types.submodule ({ name, config, ... }: {
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

      targetPort = lib.mkOption { type = lib.types.port; description = "Port on the deployment to forward to."; };
      listenPort = lib.mkOption {
        type = lib.types.port;
        readOnly = true;
        default = listenPortOf name config;
        defaultText = "an app's published port; a guest's portBase + vmid x portsPerGuest + its slot among the guest's services";
        description = "Local port of the activation proxy, fixed by its own deployment.";
      };
      bootTimeout = lib.mkOption { type = lib.types.int; default = 180; description = "Seconds the deployment may take to answer the held client."; };
      busyPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "HTTP path on targetPort answering 200 while the deployment must stay up (a running build); idle shutdowns skip it then.";
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
    enable = lib.mkEnableOption "socket-activated deployments that start on their first request";

    side = lib.mkOption {
      type = lib.types.enum [ "internal" "external" ];
      description = "Which zone's idle guests this host fronts. Every idle guest of that zone must have a service entry.";
    };

    # a test points these at its fake api
    apiUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://${site.lan.proxmox}:${toString net.ports.proxmoxApi}/api2/json";
      description = "Proxmox API base URL.";
    };
    caFile = lib.mkOption {
      type = lib.types.str;
      default = "${pkgs.writeText "pve-root-ca.pem" site.proxmoxCa}";
      defaultText = lib.literalExpression "site.json proxmoxCa";
      description = "The proxmox root ca (/etc/pve/pve-root-ca.pem) the api's certificate must chain to.";
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
      description = "Services that may run on demand, keyed by name. Only deployments with idle set get a proxy.";
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
    sops.templates.${authHeaderTemplate}.content = "Authorization: PVEAPIToken=${config.sops.placeholder.${tokenSecret}}\n";

    assertions =
      [{
        assertion = lib.allUnique (lib.mapAttrsToList (_: svc: svc.listenPort) cfg.services);
        message = "homelab.onDemand.services: two services share a listenPort (two routes of an app on one published port?)";
      }]
      ++ (lib.mapAttrsToList (name: svc: {
        assertion = if svc.app == null then svc.vmid != null && inventory ? ${toString svc.vmid} && slotOf name svc < portsPerGuest
          else svc.vmid == null && svc.manager != null && svc.host != null && svc.idleAfter != null;
        message = "homelab.onDemand.services.${name}: either a vm of the inventory with at most ${toString portsPerGuest} services, or an app with manager, host and idleAfter";
      }) cfg.services)
      ++ (lib.mapAttrsToList (id: vm: {
        assertion = vm.type != cfg.side || !vm.powered || vm.idle == null
          || lib.any (svc: toString svc.vmid == id) (lib.attrValues cfg.services);
        message = "vm ${id} (${vm.name}) idles but has no homelab.onDemand.services entry on the ${cfg.side} ingress";
      }) inventory);

    # first connection queues while the deployment starts
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
          TimeoutStartSec = svc.bootTimeout + startSlackS;
          ExecStartPre = lib.getExe (wakeScript name svc);
          ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd"
            + " --exit-idle-time=${(targetOf svc).stopAfter}"
            + " ${(targetOf svc).ip}:${toString svc.targetPort}";
          ExecStopPost = lib.getExe (sleepScript name svc);
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
          TimeoutStartSec = svc.bootTimeout + startSlackS;
          ExecStart = lib.getExe (wakeScript name svc);
        };
      }
    ) scheduled // lib.optionalAttrs (active != { }) {
      ondemand-reaper = {
        description = "Shut down idle deployments that never got a connection";
        serviceConfig = { Type = "oneshot"; ExecStart = lib.getExe reaperScript; };
      };
    };

    systemd.timers = lib.optionalAttrs (active != { }) {
      ondemand-reaper = {
        wantedBy = [ "timers.target" ];
        timerConfig = { OnBootSec = reaperFirstAfter; OnUnitActiveSec = reaperEvery; };
      };
    } // lib.mapAttrs' (name: svc: lib.nameValuePair "ondemand-wakeat-${name}" {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = svc.wakeAt; Persistent = true; };
    }) scheduled;
  };
}
