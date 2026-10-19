# a guest's long-lived units outlive what the nas does to its mounts: a deploy that changes the exports, a restart of
# nfs-server, the automount's idle expiry after either.
#
#   vm-104  the test nas, by the real export rules; `nixpkgs-mountd` is the generation before the fix, with nixpkgs'
#           restartable nfs-mountd, and `added-share` exports one more share
#   vm-114  mounts its share with a short idle timeout; nginx requires it through nasRequires (modules/nas.nix), and
#           `held` through RequiresMountsFor, the positive control: the expiry stops it, so the fault has happened
{
  pkgs,
  lib,
  specialArgs,
  ...
}:
let
  lab = import ../../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
  share = "/var/lib/calendar";
  addedShare = "/srv/nas/data/added-share";
  # the lab's 60 s, shortened so the test waits past it within seconds
  idleS = 5;
  page = "served-from-local-disk";
in
pkgs.testers.runNixOSTest {
  name = "nfs-restart";

  node.specialArgs = lab.specialArgs;
  nodes.vm-104 = {
    imports = [ (lab.nas { flat = true; }) ];
    specialisation.nixpkgs-mountd.configuration.systemd.services.nfs-mountd.restartIfChanged = lib.mkForce true;
    specialisation.added-share.configuration = {
      services.nfs.server.exports = "${addedShare} ${lab.inventory."114".ip}(ro,sync,subtree_check)\n";
      systemd.tmpfiles.rules = [ "d ${addedShare} 0755 root root -" ];
    };
  };
  nodes.vm-114 =
    { nasMount, nasRequires, ... }:
    {
      imports = [
        (lab.guest "114" {
          flat = true;
          nas = true;
        })
      ];
      homelab.nasMounts = lib.mapAttrs (
        _: m:
        m
        // {
          options = map (
            o: if lib.hasPrefix "x-systemd.idle-timeout=" o then "x-systemd.idle-timeout=${toString idleS}" else o
          ) m.options;
        }
      ) (nasMount share "calendar");

      services.nginx = {
        enable = true;
        virtualHosts.localhost.root = pkgs.writeTextDir "index.html" page;
      };
      systemd.services.nginx = nasRequires [ share ];

      systemd.services.held = {
        wantedBy = [ "multi-user.target" ];
        unitConfig.RequiresMountsFor = [ share ];
        serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
      };
    };

  testScript = ''
    SHARE = "${share}"
    IDLE_S = ${toString idleS}

    def mounted():
        return vm_114.execute(f"findmnt -t nfs4 {SHARE}")[0] == 0

    def expired():
        vm_114.wait_until_succeeds(f"! findmnt -t nfs4 {SHARE}", timeout=IDLE_S * 12)

    def serving():
        vm_114.succeed("systemctl is-active nginx.service")
        assert vm_114.succeed("curl -sf http://localhost/") == "${page}"

    def nfs_server_started():
        return vm_104.succeed("systemctl show -P ActiveEnterTimestampMonotonic nfs-server.service").strip()

    def switch(specialisation):
        vm_104.succeed(f"/run/booted-system/specialisation/{specialisation}/bin/switch-to-configuration test")

    vm_104.start()
    vm_104.wait_for_unit("nfs-exports-reload.service")
    started = nfs_server_started()
    switch("nixpkgs-mountd")
    assert nfs_server_started() != started, "the switch to nixpkgs' nfs-mountd kept nfs-server, the control is void"
    vm_104.wait_for_unit("nfs-exports-reload.service")
    vm_114.start()
    vm_114.wait_for_unit("nginx.service")
    vm_114.wait_for_unit("held.service")
    vm_114.succeed(f"touch {SHARE}/written-before")
    assert mounted()

    with subtest("from nixpkgs' nfs-mountd, an exports change reloads the exports; nfs-server keeps running"):
        started = nfs_server_started()
        switch("added-share")
        assert nfs_server_started() == started, "the exports change restarted nfs-server"
        vm_104.wait_until_succeeds("exportfs -v | grep -q '^${addedShare}'", timeout=60)
        vm_114.succeed("mkdir -p /mnt/added && timeout 30 mount -t nfs4 -o ro ${lab.inventory."104".ip}:${addedShare} /mnt/added")
        vm_114.succeed("umount /mnt/added")
        serving()

    with subtest("nfs-server restarts, the mount expires: nginx keeps serving, RequiresMountsFor stopped its unit"):
        vm_104.succeed("systemctl restart nfs-server")
        expired()
        vm_114.sleep(IDLE_S * 2)
        serving()
        vm_114.fail("systemctl is-active held.service")

    with subtest("the share comes back on access, its data intact"):
        vm_114.succeed(f"test -e {SHARE}/written-before")
        assert mounted()
        serving()
  '';
}
