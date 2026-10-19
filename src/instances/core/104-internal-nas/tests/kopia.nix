# kopia on the nas: init, snapshot, restore; a restore of a guest's local state copy (paperless, instance.nix
# `shares`) is marked with a fresh generation for its seed (modules/local-state), any other share is not; the
# syncthing folders and cold storage snapshot into their own repository, cold storage's upload skips without a
# session, and the repository mirror keeps its remote copy; a repository left at its old place stops init
{ pkgs, lib, ... }:
pkgs.testers.runNixOSTest {
  name = "kopia";

  nodes.machine = {
    imports = [
      ../../../../tests/stubs.nix
      ../lib/kopia.nix
    ];
    virtualisation.memorySize = 2048;
    environment.systemPackages = [ pkgs.curl ];
    # main.nix's folder; syncthing itself stays off, and the test starts every run itself
    services.syncthing.settings.folders.sync.path = "/srv/nas/syncthing/sync";
    systemd.timers = lib.genAttrs [ "kopia-syncthing" "proton-bisync" ] (_: {
      wantedBy = lib.mkForce [ ];
    });
    # tiny nas tree
    systemd.tmpfiles.rules = [
      "d /srv/nas/data/paperless 0777 root root -"
      "f /srv/nas/data/paperless/invoice.txt 0644 root root - invoice-v1"
      "f /srv/nas/data/paperless/receipt.txt 0644 root root - receipt-v1"
      "d /srv/nas/data/minecraft/cobblemon/world 0777 root root -"
      "f /srv/nas/data/minecraft/cobblemon/world/level.dat 0644 root root - world-v1"
      "d /srv/nas/BACKUPS 0700 root root -"
      "f /srv/nas/syncthing/sync/notes.txt 0644 root root - notes-v1"
      "f /srv/nas/syncthing/borg-luca-pc/data 0644 root root - borg"
      "f /srv/nas/bulk/cold-storage/island_2019/beach.jpg 0644 root root - photo"
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
        machine.succeed("echo CORRUPT > /srv/nas/data/minecraft/cobblemon/world/level.dat")
        listing = machine.succeed("nas-restore list")
        print(listing)

    with subtest("snapshot does not contain the repository itself"):
        machine.fail("nas-restore files 0 bulk/BACKUPS/kopia")
        machine.succeed("nas-restore files 0 data/paperless | grep invoice.txt")

    with subtest("restore latest in place"):
        machine.succeed("nas-restore service paperless --yes")
        assert machine.succeed("cat /srv/nas/data/paperless/invoice.txt").strip() == "invoice-v2"
        assert machine.succeed("cat /srv/nas/data/paperless/receipt.txt").strip() == "receipt-v1"
        # other services untouched
        assert machine.succeed("cat /srv/nas/data/minecraft/cobblemon/world/level.dat").strip() == "CORRUPT"

    with subtest("a local state copy's restore carries a new generation, marked restored"):
        generation = machine.succeed("cat /srv/nas/data/paperless/.generation").strip()
        assert generation.startswith("restored-") and len(generation) > len("restored-"), generation
        machine.succeed("nas-restore service paperless --yes")
        assert machine.succeed("cat /srv/nas/data/paperless/.generation").strip() != generation, "no fresh generation"
        machine.succeed("nas-restore service minecraft --yes")
        machine.fail("test -e /srv/nas/data/minecraft/.generation")
        machine.succeed("echo CORRUPT > /srv/nas/data/minecraft/cobblemon/world/level.dat")

    with subtest("restore an older snapshot by age"):
        machine.succeed("nas-restore service paperless 1 --yes")
        assert machine.succeed("cat /srv/nas/data/paperless/invoice.txt").strip() == "invoice-v1"

    with subtest("select by snapshot id and by date (stable when new snapshots are taken)"):
        import json
        import re
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
        assert machine.succeed("cat /tmp/mc/cobblemon/world/level.dat").strip() == "world-v1"

    with subtest("interactive restore refuses without confirmation"):
        machine.fail("echo no | nas-restore service minecraft")
        assert machine.succeed("cat /srv/nas/data/minecraft/cobblemon/world/level.dat").strip() == "CORRUPT"

    with subtest("freshness metric for the backup alert"):
        machine.succeed("nas-restore now")
        tree = int(machine.succeed("find /srv/nas \\( -path /srv/nas/BACKUPS -o -path /srv/nas/bulk -o -path /srv/nas/syncthing \\) -prune -o -type f -print | wc -l"))
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
        # the off-site sample picks pack blobs by the path kopia writes them under (lib/kopia.nix): sharded as
        # p00/2ab/<rest>, so a match on the file name alone found none in the real repository
        packs = machine.succeed("cd /srv/nas/bulk/BACKUPS/kopia && find . -type f | sed 's|^[.]/||' | grep -cE '^[pq][0-9a-f]'")
        assert int(packs) > 0, "the off-site sample's pack pattern matches no blob of a real repository"

    with subtest("the repository mirror skips without a proton session and publishes no success (tests/proton-mirror.nix runs it)"):
        machine.succeed("systemctl start proton-sync.service")
        machine.succeed("journalctl -u proton-sync --no-pager | grep -q 'no proton session'")
        machine.fail("ls /var/lib/node-exporter-textfile/proton_sync.prom")

    with subtest("web UI answers"):
        machine.fail("curl -sf http://127.0.0.1:51515/")
        machine.succeed("curl -sf -u \"kopia:$(cat /run/secrets/kopia-server-password)\" http://127.0.0.1:51515/ | grep -qi kopia")

    with subtest("init is idempotent"):
        machine.succeed("systemctl restart kopia-init.service kopia-server.service")
        machine.wait_for_open_port(51515)
        machine.succeed("nas-restore list | grep -c . ")

    with subtest("the syncthing folders snapshot into their own repository on the ssd, under the nas job lock"):
        machine.succeed("systemctl start kopia-syncthing.service")
        snaps = json.loads(machine.succeed("kopia-syncthing snapshot list /srv/nas/syncthing --json"))
        assert len(snaps) == 1, snaps
        listing = machine.succeed("kopia-syncthing ls -r " + snaps[0]["rootEntry"]["obj"])
        assert "borg-luca-pc/data" in listing and "sync/notes.txt" in listing, listing
        machine.succeed("test -e /srv/nas/BACKUPS/kopia-syncthing/kopia.repository.f")
        prom = machine.succeed("cat /var/lib/node-exporter-textfile/syncthing_backup.prom")
        assert 'homelab_backup_last_success_timestamp_seconds{type="syncthing"}' in prom, prom
        machine.fail("nas-restore files 0 syncthing")

    with subtest("cold storage snapshots into the syncthing folders' repository on the ssd, not beside itself on the hdd"):
        snaps = json.loads(machine.succeed("kopia-syncthing snapshot list /srv/nas/bulk/cold-storage --json"))
        assert len(snaps) == 1, snaps
        listing = machine.succeed("kopia-syncthing ls -r " + snaps[0]["rootEntry"]["obj"])
        assert "island_2019/beach.jpg" in listing, listing
        policy = machine.succeed("kopia-syncthing policy show /srv/nas/bulk/cold-storage")
        assert re.search(r"Annual snapshots:\s+10\b", policy), policy
        prom = machine.succeed("cat /var/lib/node-exporter-textfile/cold_storage_backup.prom")
        assert 'homelab_backup_last_success_timestamp_seconds{type="cold-storage"}' in prom, prom
        machine.fail("nas-restore files 0 bulk/cold-storage")

    with subtest("cold storage's upload skips without a proton session; the repository mirror keeps its remote copy"):
        machine.succeed("systemctl start proton-cold-storage.service")
        machine.succeed("journalctl -u proton-cold-storage --no-pager | grep -q 'no proton session'")
        machine.fail("ls /var/lib/node-exporter-textfile/proton_cold_storage.prom")
        keep = machine.succeed("systemctl show -p Environment --value proton-sync")
        assert "PROTON_MIRROR_ROOT_KEEP=BACKUPS cold-storage sync" in keep, keep

    with subtest("a repository left at its old place on the ssd stops init instead of starting a second one"):
        machine.succeed("mkdir -p /srv/nas/BACKUPS/kopia && touch /srv/nas/BACKUPS/kopia/kopia.repository.f")
        machine.fail("systemctl restart kopia-init.service")
        machine.succeed("journalctl -u kopia-init --no-pager | grep -q 'move /srv/nas/BACKUPS/kopia'")
  '';
}
