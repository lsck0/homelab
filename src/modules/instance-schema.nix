# what an instance.nix may say: the facts other hosts and terraform read about one guest, typed and defaulted once
#
# instance.nix is a module over this schema with the arguments id, zone, site, net, telemetry, roles, swarmManagers,
# grantSourceNames and profiles; modules/lab collects every one. Cross-instance rules are modules/lab's and
# modules/catalog.nix's. The smallest, a plain route to port 80:
#   { ... }: { vm.bootPhase = "apps"; services.demo.port = 80; }
#
# guest kind: a vm when it is the router, sits outside the internal zone (strangers' traffic wants a vm's isolation),
# passes a device through, takes extra disks, or `needs` what an unprivileged container cannot give (its own
# container runtime, nfs); an unprivileged lxc otherwise. `vm.kind.<kind> = "<why>"` overrides the rule.
{ lib, config, id, zone, telemetry, grantSourceNames, ... }:
let
  inherit (lib) mkOption types;
  service = import ./service.nix { inherit lib; };

  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  # host boot starts the lab phase by phase: storage first, the public side last (proxmox startup order)
  bootPhases = [ "nas" "network" "dev" "apps" "media" "public" ];
  # plain vm working set measured 445-600 MiB; an lxc runs no kernel of its own
  memoryDefaultMiB = { vm = 768; lxc = 512; };
  # at 384 MiB a vm drops ssh
  balloonFloorMiB = 512;
  # the lab's own path (router, ingresses, sso) and the public side, unless idle: squeezed, every route stalls
  unballoonedPhases = [ "network" "public" ];
  # proxmox's own cpu weight
  cpuUnitsDefault = 100;
  diskDefaultGiB = 8;
  # a shared module's listeners beyond the guest's own services: the ingress (modules/traefik and its log shipper),
  # a swarm's manager and worker (modules/swarm), the apps' telemetry on a worker (modules/app-telemetry.nix)
  openingFeatures = [ "ingress" "swarmManager" "swarmWorker" "appTelemetry" ];
  guestFeatures = [ "vpnEgress" "vpnInbound" "torEgress" ] ++ openingFeatures;
  secretKind = types.strMatching (import ./secrets.nix { inherit lib; }).kindPattern;
  vmidString = types.strMatching "[0-9]+";
  inherit (service) urlPath why;

  # -----------------------------------------------------------------------------
  # TYPES
  # -----------------------------------------------------------------------------

  diskType = types.submodule {
    options = {
      sizeGiB = mkOption { type = types.ints.positive; description = "Size of the disk."; };
      store = mkOption {
        type = types.enum [ "guest" "bulk" ];
        default = "guest";
        description = "guest: the datastore of every guest disk (var.proxmox_datastore); bulk: the hdd of site.json `bulk`.";
      };
    };
  };

  oidcType = types.submodule {
    options = {
      name = mkOption { type = types.str; description = "Client name authelia shows."; };
      tokenAuthMethod = mkOption { type = types.enum [ "client_secret_basic" "client_secret_post" ]; description = "How it sends its secret."; };
      callback = mkOption { type = urlPath; description = "The callback path on the service's host."; };
      pkce = mkOption { type = types.bool; description = "The client sends a code challenge (S256)."; };
    };
  };

  serviceType = types.submodule ({ name, config, ... }: {
    # the probers check the backend itself, not the sso portal in front of it
    config.health = lib.mkDefault config.path;
    options = service.exposureOptions { inherit name zone; features = service.protectionFeatures ++ service.exemptionFeatures ++ service.telemetryFeatures; } // {
      homepage = mkOption {
        type = service.cardType { inherit name; group = "Apps"; icon = "mdi-web"; description = ""; };
        default = { };
        description = "The service's card on the dashboard (vm-102), shown with the homepage feature.";
      };
      oidc = mkOption {
        type = types.nullOr oidcType;
        default = null;
        description = "An authelia oidc client named like the service (secret <name>-oidc-secret); users need admins or app-<name>.";
      };
      metrics = mkOption {
        type = types.attrsOf (types.submodule {
          options = {
            port = mkOption { type = types.port; description = "The exporter's port on the instance."; };
            path = mkOption { type = urlPath; default = "/metrics"; description = "The scrape path."; };
          };
        });
        default = { };
        description = "Name -> an exporter of the service vm-103 scrapes.";
      };
    };
  });

  grantType = types.submodule {
    options = {
      from = mkOption {
        type = types.nonEmptyListOf (types.either vmidString (types.enum grantSourceNames));
        description = "Who may connect: guests by vmid or role, or ${lib.concatStringsSep ", " grantSourceNames} (modules/lab `sourceOf`).";
      };
      tcp = mkOption { type = types.nonEmptyListOf types.port; description = "Guarded ports of this guest they may reach."; };
      why = mkOption { type = why; description = "Why the grant exists."; };
    };
  };

  shareType = types.submodule {
    options = {
      readOnly = mkOption { type = types.bool; default = false; description = "vm-104 exports it read-only to this guest."; };
      mode = mkOption {
        type = types.nullOr (types.strMatching "0[0-7]{3}");
        default = null;
        description = "The share's mode on the nas, root's (tokens, db dumps); null: 0777, for services running as their own uid.";
      };
      localState = mkOption {
        type = types.bool;
        default = false;
        description = "The nas copy of the guest's homelab.localState <name>: nas-restore makes the guest take a restore of it.";
      };
    };
  };

  kindDerived = if zone != "internal" || config.vm.pci != [ ] || config.vm.disks != [ ] || config.vm.needs != [ ] then "vm" else "lxc";
  kindOverrides = lib.filterAttrs (_: reason: reason != null) config.vm.kind;
