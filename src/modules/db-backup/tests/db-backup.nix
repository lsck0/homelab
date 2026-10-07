# database dumps to the nas as shipped: modules/db-backup on lab guests at their real addresses, a test nas that
# exports exactly what they mount (109-internal-nas's lib/nas-exports.nix). vm-101 (internal) dumps a sqlite database, a command's
# dump, an empty one and a failing one; vm-206 (dmz) dumps its own sqlite database.
#
# Claims: a dump is restorable (integrity_check, rows) even under a concurrent writer and through a nas outage; a
# failed or empty dump leaves nothing behind and no fresh metric; retention keeps the newest DUMPS_KEPT; each host
# reaches only its own dump dir, which only root may enter on the nas. Every refusal has its positive control.
{ pkgs, lib, specialArgs, inputs, ... }:
let
  lab = import ../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
  ip = id: lab.inventory.${id}.ip;
  nasIp = ip "109";
  dumps = "/srv/nas/data/db-dumps";
  # modules/db-backup's retention
  dumpsKept = 14;
  # the fault's length, the one time-based claim: the dump waits out the outage on its hard mount
  outageS = 20;

  guest = id: databases: {
    imports = [ (lab.guest id { flat = true; nas = true; }) ];
    environment.systemPackages = [ pkgs.sqlite pkgs.zstd ];
    homelab.dbBackup.databases = databases;
  };

  # the dmz assertion of modules/nas.nix, as evaluated for the real vm-206: a media mount is refused there
  privatebin = inputs.self.nixosConfigurations."206-external-privatebin";
  failedAssertions = config: map (a: a.message) (lib.filter (a: !a.assertion) config.assertions);
  withMedia = (privatebin.extendModules {
    modules = [ ({ nasMedia, ... }: { homelab.nasMounts = nasMedia "/srv/media" "movies"; }) ];
  }).config;
  dmzRule = "dmz hosts may only mount /srv/nas/data/<share>";
in
assert lib.assertMsg (!(lib.any (lib.hasInfix dmzRule) (failedAssertions privatebin.config)))
  "db-backup: the real vm-206 already fails the dmz mount assertion";
assert lib.assertMsg (lib.any (lib.hasInfix dmzRule) (failedAssertions withMedia))
  "db-backup: vm-206 with a media mount passes nas.nix's dmz assertion";
