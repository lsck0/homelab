# the nas's nfs exports, from the shares every guest declares (nasClients: lab.nasClients, a test's tests/lib/nas-clients.nix)
#
# Each guest gets exactly the paths it mounts, read-only where it mounts them read-only, and reaches nfs only from its
# own address. security: every export checks subtrees, so a forged file handle cannot leave its share for the rest of
# the root file system (the age key, BACKUPS); a read-only export of a share any uid writes squashes root. A share
# whose writer declares a mode (homelab.nasMounts.<mountpoint>.shareMode, the tokens and db dumps) is root's and keeps
# the client's root. An export trusts the client's source address (sec=sys), which only Proxmox's per-NIC ip filter
# binds to the guest; see modules/tokens.
#
# The data tree is the shares': anything else below it (a share no guest declares any more) is closed to root and
# listed by nas-data-orphans, never deleted.
{
  config,
  lib,
  pkgs,
  utils,
  inventory,
  site,
  nasClients,
  lab,
  ...
}:
let
  cfg = config.homelab.nasExports;
  net = import ../../../../modules/net.nix { inherit lib inventory site; };
  firewall = import ./firewall-allow.nix { inherit lib net; };
  # nfsd sizes its largest rpc from the ram at start; ballooned down it shrinks and hard mounts hang on "RPC fragment too large"
  nfsdMaxBlockBytes = 1048576;

  dataRoot = "/srv/nas/data";
  dataShares = lib.filter (lib.hasPrefix "${dataRoot}/") (lib.attrNames clientsByPath);
  # "/srv/nas/data/a/b/c" -> [ "/srv/nas/data/a" "/srv/nas/data/a/b" ]
  parentsOf =
    path:
    let
      parts = lib.splitString "/" (lib.removePrefix "${dataRoot}/" path);
    in
    map (n: "${dataRoot}/${lib.concatStringsSep "/" (lib.take n parts)}") (lib.range 1 (lib.length parts - 1));

  # every share a guest declares, powered or not (lab.shares), and the exported ones; their parents hold no data
  labShares = lib.concatLists (lib.attrValues lab.shares);
  declaredShares = lib.unique (lib.filter (lib.hasPrefix "${dataRoot}/") (map (s: s.path) labShares ++ dataShares));
  declaredParents = lib.subtractLists declaredShares (lib.unique (lib.concatMap parentsOf declaredShares));
  orphanMode = "0700";

  # a share's mode as its writers declare it, powered or not: one mode, or none (0777 for any uid)
  modeOf =
    path:
    let
      modes = lib.unique (
        lib.filter (m: m != null) (map (s: s.mode) (lib.filter (s: s.path == path) labShares ++ clientsByPath.${path}))
      );
    in
    if lib.length modes > 1 then
      throw "nas-exports: the writers of ${path} declare the share modes ${toString modes}"
    else if modes == [ ] then
      null
    else
      lib.head modes;

  shareRule =
    path:
    let
      mode = modeOf path;
    in
    if mode == null then "d ${path} 0777 nobody nogroup -" else "d ${path} ${mode} root root -";

  # every guest's nas mounts as { path, ip, readOnly, mode }, grouped by path
  clientsByPath = lib.groupBy (c: c.path) (
    lib.concatLists (lib.mapAttrsToList (ip: map (s: s // { inherit ip; })) nasClients)
  );

  # the file system a share lies on below the root (the hdd, the syncthing bind): absent, the export would serve the
  # empty mountpoint on the root disk, so it names it (mp=) and the reload waits for it
  mountpoints = lib.sort (a: b: lib.stringLength a > lib.stringLength b) (
    lib.remove "/" (lib.attrNames config.fileSystems)
  );
  mountpointOf = path: lib.findFirst (m: path == m || lib.hasPrefix "${m}/" path) null mountpoints;
  exportedMountpoints = lib.unique (lib.filter (m: m != null) (map mountpointOf (lib.attrNames clientsByPath)));

  exportOptions =
    c:
    let
      mountpoint = mountpointOf c.path;
    in
    lib.concatStringsSep "," (
      [
        (if c.readOnly then "ro" else "rw")
        "sync"
        "subtree_check"
        (if c.readOnly && modeOf c.path == null then "root_squash" else "no_root_squash")
      ]
      ++ lib.optional (mountpoint != null) "mp=${mountpoint}"
    );
in
{
  options.homelab.nasExports.enable = lib.mkEnableOption "the nfs exports of every path a guest mounts (nasClients)";

  config = lib.mkIf cfg.enable {
    services.nfs.server = {
      enable = true;
      exports = lib.concatStrings (
        lib.mapAttrsToList (
          path: clients: "${path} ${lib.concatMapStringsSep " " (c: "${c.ip}(${exportOptions c})") clients}\n"
        ) clientsByPath
      );
    };

    systemd.services.nfs-server.serviceConfig.ExecStartPre = [
      "${pkgs.bash}/bin/sh -c 'echo ${toString nfsdMaxBlockBytes} > /proc/fs/nfsd/max_block_size'"
    ];

    # nixpkgs' nfsd module restarts only mountd when /etc/exports changes, and only nfs-server's start runs exportfs:
    # a share added by a deploy stays unexported, and its clients get "No such file or directory", until a reboot
    systemd.services.nfs-exports-reload = {
      description = "Re-export the NAS shares after /etc/exports changes";
      # a new share's directory comes from tmpfiles, which a switch reruns in the same transaction; the hdd is nofail,
      # so local-fs.target does not wait for it
      after = [
        "nfs-server.service"
        "systemd-tmpfiles-setup.service"
        "systemd-tmpfiles-resetup.service"
      ]
      ++ map (m: "${utils.escapeSystemdPath m}.mount") exportedMountpoints;
      requires = [ "nfs-server.service" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ config.environment.etc.exports.source ];
      # right after nfsd restarts, exportfs can fail an export ("does not support NFS export") that a retry takes
      startLimitIntervalSec = 0;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.nfs-utils}/bin/exportfs -ra";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    systemd.services.nas-data-orphans = {
      description = "Close and list what lies in the NAS data tree without a share";
      after = [ "nfs-exports-reload.service" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ (builtins.toJSON declaredShares) ];
      path = [ pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        for parent in ${lib.escapeShellArgs ([ dataRoot ] ++ declaredParents)}; do
          for entry in "$parent"/* "$parent"/.[!.]*; do
            [ -e "$entry" ] || [ -L "$entry" ] || continue
            case "$entry" in ${
              lib.concatMapStringsSep "|" lib.escapeShellArg (declaredShares ++ declaredParents)
            }) continue ;; esac
            # a link is listed only: chown and chmod would act on its target
            if [ ! -L "$entry" ] && [ "$(stat -c '%a %U %G' "$entry")" != "${lib.removePrefix "0" orphanMode} root root" ]; then
              chown root:root "$entry"
              chmod ${orphanMode} "$entry"
            fi
            echo "orphan: $entry, no guest declares it (closed to root); delete it once nothing needs it"
          done
        done
      '';
    };

    networking.firewall.extraCommands = firewall.allowFrom {
      sources = lib.attrNames nasClients;
      tcp = [
        net.ports.nfs
        net.ports.rpcbind
      ];
      udp = [ net.ports.rpcbind ];
    };

    # a `d` line also fixes the mode and owner of an existing share. tmpfiles' d makes no missing parents: a nested
    # share (tokens/vm-107) needs its parents spelled out, root's, since tmpfiles refuses any path below a directory a
    # non-root user owns
    systemd.tmpfiles.rules =
      map shareRule dataShares
      ++ map (path: "d ${path} 0755 root root -") (
        [ dataRoot ] ++ lib.subtractLists dataShares (lib.unique (lib.concatMap parentsOf dataShares))
      );
  };
}