in {
  options = {
    hostName = mkOption {
      type = types.strMatching "[a-z][a-z0-9-]*";
      default = "vm-${id}";
      description = "The guest's hostname; every guest is vm-<vmid>, only the router names itself.";
    };

    vm = {
      power = mkOption {
        type = types.enum [ "on" "off" ];
        default = "on";
        description = "on: started with the host (and stopped by `idle` when set); off: never started.";
      };
      needs = mkOption {
        type = types.listOf (types.enum [ "containers" "nfs" ]);
        default = [ ];
        description = "What the guest's configuration needs of its kernel: its own container runtime, nfs (tests/policy holds main.nix to it).";
      };
      kind = mkOption {
        type = types.submodule {
          options = lib.genAttrs [ "vm" "lxc" ] (kind:
            mkOption { type = types.nullOr why; default = null; description = "Why this guest is a ${kind} against the rule."; });
        };
        default = { };
        description = "Override of the derived kind, with its reason.";
      };
      guestKind = mkOption {
        type = types.enum [ "vm" "lxc" ];
        readOnly = true;
        default = if kindOverrides == { } then kindDerived else lib.head (lib.attrNames kindOverrides);
        description = "The kind the guest is: the rule's, or the override's.";
      };
      privileged = mkOption {
        type = types.bool;
        default = false;
        description = "lxc only, internal zone only: root in the container is root on the host; only for nfs mounts.";
      };
      features = mkOption { type = types.str; default = "nesting=1"; description = "lxc only: proxmox features, set by sync.nu as root."; };
      bootPhase = mkOption { type = types.enum bootPhases; default = "apps"; description = "When the host boots it, phases in order."; };
      bootOrder = mkOption {
        type = types.ints.positive;
        readOnly = true;
        default = lib.lists.findFirstIndex (phase: phase == config.vm.bootPhase) null bootPhases + 1;
        description = "The proxmox startup order of bootPhase.";
      };
      memoryMiB = mkOption { type = types.ints.positive; default = memoryDefaultMiB.${config.vm.guestKind}; description = "Memory ceiling (an lxc's limit)."; };
      balloonMiB = mkOption {
        type = types.ints.unsigned;
        default = if lib.elem config.vm.bootPhase unballoonedPhases && config.idle.stopAfter == null then config.vm.memoryMiB
          else lib.max balloonFloorMiB (config.vm.memoryMiB / 2);
        defaultText = lib.literalExpression "memoryMiB in boot phases ${toString unballoonedPhases} unless idle, else max ${toString balloonFloorMiB} (memoryMiB / 2)";
        description = "Balloon floor (vm), 0: no balloon; tests/policy/guests.nix holds the floors to the node's memory.";
      };
      cores = mkOption { type = types.ints.positive; default = 2; description = "CPU cores."; };
      cpuUnits = mkOption { type = types.ints.positive; default = cpuUnitsDefault; description = "Proxmox cpu weight."; };
      cpuLimitCores = mkOption { type = types.nullOr types.ints.positive; default = null; description = "Proxmox cpulimit in whole cores (the bpg provider takes no fraction); null: none."; };
      diskGiB = mkOption { type = types.ints.positive; default = diskDefaultGiB; description = "Root disk; terraform grows it, never shrinks it."; };
      diskLimits = mkOption {
        type = types.nullOr (types.submodule {
          options = lib.genAttrs [ "readMBps" "writeMBps" "readIops" "writeIops" ] (limit:
            mkOption { type = types.ints.positive; description = "Root disk ${limit}."; });
        });
        default = null;
        description = "Root disk throughput and iops caps; null: none.";
      };
      nicRateMBps = mkOption { type = types.nullOr types.ints.positive; default = null; description = "Nic rate limit; null: none."; };
      machine = mkOption { type = types.nullOr (types.enum [ "q35" ]); default = null; description = "q35 for pci passthrough."; };
      pci = mkOption { type = types.listOf types.str; default = [ ]; description = "Proxmox pci mappings passed through (lib.tf: `gpu`)."; };
      disks = mkOption { type = types.listOf diskType; default = [ ]; description = "Extra disks, scsi1 onward."; };
    };

    idle = mkOption { type = service.idleType; default = { }; description = "When the guest stops on its own; its zone's ingress wakes it."; };

    services = mkOption {
      type = types.attrsOf serviceType;
      default = { };
      description = "Service name (unique in the lab) -> its exposure, protection, card, oidc client and exporters.";
    };
    grants = mkOption {
      type = types.listOf grantType;
      default = [ ];
      description = "Who may reach which of this guest's guarded ports (homelab.ingressOnly), besides its zone's ingress: every source but those is one.";
    };
    shares = mkOption {
      type = types.attrsOf shareType;
      default = { };
      description = "Nas paths below /srv/nas this guest mounts (\"data/<share>\", \"bulk/media\"), token dirs aside (`tokens`, `tokenReads`): vm-104 exports exactly these to it, the router opens nfs to it (lab.nasClients); modules/nas.nix holds its mounts to them.";
    };
    alerts = mkOption {
      type = types.attrsOf telemetry.alertType;
      default = { };
      description = "Grafana rule uid -> a rule over this guest's own metrics or logs (modules/telemetry.nix alertType); vm-103 provisions it.";
    };
    roles = mkOption {
      type = types.listOf (types.strMatching "[a-z][a-z0-9-]*");
      default = [ ];
      description = "Lab-wide roles this guest holds (\"collector\", \"nas\"; \"dashboard\" reads every widget's token, \"operator\" every token); one guest per role (lab.roles), a grant's source by name.";
    };
    tokens = mkOption {
      type = types.listOf (types.strMatching "[a-z0-9-]+");
      default = [ ];
      description = "Lab tokens this guest mints into its own nas token dir (modules/tokens); others read them.";
    };
    tokenReads = mkOption {
      type = types.listOf (types.strMatching "[a-z0-9-]+");
      default = [ ];
      description = "Lab tokens of other guests this one reads; vm-104 exports their minters' dirs to it read-only (lab.nasClients).";
    };
    on = mkOption {
      type = service.featuresType guestFeatures;
      default = [ ];
      description = ''
        What the guest opts into for itself (modules/profiles.nix). vpnEgress: its internet traffic leaves through the
        router's shared wireguard exit, vpnInbound: the exit's one forwarded port leads here; torEgress: through the
        router's tor, tcp and dns only; each with a killswitch, lab traffic staying direct, and without one the house's
        own address. ${lib.concatStringsSep ", " openingFeatures}: the firewall openings of the shared module of that
        name, which refuses to evaluate without its own. Unasked, a guest's firewall opens ssh, node-exporter and its
        services' ports (modules/network.nix), and whatever its own main.nix opens.
      '';
    };
    secrets = mkOption {
      type = types.attrsOf secretKind;
      default = { };
      description = "Secrets only this guest reads -> their kind (src/secrets/shared.nix lists the kinds); shared ones are declared there.";
    };
  };
}
