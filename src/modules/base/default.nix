# what every lab host runs: the lab's module stack, sops, ssh, metrics and log shipping
{
  config,
  pkgs,
  lib,
  inventory,
  lab,
  ...
}:
let
  # where every host ships its journal and logs: the collector's address and ports are telemetry.nix's
  telemetry = import ../telemetry.nix { inherit lib inventory; };
  isCollector = config.networking.hostName == "vm-${telemetry.collectorVmid}";
  promtailOn = isCollector || config.homelab.traefik.enable;
  promtailPort = telemetry.ports.promtail;
  inherit (config.homelab) textfileDir;
  failedUnitsFile = "systemd_failed_units";
  driftFile = "system_drift";
  # sync.nu records each generation it deploys or finds deployed (scripts/lib/lab.nu DEPLOYED_TOPLEVEL_FILE)
  deployedToplevelFile = "/var/lib/homelab/deployed-toplevel";

  # which file each secret comes from (modules/secrets.nix); null on the install images, which have no key
  secrets = import ../secrets.nix { inherit lib lab; };
  host = secrets.hostOf config.networking.hostName;

  # a path segment or query value of 32+ token characters is a secret in the url (feed tokens, share links)
  urlSecretPattern = "[/=]([A-Za-z0-9_-]{32,})";

  # a line naming its own level (logfmt or json) is labeled with it in journald's words, whatever priority journald
  # gave it: podman tags every stderr line err, and loki's warnings arrive as info
  ownLevels = {
    err = "error|fatal";
    warning = "warn";
    info = "info";
    debug = "debug";
  };
  ownLevelStages = lib.mapAttrsToList (level: words: {
    match = {
      selector = ''{job="systemd-journal"} |~ "(level=|\"level\":\")(${words})"'';
      stages = [ { static_labels = { inherit level; }; } ];
    };
  }) ownLevels;
  # crowdsec's lapi logs every bouncer's poll (loki itself logs at warn, 103-internal-grafana)
  noiseStages = [
    {
      match = {
        selector = ''{unit="podman-crowdsec.service"} |~ "GET /v1/(heartbeat|allowlists|decisions)"'';
        action = "drop";
        drop_counter_reason = "crowdsec_poll";
      };
    }
  ];
