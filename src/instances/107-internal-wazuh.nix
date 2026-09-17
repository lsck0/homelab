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
  # dashboard https://wazuh.lsck0.dev behind Authelia; its own login is admin
  # with the password in /var/lib/wazuh/admin-pass, generated on first setup.
  virtualisation.docker.enable = true;
  boot.kernel.sysctl."vm.max_map_count" = 262144;

  systemd.services.wazuh-setup = {
    description = "Fetch wazuh-docker ${version}, generate certificates, enable syslog input";
    after = [ "docker.service" "network-online.target" ];
    requires = [ "docker.service" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.git pkgs.docker pkgs.docker-compose pkgs.gnugrep pkgs.gnused pkgs.gawk pkgs.coreutils pkgs.openssl pkgs.apacheHttpd ];
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

      # replace the upstream demo passwords of the dashboard login (admin) and
      # the dashboard's indexer user (kibanaserver). The indexer seeds its users
      # from internal_users.yml on first start only, so this runs before it.
      mkdir -p /var/lib/wazuh && chmod 700 /var/lib/wazuh
      for u in admin kibanaserver; do
        [ -s /var/lib/wazuh/$u-pass ] || openssl rand -hex 16 | tr -d '\n' > /var/lib/wazuh/$u-pass
      done
      if grep -q 'INDEXER_PASSWORD=SecretPassword' docker-compose.yml; then
        if docker volume inspect single-node_wazuh-indexer-data >/dev/null 2>&1; then
          echo "indexer already initialised with the demo passwords: rotate them by hand" >&2
          exit 1
        fi
        A=$(cat /var/lib/wazuh/admin-pass); K=$(cat /var/lib/wazuh/kibanaserver-pass)
        users=config/wazuh_indexer/internal_users.yml
        ADMIN=$(htpasswd -nbBC 12 "" "$A" | cut -d: -f2) KIBANA=$(htpasswd -nbBC 12 "" "$K" | cut -d: -f2) awk '
          /^[a-z_-]+:$/ { user = $0 }
          /^  hash:/ && user == "admin:"        { print "  hash: \"" ENVIRON["ADMIN"] "\"";  next }
          /^  hash:/ && user == "kibanaserver:" { print "  hash: \"" ENVIRON["KIBANA"] "\""; next }
          { print }' $users > $users.tmp
        mv $users.tmp $users
        sed -i "s/INDEXER_PASSWORD=SecretPassword/INDEXER_PASSWORD=$A/; s/DASHBOARD_PASSWORD=kibanaserver/DASHBOARD_PASSWORD=$K/" docker-compose.yml
      fi
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
