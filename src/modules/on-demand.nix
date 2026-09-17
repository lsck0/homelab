{ config, lib, pkgs, inventory, ... }:
let
  cfg = config.homelab.onDemand;

  vmOf = svc: inventory.${toString svc.vmid};
  isOnDemand = svc: (vmOf svc).enabled == "onDemand";
  active = lib.filterAttrs (_: isOnDemand) cfg.services;

  # several routes can share one VM (e.g. NAS web UI + Syncthing). The VM may
  # only go down when none of its proxies is serving.
  siblingsBusy = svc: lib.concatStrings (lib.mapAttrsToList (n: s:
    lib.optionalString (s.vmid == svc.vmid) ''
      systemctl is-active --quiet ondemand-${n}.service && exit 0
    '') active);

  # "15m" -> 900. Cooldowns live in instances.tf; keep the format simple so the
  # proxy idle timeout and the reaper agree on the same number.
  toSeconds = s:
    let m = builtins.match "([0-9]+)(s|m|h|d)" s;
        unit = { s = 1; m = 60; h = 3600; d = 86400; };
    in if m == null then throw "on-demand cooldown '${s}' must look like 30s, 15m, 2h or 1d"
       else lib.toInt (builtins.elemAt m 0) * unit.${builtins.elemAt m 1};

  apiEnv = svc: ''
    TOKEN=$(cat ${cfg.tokenFile})
    API="${cfg.apiUrl}/nodes/${cfg.node}/qemu/${toString svc.vmid}"
    pve() { curl -sfk --max-time 20 -H "Authorization: PVEAPIToken=$TOKEN" "$@"; }
    vm_status() { pve "$API/status/current" | jq -r '.data.status // "unknown"'; }
  '';

  wakeScript = name: svc: pkgs.writeShellScript "ondemand-wake-${name}" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.netcat-gnu ]}"
    ${apiEnv svc}

    # keep the client waiting until the app really answers. An open port is not
    # enough, apps often return 5xx for a while after starting.
    for i in $(seq 1 ${toString svc.bootTimeout}); do
      # check the power state every 10s, the VM might be shutting down right now.
      # API errors just mean we try again next round.
      if [ $((i % 10)) -eq 1 ]; then
        STATUS=$(vm_status || echo unknown)
        if [ "$STATUS" = "stopped" ]; then
          echo "vm-${toString svc.vmid} is stopped, starting for ${name}"
          pve -X POST "$API/status/start" >/dev/null || echo "start request failed, retrying"
        fi
      fi
      if nc -z -w 2 ${(vmOf svc).ip} ${toString svc.targetPort}; then
        ${if svc.httpCheck then ''
        code=$(curl -sk -o /dev/null -w '%{http_code}' -m 3 "http://${(vmOf svc).ip}:${toString svc.targetPort}/" 2>/dev/null || echo 000)
        case "$code" in 000|5??) : ;; *) exit 0 ;; esac
        '' else "exit 0"}
      fi
      sleep 1
    done

    echo "vm-${toString svc.vmid} not ready at ${(vmOf svc).ip}:${toString svc.targetPort} in ${toString svc.bootTimeout}s"
    exit 1
  '';

  sleepScript = name: svc: pkgs.writeShellScript "ondemand-sleep-${name}" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.systemd ]}"

    # only power down after a clean idle exit. A crash or a failed wake must
    # leave the VM alone, otherwise a boot loop would keep shutting it off.
    [ "''${SERVICE_RESULT:-}" = "success" ] || exit 0
    ${siblingsBusy svc}
    ${apiEnv svc}

    echo "${name} idle for ${(vmOf svc).cooldown}, shutting down vm-${toString svc.vmid}"
    pve -X POST "$API/status/shutdown" >/dev/null
  '';

  # the proxy only powers a VM off after it served a connection. A VM that was
  # started some other way (sync.sh deploy, Hermes, the Proxmox UI) and never
  # got a request would run forever; the reaper stops it after the cooldown.
  reaperScript = pkgs.writeShellScript "ondemand-reaper" ''
    set -uo pipefail
    export PATH="${lib.makeBinPath [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.systemd ]}"
    now=$(date +%s)
    ${lib.concatStrings (lib.mapAttrsToList (name: svc: ''
      (
        ${apiEnv svc}
        cooldown=${toString (toSeconds (vmOf svc).cooldown)}
        ${siblingsBusy svc}
        cur=$(pve "$API/status/current")
        [ "$(echo "$cur" | jq -r '.data.status // ""')" = running ] || exit 0
        uptime=$(echo "$cur" | jq -r '.data.uptime // 0')
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
      default = "https://192.168.178.200:8006/api2/json";
      description = "Proxmox API base URL.";
    };

    node = lib.mkOption {
      type = lib.types.str;
      default = "luca-server";
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

    # the first connection waits in the socket queue while the VM boots.
    systemd.sockets = lib.mapAttrs' (name: svc:
      lib.nameValuePair "ondemand-${name}" {
        description = "On-demand activation socket for ${name}";
        wantedBy = [ "sockets.target" ];
        socketConfig = {
          ListenStream = "127.0.0.1:${toString svc.listenPort}";
          # one proxy process for all connections, not one per connection.
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
          # start-pre holds the client while the VM boots; systemd's default 90s
          # start timeout would kill the wake before a cold VM answers.
          TimeoutStartSec = svc.bootTimeout + 60;
          ExecStartPre = wakeScript name svc;
          ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd"
            + " --exit-idle-time=${(vmOf svc).cooldown}"
            + " ${(vmOf svc).ip}:${toString svc.targetPort}";
          ExecStopPost = sleepScript name svc;
          # A failed wake should not blacklist the unit; the next connection retries.
          Restart = "no";
        };
      }
    ) active // lib.optionalAttrs (active != {}) {
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
    };
  };
}
