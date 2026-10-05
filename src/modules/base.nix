{ config, pkgs, lib, ... }:
let
  # vm-105 collects every journal and feeds loki
  isCollector = config.networking.hostName == "vm-105";
  promtailOn = isCollector || (config.homelab.traefik.enable or false);

  # only the secrets this host reads, encrypted to its own key (scripts/secrets-hosts.sh)
  hostSecrets = ../host-secrets + "/${config.networking.hostName}.json";
  # the golden image and lxc template boot as "nixos"; they have no key, the first deploy brings host and secrets
  isInstallImage = config.networking.hostName == "nixos";
in {
  imports = [
    ./db-backup.nix
    ./swarm.nix
    ./local-state.nix
    ./nas.nix
    ./network.nix
    ./traefik.nix
    ./on-demand.nix
    ./retry.nix
    ./servarr.nix
    ./tokens.nix
  ];

  options.homelab.acmeEmail = lib.mkOption {
    type = lib.types.str;
    default = "luca.sandrock@proton.me";
    description = "Default email for ACME certificates.";
  };

  config = {
    assertions = [{
      assertion = isInstallImage || builtins.pathExists hostSecrets;
      message = "${toString hostSecrets} missing: run src/scripts/secrets-hosts.sh (sync.sh does)";
    }];

    sops = {
      defaultSopsFile = lib.mkIf (!isInstallImage) hostSecrets;
      # the host's own key, pushed by sync.sh; it opens host-secrets/<host>.json and nothing else
      age.keyFile = "/var/lib/sops-nix/key.txt";
      gnupg.sshKeyPaths = [];
    };

    # eth0 naming so cloud-init config matches
    networking.usePredictableInterfaceNames = false;
    # deployer, owner, owner's YubiKey, hermes: the same files terraform and sync.sh (proxmox) install
    users.users.root.openssh.authorizedKeys.keyFiles = lib.filesystem.listFilesRecursive ../keys;

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
      openFirewall = lib.mkDefault true;
      # services publish their own metrics here
      enabledCollectors = [ "textfile" ];
      extraFlags = [ "--collector.textfile.directory=/var/lib/node-exporter-textfile" ];
    };
    systemd.tmpfiles.rules = [
      "d /var/lib/node-exporter-textfile 0755 root root -"
    ];

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
            # docker and podman log to journald: every container is unit docker.service without these
            { source_labels = [ "__journal_container_name" ]; target_label = "container_name"; }
            # swarm task containers are <stack>_<service>.<slot>.<task id>: without the task id, a new stream per
            # deploy and restart. same patterns as the cadvisor scrape in 105-internal-grafana.nix
            { source_labels = [ "__journal_container_name" ]; regex = "([^.]+\\.[^.]+)\\.[^.]+"; target_label = "container_name"; }
            { source_labels = [ "__journal_container_name" ]; regex = "([^.]+)\\.[^.]+\\.[^.]+"; target_label = "swarm_service"; }
            { source_labels = [ "__journal_container_name" ]; regex = "([^_.]+)_[^.]+\\.[^.]+\\.[^.]+"; target_label = "swarm_stack"; }
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

    # internal vms have no ipv6 routing
    networking.enableIPv6 = false;

    # deploys come in bursts, each an uncollected generation; 14d kept 20+ and filled small disks
    nix.gc = { automatic = true; dates = "daily"; options = "--delete-older-than 3d"; };
    services.journald.extraConfig = "SystemMaxUse=200M";
    nix.optimise.automatic = true;

    # attic (vm-110) substituter, read-only netrc token
    sops.secrets.attic-pull-token = lib.mkIf (!isInstallImage) {};
    sops.templates."nix-netrc" = lib.mkIf (!isInstallImage) {
      content = ''
        machine 10.100.0.110
          password ${config.sops.placeholder.attic-pull-token}
      '';
    };
    nix.settings = lib.mkMerge [
      { experimental-features = [ "nix-command" "flakes" ]; }
      (lib.mkIf (!isInstallImage) {
        netrc-file = config.sops.templates."nix-netrc".path;
        extra-substituters = [ "http://10.100.0.110:8080/homelab" ];
        extra-trusted-public-keys = [ "homelab:OtKSPQnvWs0hIa5D2RxbBwENbAo9qkX3yAr5PoWvtyc=" ];
      })
    ];
    system.stateVersion = "25.11";
  };
}
