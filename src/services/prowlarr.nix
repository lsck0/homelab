# prowlarr: indexer manager, indexer traffic through tor, flaresolverr beside it
{ pkgs, hostIp, ... }: {
  homelab.servarr.prowlarr = {
    image = "lscr.io/linuxserver/prowlarr:2.6.5.5623-ls161";
    port = 9696;
  };

  # indexer traffic leaves through tor
  systemd.services.prowlarr-tor-proxy = {
    description = "Send Prowlarr's indexer traffic through Tor";
    # setup exports the key read below
    after = [ "podman-prowlarr.service" "prowlarr-setup.service" ];
    wants = [ "prowlarr-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.systemd ];
    startLimitIntervalSec = 0;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 30;
      PrivateTmp = true;
    };
    script = ''
      API=http://127.0.0.1:9696/api/v1
      KEY=$(cat /var/lib/homepage-tokens/prowlarr-key.token)
      for _ in $(seq 1 60); do
        curl -fsS -H "X-Api-Key: $KEY" "$API/config/host" -o /tmp/host.json && break
        sleep 2
      done
      [ -s /tmp/host.json ] || { echo "Prowlarr API did not answer"; exit 1; }

      # allowedHosts in the same write or prowlarr refuses
      jq -c '.
        | .allowedHosts = "prowlarr.lsck0.dev,${hostIp},127.0.0.1,localhost"
        | .proxyEnabled = true
        | .proxyType = "socks5"
        | .proxyHostname = "10.100.0.1"
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
      # kestrel reads allowedHosts only at start
      systemctl restart podman-prowlarr.service
      echo "Prowlarr now reaches indexers through Tor (10.100.0.1:9055)"
    '';
  };

  # flaresolverr for cloudflare-guarded trackers
  virtualisation.oci-containers.containers.flaresolverr = {
    image = "ghcr.io/flaresolverr/flaresolverr:v3.4.2";
    ports = [ "10.88.0.1:8191:8191" ];
    environment = {
      LOG_LEVEL = "warning";
      TZ = "Europe/Berlin";
    };
    # one chromium per solve
    extraOptions = [ "--memory=1g" ];
  };
  # 10.88.0.1 exists once podman has created its bridge for prowlarr
  systemd.services.podman-flaresolverr = {
    after = [ "podman-prowlarr.service" ];
    wants = [ "podman-prowlarr.service" ];
  };
}
