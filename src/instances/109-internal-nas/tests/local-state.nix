# local state with a nas copy as shipped (modules/local-state) on a lab guest, against a test nas that exports its
# share by the real rules and runs the real kopia and nas-restore (lib/kopia.nix). Claims: neither direction destroys
# the other copy; a kopia restore of the share reaches the guest and the mirror never overwrites it; diverged copies
# are refused; a service whose state lay on the share itself moves onto the guest's disk with its data; a dropped
# share leaves no stale automount (modules/nas.nix nasMountsPrune); what lies in the nas data tree without a share
# is closed to root and listed, never deleted (lib/nas-exports.nix).
{ pkgs, lib, specialArgs, ... }:
let
  lab = import ../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
  name = "demo";
  local = "/var/lib/demo";
  nasCopy = "/srv/${name}-nas";
  share = "/srv/nas/data/${name}";
  # rsync as shipped, ending as when the app replaced a file mid-copy (exit 24) while /tmp/vanish exists
  vanishingRsync = pkgs.writeShellScriptBin "rsync" ''
    ${pkgs.rsync}/bin/rsync "$@" || exit $?
    if [ -e /tmp/vanish ]; then exit 24; fi
  '';
in
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
    systemd.services."${name}-mirror".path = lib.mkBefore [ vanishingRsync ];
    specialisation.dropped.configuration.homelab.localState = lib.mkForce { };
    # the layout before localState: the app's state directory is the share itself
    specialisation.onShare.configuration = { nasMount, ... }: {
      homelab.localState = lib.mkForce { };
      homelab.nasMounts = nasMount local name;
    };
  };

  testScript = ''
    import json

    def generations():
        return (vm_121.succeed("cat ${local}/.generation").strip(), vm_109.succeed("cat ${share}/.generation").strip())

    def restart_app():
        vm_121.succeed("systemctl reset-failed ${name}-seed demo; systemctl restart demo")

    def switch(configuration):
        vm_121.succeed(f"{configuration}/bin/switch-to-configuration test")

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

    with subtest("a file the app replaces mid-copy does not fail the mirror"):
        vm_121.succeed("echo v1b > ${local}/state.txt && touch /tmp/vanish && systemctl start ${name}-mirror && rm /tmp/vanish")
        assert vm_109.succeed("cat ${share}/state.txt").strip() == "v1b"
        vm_121.succeed("grep -q 'state=\"${name}\"' /var/lib/node-exporter-textfile/local_state_${name}.prom")
        vm_121.succeed("echo v1 > ${local}/state.txt && systemctl start ${name}-mirror")

    with subtest("a kopia restore reaches the guest; the mirror reseeds instead of overwriting it"):
        vm_109.succeed("nas-restore now")
        good = json.loads(vm_109.succeed("kopia-nas snapshot list /srv/nas --json"))[-1]["id"]
        vm_121.succeed("echo v2 > ${local}/state.txt && systemctl start ${name}-mirror")
        assert vm_109.succeed("cat ${share}/state.txt").strip() == "v2"
        out = vm_109.succeed(f"nas-restore service ${name} {good} --yes")
        assert "vm-121's local state" in out and "systemctl start ${name}-reseed" in out, out
        assert vm_109.succeed("cat ${share}/state.txt").strip() == "v1"
        marked = vm_109.succeed("cat ${share}/.generation").strip()
        assert marked.startswith("restored-"), f"the restore is not marked: {marked}"
        restored = marked.removeprefix("restored-")
        vm_121.succeed("systemctl start ${name}-mirror")
        vm_121.wait_until_succeeds("[ \"$(cat ${local}/state.txt)\" = v1 ]", timeout=60)
        vm_121.wait_until_succeeds("journalctl -u ${name}-seed --no-pager | grep -q 'replaced ${local} with the restored nas copy'", timeout=30)
        assert vm_109.succeed("cat ${share}/state.txt").strip() == "v1", "the mirror overwrote the restore"
        assert generations() == (restored, restored), "the mark stayed, or the ids differ"
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

    with subtest("state that lived on the share itself moves onto the guest's disk, the share keeps it"):
        vm_121.succeed("rm -rf ${nasCopy}/* ${nasCopy}/.generation ${local}/* ${local}/.generation")
        switch("/run/booted-system/specialisation/onShare")
        vm_121.succeed("echo on-share > ${local}/state.txt && findmnt ${local}")
        assert vm_109.succeed("cat ${share}/state.txt").strip() == "on-share"
        switch("/run/booted-system")
        vm_121.wait_for_unit("demo.service")
        vm_121.fail("findmnt ${local}")
        assert vm_121.succeed("cat ${local}/state.txt").strip() == "on-share"
        assert vm_109.succeed("cat ${share}/state.txt").strip() == "on-share", "the nas copy changed"
        here, there = generations()
        assert here and here == there, (here, there)

    with subtest("an undeclared dir in the nas data tree is closed to root and listed, its data kept"):
        vm_109.succeed("mkdir -p /srv/nas/data/stray && chmod 0777 /srv/nas/data/stray && echo old > /srv/nas/data/stray/key")
        vm_109.succeed("chown nobody:nogroup /srv/nas/data/stray && systemctl restart nas-data-orphans")
        assert vm_109.succeed("stat -c '%a %U' /srv/nas/data/stray").strip() == "700 root"
        assert vm_109.succeed("cat /srv/nas/data/stray/key").strip() == "old"
        vm_109.succeed("journalctl -u nas-data-orphans --no-pager | grep -q 'orphan: /srv/nas/data/stray'")
        assert vm_109.succeed("stat -c '%a' ${share}").strip() == "777", "a declared share was closed"

    with subtest("a switch that drops the share leaves no stale automount on its mountpoint"):
        vm_121.succeed("ls ${nasCopy} >/dev/null && findmnt ${nasCopy}")
        switch("/run/booted-system/specialisation/dropped")
        vm_121.fail("findmnt ${nasCopy}")
        vm_121.fail("systemctl is-active $(systemd-escape --path ${nasCopy}).automount")
  '';
}
