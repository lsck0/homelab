# the NAS's nfs exports, from the shares every guest declares (nasClients: lab.nasClients, a test's tests/lib/nas-clients.nix)
#
# Each guest gets exactly the paths it mounts, read-only where it mounts them read-only; the dmz and the apps zone
# additionally get subtree checks. Every exported data share is a directory created with its parents before the
# exports are reloaded: any uid may write it (the guests' services run as their own uids), unless its writer
# declares a mode (homelab.nasMounts.<mountpoint>.shareMode), which makes it root's, as the tokens and db dumps are.
# vm-109 enables it; a test enables it on its stand-in nas with nasClients computed over the test's nodes.
#
# Limit: an export trusts the client's source address (sec=sys). Only Proxmox binding each guest's NIC to its
# inventory address makes that address mean the guest; see modules/tokens.
{ config, lib, pkgs, inventory, site, nasClients, ... }:
let
  cfg = config.homelab.nasExports;
  net = import ../../../modules/net.nix { inherit lib inventory site; };
  nfsPorts = [ net.ports.nfs net.ports.rpcbind ];
  # nfsd sizes its largest rpc from the ram at start; ballooned down it shrinks and hard mounts hang on "RPC fragment too large"
  nfsdMaxBlockBytes = 1048576;

  dataRoot = "/srv/nas/data";
  dataShares = lib.filter (lib.hasPrefix "${dataRoot}/") (lib.attrNames clientsByPath);
  # "/srv/nas/data/a/b/c" -> [ "/srv/nas/data/a" "/srv/nas/data/a/b" ]
  parentsOf = path: let parts = lib.splitString "/" (lib.removePrefix "${dataRoot}/" path); in
    map (n: "${dataRoot}/${lib.concatStringsSep "/" (lib.take n parts)}") (lib.range 1 (lib.length parts - 1));

  # a share's mode, as its clients declare it: one mode, or none (0777 for any uid)
  modeOf = path: let modes = lib.unique (lib.filter (m: m != null) (map (c: c.mode or null) clientsByPath.${path})); in
    if lib.length modes > 1 then throw "nas-exports: clients of ${path} declare the share modes ${toString modes}"
    else if modes == [ ] then null else lib.head modes;
  shareRule = path: let mode = modeOf path; in
    if mode == null then "d ${path} 0777 nobody nogroup -" else "d ${path} ${mode} root root -";

  # dmz and apps zone clients get subtree checks
  internalIps = map (v: v.ip) (lib.filter (v: v.type == "internal") (lib.attrValues inventory));

  # every guest's nas mounts as { path, ip, readOnly }, grouped by path
  clientsByPath = lib.groupBy (c: c.path)
    (lib.concatLists (lib.mapAttrsToList (ip: map (s: s // { inherit ip; })) nasClients));
  exportOptions = c: lib.concatStringsSep "," ([
    (if c.readOnly then "ro" else "rw") "sync" "no_root_squash"
    (if lib.elem c.ip internalIps then "no_subtree_check" else "subtree_check")
  ]
  # a missing hdd must not export the empty mountpoint on the nvme
  ++ lib.optional (lib.hasPrefix "/srv/nas/bulk" c.path) "mp=/srv/nas/bulk");
in {
  options.homelab.nasExports.enable = lib.mkEnableOption "the nfs exports of every path a guest mounts (nasClients)";

  config = lib.mkIf cfg.enable {
    services.nfs.server = {
      enable = true;
      exports = lib.concatStrings (lib.mapAttrsToList (path: clients:
        "${path} ${lib.concatMapStringsSep " " (c: "${c.ip}(${exportOptions c})") clients}\n"
      ) clientsByPath);
    };

    systemd.services.nfs-server.serviceConfig.ExecStartPre =
      [ "${pkgs.bash}/bin/sh -c 'echo ${toString nfsdMaxBlockBytes} > /proc/fs/nfsd/max_block_size'" ];

    # nixpkgs' nfsd module restarts only mountd when /etc/exports changes, and only nfs-server's start runs exportfs:
    # a share added by a deploy stays unexported, and its clients get "No such file or directory", until a reboot
    systemd.services.nfs-exports-reload = {
      description = "Re-export the NAS shares after /etc/exports changes";
      # a new share's directory comes from tmpfiles, which a switch reruns in the same transaction
      after = [ "nfs-server.service" "systemd-tmpfiles-setup.service" "systemd-tmpfiles-resetup.service" ];
      requires = [ "nfs-server.service" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ config.environment.etc.exports.source ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.nfs-utils}/bin/exportfs -ra";
      };
    };

    networking.firewall.allowedTCPPorts = nfsPorts;
    networking.firewall.allowedUDPPorts = nfsPorts;

    # per-service state: every share a guest mounts; a `d` line also fixes the mode and owner of an existing one
    systemd.tmpfiles.rules = map shareRule dataShares
      # tmpfiles' d makes no missing parents: a nested share (tokens/vm-140) needs its parents spelled out. root owns
      # them and the data root, since tmpfiles refuses any path below a directory a non-root user owns
      ++ map (path: "d ${path} 0755 root root -")
        ([ dataRoot ] ++ lib.subtractLists dataShares (lib.unique (lib.concatMap parentsOf dataShares)));
  };
}
