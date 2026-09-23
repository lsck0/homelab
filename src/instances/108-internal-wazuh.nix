{ config, pkgs, ... }:
let
  version = "4.14.7";
  src = pkgs.fetchFromGitHub {
    owner = "wazuh";
    repo = "wazuh-docker";
    rev = "v${version}";
    hash = "sha256-kM5irCpAVkAdqdIce8Q4MdmMgaBg6set9BSI3W7mPiQ=";
  };
  dir = "/opt/wazuh-docker";
  stack = "${dir}/single-node";

  # compose override: keep the indexer and manager API on loopback (Docker
  # publishes ports past the NixOS firewall), add the syslog receiver, and
  # mount the two security files that teach the indexer about lldap. They are
  # written at runtime by wazuh-ldap.service rather than coming from the nix
  # store, because one of them carries the LDAP bind password.
  override = pkgs.writeText "wazuh-override.yml" ''
    services:
      wazuh.manager:
        ports: !override
          - "514:514/udp"
          - "127.0.0.1:55000:55000"
      wazuh.indexer:
        ports: !override
          - "127.0.0.1:9200:9200"
        volumes:
          - ${stack}/config/wazuh_indexer/config.yml:/usr/share/wazuh-indexer/config/opensearch-security/config.yml
          - ${stack}/config/wazuh_indexer/roles_mapping.yml:/usr/share/wazuh-indexer/config/opensearch-security/roles_mapping.yml
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
  networking.hostName = "vm-108";

  # Wazuh single-node (manager + indexer + dashboard) from the official
  # wazuh-docker release. State lives in Docker volumes on the local disk.
  # dashboard https://wazuh.lsck0.dev behind Authelia; its own login is admin
  # with the same password as the Authelia account (sops: authelia-admin-pass),
  # so the dashboard's second login stops being a separate credential.
  # kibanaserver is the dashboard's own service account, never typed by a human,
  # so it keeps a generated password.
  sops.secrets.authelia-admin-pass = {};
  sops.secrets.lldap-admin-password = {};
  virtualisation.docker.enable = true;
  boot.kernel.sysctl."vm.max_map_count" = 262144;

  systemd.services.wazuh-setup = {
    description = "Install wazuh-docker ${version}, generate certificates, enable syslog input";
    after = [ "docker.service" "network-online.target" ];
    requires = [ "docker.service" ];
    wants = [ "network-online.target" ];
    # the certificate generator pulls an image: retry while DNS or the registry is not up yet
    startLimitIntervalSec = 0;
    path = [ pkgs.docker pkgs.docker-compose pkgs.gnugrep pkgs.gnused pkgs.gawk pkgs.coreutils pkgs.openssl pkgs.apacheHttpd ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; Restart = "on-failure"; RestartSec = 30; };
    script = ''
      # a writable copy: setup edits the manager config, users and compose file in place
      if [ ! -f ${dir}/single-node/docker-compose.yml ]; then
        mkdir -p ${dir}
        cp -r ${src}/. ${dir}/
        chmod -R u+w ${dir}
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
      # the human-facing account shares the Authelia password.
      cp ${config.sops.secrets.authelia-admin-pass.path} /var/lib/wazuh/admin-pass
      chmod 600 /var/lib/wazuh/admin-pass
      [ -s /var/lib/wazuh/kibanaserver-pass ] \
        || openssl rand -hex 16 | tr -d '\n' > /var/lib/wazuh/kibanaserver-pass
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
        # Not sed: the admin password is the Authelia one and may contain "/"
        # (ends the s/// replacement) or a trailing "\" (escapes the delimiter),
        # either of which makes sed fail and leaves the demo password in place.
        # ENVIRON avoids awk's -v escape processing, and index/substr does a
        # literal replacement, so "&" and "\" in the value stay verbatim.
        A="$A" K="$K" awk '
          function repl(line, needle, val,   p) {
            p = index(line, needle)
            if (p == 0) return line
            return substr(line, 1, p - 1) val substr(line, p + length(needle))
          }
          {
            $0 = repl($0, "INDEXER_PASSWORD=SecretPassword", "INDEXER_PASSWORD=" ENVIRON["A"])
            $0 = repl($0, "DASHBOARD_PASSWORD=kibanaserver", "DASHBOARD_PASSWORD=" ENVIRON["K"])
            print
          }' docker-compose.yml > docker-compose.yml.tmp
        mv docker-compose.yml.tmp docker-compose.yml
      fi

      # The block above only fires while the compose file still carries the
      # upstream demo password. An install that was already rewritten with some
      # other value skips it silently, and the dashboard login then differs from
      # the Authelia one without anything saying so. Say so.
      if ! grep -qF "INDEXER_PASSWORD=$(cat /var/lib/wazuh/admin-pass)" docker-compose.yml; then
        echo "WARNING: the indexer admin password is NOT the Authelia one." >&2
        echo "WARNING: rotate it with src/scripts/wazuh-rotate-admin.sh (needs the admin cert)." >&2
      fi
    '';
  };

  # Sign in with the lldap account rather than the indexer's own user
  # database. Runs after the stack is up because it pushes the configuration
  # into the running cluster, not just onto disk.
  # The files must exist before the stack starts: Docker creates a directory
  # where a bind-mount source is missing, and the indexer then refuses to
  # start at all with "Are you trying to mount a directory onto a file".
  systemd.services.wazuh-ldap-files = {
    description = "Write the Wazuh indexer's lldap security files";
    before = [ "wazuh.service" ];
    requiredBy = [ "wazuh.service" ];
    path = [ pkgs.coreutils ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    environment.LDAP_BIND_PASSWORD_FILE = config.sops.secrets.lldap-admin-password.path;
    script = "exec ${pkgs.bash}/bin/bash ${../scripts/wazuh-ldap.sh} write";
  };

  systemd.services.wazuh-ldap = {
    description = "Point the Wazuh indexer at lldap";
    after = [ "wazuh.service" ];
    requires = [ "wazuh.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.docker pkgs.coreutils pkgs.gnugrep ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      WorkingDirectory = stack;
      TimeoutStartSec = "10min";
      Restart = "on-failure";
      RestartSec = 60;
    };
    environment.LDAP_BIND_PASSWORD_FILE = config.sops.secrets.lldap-admin-password.path;
    script = "exec ${pkgs.bash}/bin/bash ${../scripts/wazuh-ldap.sh}";
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
    for src in 10.100.0.100 10.100.0.103 10.100.0.106; do
      iptables -A DOCKER-HOMELAB -s $src -j RETURN
    done
    iptables -A DOCKER-HOMELAB -j DROP
  '';
}
