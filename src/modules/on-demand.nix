{ config, lib, pkgs, inventory, site, ... }:
let
  cfg = config.homelab.onDemand;

  vmOf = svc: inventory.${toString svc.vmid};
  isOnDemand = svc: (vmOf svc).enabled == "onDemand";
  active = lib.filterAttrs (_: isOnDemand) cfg.services;
  scheduled = lib.filterAttrs (_: svc: svc.wakeAt != null) active;

  # several routes can share one VM
  siblingsBusy = svc: lib.concatStrings (lib.mapAttrsToList (n: s:
    lib.optionalString (s.vmid == svc.vmid) ''
      systemctl is-active --quiet ondemand-${n}.service && exit 0
    '') active);

  # "15m" -> 900
  toSeconds = s:
    let m = builtins.match "([0-9]+)(s|m|h|d)" s;
        unit = { s = 1; m = 60; h = 3600; d = 86400; };
    in if m == null then throw "on-demand cooldown '${s}' must look like 30s, 15m, 2h or 1d"
       else lib.toInt (builtins.elemAt m 0) * unit.${builtins.elemAt m 1};

  apiEnv = svc: ''
    TOKEN=$(cat ${cfg.tokenFile})
    API="${cfg.apiUrl}/nodes/${cfg.node}/${if (vmOf svc).kind or "vm" == "lxc" then "lxc" else "qemu"}/${toString svc.vmid}"
    pve() { curl -sfk --max-time 20 -H "Authorization: PVEAPIToken=$TOKEN" "$@"; }
    vm_status() { pve "$API/status/current" | jq -r '.data.status // "unknown"'; }
    vm_status_uptime() { pve "$API/status/current" | jq -r '.data.uptime // 0'; }
  '';

  # silence from a saturated build counts as busy until this uptime; 21h stays clear of the next daily wakeAt
  silentBusyUptimeMax = 21 * 3600;

  # exits the calling script while the vm reports work that must not be cut off; needs $uptime
  busyCheck = svc: lib.optionalString (svc.busyPath != null) ''
    busy=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://${(vmOf svc).ip}:${toString svc.targetPort}${svc.busyPath}" || true)
    [ "$busy" = 200 ] && { echo "vm-${toString svc.vmid} reports busy, leaving it up"; exit 0; }
    if [ "''${busy:-000}" = 000 ] && [ "$uptime" -lt ${toString silentBusyUptimeMax} ]; then
      echo "vm-${toString svc.vmid} does not answer its busy check, leaving it up"; exit 0
    fi
  '';

  # sync.sh writes a deadline here so no guest is shut down mid-deploy
  pauseFile = "/run/ondemand-reaper-pause-until";
  pauseCheck = ''
    pause=$(cat ${pauseFile} 2>/dev/null || echo 0)
    [ "$(date +%s)" -lt "$pause" ] 2>/dev/null && { echo "paused by a deploy until $(date -d "@$pause")"; exit 0; }
  '';

  wakeScript = name: svc: pkgs.writeShellScript "ondemand-wake-${name}" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.netcat-gnu ]}"
    ${apiEnv svc}

    # two good checks: a shutting-down vm still accepts briefly (502)
    good=0
    for i in $(seq 1 ${toString svc.bootTimeout}); do
      # recheck power state every 10s; api errors retry
      if [ $((i % 10)) -eq 1 ]; then
        STATUS=$(vm_status || echo unknown)
        if [ "$STATUS" = "stopped" ]; then
          echo "vm-${toString svc.vmid} is stopped, starting for ${name}"
          pve -X POST "$API/status/start" >/dev/null || echo "start request failed, retrying"
          # earlier answers came from the dying instance
          good=0
        fi
      fi
      if nc -z -w 2 ${(vmOf svc).ip} ${toString svc.targetPort}; then
        ${if svc.httpCheck then ''
        code=$(curl -sk -o /dev/null -w '%{http_code}' -m 3 "http://${(vmOf svc).ip}:${toString svc.targetPort}/" 2>/dev/null || echo 000)
        case "$code" in 000|5??) good=0 ;; *) good=$((good + 1)) ;; esac
        '' else "good=$((good + 1))"}
      else
        good=0
      fi
      [ "$good" -ge 2 ] && exit 0
      sleep 1
    done

    echo "vm-${toString svc.vmid} not ready at ${(vmOf svc).ip}:${toString svc.targetPort} in ${toString svc.bootTimeout}s"
    exit 1
  '';

  sleepScript = name: svc: pkgs.writeShellScript "ondemand-sleep-${name}" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.systemd ]}"

    # only after a clean idle exit, never on crash
    [ "''${SERVICE_RESULT:-}" = "success" ] || exit 0
    ${pauseCheck}
    ${siblingsBusy svc}
    ${apiEnv svc}
    ${lib.optionalString (svc.busyPath != null) "uptime=$(vm_status_uptime || echo 0)"}
    ${busyCheck svc}

    echo "${name} idle for ${(vmOf svc).cooldown}, shutting down vm-${toString svc.vmid}"
    pve -X POST "$API/status/shutdown" >/dev/null
  '';

  # powers off vms the proxy never served, and re-arms proxies orphaned by an external stop (terraform apply, crash, manual stop)
  reaperScript = pkgs.writeShellScript "ondemand-reaper" ''
    set -uo pipefail
    export PATH="${lib.makeBinPath [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.systemd ]}"
    now=$(date +%s)
    ${pauseCheck}
    ${lib.concatStrings (lib.mapAttrsToList (name: svc: ''
      (
        ${apiEnv svc}
        cooldown=${toString (toSeconds (vmOf svc).cooldown)}
        cur=$(pve "$API/status/current")
        status=$(echo "$cur" | jq -r '.data.status // ""')
        # orphaned proxy: proxyd runs but its vm was stopped externally (a failed api call reads "", not stopped),
        # so the socket never re-activates and the next connection hits "no route to host". stop it to re-arm the
        # socket; must run before siblingsBusy, which would exit on this service's own active proxy.
        if systemctl is-active --quiet ondemand-${name}.service && [ "$status" = stopped ]; then
          echo "vm-${toString svc.vmid} (${name}) stopped while its proxy runs, re-arming the socket"
          systemctl stop ondemand-${name}.service || true
          exit 0
        fi
        ${siblingsBusy svc}
        [ "$status" = running ] || exit 0
        uptime=$(echo "$cur" | jq -r '.data.uptime // 0')
        ${busyCheck svc}
        last=$(systemctl show -p InactiveEnterTimestamp --value ondemand-${name}.service)
        last=$([ -n "$last" ] && date -d "$last" +%s 2>/dev/null || echo 0)
        if [ "$uptime" -ge "$cooldown" ] && [ $((now - last)) -ge "$cooldown" ]; then
          echo "vm-${toString svc.vmid} (${name}) up ''${uptime}s without connections, shutting down"
          pve -X POST "$API/status/shutdown" >/dev/null
        fi
      )
    '') active)}
  '';

  serviceType = lib.types.submodule ({ config, ... }: {
    options = {
      vmid = lib.mkOption {
        type = lib.types.int;
        description = "Proxmox VM ID (key in instances.tf). IP, enabled state and cooldown come from the inventory.";
      };

      targetPort = lib.mkOption {
        type = lib.types.port;
        description = "Port on the VM to forward to.";
      };

      listenPort = lib.mkOption {
        type = lib.types.port;
        default = 20000 + config.vmid;
        description = "Local port of the activation proxy. Must be unique per host; set it explicitly when two services share a VM.";
      };

      bootTimeout = lib.mkOption {
        type = lib.types.int;
        default = 180;
        description = "Seconds to wait for the VM to answer before failing the connection.";
      };

      busyPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/busy";
        description = "HTTP path on the VM's targetPort that answers 200 while the VM must stay up (a running build). Idle shutdowns skip the VM while it does.";
      };

      wakeAt = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "03:00";
        description = "systemd OnCalendar expression at which to boot the VM without a request, for work it starts on its own at boot.";
      };

      httpCheck = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Wait for a non-5xx HTTP response (not just an open TCP port) before releasing the held client. Set false for non-HTTP backends (e.g. Minecraft).";
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

    apiUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://${site.lan.proxmox}:8006/api2/json";
      description = "Proxmox API base URL.";
    };

    node = lib.mkOption {
      type = lib.types.str;
      default = site.node;
      description = "Proxmox node name.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        File containing a Proxmox API token as USER@REALM!TOKENID=SECRET.
        The token needs VM.PowerMgmt and VM.Audit on the target VMs.
      '';
    };

    services = lib.mkOption {
      type = lib.types.attrsOf serviceType;
      default = {};
      description = "Services that may run on demand, keyed by name. Only VMs with enabled = \"onDemand\" get a proxy.";
    };

    address = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      description = ''
        host:port to reach each service: the local activation proxy when the VM
        is onDemand, the VM itself when it is always on. Point Traefik here so
        flipping `enabled` in instances.tf needs no other change.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    homelab.onDemand.address = lib.mapAttrs (_: svc:
      if isOnDemand svc then "127.0.0.1:${toString svc.listenPort}"
      else "${(vmOf svc).ip}:${toString svc.targetPort}"
    ) cfg.services;

    assertions =
      (lib.mapAttrsToList (name: svc: {
        assertion = inventory ? ${toString svc.vmid};
        message = "homelab.onDemand.services.${name}: vm ${toString svc.vmid} is not in instances.tf";
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
          ListenStream = "127.0.0.1:${toString svc.listenPort}";
          # one proxy for all connections
          Accept = false;
        };
      }
    ) active;

    systemd.services = lib.mapAttrs' (name: svc:
      lib.nameValuePair "ondemand-${name}" {
        description = "On-demand proxy for ${name} (vm-${toString svc.vmid})";
        requires = [ "ondemand-${name}.socket" ];
        wants = [ "network-online.target" ];
        after = [ "ondemand-${name}.socket" "network-online.target" ];
        serviceConfig = {
          # default 90s is shorter than a boot
          TimeoutStartSec = svc.bootTimeout + 60;
          ExecStartPre = wakeScript name svc;
          ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd"
            + " --exit-idle-time=${(vmOf svc).cooldown}"
            + " ${(vmOf svc).ip}:${toString svc.targetPort}";
          ExecStopPost = sleepScript name svc;
          # next connection retries a failed wake
          Restart = "no";
        };
      }
    ) active // lib.mapAttrs' (name: svc:
      lib.nameValuePair "ondemand-wakeat-${name}" {
        description = "Scheduled wake of vm-${toString svc.vmid} for ${name}";
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          TimeoutStartSec = svc.bootTimeout + 60;
          ExecStart = wakeScript name svc;
        };
      }
    ) scheduled // lib.optionalAttrs (active != {}) {
      ondemand-reaper = {
        description = "Shut down idle on-demand VMs that never got a connection";
        serviceConfig = { Type = "oneshot"; ExecStart = reaperScript; };
      };
    };

    systemd.timers = lib.optionalAttrs (active != {}) {
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
