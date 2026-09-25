# Kopia on vm-107: repository init, snapshot, restore of a broken service dir
{ pkgs, ... }:
pkgs.testers.runNixOSTest {
  name = "kopia";

  nodes.machine = {
    imports = [ ./stubs.nix ../instances/107-internal-kopia.nix ];
    virtualisation.memorySize = 2048;
    environment.systemPackages = [ pkgs.curl ];
    # A tiny NAS tree: two services' data and the backup dir.
    systemd.tmpfiles.rules = [
      "d /srv/nas/data/paperless 0777 root root -"
      "f /srv/nas/data/paperless/invoice.txt 0644 root root - invoice-v1"
      "f /srv/nas/data/paperless/receipt.txt 0644 root root - receipt-v1"
      "d /srv/nas/data/minecraft/world 0777 root root -"
      "f /srv/nas/data/minecraft/world/level.dat 0644 root root - world-v1"
      "d /srv/nas/BACKUPS 0700 root root -"
    ];
    # nothing else may run the NAS-wide snapshot concurrently in the test.
    systemd.services.kopia-metrics.wantedBy = pkgs.lib.mkForce [ ];
  };

  testScript = ''
    machine.wait_for_unit("kopia-server.service")
    machine.wait_for_open_port(51515)

    with subtest("repository and policy are set up"):
        policy = machine.succeed("kopia-nas policy show /srv/nas")
        print(policy)
        assert "2:00" in policy, "snapshot time missing"
        assert "BACKUPS" in policy, "BACKUPS not ignored"

    with subtest("snapshot, then break the data"):
        machine.succeed("nas-restore now")
        machine.succeed("echo invoice-v2 > /srv/nas/data/paperless/invoice.txt")
        machine.succeed("nas-restore now")
        machine.succeed("echo CORRUPT > /srv/nas/data/paperless/invoice.txt")
        machine.succeed("rm /srv/nas/data/paperless/receipt.txt")
        machine.succeed("echo CORRUPT > /srv/nas/data/minecraft/world/level.dat")
        listing = machine.succeed("nas-restore list")
        print(listing)

    with subtest("snapshot does not contain the repository itself"):
        machine.fail("nas-restore files 0 BACKUPS/kopia")
        machine.succeed("nas-restore files 0 data/paperless | grep invoice.txt")

    with subtest("restore latest in place"):
        machine.succeed("nas-restore service paperless --yes")
        assert machine.succeed("cat /srv/nas/data/paperless/invoice.txt").strip() == "invoice-v2"
        assert machine.succeed("cat /srv/nas/data/paperless/receipt.txt").strip() == "receipt-v1"
        # other services untouched
        assert machine.succeed("cat /srv/nas/data/minecraft/world/level.dat").strip() == "CORRUPT"

    with subtest("restore an older snapshot by age"):
        machine.succeed("nas-restore service paperless 1 --yes")
        assert machine.succeed("cat /srv/nas/data/paperless/invoice.txt").strip() == "invoice-v1"

    with subtest("select by snapshot id and by date (stable when new snapshots are taken)"):
        import json
        snaps = json.loads(machine.succeed("kopia-nas snapshot list /srv/nas --json"))
        # newest snapshot before the safety snapshot (retention may prune older ones)
        first_id = snaps[-1]["id"]
        machine.succeed("echo CORRUPT > /srv/nas/data/paperless/invoice.txt")
        machine.succeed("nas-restore now")  # safety snapshot of the broken state shifts ages
        rc, out = machine.execute(f"nas-restore service paperless {first_id} --yes 2>&1")
        print(out)
        assert rc == 0, out
        assert machine.succeed("cat /srv/nas/data/paperless/invoice.txt").strip() == "invoice-v2"
        today = machine.succeed("TZ=Europe/Berlin date +%F").strip()
        machine.succeed(f"nas-restore files {today} data/paperless | grep invoice.txt")
        machine.fail("nas-restore service paperless 1999-01-01 --yes")
        listing = machine.succeed("nas-restore list")
        print(listing)
        assert first_id in listing

    with subtest("restore a subtree elsewhere"):
        machine.succeed(f"nas-restore restore {first_id} data/minecraft /tmp/mc")
        assert machine.succeed("cat /tmp/mc/world/level.dat").strip() == "world-v1"

    with subtest("interactive restore refuses without confirmation"):
        machine.fail("echo no | nas-restore service minecraft")
        assert machine.succeed("cat /srv/nas/data/minecraft/world/level.dat").strip() == "CORRUPT"

    with subtest("freshness metric for the backup alert"):
        machine.succeed("systemctl start kopia-metrics.service")
        prom = machine.succeed("cat /var/lib/node-exporter-textfile/nas_backup.prom")
        print(prom)
        assert 'homelab_backup_last_success_timestamp_seconds{type="daily"}' in prom
        files = int([l for l in prom.splitlines() if l.startswith("homelab_backup_snapshot_files ")][0].split()[1])
        assert files == 3, f"snapshot file count {files} is not the tree total (3)"

    with subtest("web UI answers"):
        machine.succeed("curl -sf http://127.0.0.1:51515/ | grep -qi kopia")

    with subtest("init is idempotent"):
        machine.succeed("systemctl restart kopia-init.service kopia-server.service")
        machine.wait_for_open_port(51515)
        machine.succeed("nas-restore list | grep -c . ")
  '';
}
