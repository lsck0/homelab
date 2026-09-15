{ config, lib, pkgs, ... }:
let
  cfg = config.homelab.onDemand;

  # Talks to the Proxmox API as the host this module runs on. The token file
  # holds the full "USER@REALM!TOKENID=SECRET" string.
  wakeScript = name: svc: pkgs.writeShellScript "ondemand-wake-${name}" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.netcat-gnu ]}"

    TOKEN=$(cat ${cfg.tokenFile})
    API="${cfg.apiUrl}/nodes/${cfg.node}/qemu/${toString svc.vmid}"

    STATUS=$(curl -sk -H "Authorization: PVEAPIToken=$TOKEN" "$API/status/current" \
      | jq -r '.data.status // "unknown"')

    if [ "$STATUS" != "running" ]; then
      echo "vm-${toString svc.vmid} is $STATUS, starting for ${name}"
      curl -sk -X POST -H "Authorization: PVEAPIToken=$TOKEN" "$API/status/start" >/dev/null
    fi

    # Hold the queued client connection until the service actually answers.
    for _ in $(seq 1 ${toString svc.bootTimeout}); do
      nc -z -w 2 ${svc.target} ${toString svc.targetPort} && exit 0
      sleep 1
    done

    echo "vm-${toString svc.vmid} did not open ${svc.target}:${toString svc.targetPort} in ${toString svc.bootTimeout}s"
    exit 1
  '';

  sleepScript = name: svc: pkgs.writeShellScript "ondemand-sleep-${name}" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pkgs.curl pkgs.coreutils ]}"

    # Only power down after a clean idle exit. A crash or a failed wake must
    # leave the VM alone, otherwise a boot loop would keep shutting it off.
    [ "''${SERVICE_RESULT:-}" = "success" ] || exit 0

    TOKEN=$(cat ${cfg.tokenFile})
    API="${cfg.apiUrl}/nodes/${cfg.node}/qemu/${toString svc.vmid}"

    echo "${name} idle, shutting down vm-${toString svc.vmid}"
    curl -sk -X POST -H "Authorization: PVEAPIToken=$TOKEN" "$API/status/shutdown" >/dev/null
  '';

  serviceType = lib.types.submodule ({ ... }: {
    options = {
      vmid = lib.mkOption {
        type = lib.types.int;
        description = "Proxmox VM ID to start and stop.";
      };

      listenAddress = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Address the activation proxy listens on.";
      };

      listenPort = lib.mkOption {
        type = lib.types.port;
        description = "Port the activation proxy listens on. Point the reverse proxy here instead of at the VM.";
      };

      target = lib.mkOption {
        type = lib.types.str;
        description = "IP of the on-demand VM.";
      };

      targetPort = lib.mkOption {
        type = lib.types.port;
        description = "Port on the on-demand VM to forward to.";
      };

      idleTimeout = lib.mkOption {
        type = lib.types.str;
        default = "30m";
        description = "How long the VM stays up after the last connection closes.";
      };

      bootTimeout = lib.mkOption {
        type = lib.types.int;
        default = 180;
        description = "Seconds to wait for the VM to answer before failing the connection.";
      };
    };
  });
in {
  options.homelab.onDemand = {
    enable = lib.mkEnableOption "socket-activated VMs that boot on first request";

    apiUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://192.168.178.200:8006/api2/json";
      description = "Proxmox API base URL.";
    };

    node = lib.mkOption {
      type = lib.types.str;
      default = "pve";
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
      description = "On-demand services, keyed by name.";
    };
  };

  config = lib.mkIf (cfg.enable && cfg.services != {}) {
    # systemd holds the client connection in the socket queue while the VM
    # boots, so the first request waits instead of being refused — as long as
    # the client's own timeout is longer than the boot.
    systemd.sockets = lib.mapAttrs' (name: svc:
      lib.nameValuePair "ondemand-${name}" {
        description = "On-demand activation socket for ${name}";
        wantedBy = [ "sockets.target" ];
        socketConfig = {
          ListenStream = "${svc.listenAddress}:${toString svc.listenPort}";
          # One proxy process for all connections, not one per connection.
          Accept = false;
        };
      }
    ) cfg.services;

    systemd.services = lib.mapAttrs' (name: svc:
      lib.nameValuePair "ondemand-${name}" {
        description = "On-demand proxy for ${name} (vm-${toString svc.vmid})";
        requires = [ "ondemand-${name}.socket" ];
        after = [ "ondemand-${name}.socket" "network-online.target" ];
        serviceConfig = {
          ExecStartPre = wakeScript name svc;
          ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd"
            + " --exit-idle-time=${svc.idleTimeout}"
            + " ${svc.target}:${toString svc.targetPort}";
          ExecStopPost = sleepScript name svc;
          # A failed wake should not blacklist the unit; the next connection retries.
          Restart = "no";
        };
      }
    ) cfg.services;
  };
}
