# local state with a nas copy as shipped (modules/local-state) on a lab guest, against a test nas exporting
# its share by the real rules. Claims: neither direction destroys the other copy. The seed restores only into a
# directory without files, adopts local data the nas never mirrored, and refuses local data without its marker when
# the nas holds a mirror; the mirror runs only once seeded and marks the nas copy.
{ pkgs, lib, specialArgs, ... }:
let
  lab = import ../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
  local = "/var/lib/demo";
  nasCopy = "/srv/demo-nas";
  share = "/srv/nas/data/demo";
in
pkgs.testers.runNixOSTest {
  name = "local-state";

  node.specialArgs = lab.specialArgs;
  nodes.vm-109 = lab.nas { flat = true; };
  nodes.vm-121 = {
    imports = [ (lab.guest "121" { flat = true; nas = true; }) ];
    homelab.localState.demo = { path = local; unit = "demo"; };
    # the app the seed must precede
    systemd.services.demo = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; ExecStart = "${pkgs.coreutils}/bin/true"; };
    };
  };

  testScript = ''
    start_all()
    vm_109.wait_for_unit("nfs-exports-reload.service")
    vm_121.wait_for_unit("demo.service")

    with subtest("a fresh guest with an empty nas copy is seeded, and the app starts after it"):
        vm_121.succeed("test -e ${local}/.seeded")

    with subtest("the mirror copies local data to the nas and marks the copy"):
        vm_121.succeed("echo v1 > ${local}/state.txt && systemctl start demo-mirror")
        assert vm_109.succeed("cat ${share}/state.txt").strip() == "v1"
        vm_109.succeed("test -e ${share}/.mirrored")

    with subtest("local data without its marker against a mirrored nas copy: refused, nothing touched"):
        vm_121.succeed("echo v2-local > ${local}/state.txt && rm ${local}/.seeded")
        vm_121.fail("systemctl start demo-seed")
        vm_121.wait_until_succeeds("journalctl -u demo-seed --no-pager | grep -q 'is a mirror'", timeout=30)
        assert vm_121.succeed("cat ${local}/state.txt").strip() == "v2-local", "the seed overwrote local data"
        assert vm_109.succeed("cat ${share}/state.txt").strip() == "v1", "the nas copy changed"
        # an unseeded install never mirrors over the nas copy
        vm_121.succeed("systemctl start demo-mirror")
        assert vm_109.succeed("cat ${share}/state.txt").strip() == "v1"

    with subtest("an emptied local dir is restored from the nas copy"):
        vm_121.succeed("rm -rf ${local}/* && systemctl reset-failed demo-seed")
        vm_121.succeed("systemctl start demo-seed")
        assert vm_121.succeed("cat ${local}/state.txt").strip() == "v1"
        vm_121.succeed("test -e ${local}/.seeded")

    with subtest("local data against a nas copy that was never mirrored is adopted, then mirrored"):
        # through the guest's own mount: a deletion on the nas side would sit behind its nfs attribute cache
        vm_121.succeed("rm -rf ${nasCopy}/* ${nasCopy}/.mirrored")
        vm_121.succeed("echo v3 > ${local}/state.txt && rm ${local}/.seeded")
        vm_121.succeed("systemctl start demo-seed")
        assert vm_121.succeed("cat ${local}/state.txt").strip() == "v3"
        vm_121.succeed("systemctl start demo-mirror")
        assert vm_109.succeed("cat ${share}/state.txt").strip() == "v3"
  '';
}
