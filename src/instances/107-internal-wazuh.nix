{ pkgs, ... }:
let
  version = "4.14.7";
  dir = "/opt/wazuh-docker";
  stack = "${dir}/single-node";

  # compose override: keep the indexer and manager API on loopback (Docker
  # publishes ports past the NixOS firewall), and add the syslog receiver.
  override = pkgs.writeText "wazuh-override.yml" ''
    services:
      wazuh.manager:
        ports: !override
          - "514:514/udp"
          - "127.0.0.1:55000:55000"
      wazuh.indexer:
        ports: !override
          - "127.0.0.1:9200:9200"
  '';

  # every VM forwards its journal here over syslog (modules/base.nix).
  syslogRemote = ''
    <remote>
      <connection>syslog</connection>
      <port>514</port>
      <protocol>udp</protocol>
      <allowed-ips>10.0.0.0/8</allowed-ips>
      <allowed-ips>192.168.178.0/24</allowed-ips>
    </remote>
  '';

  compose = "${pkgs.docker-compose}/bin/docker-compose -p single-node -f ${stack}/docker-compose.yml -f ${override}";
in {
  networking.hostName = "vm-107";

  # Wazuh single-node (manager + indexer + dashboard) from the official
  # wazuh-docker release. State lives in Docker volumes on the local disk.
  # dashboard https://wazuh.lsck0.dev behind Authelia; its own login is the
  # upstream default admin / SecretPassword (reachable only via Traefik).
  virtualisation.docker.enable = true;
  boot.kernel.sysctl."vm.max_map_count" = 262144;

  systemd.services.wazuh-setup = {
    description = "Fetch wazuh-docker ${version}, generate certificates, enable syslog input";
    after = [ "docker.service" "network-online.target" ];
    requires = [ "docker.service" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.git pkgs.docker pkgs.docker-compose pkgs.gnugrep pkgs.gawk pkgs.coreutils ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      if [ ! -d ${dir}/.git ]; then
        git clone --depth 1 -b v${version} https://github.com/wazuh/wazuh-docker ${dir}
      fi
      cd ${stack}
      if [ ! -f config/wazuh_indexer_ssl_certs/root-ca.pem ]; then
        docker-compose -f generate-indexer-certs.yml run --rm generator
      fi
      conf=config/wazuh_cluster/wazuh_manager.conf
      if ! grep -q '<connection>syslog</connection>' $conf; then
        # insert the syslog <remote> block before the secure one.
        BLOCK=${pkgs.lib.escapeShellArg syslogRemote} \
          awk '/<remote>/ && !done { print ENVIRON["BLOCK"]; done=1 } { print }' $conf > $conf.tmp
        mv $conf.tmp $conf
      fi
      mkdir -p /var/lib/wazuh
      echo -n SecretPassword > /var/lib/wazuh/admin-pass
      chmod 600 /var/lib/wazuh/admin-pass
    '';
  };

  systemd.services.wazuh = {
    description = "Wazuh single-node stack";
    after = [ "wazuh-setup.service" ];
    requires = [ "wazuh-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    restartTriggers = [ override ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      WorkingDirectory = stack;
      ExecStart = "${compose} up -d --remove-orphans";
      ExecStop = "${compose} down";
      TimeoutStartSec = "15min";
    };
  };

  # dashboard (published 443 -> 5601) only for internal Traefik, Homepage and Uptime Kuma.
  networking.firewall.extraCommands = ''
    iptables -N DOCKER-USER 2>/dev/null || true
    iptables -F DOCKER-HOMELAB 2>/dev/null || iptables -N DOCKER-HOMELAB
    iptables -D DOCKER-USER -p tcp --dport 5601 -j DOCKER-HOMELAB 2>/dev/null || true
    iptables -I DOCKER-USER -p tcp --dport 5601 -j DOCKER-HOMELAB
    for src in 10.100.0.100 10.100.0.103 10.100.0.105; do
      iptables -A DOCKER-HOMELAB -s $src -j RETURN
    done
    iptables -A DOCKER-HOMELAB -j DROP
  '';
}
