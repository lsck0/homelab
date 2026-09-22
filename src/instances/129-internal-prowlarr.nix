{ pkgs, ... }: {
  networking.hostName = "vm-129";

  # indexer manager. Indexers and the app connections to Radarr/Sonarr/Lidarr/
  # Bookshelf are created by the *arr wiring on vm-133.
  homelab.servarr.prowlarr = {
    image = "lscr.io/linuxserver/prowlarr:2.6.5.5623-ls161";
    port = 9696;
  };

  # Every request to an indexer leaves through Tor, on the isolated SOCKS port
  # vm-113 keeps for exactly this (9055: a fresh circuit per destination, and a
  # different circuit from the torrent traffic on 9050). Radarr and Sonarr do
  # not talk to trackers themselves - their indexer entries point back at
  # Prowlarr - so proxying Prowlarr covers searching and grabbing both.
  #
  # Set over the API because Prowlarr keeps its configuration in its own
  # database, not a file. Idempotent: it reads the current config and only
  # writes when something differs.
  systemd.services.prowlarr-tor-proxy = {
    description = "Send Prowlarr's indexer traffic through Tor";
    after = [ "podman-prowlarr.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.jq pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 30;
    };
    script = ''
      API=http://127.0.0.1:80/api/v1
      KEY=$(cat /var/lib/homepage-tokens/prowlarr-key.token)
      for _ in $(seq 1 60); do
        curl -fsS -H "X-Api-Key: $KEY" "$API/config/host" -o /tmp/host.json && break
        sleep 2
      done
      [ -s /tmp/host.json ] || { echo "Prowlarr API did not answer"; exit 1; }

      # allowedHosts has to go in the same write: Prowlarr refuses any host
      # config update while it is empty and authentication is not required,
      # which is also the standing health warning.
      jq -c '.
        | .allowedHosts = "prowlarr.lsck0.dev,10.100.0.129,127.0.0.1,localhost"
        | .proxyEnabled = true
        | .proxyType = "socks5"
        | .proxyHostname = "10.100.0.113"
        | .proxyPort = 9055
        | .proxyUsername = ""
        | .proxyPassword = ""
        | .proxyBypassLocalAddresses = true
        | .proxyBypassFilter = ""' /tmp/host.json > /tmp/host.new

      if jq -e --slurpfile a /tmp/host.json --slurpfile b /tmp/host.new -n '$a[0] == $b[0]' >/dev/null; then
        echo "Prowlarr already proxied through Tor"
        exit 0
      fi

      curl -fsS -X PUT "$API/config/host/$(jq -r .id /tmp/host.json)" -H "X-Api-Key: $KEY" \
        -H "Content-Type: application/json" --data-binary @/tmp/host.new -o /dev/null
      echo "Prowlarr now reaches indexers through Tor (10.100.0.113:9055)"
    '';
  };

  # Half the useful public trackers sit behind Cloudflare's bot check and
  # answer Prowlarr with "blocked by CloudFlare Protection": 1337x, EZTV,
  # kickasstorrents, ExtraTorrent and Uindex all failed to add for that reason.
  # FlareSolverr drives a headless browser through the challenge and hands the
  # cookie back, which is the only way those indexers work at all.
  #
  # Bound to the podman bridge, not the host address: Prowlarr runs in its own
  # bridged container, so 127.0.0.1 there is not this host. 10.88.0.1 is the
  # bridge gateway, reachable from sibling containers and from nowhere off the
  # VM, which matters because FlareSolverr is an unauthenticated
  # browser-as-a-service.
  virtualisation.oci-containers.containers.flaresolverr = {
    image = "ghcr.io/flaresolverr/flaresolverr:v3.4.2";
    ports = [ "10.88.0.1:8191:8191" ];
    environment = {
      LOG_LEVEL = "warning";
      TZ = "Europe/Berlin";
    };
  };
}
