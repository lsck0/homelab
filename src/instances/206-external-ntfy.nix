{ ... }: {
  networking.hostName = "vm-206";

  # ntfy push notifications. Deliberately in the external DMZ (public via
  # Cloudflare) so alerts reach a phone even when the home LAN or the internal
  # network is down — the whole point of a dead-man's-switch channel.
  #
  # No login: access is by unguessable topic name. Grafana/Alertmanager publish
  # to a secret topic and the phone subscribes to the same one. Rotate by
  # changing the topic. (Add ntfy auth later if topics leak.)
  services.ntfy-sh = {
    enable = true;
    settings = {
      base-url = "https://ntfy.lsck0.dev";
      listen-http = ":80";
      behind-proxy = true;
      auth-default-access = "read-write";
      cache-file = "/var/lib/ntfy-sh/cache.db";
      attachment-cache-dir = "/var/lib/ntfy-sh/attachments";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/ntfy-sh 0750 ntfy-sh ntfy-sh -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
