# vm-104's two-way sync of the syncthing folder with proton drive (lib/proton-bisync.sh under the real units of
# lib/kopia.nix) against a local folder standing in for proton drive: rclone's local backend under the remote's name.
# Not signed in and no baseline fail before rclone starts, the share's metric at 0 for the stale alert; the baseline
# merges both sides and deletes nothing; additions, edits and deletions go both ways, what lands in the folder owned by
# the syncthing user with its modes; a conflict keeps both versions; a mass deletion waits for allow-large; a missing,
# unmarked or empty folder and a missing check file are refused; syncthing's internals stay local; an hourly run skips
# while another off-site run holds the proton lock.
{ pkgs, lib, ... }:
let
  folder = "/srv/nas/syncthing/sync";
  # the drive's my-files; the folder's copy sits where the real one does, below homelab-offsite
  drive = "/srv/fake-proton";
  remote = "${drive}/homelab-offsite/sync";
  user = "nobody";
  group = "nogroup";
in
pkgs.testers.runNixOSTest {
  name = "proton-bisync";

  nodes.machine = {
    imports = [ ../../../tests/stubs.nix ../lib/kopia.nix ];
    virtualisation.memorySize = 2048;
    # main.nix's folder and owner; syncthing itself stays off
    services.syncthing = { inherit user group; settings.folders.sync.path = folder; };
    systemd.services = lib.genAttrs [ "proton-bisync" "proton-bisync-resync" ] (_: {
      environment.PROTON_BISYNC_REMOTE = lib.mkForce "proton:${remote}";
      environment.PROTON_BISYNC_PROBE = lib.mkForce "${pkgs.coreutils}/bin/true";
    });
    # the test starts every run itself
    systemd.timers.proton-bisync.wantedBy = lib.mkForce [ ];
  };

  testScript = ''
    import shlex

    F = "${folder}"
    R = "${remote}"
    STATE = "/var/lib/proton-bisync"
    PROM = "/var/lib/node-exporter-textfile/proton_bisync.prom"
    FILLERS = 20

    def owned(cmd):
        """runs a shell command as the folder's owner, as syncthing and the owner's edits on proton would write"""
        machine.succeed(f"setpriv --reuid=${user} --regid=${group} --clear-groups -- sh -c {shlex.quote(cmd)}")

    def run(unit: str, ok: bool = True) -> str:
        """starts a run and returns its log"""
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

    def absent(*paths):
        for p in paths:
            machine.fail(f"test -e {shlex.quote(p)}")

    machine.wait_for_unit("multi-user.target")
    machine.succeed(f"install -d -o ${user} -g ${group} {F} {F}/.stfolder ${drive} ${drive}/homelab-offsite {R}")
    owned(f"mkdir -p {F}/docs {F}/.stversions && echo local-a > {F}/docs/a.txt && echo local > {F}/common.txt"
          f" && for i in $(seq {FILLERS}); do echo $i > {F}/docs/fill-$i.txt; done"
          f" && echo old > {F}/.stversions/old.txt && echo pull > {F}/docs/.syncthing.b.txt.tmp"
          f" && echo pull > {F}/docs/~syncthing~c.txt.tmp")
    owned(f"mkdir -p {R}/.stversions && echo remote-only > {R}/r.txt && echo remote > {R}/common.txt"
          f" && echo theirs > {R}/.stversions/rv.txt")

    with subtest("not signed in: refused before rclone, the share's metric at 0 so the stale alert fires"):
        out = run("proton-bisync", ok=False)
        assert "not signed in" in out, out
        assert metric() == 0, machine.succeed(f"cat {PROM}")

    with subtest("signed in without a baseline: refused, pointing at the resync"):
        # what proton-bisync-login leaves, for the local stand-in
        machine.succeed(f"printf '[proton]\\ntype = local\\n' > {STATE}/rclone.conf && chown ${user}:${group} {STATE}/rclone.conf")
        out = run("proton-bisync", ok=False)
        assert "proton-bisync-resync" in out, out

    with subtest("the baseline merges both sides, deletes nothing, takes the newer version, leaves syncthing's internals out"):
        run("proton-bisync-resync")
        assert cat(f"{F}/r.txt") == "remote-only"
        assert cat(f"{R}/docs/a.txt") == "local-a"
        assert cat(f"{R}/common.txt") == "remote" and cat(f"{F}/common.txt") == "remote"
        machine.succeed(f"test -e {F}/RCLONE_TEST && test -e {R}/RCLONE_TEST")
        absent(f"{R}/.stfolder", f"{R}/.stversions/old.txt", f"{R}/docs/.syncthing.b.txt.tmp",
               f"{R}/docs/~syncthing~c.txt.tmp", f"{F}/.stversions/rv.txt")
        assert metric() > 0

    with subtest("additions and edits go both ways; what lands in the folder is the syncthing user's, 0644 and 0755"):
        owned(f"echo l2 > {F}/l2.txt && mkdir -p {R}/new/sub && echo r2 > {R}/new/sub/r2.txt"
              f" && echo remote-edit > {R}/docs/a.txt && touch -d '+1 min' {R}/docs/a.txt"
              f" && echo pull > {F}/.syncthing.d.txt.tmp && echo mine > {F}/.stversions/new.txt"
              f" && echo theirs > {R}/.stversions/new2.txt")
        run("proton-bisync")
        assert cat(f"{R}/l2.txt") == "l2"
        assert cat(f"{F}/new/sub/r2.txt") == "r2"
        assert cat(f"{F}/docs/a.txt") == "remote-edit"
        absent(f"{R}/.syncthing.d.txt.tmp", f"{R}/.stversions/new.txt", f"{F}/.stversions/new2.txt")
        modes = machine.succeed(f"stat -c '%U:%G %a %n' {F}/new {F}/new/sub {F}/new/sub/r2.txt {F}/r.txt {F}/docs/a.txt")
        print(modes)
        assert modes.split("\n")[:5] == [f"${user}:${group} {m} {p}" for m, p in [
            ("755", f"{F}/new"), ("755", f"{F}/new/sub"), ("644", f"{F}/new/sub/r2.txt"), ("644", f"{F}/r.txt"),
            ("644", f"{F}/docs/a.txt")]], modes
        assert machine.succeed(f"find {F} ! -user ${user} -o ! -group ${group}") == ""

    with subtest("a file changed on both sides keeps both: the newer under its name, the older with the conflict suffix"):
        owned(f"echo local-new > {F}/common.txt && touch -d '+2 min' {F}/common.txt"
              f" && echo remote-new > {R}/common.txt && touch -d '+3 min' {R}/common.txt")
        run("proton-bisync")
        for side in [F, R]:
            assert cat(f"{side}/common.txt") == "remote-new", side
            assert cat(f"{side}/common.proton-conflict1.txt") == "local-new", machine.succeed(f"ls {side}")

    with subtest("deletions go both ways"):
        owned(f"rm {F}/l2.txt {R}/r.txt")
        run("proton-bisync")
        absent(f"{R}/l2.txt", f"{F}/r.txt")

    with subtest("deleting over the limit syncs nothing until allow-large lets one run through"):
        owned(f"rm {F}/docs/fill-1[0-9].txt {F}/docs/fill-[1-5].txt")
        out = run("proton-bisync", ok=False)
        assert "allow-large" in out, out
        machine.succeed(f"test -e {R}/docs/fill-12.txt")
        machine.succeed(f"touch {STATE}/allow-large")
        run("proton-bisync")
        absent(f"{R}/docs/fill-12.txt", f"{R}/docs/fill-3.txt", f"{STATE}/allow-large")
        machine.succeed(f"test -e {R}/docs/fill-20.txt")

    with subtest("a side without the check file is refused"):
        owned(f"mv {R}/RCLONE_TEST {R}/../RCLONE_TEST && echo l3 > {F}/l3.txt")
        out = run("proton-bisync", ok=False)
        assert "RCLONE_TEST" in out, out
        absent(f"{R}/l3.txt")
        owned(f"mv {R}/../RCLONE_TEST {R}/RCLONE_TEST")
        run("proton-bisync")
        assert cat(f"{R}/l3.txt") == "l3"

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

    with subtest("an hourly run skips while another off-site run holds the proton lock"):
        owned(f"echo l4 > {F}/l4.txt")
        machine.succeed("systemd-run --unit=hold-proton flock /run/proton-drive.lock ${pkgs.coreutils}/bin/sleep 600")
        machine.wait_until_fails("flock -n /run/proton-drive.lock true")
        assert "skipping this hour" in run("proton-bisync")
        absent(f"{R}/l4.txt")
        machine.succeed("systemctl stop hold-proton")
        run("proton-bisync")
        assert cat(f"{R}/l4.txt") == "l4"
  '';
}