pkgs.testers.runNixOSTest {
  name = "db-backup";

  node.specialArgs = lab.specialArgs;
  nodes.vm-109 = { imports = [ (lab.nas { flat = true; }) ]; environment.systemPackages = [ pkgs.sqlite pkgs.zstd ]; };
  nodes.vm-101 = guest "101" {
    app.sqlite = "/var/lib/app/db.sqlite";
    pg.command = "cat /var/lib/app/dump.sql";
    empty.command = "true";
    half.command = "sh -c 'echo half-a-dump; exit 1'";
  };
  nodes.vm-206 = guest "206" { paste.sqlite = "/var/lib/paste/db.sqlite"; };

  testScript = ''
    NAS = "${nasIp}"
    DUMPS = "${dumps}"

    def latest(host, name):
        return vm_109.succeed(f"ls -1t {DUMPS}/{host}/{name}/{name}-*.zst | head -1").strip()

    def restored(path):
        """a dump decompressed on the nas: (integrity_check, rows, unpaired rows)"""
        vm_109.succeed(f"rm -f /tmp/r.sqlite && zstd -q -d {path} -o /tmp/r.sqlite")
        check = vm_109.succeed("sqlite3 /tmp/r.sqlite 'PRAGMA integrity_check'").strip()
        rows = int(vm_109.succeed("sqlite3 /tmp/r.sqlite 'SELECT count(*) FROM t'"))
        unpaired = int(vm_109.succeed("sqlite3 /tmp/r.sqlite 'SELECT count(*) FROM t a WHERE NOT EXISTS (SELECT 1 FROM t b WHERE b.id = -a.id)'"))
        return check, rows, unpaired

    def run(machine, unit):
        # many runs in a minute are this test's, not the timer's: clear the start rate limit
        machine.succeed(f"systemctl reset-failed {unit}; systemctl start {unit}")

    def metric(machine, name):
        return machine.succeed(f"cat /var/lib/node-exporter-textfile/db_dump_{name}.prom 2>/dev/null || true")

    start_all()
    vm_109.wait_for_unit("nfs-exports-reload.service")
    for m in (vm_101, vm_206):
        m.wait_for_unit("multi-user.target")
    vm_101.succeed("mkdir -p /var/lib/app && sqlite3 /var/lib/app/db.sqlite 'CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)'")
    vm_101.succeed("sqlite3 /var/lib/app/db.sqlite \"WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 500) "
                   "INSERT INTO t SELECT i, hex(randomblob(64)) FROM n UNION ALL SELECT -i, 'pair' FROM n\"")
    vm_206.succeed("mkdir -p /var/lib/paste && sqlite3 /var/lib/paste/db.sqlite 'CREATE TABLE t (id INTEGER PRIMARY KEY); INSERT INTO t VALUES (1), (-1)'")

    with subtest("a sqlite dump lands on the nas and restores"):
        start = int(vm_101.succeed("date +%s"))
        run(vm_101, "db-backup-app")
        check, rows, unpaired = restored(latest("vm-101", "app"))
        assert (check, rows, unpaired) == ("ok", 1000, 0), (check, rows, unpaired)
        line = [l for l in metric(vm_101, "app").splitlines() if l.startswith("homelab_db_dump_last_success_timestamp_seconds")][0]
        assert 'db="app"' in line and int(line.split()[-1]) >= start, line

    with subtest("a command's dump lands on the nas"):
        vm_101.succeed("echo 'CREATE TABLE x (y int);' > /var/lib/app/dump.sql")
        run(vm_101, "db-backup-pg")
        assert "CREATE TABLE x" in vm_109.succeed(f"zstd -dc {latest('vm-101', 'pg')}")

    with subtest("five dumps under a concurrent writer: each restores whole, no unpaired row"):
        vm_101.succeed("systemd-run --unit=writer --setenv=PATH=$PATH bash -c 'for i in $(seq 1001 6000); do "
                       "sqlite3 /var/lib/app/db.sqlite \"BEGIN; INSERT INTO t VALUES ($i, 1); INSERT INTO t VALUES (-$i, 1); COMMIT\"; done'")
        for _ in range(5):
            run(vm_101, "db-backup-app")
            check, rows, unpaired = restored(latest("vm-101", "app"))
            assert check == "ok" and unpaired == 0 and rows % 2 == 0, (check, rows, unpaired)
        vm_101.succeed("systemctl stop writer || true")

    with subtest("an empty dump fails and leaves nothing"):
        vm_101.fail("systemctl start db-backup-empty")
        vm_109.fail(f"ls {DUMPS}/vm-101/empty/empty-*.zst")
        assert vm_109.succeed(f"ls -A {DUMPS}/vm-101/empty") == "", "a temp file stayed behind"
        assert metric(vm_101, "empty") == ""

    with subtest("a dump whose command fails halfway leaves no partial file"):
        vm_101.fail("systemctl start db-backup-half")
        assert vm_109.succeed(f"ls -A {DUMPS}/vm-101/half") == "", "a partial dump or temp file stayed behind"
        assert metric(vm_101, "half") == ""

    with subtest("retention keeps the newest ${toString dumpsKept}"):
        d = f"{DUMPS}/vm-101/app"
        vm_109.succeed(f"rm -f {d}/*.zst")
        for i in range(16):
            vm_109.succeed(f"touch -d '{30 - i} days ago' {d}/app-old{i:02d}.sqlite.zst")
        run(vm_101, "db-backup-app")
        kept = vm_109.succeed(f"ls -1 {d}").split()
        assert len(kept) == ${toString dumpsKept}, kept
        assert not {"app-old00.sqlite.zst", "app-old01.sqlite.zst", "app-old02.sqlite.zst"} & set(kept), kept
        assert any(not k.startswith("app-old") for k in kept), "the new dump is gone"

    with subtest("each host reaches its own dump dir only, which only root enters on the nas"):
        run(vm_206, "db-backup-paste")
        vm_109.succeed(f"ls {DUMPS}/vm-206/paste/paste-*.zst")
        vm_109.fail(f"ls {DUMPS}/vm-101/paste")
        for host in ("vm-101", "vm-206"):
            assert vm_109.succeed(f"stat -c '%a %U' {DUMPS}/{host}").strip() == "700 root"
        listing = vm_109.succeed("exportfs -v")
        print(listing)
        for node, other, own in ((vm_206, "vm-101", "vm-206"), (vm_101, "vm-206", "vm-101")):
            node.succeed("mkdir -p /mnt/probe")
            node.fail(f"timeout 30 mount -t nfs4 -o ro,soft,timeo=10,retrans=1 {NAS}:{DUMPS}/{other} /mnt/probe")
            node.succeed(f"timeout 30 mount -t nfs4 -o ro {NAS}:{DUMPS}/{own} /mnt/probe && umount /mnt/probe")
            node.succeed(f"timeout 30 mount -t nfs4 -o ro {NAS}:/ /mnt/probe")
            seen = node.succeed(f"ls /mnt/probe{DUMPS}").split()
            node.succeed("umount /mnt/probe")
            assert seen == [own], f"{own} sees {seen}"

    with subtest("the nas goes away mid-dump: the dump waits, completes and restores"):
        vm_109.block()
        vm_101.succeed("systemctl start --no-block db-backup-app")
        vm_101.succeed("sleep ${toString outageS}")
        # still at it: the hard mount holds the dump instead of failing it
        vm_101.succeed("systemctl show -p ActiveState db-backup-app | grep -qx ActiveState=activating")
        vm_109.unblock()
        vm_101.wait_until_succeeds("systemctl show -p ActiveState db-backup-app | grep -qx ActiveState=inactive", timeout=300)
        vm_101.succeed("systemctl show -p Result db-backup-app | grep -qx Result=success")
        check, rows, unpaired = restored(latest("vm-101", "app"))
        assert check == "ok" and unpaired == 0, (check, rows, unpaired)
  '';
}
