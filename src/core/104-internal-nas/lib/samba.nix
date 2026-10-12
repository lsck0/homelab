# the nas's smb: the owner's shares, each open to one samba user only, sealed (SMB 3.1.1 encryption), no guest
#
# The user's password comes from the secret samba-homelab, a copy of the dotfiles' cifs credentials file of the same
# name (username=<user>, password=<password>), which the owner's machines mount with; samba-user writes it into the
# passdb at every boot and on every change of the secret, and drops any other passdb user.
#
# The homelab share is the whole tree, data/ with every service's state and BACKUPS/ with the kopia repository among
# it, acting as root: the owner reads and writes every service's files. A new file takes the owner and mode of its
# directory (inherit owner/permissions), so what the owner drops into a service's state stays that service's.
# The shares of homelab.smb.shares act as nobody, as before; they keep the smaller views (inbox, media) mountable.
{ config, lib, pkgs, inventory, site, ... }:
let
  cfg = config.homelab.smb;
  net = import ../../../modules/net.nix { inherit lib inventory site; };
  samba = config.services.samba.package;
  credentials = config.sops.secrets.samba-homelab.path;
  # the whole tree, the owner's single mount on every machine
  homelabShare = "homelab";
  nasRoot = "/srv/nas";

  ownerShare = { browseable = "yes"; "valid users" = cfg.user; };
  nobodyShare = share: ownerShare // {
    inherit (share) path;
    "force user" = "nobody";
    "force group" = "nogroup";
    "read only" = if share.writable then "no" else "yes";
  } // lib.optionalAttrs share.writable { "create mask" = "0664"; "directory mask" = "0775"; };
in {
  options.homelab.smb = {
    user = lib.mkOption {
      type = lib.types.strMatching "[a-z_][a-z0-9_-]*";
      default = "luca";
      description = "The one samba user, the owner; samba-homelab's username= must name it.";
    };
    shares = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          path = lib.mkOption { type = lib.types.str; };
          writable = lib.mkOption { type = lib.types.bool; default = false; };
        };
      });
      default = { };
      description = "Shares acting as nobody, by name, beside the homelab share of the whole tree.";
    };
  };

  config = {
    assertions = [{
      assertion = !(cfg.shares ? ${homelabShare});
      message = "homelab.smb.shares.${homelabShare}: the name of the share of the whole tree";
    }];

    # the copy secrets-sync.sh keeps of the dotfiles' cifs credentials file
    sops.secrets.samba-homelab.restartUnits = [ "samba-user.service" ];

    # passdb users map to a unix account; this one never logs in, every share forces its own user
    users.users.${cfg.user} = { isSystemUser = true; group = "nogroup"; };

    services.samba = {
      enable = true;
      openFirewall = true;
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
          # owner pc and notebook (dhcp-reserved in the fritzbox), wireguard and tailnet only
          "hosts allow" = "${site.lan.workstation} ${site.lan.notebook} ${net.wireguard.subnet} ${net.tailnet} 127.0.0.1";
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
      } // lib.mapAttrs (_: nobodyShare) cfg.shares;
    };

    systemd.services.samba-user = {
      description = "Set the owner's samba password from samba-homelab, drop every other samba user";
      wantedBy = [ "multi-user.target" ];
      before = [ "samba-smbd.service" ];
      path = [ samba pkgs.gnused pkgs.coreutils ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        # the first value of a credentials file's key
        field() { sed -n "/^$1=/{s///p;q}" ${credentials}; }
        user=$(field username)
        password=$(field password)
        if [ "$user" != ${cfg.user} ] || [ -z "$password" ]; then
          echo "samba-homelab must hold username=${cfg.user} and a password= line: fill the dotfiles' samba-homelab" >&2
          exit 1
        fi
        printf '%s\n%s\n' "$password" "$password" | smbpasswd -s -a ${cfg.user} >/dev/null
        for other in $(pdbedit -L | cut -d: -f1); do
          [ "$other" = ${cfg.user} ] || pdbedit -x -u "$other"
        done
      '';
    };
  };
}
