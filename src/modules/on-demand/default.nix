# idle deployments (the `idle` property): an ingress's local proxy wakes a sleeping deployment on its first
# connection, holds it until the backend answers, and stops it after its idle time without connections
#
# a vm is powered through the proxmox api with the side's own token (read by curl from a sops header file, never an
# argv, over tls pinned to the proxmox ca); a swarm app through its manager's controller (modules/swarm)
#
# workaround: switch-to-configuration never restarts a changed .socket unit (nixpkgs issue 74899), so a moved
# ListenStream listens nowhere after the reload. Each socket is PartOf a oneshot anchor restarted on any change of the
# socket's unit file. Delete the anchors once the switcher restarts changed sockets itself.
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
  metricsName = "ondemand";
  metricsFile = "${config.homelab.textfileDir}/${metricsName}.prom";
  # a file per wake: a wake runs beside the reaper and the other wakes
  wakeMetricsName = name: "ondemand_wake_${name}";
  # written before a stop: a wake that finds the deployment still running waits for it to go first, since a dying
  # deployment's services keep answering through its acpi shutdown
  stoppingStampOf = key: "/run/ondemand-stopping-${key}";

  # silence from a saturated build counts as busy until this uptime; 21h stays clear of the next daily wakeAt
  silentBusyUptimeMax = 21 * 3600;
  apiTimeoutS = 20;
  busyTimeoutS = 5;
  httpCheckTimeoutS = 3;
  portCheckTimeoutS = 2;
  statusEveryS = 10;
  # a shutdown takes seconds: polled faster than statusEveryS so the held client is not kept waiting for the poll
  stoppingPollS = 1;
  # the held client waits at most this past its backend's readiness, at a connect per check
  readyPollS = "0.2";
  startSlackS = 60;
  reaperFirstAfter = "5m";
  socketAnchorOf = name: "ondemand-${name}-bind";
  reaperEvery = "2m";

  # -----------------------------------------------------------------------------
  # INTERNAL
  # -----------------------------------------------------------------------------

  # `key` names the deployment in units, logs and metrics
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
  # one scheduled wake per deployment, under its first service's name
  firstServiceOf = key: lib.head (lib.attrNames (lib.filterAttrs (_: s: (targetOf s).key == key) active));
  scheduled = lib.filterAttrs (name: svc: svc.wakeAt != null && name == firstServiceOf (targetOf svc).key) active;

  slotOf = name: svc: lib.lists.findFirstIndex (n: n == name) null
    (lib.attrNames (lib.filterAttrs (_: s: s.app == null && s.vmid == svc.vmid) cfg.services));
  listenPortOf = name: svc: if svc.app != null then svc.targetPort else portBase + svc.vmid * portsPerGuest + slotOf name svc;

  # exits while a proxy of the deployment holds it or wakes it (activating). The reaper also leaves a deactivating one
  # to its own sleep; a sleep does not, or two siblings exiting together would each leave the stop to the other.
  # `self` is skipped: a sleep runs inside its own proxy's stop
  siblingsBusy = svc: self: states: lib.concatStrings (lib.mapAttrsToList (n: s:
    lib.optionalString ((targetOf s).key == (targetOf svc).key && n != self) ''
      case "$(systemctl show -p ActiveState --value ondemand-${n}.service)" in ${lib.concatStringsSep "|" states}) exit 0 ;; esac
    '') active);
  proxyBusyStates = [ "active" "activating" "reloading" ];

  # the shape modules/service.nix types idle.stopAfter to
  toSeconds = s:
    let m = builtins.match "([0-9]+)(s|m|h|d)" s;
        unit = { s = 1; m = 60; h = 3600; d = 86400; };
    in assert lib.assertMsg (m != null) "on-demand stopAfter '${s}' must look like 30s, 15m, 2h or 1d";
    lib.toInt (builtins.elemAt m 0) * unit.${builtins.elemAt m 1};

  # power_status (running or stopped), power_uptime (seconds), power_start, power_stop; each fails with the api.
  # power_stop marks the deployment stopping first and takes the mark back when the request fails
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
    stop = stopWith svc ''pve -X POST "$api/status/shutdown" >/dev/null'';
  } else {
    setup = ''controller="${svc.manager}"'';
    status = ''power_status() { curl -sf --max-time ${toString apiTimeoutS} "$controller/state/${svc.app}"; }'';
    uptime = ''power_uptime() { curl -sf --max-time ${toString apiTimeoutS} "$controller/uptime/${svc.app}"; }'';
    start = ''power_start() { curl -sf --max-time ${toString apiTimeoutS} -X POST "$controller/wake/${svc.app}" >/dev/null; }'';
    stop = stopWith svc ''curl -sf --max-time ${toString apiTimeoutS} -X POST "$controller/sleep/${svc.app}" >/dev/null'';
  };
  stopWith = svc: request: let stamp = stoppingStampOf (targetOf svc).key; in ''
    power_stop() {
      touch ${stamp}
      ${request} || { rm -f ${stamp}; return 1; }
    }
  '';
  powerEnv = svc: ops: lib.concatMapStringsSep "\n" (op: (powerOf svc).${op}) ([ "setup" ] ++ ops);

  # busy is the guest's: every route to it, a sibling without busyPath included, asks the one route that has it
  busyRouteOf = svc: lib.findFirst (s: (targetOf s).key == (targetOf svc).key && s.busyPath != null) null (lib.attrValues cfg.services);

  # exits while the deployment reports work that must not be cut off; needs $uptime
  busyCheck = svc: let busy = busyRouteOf svc; target = targetOf svc; in lib.optionalString (busy != null) ''
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
      stopping=${stoppingStampOf target.key}
      wake_ok() {
        metrics=${config.homelab.textfileDir}/${wakeMetricsName name}.prom
        printf '# TYPE homelab_ondemand_wake_ok gauge\nhomelab_ondemand_wake_ok{service="${name}",target="${target.key}"} %s\n' "$1" > "$metrics.tmp"
        mv "$metrics.tmp" "$metrics"
      }
      api_error=""
      good=0
      draining=0
      boot_timeout=${toString svc.bootTimeout}
      deadline=$((SECONDS + boot_timeout))
      status_at=$SECONDS
      while [ "$SECONDS" -lt "$deadline" ]; do
        if [ "$SECONDS" -ge "$status_at" ]; then
          status_at=$((SECONDS + ${toString statusEveryS}))
          if ! status=$(power_status); then
            api_error="the power api failed"
            echo "${target.key}: $api_error, asking again in ${toString statusEveryS}s" >&2
          elif [ "$status" = stopped ]; then
            rm -f "$stopping"
            draining=0
            echo "${target.key} is stopped, starting for ${name}"
            power_start || { api_error="the start request failed"; echo "${target.key}: $api_error" >&2; }
            good=0
          elif [ -e "$stopping" ] && [ $(($(date +%s) - $(stat -c %Y "$stopping"))) -lt "$boot_timeout" ]; then
            [ "$draining" = 1 ] || echo "${target.key} is shutting down, starting it again once it stopped"
            draining=1
            good=0
            status_at=$((SECONDS + ${toString stoppingPollS}))
          else
            draining=0
          fi
        fi
        if [ "$draining" = 1 ]; then sleep ${readyPollS}; continue; fi
        ${if svc.httpCheck then ''
        # a fresh connect each poll: a port nothing listens on yet may drop the syn, and the retransmit waits seconds
        code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout ${readyPollS} -m ${toString httpCheckTimeoutS} \
          "http://${target.ip}:${toString svc.targetPort}${svc.healthPath}") || code=000
        case "$code" in 000|5??) good=0 ;; *) good=$((good + 1)) ;; esac
        '' else ''
        if nc -z -w ${toString portCheckTimeoutS} ${target.ip} ${toString svc.targetPort}; then good=$((good + 1)); else good=0; fi
        ''}
        if [ "$good" -ge 2 ]; then wake_ok 1; exit 0; fi
        sleep ${readyPollS}
      done
      echo "${target.key} not ready at ${target.ip}:${toString svc.targetPort} in ${toString svc.bootTimeout}s''${api_error:+; $api_error}" >&2
      wake_ok 0
      exit 1
    '';
  };

  sleepScript = name: svc: let target = targetOf svc; in pkgs.writeShellApplication {
    name = "ondemand-sleep-${name}";
    runtimeInputs = [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.systemd ];
    text = ''
      # an idle exit only, never a crash
      [ "''${SERVICE_RESULT:-}" = "success" ] || exit 0
      ${pauseCheck}
      ${siblingsBusy svc name proxyBusyStates}
      ${powerEnv svc ([ "stop" ] ++ lib.optional (busyRouteOf svc != null) "uptime")}
      ${lib.optionalString (busyRouteOf svc != null) "uptime=$(power_uptime)"}
      ${busyCheck svc}
      echo "${name} idle for ${target.stopAfter}, stopping ${target.key}"
      power_stop
    '';
  };

  # powers off deployments the proxy never served and re-arms proxies orphaned by an external stop. Each service runs
  # in a subshell whose status `||` reads, where errexit does not hold: every call is checked by hand
  reaperScript = pkgs.writeShellApplication {
    name = "ondemand-reaper";
    runtimeInputs = [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.systemd ];
    bashOptions = [ "nounset" "pipefail" ];
    text = ''
      # shellcheck disable=SC2034 # read by each service's block below, which nix renders
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
          # a proxy whose deployment was stopped behind its back never re-activates its socket; before siblingsBusy,
          # which would exit on this proxy itself
          if systemctl is-active --quiet ondemand-${name}.service && [ "$status" = stopped ]; then
            echo "${target.key} (${name}) stopped while its proxy runs, re-arming the socket"
            systemctl stop ondemand-${name}.service || exit 1
            exit 0
          fi
          ${siblingsBusy svc null (proxyBusyStates ++ [ "deactivating" ])}
          [ "$status" = running ] || exit 0
          uptime=$(power_uptime) || { echo "${target.key} (${name}): the power api failed for its uptime" >&2; exit 1; }
          ${busyCheck svc}
          last=$(systemctl show -p InactiveEnterTimestamp --value ondemand-${name}.service)
          last_s=0
          if [ -n "$last" ]; then last_s=$(date -d "$last" +%s); fi
          if [ "$uptime" -ge "$stop_after" ] && [ $((now - last_s)) -ge "$stop_after" ]; then
            echo "${target.key} (${name}) up ''${uptime}s, no connection for $((now - last_s))s, stopping"
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
      healthPath = lib.mkOption {
        type = lib.types.str;
        default = "/";
        description = "With httpCheck: the path that answers below 500 once the deployment serves (its route's health).";
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
      description = "sync.nu writes a deadline (unix seconds) here so no guest is shut down mid-deploy.";
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
    homelab.textfiles = [ metricsName ] ++ map wakeMetricsName (lib.attrNames active);

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

    systemd.sockets = lib.mapAttrs' (name: svc:
      lib.nameValuePair "ondemand-${name}" {
        description = "On-demand activation socket for ${name}";
        wantedBy = [ "sockets.target" ];
        partOf = [ "${socketAnchorOf name}.service" ];
        socketConfig = {
          ListenStream = "${loopback}:${toString svc.listenPort}";
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
          # the next connection retries a failed wake
          Restart = "no";
        };
      }
    ) active // lib.mapAttrs' (name: _:
      lib.nameValuePair (socketAnchorOf name) {
        description = "Rebinds ondemand-${name}.socket when its definition changes";
        wantedBy = [ "multi-user.target" ];
        restartTriggers = [ config.systemd.units."ondemand-${name}.socket".unit ];
        # a restart, never a stop before the daemon reload: the socket must come back with its new definition
        stopIfChanged = false;
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; ExecStart = "${pkgs.coreutils}/bin/true"; };
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
