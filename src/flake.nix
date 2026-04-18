{
  description = "Homelab NixOS Configurations";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, sops-nix, ... }:
  let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    lib = nixpkgs.lib;

    common = {
      imports = [
        ({ pkgs, lib, modulesPath, ... }: {
          imports = [
            (modulesPath + "/profiles/qemu-guest.nix")
            ./modules/docker-stack.nix
          ];

          options.homelab.acmeEmail = lib.mkOption {
            type = lib.types.str;
            default = "admin@example.com";
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
              defaultSopsFile = ./secrets.yaml;
              age.keyFile = "/var/lib/sops-nix/key.txt";
              gnupg.sshKeyPaths = [];
            };

            services.qemuGuest.enable = true;
            # Use simple eth0 naming so cloud-init network config matches
            networking.usePredictableInterfaceNames = false;
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
            };
            networking.firewall.allowedTCPPorts = [ 9100 ];

            # Prefer IPv4 — internal VMs have no IPv6 routing
            networking.enableIPv6 = false;

            nix.settings.experimental-features = [ "nix-command" "flakes" ];
            system.stateVersion = "25.11";
          };
        })
        sops-nix.nixosModules.sops
      ];
    };

    hostDirs = [ ./instances ];

    hostEntries = builtins.concatLists (map (dir:
      map (name: {
        inherit dir name;
      }) (builtins.filter
        (name:
          (name == "300-router.nix") ||
          (name == "301-grafana.nix") ||
          ((builtins.match "^[12][0-9]{2}-(internal|external)-.*\\.nix$" name) != null)
        )
        (builtins.attrNames (builtins.readDir dir)))
    ) hostDirs);

    parseEntry = entry: let
      basename = lib.removeSuffix ".nix" entry.name;
      parts = lib.splitString "-" basename;
      vmId = lib.toInt (builtins.head parts);
      type =
        if builtins.length parts >= 2 then builtins.elemAt parts 1
        else "unknown";
    in { inherit basename vmId type; };

    networkConfig = parsed: { lib, ... }: let
      # Compute static IP from VM ID and type
      subnet =
        if parsed.type == "internal" then "10.100.0"
        else if parsed.type == "external" then "10.200.0"
        else null;
      gateway =
        if parsed.type == "internal" then "10.100.0.1"
        else if parsed.type == "external" then "10.200.0.1"
        else null;
    in lib.mkIf (subnet != null) {
      networking.useDHCP = lib.mkDefault false;
      networking.interfaces.eth0.ipv4.addresses = [{
        address = "${subnet}.${toString parsed.vmId}";
        prefixLength = 24;
      }];
      networking.defaultGateway = { address = gateway; interface = "eth0"; };
      networking.nameservers = [ gateway ];
    };

    hostConfigs = builtins.listToAttrs (map (entry: let
      parsed = parseEntry entry;
    in {
      name = parsed.basename;
      value = lib.nixosSystem {
        inherit system;
        modules = [
          common
          (networkConfig parsed)
          (entry.dir + "/${entry.name}")
        ];
      };
    }) hostEntries);

  in {
    # Golden Image
    # Build with: sudo nix build ./src#cloud-image --extra-experimental-features "nix-command flakes"
    packages.${system}.cloud-image = let
      goldenConfig = (lib.nixosSystem {
        inherit system;
        modules = [
          common
          ({ lib, ... }: {
            services.cloud-init.enable = true; services.cloud-init.network.enable = true;
            # Ensure only root is used and no default 'nixos' user is created
            services.cloud-init.settings = {
              users = [ "root" ];
              disable_root = false;
            };
          })
        ];
      }).config;
    in import "${nixpkgs}/nixos/lib/make-disk-image.nix" {
      inherit pkgs lib;
      config = goldenConfig;
      format = "qcow2";
      diskSize = "auto";
      additionalSpace = "1G";
      label = "nixos";
    };

    # Host configs are auto-discovered from src/instances/{1XX-internal-*,2XX-external-*,300-router}.nix
    nixosConfigurations = hostConfigs;
  };
}
