# what an instance.nix may say: the facts other hosts and terraform read about one guest, typed and defaulted once
#
# An instance folder is src/instances/<vmid>-<zone>-<service>/: main.nix is the guest's nixos configuration,
# instance.nix the data below, and modules/lab collects every instance.nix into the lab's facts. An unknown key,
# a wrong type or a missing required field fails every host's evaluation naming the option. Cross-instance rules
# (unique hosts, ports, tokens, vmids) are modules/lab's and modules/catalog.nix's.
#
# instance.nix is a module over this schema with the arguments id (the vmid, a string), zone, site (site.json), net
# (modules/net.nix over the collected inventory), telemetry (modules/telemetry.nix) and swarmManagers (the vmids of
# every enabled swarm's manager, modules/lab). The smallest:
#
#   # what the guest is for, in one line
#   { ... }: {
#     vm.bootPhase = "apps";
#     services.demo = { port = 80; homepage.icon = "mdi-cube"; };
#   }
#
# Guest kind: a vm when it is the router, sits outside the internal zone (strangers' traffic wants a vm's isolation),
# passes a device through, takes extra disks, or `needs` what an unprivileged container cannot give (its own
# container runtime, nfs); an unprivileged lxc otherwise. `vm.kind.<kind> = "<why>"` overrides the rule.
{ lib, config, id, zone, ... }:
let
  inherit (lib) mkOption types;
  service = import ./service.nix { inherit lib; };

  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  # host boot starts the lab phase by phase: storage first, the public side last (proxmox startup order)
  bootPhases = [ "nas" "network" "dev" "apps" "media" "public" ];
  # plain vm working set measured 445-600 MiB
  memoryDefaultMiB = 768;
  # at 384 MiB a vm drops ssh
  balloonFloorMiB = 512;
  # proxmox's own cpu weight
  cpuUnitsDefault = 100;
  diskDefaultGiB = 8;
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

  serviceType = types.submodule ({ name, ... }: {
    config.off.frontend = lib.mkDefault "a nixos service's own ui sends no browser telemetry";
    options = service.exposureOptions { inherit name zone; features = service.protectionFeatures ++ service.telemetryFeatures; } // {
      homepage = mkOption {
        type = service.cardType { inherit name; group = "Apps"; icon = "mdi-web"; description = ""; };
        default = { };
        description = "The service's card on the dashboard (vm-103); off.homepage drops it.";
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
        description = "Name -> an exporter of the service vm-105 scrapes.";
      };
    };
  });

  grantType = types.submodule {
    options = {
      from = mkOption { type = types.nonEmptyListOf vmidString; description = "Guests (vmids) that may connect."; };
      tcp = mkOption { type = types.nonEmptyListOf types.port; description = "Guarded ports of this guest they may reach."; };
      why = mkOption { type = why; description = "Why the grant exists."; };
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
      features = mkOption { type = types.str; default = "nesting=1"; description = "lxc only: proxmox features, set by sync.sh as root."; };
      bootPhase = mkOption { type = types.enum bootPhases; default = "apps"; description = "When the host boots it, phases in order."; };
      bootOrder = mkOption {
        type = types.ints.positive;
        readOnly = true;
        default = lib.lists.findFirstIndex (phase: phase == config.vm.bootPhase) null bootPhases + 1;
        description = "The proxmox startup order of bootPhase.";
      };
      memoryMiB = mkOption { type = types.ints.positive; default = memoryDefaultMiB; description = "Memory ceiling."; };
      balloonMiB = mkOption {
        type = types.ints.unsigned;
        default = lib.max balloonFloorMiB (config.vm.memoryMiB / 2);
        defaultText = lib.literalExpression "max ${toString balloonFloorMiB} (memoryMiB / 2)";
        description = "Balloon floor (vm), 0: no balloon.";
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
      description = "Who may reach which of this guest's guarded ports (homelab.ingressOnly), besides its zone's ingress.";
    };
    tokens = mkOption {
      type = types.listOf (types.strMatching "[a-z0-9-]+");
      default = [ ];
      description = "Lab tokens this guest mints into its own nas token dir (modules/tokens); others read them.";
    };
    egress = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          via = mkOption { type = types.enum [ "vpn" ]; description = "vpn: the router's shared wireguard exit, with a killswitch."; };
          inbound = mkOption { type = types.bool; description = "The exit's one forwarded port leads here."; };
        };
      });
      default = null;
      description = "Which exit the guest's internet traffic leaves through; null: the house's own address.";
    };
    secrets = mkOption {
      type = types.attrsOf secretKind;
      default = { };
      description = "Secrets only this guest reads -> their kind (src/secrets/shared.nix lists the kinds); shared ones are declared there.";
    };
  };
}
