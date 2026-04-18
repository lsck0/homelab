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

    hostConfigs = builtins.listToAttrs (map (entry: {
      name = lib.removeSuffix ".nix" entry.name;
      value = lib.nixosSystem {
        inherit system;
        modules = [
          common
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
