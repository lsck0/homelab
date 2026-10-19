# the nas's smb: the owner's shares, each open to the one samba user only, sealed (SMB 3.1.1 encryption), no guest
#
# The password comes from samba-homelab, a copy of the dotfiles' cifs credentials file (username=, password=).
# security: the homelab share is the whole tree acting as root, BACKUPS and every service's state among it; a new
# file takes the owner and mode of its directory, so what the owner drops into a service's state stays the service's.
{
  config,
  lib,
  pkgs,
  inventory,
  site,
  ...
}:
let
  cfg = config.homelab.smb;
  net = import ../../../../modules/net.nix { inherit lib inventory site; };
  firewall = import ./firewall-allow.nix { inherit lib net; };
  smbPorts = [
    139
    445
  ];
  samba = config.services.samba.package;
  credentials = config.sops.secrets.samba-homelab.path;
  # the one samba user, the owner; samba-homelab's username= names it
  user = "luca";
  # the whole tree, the owner's single mount on every machine
  homelabShare = "homelab";
  nasRoot = "/srv/nas";

  ownerShare = {
    browseable = "yes";
    "valid users" = user;
  };
  nobodyShare =
    share:
    ownerShare
    // {
      inherit (share) path;
      "force user" = "nobody";
      "force group" = "nogroup";
      "read only" = if share.writable then "no" else "yes";
    }
    // lib.optionalAttrs share.writable {
      "create mask" = "0664";
      "directory mask" = "0775";
    };
in
{
  options.homelab.smb = {
    shares = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            path = lib.mkOption { type = lib.types.str; };
            writable = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
          };
        }
      );
      default = { };
      description = "Shares acting as nobody, by name, beside the homelab share of the whole tree.";
    };
  };

  config = {
    assertions = [
      {
        assertion = !(cfg.shares ? ${homelabShare});
        message = "homelab.smb.shares.${homelabShare}: the name of the share of the whole tree";
      }
    ];

    # the copy secrets-sync.nu keeps of the dotfiles' cifs credentials file
    sops.secrets.samba-homelab.restartUnits = [ "samba-user.service" ];

    # passdb users map to a unix account; this one never logs in, every share forces its own user
    users.users.${user} = {
      isSystemUser = true;
      group = "nogroup";
    };

    services.samba = {
      enable = true;
      settings = {
        global = {
          workgroup = "WORKGROUP";
          "server string" = "${config.networking.hostName}-nas";
          "map to guest" = "never";
          # no anonymous share listing either
          "restrict anonymous" = "2";
          # every client is a current linux cifs or windows; nothing in the lab speaks smb, the guests mount nfs
          "server min protocol" = "SMB3_11";
          "server smb encrypt" = "required";
          "hosts allow" = "${toString firewall.ownerSources} 127.0.0.1";
          "hosts deny" = "0.0.0.0/0";
        };
        ${homelabShare} = ownerShare // {
          path = nasRoot;
          "read only" = "no";
          "force user" = "root";
          "force group" = "root";
          "inherit owner" = "unix only";
          "inherit permissions" = "yes";
          # a new file's owner execute bit would stand for the dos archive flag
          "map archive" = "no";
        };
      }
      // lib.mapAttrs (_: nobodyShare) cfg.shares;
    };

    # smbd parses a refused client's packets before hosts allow drops it: the firewall admits only the owner's machines
    networking.firewall.extraCommands = firewall.allowFrom {
      sources = firewall.ownerSources;
      tcp = smbPorts;
    };

    systemd.services.samba-user = {
      description = "Set the owner's samba password from samba-homelab, drop every other samba user";
      wantedBy = [ "multi-user.target" ];
      before = [ "samba-smbd.service" ];
      path = [
        samba
        pkgs.gnused
        pkgs.coreutils
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # the first value of a credentials file's key
        field() { sed -n "/^$1=/{s///p;q}" ${credentials}; }
        user=$(field username)
        password=$(field password)
        if [ "$user" != ${user} ] || [ -z "$password" ]; then
          echo "samba-homelab must hold username=${user} and a password= line: fill the dotfiles' samba-homelab" >&2
          exit 1
        fi
        printf '%s\n%s\n' "$password" "$password" | smbpasswd -s -a ${user} >/dev/null
        for other in $(pdbedit -L | cut -d: -f1); do
          [ "$other" = ${user} ] || pdbedit -x -u "$other"
        done
      '';
    };
  };
}
