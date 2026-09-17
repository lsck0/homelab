{ config, pkgs, ... }: {
  networking.hostName = "vm-102";

  # lightweight LDAP directory: one user store other services can share
  # (Authelia, Forgejo, Nextcloud, Grafana, Jellyfin). Runs standalone here;
  # pointing each consumer at it is a follow-up so the working Authelia file
  # backend is not disturbed in the same change.
  #
  # state (sqlite) is on local disk, not NFS: the auth directory must not wedge
  # on a NAS stall (same reasoning as Authelia).
  sops.secrets.lldap-jwt-secret = { owner = "lldap"; group = "lldap"; };
  sops.secrets.lldap-admin-password = { owner = "lldap"; group = "lldap"; };

  users.users.lldap = { isSystemUser = true; group = "lldap"; };
  users.groups.lldap = {};

  services.lldap = {
    enable = true;
    silenceForceUserPassResetWarning = true;
    settings = {
      ldap_base_dn = "dc=lsck0,dc=dev";
      ldap_host = "0.0.0.0";
      ldap_port = 3890;
      http_host = "0.0.0.0";
      http_port = 17170;
      http_url = "https://lldap.lsck0.dev";
      ldap_user_dn = "admin";
      ldap_user_email = "admin@lsck0.dev";
    };
    environment = {
      LLDAP_JWT_SECRET_FILE = config.sops.secrets.lldap-jwt-secret.path;
      LLDAP_LDAP_USER_PASS_FILE = config.sops.secrets.lldap-admin-password.path;
    };
  };

  # luca's own password (reused from the Authelia admin secret) so the seeded
  # user can log in through Authelia's LDAP backend.
  sops.secrets.authelia-admin-pass = { owner = "lldap"; group = "lldap"; };

  # seed the directory: groups (admins, users) + the admin user luca. Idempotent
  #, re-running ignores "already exists". Runs after lldap is up, via its HTTP
  # API (admin token) plus lldap_set_password for the OPAQUE password flow.
  systemd.services.lldap-bootstrap = {
    description = "Seed lldap groups and users";
    after = [ "lldap.service" ];
    requires = [ "lldap.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.jq pkgs.lldap pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 10;
    };
    script = ''
      set -euo pipefail
      URL="http://127.0.0.1:17170"
      ADMIN_PASS=$(cat ${config.sops.secrets.lldap-admin-password.path})
      LUCA_PASS=$(cat ${config.sops.secrets.authelia-admin-pass.path})

      # wait for the API.
      for _ in $(seq 1 60); do
        curl -sf "$URL/health" >/dev/null 2>&1 && break
        sleep 2
      done

      TOKEN=$(curl -sf -X POST "$URL/auth/simple/login" \
        -H 'Content-Type: application/json' \
        -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASS\"}" | jq -r '.token')
      [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "lldap admin login failed"; exit 1; }

      gql() {
        curl -sf -X POST "$URL/api/graphql" \
          -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
          -d "$1"
      }

      # groups (ignore "already exists").
      gql '{"query":"mutation{createGroup(name:\"admins\"){id}}"}' || true
      gql '{"query":"mutation{createGroup(name:\"users\"){id}}"}'  || true

      # admin user luca.
      gql '{"query":"mutation($u:CreateUserInput!){createUser(user:$u){id}}","variables":{"u":{"id":"luca","email":"'${config.homelab.acmeEmail}'","displayName":"Luca"}}}' || true

      # password via the OPAQUE flow.
      lldap_set_password --base-url "$URL" --token "$TOKEN" --username luca --password "$LUCA_PASS"

      # resolve the admins group id and add luca.
      ADMINS_ID=$(gql '{"query":"{groups{id displayName}}"}' \
        | jq -r '.data.groups[] | select(.displayName=="admins") | .id')
      [ -n "$ADMINS_ID" ] || { echo "admins group not found"; exit 1; }
      gql "{\"query\":\"mutation{addUserToGroup(userId:\\\"luca\\\",groupId:$ADMINS_ID){ok}}\"}" || true

      echo "lldap seeded: luca in admins"
    '';
  };

  # 3890 LDAP (LAN only), 17170 web UI (behind Traefik + Authelia).
  networking.firewall.allowedTCPPorts = [ 3890 17170 ];
}
