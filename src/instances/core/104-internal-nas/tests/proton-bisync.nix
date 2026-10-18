# vm-104's two-way sync of the syncthing folder with proton drive (lib/proton-bisync.nu and its engine under the real
# units of lib/kopia.nix) against the fake proton-drive cli (lib/fake-proton-drive.nix), its drive a local folder.
# No session, no baseline and a missing remote root are refused, the share's metric at 0 for the stale alert; the
# baseline merges both sides, deletes nothing, keeps both versions of a file that differs and transfers none that
# agrees; additions, edits and deletions go both ways (a local deletion into the quarantine folder), what lands in the
# folder owned by the syncthing user with its modes and the remote mtime; a conflict keeps both versions; a mass
# deletion waits for allow-large; a missing, unmarked or empty folder is refused; syncthing's internals and symlinks
# stay local; a failing item fails the run and the next run resumes with it alone; a run lists only what its budget
# allows; a download past the free-space reserve and a name beside its unicode normalization twin fail alone; a torn
# events.lock is cleared; an hourly run skips while another off-site run holds the proton lock, and a proton outage
# skips it.
{ pkgs, lib, ... }:
let
  folder = "/srv/nas/syncthing/sync";
  quarantine = "/srv/nas/syncthing/proton-bisync-trash";
  # the drive's folder; the folder's copy sits where the real one does, below /my-files/homelab-offsite
  drive = "/srv/fake-proton";
  remote = "${drive}/my-files/homelab-offsite/sync";
  user = "nobody";
  group = "nogroup";
  fakeCli = import ./lib/fake-proton-drive.nix { inherit pkgs; };
  inherit ((import ../../../../modules/upstream { inherit lib pkgs; lab.upstreams = { }; })._module.args.upstream) unavailable;
  # proton is down while /run/proton-down exists
  probe = pkgs.writeShellScript "proton-probe-fake" ''
    down=${toString unavailable}
    [ ! -e /run/proton-down ] || exit "$down"
  '';
