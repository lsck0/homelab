{ config, pkgs, lib, modulesPath, ... }: {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ./db-backup.nix
    ./docker-stack.nix
    ./nas.nix
    ./network.nix
    ./traefik.nix
    ./on-demand.nix
    ./retry.nix
    ./servarr.nix
  ];

  options.homelab.acmeEmail = lib.mkOption {
    type = lib.types.str;
    default = "luca.sandrock@proton.me";
    description = "Default email for ACME certificates.";
  };

  config = {
    boot.loader.grub.enable = true;
    boot.loader.grub.device = "/dev/sda";
    boot.growPartition = true;

    fileSystems."/" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
      autoResize = true;
    };

    sops = {
      defaultSopsFile = ../secrets.json;
      age.keyFile = "/var/lib/sops-nix/key.txt";
      gnupg.sshKeyPaths = [];
    };

    services.qemuGuest.enable = true;
    # use simple eth0 naming so cloud-init network config matches
    networking.usePredictableInterfaceNames = false;
    users.users.root.openssh.authorizedKeys.keys = [
      # the deploy key sync.sh runs with
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID3CzR77c6L49KNFZWmMc+SEQCda0+MdGBWTrEkZRly+ homelab@luca-pc"
      # the owner's own key, kept in ~/projects/secrets/ssh_privatekey.asc
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOgxytZXc8MSkvCbwV/NZGnXw+6gklCUFxv+llwIIN6Z luca.sandrock@proton.me"
    ]
    # Hermes (vm-114) has root everywhere. Written by src/scripts/hermes-secrets.sh.
    ++ lib.optional (builtins.pathExists ./hermes.pub) (lib.removeSuffix "\n" (builtins.readFile ./hermes.pub));

    services.openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "prohibit-password";
        PasswordAuthentication = false;
      };
    };

    security.sudo.wheelNeedsPassword = false;

    environment.systemPackages = with pkgs; [ vim curl htop ];
    services.prometheus.exporters.node = {
      enable = true;
      openFirewall = true;
      # textfile collector: services publish their own metrics here
      enabledCollectors = [ "textfile" ];
      extraFlags = [ "--collector.textfile.directory=/var/lib/node-exporter-textfile" ];
    };
    systemd.tmpfiles.rules = [
      "d /var/lib/node-exporter-textfile 0755 root root -"
    ];
    networking.firewall.allowedTCPPorts = [ 9100 ];

    # journals to Loki; StateDirectory because promtail's namespaced start needs it
    systemd.services.promtail.serviceConfig = lib.mkIf (config.networking.hostName != "vm-104") {
      StateDirectory = "promtail";
    };
    services.promtail = lib.mkIf (config.networking.hostName != "vm-104") {
      enable = true;
      configuration = {
        server = { http_listen_port = 9080; grpc_listen_port = 0; };
        positions.filename = "/var/lib/promtail/positions.yaml";
        clients = [{ url = "http://10.100.0.105:3100/loki/api/v1/push"; }];
        scrape_configs = [{
          job_name = "journal";
          journal = {
            max_age = "12h";
            labels = { job = "systemd-journal"; };
          };
          relabel_configs = [
            { source_labels = [ "__journal__systemd_unit" ]; target_label = "unit"; }
            { source_labels = [ "__journal__hostname" ]; target_label = "host"; }
            { source_labels = [ "__journal_priority_keyword" ]; target_label = "level"; }
          ];
        }]
        # Traefik VMs also ship the access log, for the country on the world map
        ++ lib.optional (config.homelab.traefik.enable or false) {
          job_name = "traefik-access";
          static_configs = [{
            targets = [ "localhost" ];
            labels = {
              job = "traefik-access";
              host = config.networking.hostName;
              "__path__" = "/var/log/traefik/access.log";
            };
          }];
          pipeline_stages = [
            { json.expressions = {
                country = "\"request_Cf-Ipcountry\"";
                status = "DownstreamStatus";
                method = "RequestMethod";
                service = "ServiceName";
              };
            }
            { labels = { country = ""; status = ""; method = ""; }; }
          ];
        };
      };
    };

    # No syslog forwarding: Wazuh is gone and promtail already ships journals.

    # prefer IPv4: internal VMs have no IPv6 routing
    networking.enableIPv6 = false;

    # reduce idle CPU power; has no effect on throughput
    powerManagement.cpuFreqGovernor = "powersave";

    # every deploy adds a system generation and nothing else ever collects them
    nix.gc = { automatic = true; dates = "weekly"; options = "--delete-older-than 14d"; };
    nix.optimise.automatic = true;

    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    # attic (vm-110) as an extra substituter, read-only token via netrc
    sops.secrets.attic-pull-token = {};
    sops.templates."nix-netrc".content = ''
      machine 10.100.0.110
        password ${config.sops.placeholder.attic-pull-token}
    '';
    nix.settings = {
      netrc-file = config.sops.templates."nix-netrc".path;
      extra-substituters = [ "http://10.100.0.110:8080/homelab" ];
      extra-trusted-public-keys = [ "homelab:OtKSPQnvWs0hIa5D2RxbBwENbAo9qkX3yAr5PoWvtyc=" ];
    };
    system.stateVersion = "25.11";
  };
}
