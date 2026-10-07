# dumps of live databases to the nas before kopia's snapshot, each consistent by its own engine's mechanism
{ config, lib, pkgs, nasPath, ... }:
let
  cfg = config.homelab.dbBackup;
  dir = "/var/backup/db";
  # before kopia's 02:00 snapshot
  onCalendar = "01:30";
  # per database on the nas, kopia retention covers the longer history
  keep = 14;
  sqliteBackup = import ../sqlite-backup.nix;

  dbType = lib.types.submodule {
    options = {
      sqlite = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Path to a SQLite file. Dumped with `.backup`, which takes a
          consistent copy of a database that is being written to; copying the
          file (which is what a filesystem snapshot does) can catch it
          mid-transaction together with a stale -wal.
        '';
      };

      command = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Shell command that writes an SQL dump to stdout, for anything that is
          not SQLite: `pg_dumpall`, `podman exec <ctr> pg_dump ...`, `mysqldump`.
          It runs as root; wrap it in `runuser` to dump as another user.
        '';
      };

      suffix = lib.mkOption {
        type = lib.types.strMatching "[a-z0-9]+";
        default = "sql";
        description = "What `command` writes, the dump file's extension before .zst: sql, or tar for a volume archive.";
      };

      path = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
        description = "Extra packages on the unit's PATH.";
      };
    };
  };

  script = name: db: ''
    # a dump piped through several commands fails when any of them does
    set -o pipefail
    out=${dir}/${name}
    mkdir -p "$out"
    stamp=$(date +%Y-%m-%dT%H%M)
    # dump and compressed copy are temp files until complete: a failed or interrupted run leaves no partial dump
    tmp=$(mktemp -p "$out" .${name}.XXXXXX)
    trap 'rm -f "$tmp" "$tmp.zst"' EXIT
    ${if db.sqlite != null then ''
      if [ ! -s ${lib.escapeShellArg db.sqlite} ]; then
        echo "${name}: ${db.sqlite} does not exist yet, nothing to dump"
        exit 0
      fi
      # online backup api, safe under a writer (sqlite-backup.nix)
      ${sqliteBackup.command (lib.escapeShellArg db.sqlite) "$tmp"}
      ext=sqlite
    '' else ''
      ${db.command} > "$tmp"
      [ -s "$tmp" ] || { echo "${name}: dump was empty"; exit 1; }
      ext=${db.suffix}
    ''}
    zstd -q -19 -o "$tmp.zst" "$tmp"
    mv "$tmp.zst" "$out/${name}-$stamp.$ext.zst"
    ls -1t "$out"/${name}-*.zst 2>/dev/null | tail -n +${toString (keep + 1)} | xargs -r rm -f
    echo "${name}: dumped to $out"
    # grafana's backup alert watches this
    d=${config.homelab.textfileDir}
    printf '# TYPE homelab_db_dump_last_success_timestamp_seconds gauge\nhomelab_db_dump_last_success_timestamp_seconds{db="%s"} %s\n' ${name} "$(date +%s)" > $d/db_dump_${name}.prom.tmp
    mv $d/db_dump_${name}.prom.tmp $d/db_dump_${name}.prom
  '';
in {
  options.homelab.dbBackup = {
    databases = lib.mkOption {
      type = lib.types.attrsOf dbType;
      default = { };
      description = ''
        Databases on this VM to dump with their own engine's mechanism before
        Kopia snapshots the NAS.

        Kopia copies files. For a live database that is not a backup: a
        Postgres data directory or a SQLite file captured mid-write restores as
        a corrupt or rolled-back database. These dumps land under
        /srv/nas/data/db-dumps/<vm>/<name>/ and are consistent by construction,
        so the snapshot has something restorable in it.
      '';
    };
  };

  config = lib.mkIf (cfg.databases != { }) {
    homelab.textfiles = map (name: "db_dump_${name}") (lib.attrNames cfg.databases);

    # each host mounts only its own dump dir, root-only (the units run as root): no guest sees another's dumps
    homelab.nasMounts = lib.mapAttrs (_: m: m // { shareMode = "0700"; })
      (nasPath dir "data/db-dumps/${config.networking.hostName}");

    systemd.services = lib.mapAttrs' (name: db: lib.nameValuePair "db-backup-${name}" {
      description = "Dump ${name} to the NAS";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # lxc guests mount the nas at boot, not on access
      unitConfig.RequiresMountsFor = [ dir ];
      path = [ pkgs.sqlite pkgs.zstd pkgs.coreutils pkgs.findutils ] ++ db.path;
      serviceConfig = { Type = "oneshot"; };
      script = script name db;
    }) cfg.databases;

    systemd.timers = lib.mapAttrs' (name: _: lib.nameValuePair "db-backup-${name}" {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = onCalendar;
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    }) cfg.databases;

    assertions = lib.mapAttrsToList (name: db: {
      assertion = (db.sqlite == null) != (db.command == null);
      message = "homelab.dbBackup.databases.${name}: set exactly one of `sqlite` or `command`.";
    }) cfg.databases;
  };
}
