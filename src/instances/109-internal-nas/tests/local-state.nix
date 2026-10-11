# local state with a nas copy as shipped (modules/local-state) on a lab guest, against a test nas exporting its
# share by the real rules and running the real kopia and nas-restore. Claims: neither direction destroys the other
# copy; a kopia restore of the share reaches the guest and the mirror never overwrites it; diverged copies are
# refused; a dropped share leaves no stale automount (modules/nas.nix nas-mounts-prune). The share is a real
# localState share of vm-121 (instance.nix `shares`), so nas-restore knows it.
{ pkgs, lib, specialArgs, ... }:
let
  lab = import ../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
  name = "paperless";
  local = "/var/lib/demo";
  nasCopy = "/srv/${name}-nas";
  share = "/srv/nas/data/${name}";
in
assert lib.assertMsg (lib.any (s: s.path == share && s.localState) lab.specialArgs.lab.shares."121")
  "local-state test: vm-121 no longer declares ${share} as local state; pick another of its shares";
pkgs.testers.runNixOSTest {
  name = "local-state";
  imports = [ lab.testDefaults ];

  node.specialArgs = lab.specialArgs;
  nodes.vm-109 = {
    imports = [ (lab.nas { flat = true; }) ../lib/kopia.nix ];
    virtualisation.memorySize = 2048;
    # kopia-init snapshots the nas's own local state too
    systemd.tmpfiles.rules = [ "d /var/lib/syncthing 0700 root root -" "d /var/lib/filebrowser 0700 root root -" ];
  };
  nodes.vm-121 = {
    imports = [ (lab.guest "121" { flat = true; nas = true; }) ];
    homelab.localState.${name} = { path = local; unit = "demo"; };
    # the app the seed must precede
    systemd.services.demo = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; ExecStart = "${pkgs.coreutils}/bin/true"; };
    };
    specialisation.dropped.configuration.homelab.localState = lib.mkForce { };
  };

  testScript = ''
    import json

    def generations():
        return (vm_121.succeed("cat ${local}/.generation").strip(), vm_109.succeed("cat ${share}/.generation").strip())

    def restart_app():
        vm_121.succeed("systemctl reset-failed ${name}-seed demo; systemctl restart demo")

    start_all()
    vm_109.wait_for_unit("nfs-exports-reload.service")
    vm_109.wait_for_unit("kopia-server.service")
    vm_121.wait_for_unit("demo.service")

    with subtest("a fresh guest with an empty nas copy is seeded, both copies carry one generation"):
        here, there = generations()
        assert here and here == there, (here, there)

    with subtest("the mirror copies local data to the nas"):
        vm_121.succeed("echo v1 > ${local}/state.txt && systemctl start ${name}-mirror")
        assert vm_109.succeed("cat ${share}/state.txt").strip() == "v1"

    with subtest("a kopia restore reaches the guest; the mirror reseeds instead of overwriting it"):
        vm_109.succeed("nas-restore now")
        good = json.loads(vm_109.succeed("kopia-nas snapshot list /srv/nas --json"))[-1]["id"]
        vm_121.succeed("echo v2 > ${local}/state.txt && systemctl start ${name}-mirror")
        assert vm_109.succeed("cat ${share}/state.txt").strip() == "v2"
        out = vm_109.succeed(f"nas-restore service ${name} {good} --yes")
        assert "vm-121's local state" in out, out
        assert vm_109.succeed("cat ${share}/state.txt").strip() == "v1"
        restored = vm_109.succeed("cat ${share}/.restored").strip()
        assert restored == vm_109.succeed("cat ${share}/.generation").strip(), "the restore is not marked"
        vm_121.succeed("systemctl start ${name}-mirror")
        vm_121.wait_until_succeeds("[ \"$(cat ${local}/state.txt)\" = v1 ]", timeout=60)
        vm_121.wait_until_succeeds("journalctl -u ${name}-seed --no-pager | grep -q 'replaced ${local} with the restored nas copy'", timeout=30)
        assert vm_109.succeed("cat ${share}/state.txt").strip() == "v1", "the mirror overwrote the restore"
        assert generations() == (restored, restored)
        vm_109.fail("test -e ${share}/.restored")
        vm_121.succeed("systemctl is-active demo")

    with subtest("the app starting takes a restore too"):
        vm_109.succeed(f"nas-restore service ${name} {good} --yes")
        vm_121.succeed("echo v3-local > ${local}/state.txt")
        restart_app()
        assert vm_121.succeed("cat ${local}/state.txt").strip() == "v1"

    with subtest("diverged copies: the mirror and the seed refuse, nothing touched"):
        vm_121.succeed("echo v4-local > ${local}/state.txt && echo bogus > ${local}/.generation")
        vm_121.fail("systemctl start ${name}-mirror")
        assert vm_109.succeed("cat ${share}/state.txt").strip() == "v1", "the nas copy changed"
        vm_121.fail("systemctl restart demo")
        vm_121.succeed("journalctl -u ${name}-seed --no-pager | grep -q 'diverged'")
        assert vm_121.succeed("cat ${local}/state.txt").strip() == "v4-local", "the seed overwrote local data"

    with subtest("keeping the nas copy: an emptied local dir is seeded from it"):
        vm_121.succeed("rm -rf ${local}/* ${local}/.generation")
        restart_app()
        assert vm_121.succeed("cat ${local}/state.txt").strip() == "v1"

    with subtest("local data against a nas copy with no generation is adopted, then mirrored"):
        # through the guest's own mount: a deletion on the nas side would sit behind its nfs attribute cache
        vm_121.succeed("rm -rf ${nasCopy}/* ${nasCopy}/.generation")
        vm_121.succeed("echo v5 > ${local}/state.txt && rm ${local}/.generation")
        restart_app()
        assert vm_121.succeed("cat ${local}/state.txt").strip() == "v5"
        vm_121.succeed("systemctl start ${name}-mirror")
        assert vm_109.succeed("cat ${share}/state.txt").strip() == "v5"

    with subtest("a switch that drops the share leaves no stale automount on its mountpoint"):
        vm_121.succeed("ls ${nasCopy} >/dev/null && findmnt ${nasCopy}")
        vm_121.succeed("/run/booted-system/specialisation/dropped/bin/switch-to-configuration test")
        vm_121.fail("findmnt ${nasCopy}")
        vm_121.succeed("systemctl is-active nas-mounts-prune")
  '';
}
