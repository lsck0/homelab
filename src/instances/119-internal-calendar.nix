{ config, pkgs, nasMount, ... }:
let
  stateDir = "/var/lib/calendar";
  publicDir = "${stateDir}/public";

  # kraken pair codes, not the display symbols: XXBTZEUR is BTC/EUR.
  krakenPairs = "XXBTZEUR,XETHZEUR";

  calendarSync = pkgs.writers.writePython3Bin "calendar-sync" {
    libraries = with pkgs.python3Packages; [ icalendar recurring-ical-events tzdata ];
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ../scripts/calendar-sync.py);
in {
  networking.hostName = "vm-119";

  fileSystems = nasMount stateDir "calendar";

  # one URL per line as "NAME|URL". Work Outlook and Proton both hand out a
  # published ICS link; StudIP exports one per calendar.
  sops.secrets.calendar-sources = {};
  # everything is served under a directory named after this token, so the
  # feed URLs are unguessable. Nothing else authenticates them.
  sops.secrets.calendar-token = {};
  sops.secrets.kraken-api-key = {};
  sops.secrets.kraken-api-secret = {};

  systemd.services.calendar-sync = {
    description = "Merge remote calendars and render the TRMNL payload";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ calendarSync pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
    };
    environment = {
      CALENDAR_SOURCES = config.sops.secrets.calendar-sources.path;
      KRAKEN_PAIRS = krakenPairs;
      KRAKEN_KEY_FILE = config.sops.secrets.kraken-api-key.path;
      KRAKEN_SECRET_FILE = config.sops.secrets.kraken-api-secret.path;
    };
    script = ''
      TOKEN=$(cat ${config.sops.secrets.calendar-token.path})
      [ -n "$TOKEN" ] || { echo "calendar-token is empty"; exit 1; }

      # serving from a directory named after the token keeps the secret out of
      # the nginx config, which Nix builds and validates in the world-readable
      # store.
      OUT="${publicDir}/$TOKEN"
      mkdir -p "$OUT"

      # drop stale token directories after a rotation.
      for dir in ${publicDir}/*; do
        [ -d "$dir" ] || continue
        [ "$dir" = "$OUT" ] || rm -rf "$dir"
      done

      CALENDAR_OUT="$OUT" calendar-sync
      chmod -R a+rX ${publicDir}
    '';
  };

  systemd.timers.calendar-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "15min";
      Persistent = true;
    };
  };

  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;

    virtualHosts.calendar = {
      default = true;
      listen = [{ addr = "0.0.0.0"; port = 80; }];
      root = publicDir;
      locations."~ \\.ics$".extraConfig = ''
        default_type text/calendar;
        add_header Cache-Control "no-cache";
      '';
      locations."~ \\.json$".extraConfig = ''
        default_type application/json;
        add_header Cache-Control "no-cache";
      '';
    };
  };

  systemd.tmpfiles.rules = [
    "d ${publicDir} 0755 root root -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
