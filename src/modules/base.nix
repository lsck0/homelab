{ config, pkgs, lib, ... }:
let
  # vm-105 collects every journal and feeds loki
  isCollector = config.networking.hostName == "vm-105";
  promtailOn = isCollector || (config.homelab.traefik.enable or false);
in {
  imports = [
    ./db-backup.nix
    ./docker-stack.nix
    ./local-state.nix
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
    sops = {
      defaultSopsFile = ../secrets.json;
      age.keyFile = "/var/lib/sops-nix/key.txt";
      gnupg.sshKeyPaths = [];
    };

    # eth0 naming so cloud-init config matches
    networking.usePredictableInterfaceNames = false;
    users.users.root.openssh.authorizedKeys.keys = [
      # sync.sh deploy key
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID3CzR77c6L49KNFZWmMc+SEQCda0+MdGBWTrEkZRly+ homelab@luca-pc"
      # owner's personal key
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOgxytZXc8MSkvCbwV/NZGnXw+6gklCUFxv+llwIIN6Z luca.sandrock@proton.me"
    ]
    # hermes (vm-114), written by hermes-secrets.sh
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
      # services publish their own metrics here
      enabledCollectors = [ "textfile" ];
      extraFlags = [ "--collector.textfile.directory=/var/lib/node-exporter-textfile" ];
    };
    systemd.tmpfiles.rules = [
      "d /var/lib/node-exporter-textfile 0755 root root -"
    ];
    networking.firewall.allowedTCPPorts = [ 9100 ];

    # journals ship to vm-105's journal-remote; a few MB each instead of a promtail per host
    services.journald.upload = lib.mkIf (!isCollector) {
      enable = true;
      settings.Upload.URL = "http://10.100.0.105:19532";
    };

    # promtail only on the collector and where a file log exists (traefik access)
    # namespaced start needs a statedir
    systemd.services.promtail = lib.mkIf promtailOn {
      serviceConfig.StateDirectory = "promtail";
      # journal-remote writes its files 0640 to its own group; without it no remote host reaches loki
      serviceConfig.SupplementaryGroups = lib.optional isCollector "systemd-journal-remote";
    };
    services.promtail = lib.mkIf promtailOn {
      enable = true;
      configuration = {
        server = { http_listen_port = 9080; grpc_listen_port = 0; };
        positions.filename = "/var/lib/promtail/positions.yaml";
        clients = [{ url = "http://10.100.0.105:3100/loki/api/v1/push"; }];
        scrape_configs = lib.optionals isCollector (map (j: {
          job_name = j.name;
          journal = {
            max_age = "12h";
            labels = { job = "systemd-journal"; };
          } // lib.optionalAttrs (j.path != null) { inherit (j) path; };
          relabel_configs = [
            { source_labels = [ "__journal__systemd_unit" ]; target_label = "unit"; }
            { source_labels = [ "__journal__hostname" ]; target_label = "host"; }
            { source_labels = [ "__journal_priority_keyword" ]; target_label = "level"; }
          ];
        }) [ { name = "journal"; path = null; } { name = "journal-remote"; path = "/var/log/journal/remote"; } ])
        # access log feeds the world map
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

    # no syslog forwarding: promtail ships journals

    # internal vms have no ipv6 routing
    networking.enableIPv6 = false;

    # every deploy adds an uncollected generation
    # deploys come in bursts; 14d kept 20+ generations and filled small disks
    nix.gc = { automatic = true; dates = "daily"; options = "--delete-older-than 3d"; };
    services.journald.extraConfig = "SystemMaxUse=200M";
    nix.optimise.automatic = true;

    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    # attic (vm-110) substituter, read-only netrc token
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
