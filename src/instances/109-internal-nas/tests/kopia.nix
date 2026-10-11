# kopia on the nas: init, snapshot, restore; a restore of a guest's local state copy (paperless, instance.nix
# `shares`) is marked with a fresh generation for its seed (modules/local-state), any other share is not
{ pkgs, ... }:
pkgs.testers.runNixOSTest {
  name = "kopia";

  nodes.machine = {
    imports = [ ../../../tests/stubs.nix ../lib/kopia.nix ];
    virtualisation.memorySize = 2048;
    environment.systemPackages = [ pkgs.curl ];
    # tiny nas tree
    systemd.tmpfiles.rules = [
      "d /srv/nas/data/paperless 0777 root root -"
      "f /srv/nas/data/paperless/invoice.txt 0644 root root - invoice-v1"
      "f /srv/nas/data/paperless/receipt.txt 0644 root root - receipt-v1"
      "d /srv/nas/data/minecraft/world 0777 root root -"
      "f /srv/nas/data/minecraft/world/level.dat 0644 root root - world-v1"
      "d /srv/nas/BACKUPS 0700 root root -"
      # kopia-init snapshots the nas's local state too
      "d /var/lib/syncthing 0700 root root -"
      "d /var/lib/filebrowser 0700 root root -"
    ];
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

    with subtest("a local state copy's restore carries a new generation, marked restored"):
        generation = machine.succeed("cat /srv/nas/data/paperless/.generation").strip()
        assert generation.startswith("restored-") and len(generation) > len("restored-"), generation
        machine.succeed("nas-restore service paperless --yes")
        assert machine.succeed("cat /srv/nas/data/paperless/.generation").strip() != generation, "no fresh generation"
        machine.succeed("nas-restore service minecraft --yes")
        machine.fail("test -e /srv/nas/data/minecraft/.generation")
        machine.succeed("echo CORRUPT > /srv/nas/data/minecraft/world/level.dat")

    with subtest("restore an older snapshot by age"):
        machine.succeed("nas-restore service paperless 1 --yes")
        assert machine.succeed("cat /srv/nas/data/paperless/invoice.txt").strip() == "invoice-v1"

    with subtest("select by snapshot id and by date (stable when new snapshots are taken)"):
        import json
        snaps = json.loads(machine.succeed("kopia-nas snapshot list /srv/nas --json"))
        # newest, retention may prune older ones
        first_id = snaps[-1]["id"]
        machine.succeed("echo CORRUPT > /srv/nas/data/paperless/invoice.txt")
        machine.succeed("nas-restore now")  # its safety snapshot shifts ages
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
        machine.succeed("nas-restore now")
        tree = int(machine.succeed("find /srv/nas -path /srv/nas/BACKUPS -prune -o -type f -print | wc -l"))
        machine.succeed("systemctl start kopia-metrics.service")
        prom = machine.succeed("cat /var/lib/node-exporter-textfile/nas_backup.prom")
        print(prom)
        assert 'homelab_backup_last_success_timestamp_seconds{type="daily"}' in prom
        files = int([l for l in prom.splitlines() if l.startswith("homelab_backup_snapshot_files ")][0].split()[1])
        assert files == tree, f"snapshot file count {files} is not the tree total ({tree})"

    with subtest("the weekly verify re-reads the repository and publishes its freshness; no proton session skips the sample"):
        machine.succeed("systemctl start kopia-verify.service")
        prom = machine.succeed("cat /var/lib/node-exporter-textfile/backup_verify_repository.prom")
        assert "homelab_backup_verify_last_success_timestamp_seconds" in prom, prom
        machine.succeed("journalctl -u kopia-verify --no-pager | grep -q 'no proton session'")
        machine.fail("test -e /var/lib/node-exporter-textfile/backup_verify_offsite.prom")

    with subtest("web UI answers"):
        machine.fail("curl -sf http://127.0.0.1:51515/")
        machine.succeed("curl -sf -u \"kopia:$(cat /run/secrets/kopia-server-password)\" http://127.0.0.1:51515/ | grep -qi kopia")

    with subtest("init is idempotent"):
        machine.succeed("systemctl restart kopia-init.service kopia-server.service")
        machine.wait_for_open_port(51515)
        machine.succeed("nas-restore list | grep -c . ")
  '';
}