in
{
  imports = [
    ../db-backup
    ../swarm
    ../local-state
    ../nas.nix
    ../network.nix
    ../traefik
    ../on-demand
    ../retry.nix
    ../tokens
    ../textfile
    ../upstream
  ];

  # every secret from the file the layout puts it in: its folder's, its app's, or its own copy of the shared ones
  options.sops.secrets = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { config, ... }:
        {
          config.sopsFile = lib.mkIf (host != null) (lib.mkDefault (../.. + "/${secrets.fileOf host config.key}"));
        }
      )
    );
  };

  options.homelab.acmeEmail = lib.mkOption {
    type = lib.types.str;
    default = "luca.sandrock@proton.me";
    description = "Default email for ACME certificates.";
  };

  config = {
    _module.args.catalog = lib.mkDefault lab.catalog;

    sops = {
      # the host's own key, pushed by sync.nu; it opens this host's files and nothing else
      age.keyFile = "/var/lib/sops-nix/key.txt";
      # only the pushed key: an ssh host key as a second identity would be one more key that opens the file
      age.sshKeyPaths = [ ];
      gnupg.sshKeyPaths = [ ];
    };

    # cloud-init's config names eth0
    networking.usePredictableInterfaceNames = false;
    # deployer, owner, owner's YubiKey, hermes: the same files terraform and sync.nu (proxmox) install
    users.users.root.openssh.authorizedKeys.keyFiles = lib.filesystem.listFilesRecursive ../../secrets/keys;

    services.openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "prohibit-password";
        PasswordAuthentication = false;
      };
    };

    security.sudo.wheelNeedsPassword = false;

    # nushell: the lab's script language, for an operator on the guest as for its units
    environment.systemPackages = with pkgs; [
      vim
      curl
      htop
      nushell
    ];
    services.prometheus.exporters.node = {
      enable = true;
      openFirewall = lib.mkDefault true;
      enabledCollectors = [ "textfile" ];
      extraFlags = [ "--collector.textfile.directory=${textfileDir}" ];
    };
    systemd.tmpfiles.rules = [ "d ${textfileDir} 0755 root root -" ];

    # a unit that failed and stays failed raises no other signal: a oneshot's error, a crashed timer's job
    systemd.services.systemd-failed-units-metric = {
      description = "Write the failed systemd units for the node exporter";
      serviceConfig.Type = "oneshot";
      path = [
        config.systemd.package
        pkgs.gawk
      ];
      script = ''
        metric=${textfileDir}/${failedUnitsFile}.prom
        {
          printf '# TYPE homelab_systemd_failed_units gauge\n'
          # a unit whose file a switch removed is not-found: nothing in the config can fix or restart it
          systemctl --failed --plain --no-legend --no-pager \
            | awk '$2 != "not-found" { printf "homelab_systemd_failed_units{unit=\"%s\"} 1\n", $1 }'
        } > "$metric.tmp"
        mv "$metric.tmp" "$metric"
      '';
    };
    systemd.timers.systemd-failed-units-metric = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "1min";
      };
    };
    # a hand-run switch or rollback leaves the host off what the repo last deployed; no record: never deployed by sync
    systemd.services.system-drift-metric = {
      description = "Write whether the running system is the one sync.nu deployed";
      serviceConfig.Type = "oneshot";
      path = [ pkgs.coreutils ];
      script = ''
        metric=${textfileDir}/${driftFile}.prom
        if [ ! -s ${deployedToplevelFile} ]; then
          rm -f "$metric"
          exit 0
        fi
        drift=1
        if [ "$(readlink -f /run/current-system)" = "$(cat ${deployedToplevelFile})" ]; then drift=0; fi
        printf '# TYPE homelab_system_drift gauge\nhomelab_system_drift %s\n' "$drift" > "$metric.tmp"
        mv "$metric.tmp" "$metric"
      '';
    };
    systemd.timers.system-drift-metric = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "5min";
      };
    };
    homelab.textfiles = [
      failedUnitsFile
      driftFile
    ];

    # journals ship to vm-103's journal-remote; a few MB each instead of a promtail per host
    services.journald.upload = lib.mkIf (!isCollector) {
      enable = true;
      settings.Upload.URL = telemetry.urls.journalUpload;
    };
    # every failed upload logs at err: a guest that boots before vm-103, or a burst journal-remote drops, retries every
    # 3 s at nixpkgs' default; the upload resumes from its cursor, so a slower retry loses nothing
    systemd.services.systemd-journal-upload.serviceConfig.RestartSec = lib.mkIf (!isCollector) (lib.mkForce "30s");

    systemd.services.promtail = lib.mkIf promtailOn {
      # its namespaced start needs a state dir
      serviceConfig.StateDirectory = "promtail";
      # journal-remote writes its files 0640 to its own group; without it no remote host reaches loki
      serviceConfig.SupplementaryGroups = lib.optional isCollector "systemd-journal-remote";
    };
    services.promtail = lib.mkIf promtailOn {
      enable = true;
      configuration = {
        server = {
          http_listen_port = promtailPort;
          grpc_listen_port = 0;
        };
        positions.filename = "/var/lib/promtail/positions.yaml";
        clients = [ { url = telemetry.urls.lokiPush; } ];
        scrape_configs =
          lib.optionals isCollector (
            map
              (j: {
                job_name = j.name;
                journal = {
                  max_age = "12h";
                  labels = {
                    job = "systemd-journal";
                  };
                }
                // lib.optionalAttrs (j.path != null) { inherit (j) path; };
                relabel_configs = [
                  {
                    source_labels = [ "__journal__systemd_unit" ];
                    target_label = "unit";
                  }
                  {
                    source_labels = [ "__journal__hostname" ];
                    target_label = "host";
                  }
                  {
                    source_labels = [ "__journal_priority_keyword" ];
                    target_label = "level";
                  }
                  # docker and podman log to journald: every container is unit docker.service without these
                  {
                    source_labels = [ "__journal_container_name" ];
                    target_label = "container_name";
                  }
                  # swarm task containers: without the task id, a new stream per deploy and restart (telemetry.nix)
                  {
                    source_labels = [ "__journal_container_name" ];
                    regex = telemetry.swarmTaskPatterns.container;
                    target_label = "container_name";
                  }
                  {
                    source_labels = [ "__journal_container_name" ];
                    regex = telemetry.swarmTaskPatterns.service;
                    target_label = "swarm_service";
                  }
                  {
                    source_labels = [ "__journal_container_name" ];
                    regex = telemetry.swarmTaskPatterns.stack;
                    target_label = "swarm_stack";
                  }
                ];
                pipeline_stages = noiseStages ++ ownLevelStages;
              })
              [
                {
                  name = "journal";
                  path = null;
                }
                {
                  name = "journal-remote";
                  path = "/var/log/journal/remote";
                }
              ]
          )
          # access log feeds the world map
          ++ lib.optional config.homelab.traefik.enable {
            job_name = "traefik-access";
            static_configs = [
              {
                targets = [ "localhost" ];
                labels = {
                  job = "traefik-access";
                  host = config.networking.hostName;
                  "__path__" = config.homelab.traefik.accessLog;
                };
              }
            ];
            pipeline_stages = [
              {
                replace = {
                  expression = urlSecretPattern;
                  replace = "<redacted>";
                };
              }
              {
                json.expressions = {
                  country = "\"request_Cf-Ipcountry\"";
                  status = "DownstreamStatus";
                  method = "RequestMethod";
                };
              }
              {
                labels = {
                  country = "";
                  status = "";
                  method = "";
                };
              }
            ];
          };
      };
    };

    # vm-103 scrapes every promtail for dropped entries; the port is guarded, modules/flows.nix grants vm-103
    networking.firewall.allowedTCPPorts = lib.mkIf (promtailOn && !isCollector) [ promtailPort ];
    homelab.ingressOnly.ports = lib.mkIf (promtailOn && !isCollector) [ promtailPort ];

    # internal vms have no ipv6 routing
    networking.enableIPv6 = false;

    # deploys come in bursts, each an uncollected generation; 14d kept 20+ and filled small disks
    nix.gc = {
      automatic = true;
      dates = "daily";
      options = "--delete-older-than 3d";
    };
    services.journald.extraConfig = "SystemMaxUse=200M";
    nix.optimise.automatic = true;

    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];
    system.stateVersion = "25.11";
  };
}