in
pkgs.testers.runNixOSTest {
  name = "proton-bisync";

  nodes.machine = {
    imports = [ ../../../../tests/stubs.nix ../lib/kopia.nix ];
    virtualisation.memorySize = 2048;
    # main.nix's folder and owner; syncthing itself stays off
    services.syncthing = { inherit user group; settings.folders.sync.path = folder; };
    systemd.services = lib.genAttrs [ "proton-bisync" "proton-bisync-resync" ] (_: {
      environment = {
        PROTON_BISYNC_CLI = lib.mkForce (lib.getExe fakeCli);
        PROTON_BISYNC_PROBE = lib.mkForce "${probe}";
        FAKE_DRIVE = drive;
        FAKE_LOG = "/run/fake-proton.log";
        FAKE_FAIL_FILE = "/run/fake-proton-fail";
      };
    });
    # the test starts every run itself
    systemd.timers.proton-bisync.wantedBy = lib.mkForce [ ];
  };

  testScript = ''
    import shlex

    F = "${folder}"
    R = "${remote}"
    Q = "${quarantine}"
    STATE = "/var/lib/proton-bisync"
    PROM = "/var/lib/node-exporter-textfile/proton_bisync.prom"
    LOG = "/run/fake-proton.log"
    OWNER = "${user}:${group}"
    FILLERS = 20

    def owned(cmd):
        """runs a shell command as the folder's owner, as syncthing writes"""
        machine.succeed(f"setpriv --reuid=${user} --regid=${group} --clear-groups -- sh -c {shlex.quote(cmd)}")

    def run(unit: str, ok: bool = True) -> str:
        """starts a run with a fresh cli log and returns the run's log"""
        machine.succeed(f": > {LOG}")
        if ok:
            machine.succeed(f"systemctl start {unit}")
        else:
            machine.fail(f"systemctl start {unit}")
        return machine.succeed(f"journalctl -u {unit} --invocation=0 --no-pager -o cat")

    def cat(path):
        return machine.succeed(f"cat {shlex.quote(path)}").strip()

    def metric():
        return float(machine.succeed(f"awk '/^homelab_offsite_last_success_timestamp_seconds/ {{ print $2 }}' {PROM}"))

    def listing(root):
        return machine.succeed(f"cd {root} && find . | sort")

    def calls(verb):
        """the cli calls of the last run with this verb"""
        return [line for line in machine.succeed(f"cat {LOG}").splitlines() if line.startswith(f"filesystem {verb} ")]

    def absent(*paths):
        for p in paths:
            machine.fail(f"test -e {shlex.quote(p)}")

    def modes(*paths):
        quoted = " ".join(shlex.quote(p) for p in paths)
        return machine.succeed(f"stat -c '%U:%G %a' {quoted}").split()

    machine.wait_for_unit("multi-user.target")
    machine.succeed(f"install -d -o ${user} -g ${group} {F} {F}/.stfolder && mkdir -p ${drive}/my-files/homelab-offsite")
    owned(f"mkdir -p {F}/docs {F}/.stversions && echo local-a > {F}/docs/a.txt && echo local > {F}/common.txt"
          f" && for i in $(seq {FILLERS}); do echo $i > {F}/docs/fill-$i.txt; done"
          f" && echo same > {F}/same.txt && touch -d '2020-01-01 00:00:00.123' {F}/same.txt"
          f" && echo old > {F}/.stversions/old.txt && echo pull > {F}/docs/.syncthing.b.txt.tmp"
          f" && echo pull > {F}/docs/~syncthing~c.txt.tmp && ln -s docs/a.txt {F}/link"
          f" && mkdir -p {F}/work/.identity/ssh && echo key > {F}/work/.identity/ssh/id")

    with subtest("no session: refused before the cli, the share's metric at 0 so the stale alert fires"):
        out = run("proton-bisync", ok=False)
        assert "no proton session" in out, out
        assert metric() == 0, machine.succeed(f"cat {PROM}")

    with subtest("no baseline: refused, pointing at the resync"):
        machine.succeed("mkdir -p /var/lib/proton-drive && echo '{}' > /var/lib/proton-drive/auth-session.json")
        out = run("proton-bisync", ok=False)
        assert "proton-bisync-resync" in out, out

    with subtest("a missing remote root is refused"):
        out = run("proton-bisync-resync", ok=False)
        assert "remote root" in out and "missing" in out, out
        assert calls("upload") == [] and calls("download") == []

    machine.succeed(f"mkdir -p {R}/.stversions {R}/rdir/sub && echo remote-only > {R}/r.txt && echo remote > {R}/common.txt"
                    f" && echo theirs > {R}/.stversions/rv.txt && echo deep > {R}/rdir/sub/deep.txt"
                    f" && mkdir -p {R}/.identity && echo theirs > {R}/.identity/token"
                    f" && echo same > {R}/same.txt && touch -d '2020-01-01 00:00:00.123' {R}/same.txt")

    with subtest("the baseline merges both sides, deletes nothing, keeps both versions of what differs"):
        out = run("proton-bisync-resync")
        assert cat(f"{F}/r.txt") == "remote-only" and cat(f"{F}/rdir/sub/deep.txt") == "deep"
        assert cat(f"{R}/docs/a.txt") == "local-a" and cat(f"{R}/docs/fill-7.txt") == "7"
        for side in [F, R]:
            assert cat(f"{side}/common.txt") == "local", side
            assert cat(f"{side}/common.proton-conflict.txt") == "remote", machine.succeed(f"ls {side}")
        assert not any("same.txt" in c for c in calls("upload") + calls("download")), "an agreeing file moved"
        assert metric() > 0

    with subtest("syncthing's internals, credentials and symlinks stay local, logged, without failing the run"):
        absent(f"{R}/.stfolder", f"{R}/.stversions/old.txt", f"{R}/docs/.syncthing.b.txt.tmp",
               f"{R}/docs/~syncthing~c.txt.tmp", f"{F}/.stversions/rv.txt", f"{R}/link",
               f"{R}/work/.identity/ssh/id", f"{F}/.identity/token")
        assert "stay local" in out and "link" in out, out

    with subtest("what lands in the folder is the syncthing user's, 0644 and 0755, with proton's mtime"):
        assert modes(f"{F}/rdir", f"{F}/rdir/sub", f"{F}/rdir/sub/deep.txt", f"{F}/r.txt",
                     f"{F}/common.proton-conflict.txt") == [OWNER, "755"] * 2 + [OWNER, "644"] * 3
        assert machine.succeed(f"find {F} ! -user ${user} -o ! -group ${group}") == ""
        here, there = machine.succeed(f"stat -c %.3Y {F}/r.txt {R}/r.txt").split()
        assert here == there, (here, there)

    with subtest("additions and edits go both ways; a run with nothing to do moves nothing"):
        owned(f"echo l2 > {F}/l2.txt && echo local-a2 > {F}/docs/a.txt")
        machine.succeed(f"mkdir -p {R}/new/sub && echo r2 > {R}/new/sub/r2.txt"
                        f" && echo remote-edit > {R}/r.txt && touch -d '+1 min' {R}/r.txt")
        run("proton-bisync")
        assert cat(f"{R}/l2.txt") == "l2" and cat(f"{R}/docs/a.txt") == "local-a2"
        assert cat(f"{F}/new/sub/r2.txt") == "r2" and cat(f"{F}/r.txt") == "remote-edit"
        assert modes(f"{F}/new", f"{F}/new/sub/r2.txt") == [OWNER, "755", OWNER, "644"]
        run("proton-bisync")
        assert calls("upload") + calls("download") + calls("trash") + calls("create-folder") == [], machine.succeed(f"cat {LOG}")

    with subtest("deletions go both ways: proton's into its trash, the folder's into the quarantine"):
        owned(f"rm {F}/l2.txt")
        machine.succeed(f"rm {R}/r.txt && rm -r {R}/new")
        run("proton-bisync")
        absent(f"{R}/l2.txt", f"{F}/r.txt", f"{F}/new")
        machine.succeed("test -e ${drive}/trash/l2.txt")
        day = machine.succeed("date +%F").strip()
        assert cat(f"{Q}/{day}/r.txt") == "remote-edit" and cat(f"{Q}/{day}/new/sub/r2.txt") == "r2"

    with subtest("a file changed on both sides keeps both: the folder's version under its name, proton's beside it"):
        owned(f"echo mine > {F}/docs/a.txt")
        machine.succeed(f"echo theirs > {R}/docs/a.txt && touch -d '+2 min' {R}/docs/a.txt")
        run("proton-bisync")
        for side in [F, R]:
            assert cat(f"{side}/docs/a.txt") == "mine", side
            assert cat(f"{side}/docs/a.proton-conflict.txt") == "theirs", machine.succeed(f"ls {side}/docs")

    with subtest("deleting over the limit syncs nothing until allow-large lets one run through"):
        owned(f"rm {F}/docs/fill-1[0-9].txt {F}/docs/fill-[1-5].txt && echo l3 > {F}/l3.txt")
        out = run("proton-bisync", ok=False)
        assert "allow-large" in out, out
        machine.succeed(f"test -e {R}/docs/fill-12.txt")
        absent(f"{R}/l3.txt")
        machine.succeed(f"touch {STATE}/allow-large")
        run("proton-bisync")
        absent(f"{R}/docs/fill-12.txt", f"{R}/docs/fill-3.txt", f"{STATE}/allow-large")
        machine.succeed(f"test -e {R}/docs/fill-20.txt && test -e {R}/l3.txt")

    with subtest("a failing item fails the run; the next run resumes with it alone"):
        before = metric()
        owned(f"echo up1 > {F}/up1.txt")
        machine.succeed(f"mkdir -p {R}/part && echo p1 > {R}/part/p1.txt && echo p2 > {R}/part/p2.txt"
                        f" && echo '*/part/p2.txt' > /run/fake-proton-fail")
        run("proton-bisync", ok=False)
        assert cat(f"{F}/part/p1.txt") == "p1" and cat(f"{R}/up1.txt") == "up1"
        absent(f"{F}/part/p2.txt")
        assert metric() == before
        machine.succeed("rm /run/fake-proton-fail")
        run("proton-bisync")
        assert cat(f"{F}/part/p2.txt") == "p2"
        moved = calls("upload") + calls("download")
        assert len(moved) == 1 and "p2.txt" in moved[0], moved
        assert metric() > before

    with subtest("a run lists what its budget allows; a cold folder's change waits for its turn"):
        machine.succeed("mkdir -p /run/systemd/system/proton-bisync.service.d"
                        " && printf '[Service]\\nEnvironment=PROTON_BISYNC_SWEEP_SECONDS=0\\n'"
                        " > /run/systemd/system/proton-bisync.service.d/budget.conf && systemctl daemon-reload")
        machine.succeed(f"echo deep2 > {R}/rdir/sub/deep.txt && echo top > {R}/top.txt")
        run("proton-bisync")
        assert cat(f"{F}/top.txt") == "top" and cat(f"{F}/rdir/sub/deep.txt") == "deep"
        assert len(calls("list")) == 2, calls("list")
        machine.succeed("rm -r /run/systemd/system/proton-bisync.service.d && systemctl daemon-reload")
        run("proton-bisync")
        assert cat(f"{F}/rdir/sub/deep.txt") == "deep2"

    with subtest("a download past the free-space reserve fails that file and leaves the disk alone"):
        machine.succeed("mkdir -p /run/systemd/system/proton-bisync.service.d"
                        " && printf '[Service]\\nEnvironment=PROTON_BISYNC_FREE_RESERVE_PERCENT=100\\n'"
                        " > /run/systemd/system/proton-bisync.service.d/reserve.conf && systemctl daemon-reload")
        machine.succeed(f"echo big > {R}/big.txt")
        out = run("proton-bisync", ok=False)
        assert "free" in out, out
        absent(f"{F}/big.txt")
        machine.succeed("rm -r /run/systemd/system/proton-bisync.service.d && systemctl daemon-reload")
        run("proton-bisync")
        assert cat(f"{F}/big.txt") == "big"

    with subtest("a name beside its unicode normalization twin stays where it is"):
        nfc, nfd = "Erg\u00e4nzung.txt", "Erga\u0308nzung.txt"
        owned(f"echo here > {shlex.quote(F + '/' + nfc)}")
        machine.succeed(f"echo there > {shlex.quote(R + '/' + nfd)}")
        out = run("proton-bisync", ok=False)
        assert "unicode normalization" in out, out
        absent(f"{F}/{nfd}", f"{R}/{nfc}")
        owned(f"rm {shlex.quote(F + '/' + nfc)}")
        machine.succeed(f"rm {shlex.quote(R + '/' + nfd)}")
        run("proton-bisync")

    with subtest("a torn events.lock from an unclean shutdown is cleared before the cli runs"):
        machine.succeed("head -c 15 /dev/zero > /var/lib/proton-drive/events.lock")
        run("proton-bisync")
        absent("/var/lib/proton-drive/events.lock")

    with subtest("a missing, unmarked or empty folder is refused and leaves the drive alone"):
        before = listing(R)
        machine.succeed(f"mv {F} {F}.moved")
        assert "no .stfolder" in run("proton-bisync", ok=False)
        machine.succeed(f"install -d -o ${user} -g ${group} {F}")
        owned(f"echo x > {F}/x.txt")
        assert "no .stfolder" in run("proton-bisync", ok=False)
        owned(f"rm {F}/x.txt && mkdir {F}/.stfolder")
        assert "nothing beside" in run("proton-bisync", ok=False)
        assert listing(R) == before
        machine.succeed(f"rm -r {F} && mv {F}.moved {F}")

    with subtest("a proton outage skips the run: nothing moves, no success"):
        before = metric()
        owned(f"echo l4 > {F}/l4.txt")
        machine.succeed("touch /run/proton-down")
        out = run("proton-bisync")
        absent(f"{R}/l4.txt")
        assert metric() == before and calls("list") == [], out
        machine.succeed("rm /run/proton-down")

    with subtest("an hourly run skips while another off-site run holds the proton lock"):
        machine.succeed("systemd-run --unit=hold-proton flock /run/proton-drive.lock ${pkgs.coreutils}/bin/sleep 600")
        machine.wait_until_fails("flock -n /run/proton-drive.lock true")
        assert "skipping this hour" in run("proton-bisync")
        absent(f"{R}/l4.txt")
        machine.succeed("systemctl stop hold-proton")
        run("proton-bisync")
        assert cat(f"{R}/l4.txt") == "l4"
  '';
}
