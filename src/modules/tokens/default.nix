# runtime api tokens one guest mints and others use, one nas dir per producer
#
# A token is minted by the app that owns it (an *arr's api key, home assistant's long-lived token), so it cannot
# live in sops. Each producer writes only its own directory, exported read-write to it alone and owned by root on
# the nas (only the producer's root writes it), and a consumer mounts read-only exactly the producers of the tokens
# it reads. A producer declares what it writes in its instance.nix (`tokens`), a consumer what it reads
# (`tokenReads`, or a role, modules/lab); the collector derives both the registry below and vm-109's exports from
# them. A producer writes through ownDir: a temp file, then a rename into place, so a reader never sees half a token.
#
# Limit: the nas tells clients apart by source address alone. The guarantee holds only while a guest cannot take
# another's address on the bridge, which Proxmox's per-NIC ip filter (terraform, lib.tf) has to enforce.
{ config, lib, nasMount, nasMountRo, lab, instance, ... }:
let
  cfg = config.homelab.tokens;

  # token -> vmid of the guest that mints it: every instance.nix's `tokens`
  producers = lab.tokens;

  ownId = if config.homelab.vmid == null then null else lib.toInt config.homelab.vmid;

  mints = lib.attrNames (lib.filterAttrs (_: id: id == ownId) producers);
  touched = lib.unique (mints ++ cfg.reads);
  hostDir = id: "${mountRoot}/vm-${toString id}";
  mountRoot = "/var/lib/lab-tokens.d";
  readIds = lib.unique (map (name: producers.${name}) cfg.reads);
  shareOf = id: lib.removePrefix "data/" (lab.tokenShare.pathOf id);
  tokenName = lib.types.enum (lib.attrNames producers);
in {
  options.homelab.tokens = {
    reads = lib.mkOption {
      type = lib.types.listOf tokenName;
      default = if instance == null then [ ] else lab.tokenReads.${instance.id};
      defaultText = lib.literalExpression "lab.tokenReads.<vmid>";
      description = "Tokens this host reads besides its own: its instance.nix `tokenReads` and its roles' (modules/lab).";
    };

    all = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = lib.attrNames producers;
      description = "Every token name, for hosts that read them all.";
    };

    producers = lib.mkOption {
      type = lib.types.attrsOf lib.types.int;
      readOnly = true;
      default = producers;
      description = "Token name to the vmid that mints it.";
    };

    dir = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "/var/lib/lab-tokens";
      description = ''
        <name>.token for every token this host reads or mints, as links into the producers' mounts. Read through
        it; write through ownDir.
      '';
    };

    ownDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      readOnly = true;
      default = if mints == [ ] then null else hostDir ownId;
      description = "This host's own read-write token directory: write a .tmp file there, then rename it into place.";
    };

    mountPoints = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = map hostDir (lib.unique (lib.optional (mints != [ ]) ownId ++ readIds));
      description = "The nas mounts behind dir, for RequiresMountsFor.";
    };
  };

  config = lib.mkIf (touched != [ ]) {
    homelab.nasMounts = lib.mkMerge (
      lib.optional (mints != [ ])
        (lib.mapAttrs (_: m: m // { shareMode = lab.tokenShare.mode; }) (nasMount (hostDir ownId) (shareOf ownId)))
      ++ map (id: nasMountRo (hostDir id) (shareOf id)) (lib.remove ownId readIds)
    );

    systemd.tmpfiles.rules = [ "d ${cfg.dir} 0755 root root -" ]
      ++ map (name: "L+ ${cfg.dir}/${name}.token - - - - ${hostDir producers.${name}}/${name}.token") touched;
  };
}
