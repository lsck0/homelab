# what every lab host runs: the lab's module stack, sops, ssh, metrics and log shipping, the binary cache
{ config, pkgs, lib, inventory, lab, ... }:
let
  # where every host ships its journal and logs: the collector's address and ports are telemetry.nix's
  telemetry = import ../telemetry.nix { inherit lib inventory; };
  isCollector = config.networking.hostName == "vm-${telemetry.collectorVmid}";
  promtailOn = isCollector || config.homelab.traefik.enable;
  promtailPort = telemetry.ports.promtail;
  textfileDir = config.homelab.textfileDir;
  # the attic binary cache every host substitutes from, and its signing key
  attic = lab.routes.attic;
  atticCache = "homelab";
  atticAddress = inventory.${toString attic.vmid}.ip;

  # which file each secret comes from (modules/secrets.nix); null on the install images, which have no key
  secrets = import ../secrets.nix { inherit lib lab; };
  host = secrets.hostOf config.networking.hostName;
  # the layout before per-folder files, kept until src/scripts/secrets-migrate.sh deletes it: delete both with it
  legacyFile = ../../host-secrets + "/${config.networking.hostName}.json";
  sopsFileOf = key: if builtins.pathExists legacyFile then legacyFile else ../.. + "/${secrets.fileOf host key}";
  # the golden image and lxc template boot as "nixos"; they have no key, the first deploy brings host and secrets
  isInstallImage = config.networking.hostName == "nixos";
in {
  imports = [
    ../apps-catalog
    ../db-backup
    ../swarm
    ../local-state
    ../nas.nix
    ../network.nix
    ../traefik
    ../on-demand
    ../retry.nix
    ../tokens
    ../textfile.nix
  ];

  # every secret from the file the layout puts it in: its folder's, its app's, or its own copy of the shared ones
  options.sops.secrets = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule ({ config, ... }: {
      config.sopsFile = lib.mkIf (host != null) (lib.mkDefault (sopsFileOf config.key));
    }));
  };

  options.homelab.acmeEmail = lib.mkOption {
    type = lib.types.str;
    default = "luca.sandrock@proton.me";
    description = "Default email for ACME certificates.";
  };

  config = {
    sops = {
      # the host's own key, pushed by sync.sh; it opens this host's files and nothing else
      age.keyFile = "/var/lib/sops-nix/key.txt";
      # only the pushed key: an ssh host key as a second identity would be one more key that opens the file
      age.sshKeyPaths = [ ];
      gnupg.sshKeyPaths = [ ];
    };

    # eth0 naming so cloud-init config matches
    networking.usePredictableInterfaceNames = false;
    # deployer, owner, owner's YubiKey, hermes: the same files terraform and sync.sh (proxmox) install
    users.users.root.openssh.authorizedKeys.keyFiles = lib.filesystem.listFilesRecursive ../../lab/keys;

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
      enabledCollectors = [ "textfile" ];
      extraFlags = [ "--collector.textfile.directory=${textfileDir}" ];
    };
    systemd.tmpfiles.rules = [ "d ${textfileDir} 0755 root root -" ];

    # journals ship to vm-105's journal-remote; a few MB each instead of a promtail per host
    services.journald.upload = lib.mkIf (!isCollector) {
      enable = true;
      settings.Upload.URL = telemetry.urls.journalUpload;
    };

    # promtail only on the collector and where a file log exists (traefik access)
    systemd.services.promtail = lib.mkIf promtailOn {
      # its namespaced start needs a state dir
      serviceConfig.StateDirectory = "promtail";
      # journal-remote writes its files 0640 to its own group; without it no remote host reaches loki
      serviceConfig.SupplementaryGroups = lib.optional isCollector "systemd-journal-remote";
    };
    services.promtail = lib.mkIf promtailOn {
      enable = true;
      configuration = {
        server = { http_listen_port = promtailPort; grpc_listen_port = 0; };
        positions.filename = "/var/lib/promtail/positions.yaml";
        clients = [{ url = telemetry.urls.lokiPush; }];
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
            # swarm task containers: without the task id, a new stream per deploy and restart (telemetry.nix)
            { source_labels = [ "__journal_container_name" ]; regex = telemetry.swarmTaskPatterns.container; target_label = "container_name"; }
            { source_labels = [ "__journal_container_name" ]; regex = telemetry.swarmTaskPatterns.service; target_label = "swarm_service"; }
            { source_labels = [ "__journal_container_name" ]; regex = telemetry.swarmTaskPatterns.stack; target_label = "swarm_stack"; }
          ];
        }) [ { name = "journal"; path = null; } { name = "journal-remote"; path = "/var/log/journal/remote"; } ])
        # access log feeds the world map
        ++ lib.optional config.homelab.traefik.enable {
          job_name = "traefik-access";
          static_configs = [{
            targets = [ "localhost" ];
            labels = {
              job = "traefik-access";
              host = config.networking.hostName;
              "__path__" = config.homelab.traefik.accessLog;
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

    # vm-105 scrapes every promtail for dropped entries; the port is guarded, modules/flows.nix grants vm-105
    networking.firewall.allowedTCPPorts = lib.mkIf (promtailOn && !isCollector) [ promtailPort ];
    homelab.ingressOnly.ports = lib.mkIf (promtailOn && !isCollector) [ promtailPort ];

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
        machine ${atticAddress}
          password ${config.sops.placeholder.attic-pull-token}
      '';
    };
    nix.settings = lib.mkMerge [
      { experimental-features = [ "nix-command" "flakes" ]; }
      (lib.mkIf (!isInstallImage) {
        netrc-file = config.sops.templates."nix-netrc".path;
        extra-substituters = [ "http://${atticAddress}:${toString attic.port}/${atticCache}" ];
        extra-trusted-public-keys = [ "${atticCache}:OtKSPQnvWs0hIa5D2RxbBwENbAo9qkX3yAr5PoWvtyc=" ];
      })
    ];
    system.stateVersion = "25.11";
  };
}
