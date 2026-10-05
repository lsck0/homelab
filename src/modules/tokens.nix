# runtime api tokens one guest mints and others use: per-producer nas dirs instead of one shared bucket
#
# A token is minted by the app that owns it (an *arr's api key, home assistant's long-lived token), so it
# cannot live in sops. It used to sit in one read-write share every consumer mounted, which handed every
# credential to every guest and let any of them swap one. Now each producer writes only its own directory,
# exported read-write to it alone, and a consumer mounts read-only exactly the producers it lists in
# homelab.tokens.reads. vm-109 derives the exports from these mounts, so the registry below is the policy.
{ config, lib, nasMount, nasMountRo, ... }:
let
  cfg = config.homelab.tokens;

  # token -> vmid of the guest that mints it
  producers = {
    qbittorrent-user = 112; qbittorrent-pass = 112;
    forgejo-key = 115; forgejo-hermes = 115; forgejo-runner = 115;
    paperless-key = 121;
    firefly-token = 124;
    hass-key = 125; hass-pass = 125;
    jellyseerr-key = 128;
    radarr-key = 130; sonarr-key = 130; prowlarr-key = 130; lidarr-key = 130; bazarr-key = 130;
    jellyfin-key = 134; jellyfin-admin-pass = 134; janitorr-pass = 134;
    navidrome-user = 136; navidrome-pass = 136; navidrome-token = 136; navidrome-salt = 136;
    headplane-key = 138;
    # the apps swarm's manager (modules/swarm.nix) publishes how a worker joins
    swarm-worker-token = 140;
  };

  match = builtins.match "vm-([0-9]+)" config.networking.hostName;
  ownId = if match == null then null else lib.toInt (builtins.head match);

  writes = lib.attrNames (lib.filterAttrs (_: id: id == ownId) producers);
  touched = lib.unique (writes ++ cfg.reads);
  hostDir = id: "${mountRoot}/vm-${toString id}";
  mountRoot = "/var/lib/lab-tokens.d";
  readIds = lib.unique (map (name: producers.${name}) cfg.reads);
  shareOf = id: "tokens/vm-${toString id}";
in {
  options.homelab.tokens = {
    reads = lib.mkOption {
      type = lib.types.listOf (lib.types.enum (lib.attrNames producers));
      default = [ ];
      description = "Tokens this host reads. Its own tokens (those it mints, see `producers`) are always there.";
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
        <name>.token for every token this host reads or mints, as links into the producers' mounts. Read
        through it, and write simply (`> file`) through it; a write that renames into place uses ownDir.
      '';
    };

    ownDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      readOnly = true;
      default = if writes == [ ] then null else hostDir ownId;
      description = "This host's own read-write token directory, for writes that rename into place.";
    };

    mountPoints = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = map hostDir (lib.unique (lib.optional (writes != [ ]) ownId ++ readIds));
      description = "The nas mounts behind dir, for RequiresMountsFor.";
    };
  };

  config = lib.mkIf (touched != [ ]) {
    fileSystems = lib.mkMerge (
      lib.optional (writes != [ ]) (nasMount (hostDir ownId) (shareOf ownId))
      ++ map (id: nasMountRo (hostDir id) (shareOf id)) (lib.remove ownId readIds)
    );

    systemd.tmpfiles.rules = [ "d ${cfg.dir} 0755 root root -" ]
      ++ map (name: "L+ ${cfg.dir}/${name}.token - - - - ${hostDir producers.${name}}/${name}.token") touched;
  };
}
