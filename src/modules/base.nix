{ pkgs, lib, modulesPath, ... }: {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ./docker-stack.nix
    ./nas.nix
    ./network.nix
    ./traefik.nix
    ./nas-backup.nix
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
}
