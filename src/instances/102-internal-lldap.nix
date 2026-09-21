{ config, lib, pkgs, retry, ... }:
let
  # every group referenced by a route in modules/routes.nix, plus the two base
  # groups. Authelia turns route.group into an allow rule, so a group that does
  # not exist here would deny the service to everyone.
  routes = (import ../modules/routes.nix).internal;
  routeGroups = lib.unique (lib.mapAttrsToList (_: r: r.group or "users")
    (lib.filterAttrs (_: r: (r.auth or "sso") == "sso") routes));
  groups = lib.unique ([ "admins" "users" ] ++ routeGroups);
in {
  networking.hostName = "vm-102";

  # lightweight LDAP directory: the single account store for the lab. Authelia
  # authenticates every SSO route against it, Jellyfin binds to it directly,
  # and Forgejo/Nextcloud/Vaultwarden/Audiobookshelf/Kavita reach it through
  # Authelia's OIDC provider. Group membership here is what grants or revokes
  # a service for a person.
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

      ${retry} 60 2 curl -sf "$URL/health"

      TOKEN=$(curl -sf -X POST "$URL/auth/simple/login" \
        -H 'Content-Type: application/json' \
        -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASS\"}" | jq -r '.token')
      [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "lldap admin login failed"; exit 1; }

      gql() {
        curl -sf -X POST "$URL/api/graphql" \
          -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
          -d "$1"
      }

      # every group the routes reference (ignore "already exists").
      ${lib.concatMapStrings (g: ''
        gql '{"query":"mutation{createGroup(name:\"${g}\"){id}}"}' || true
      '') groups}

      # admin user luca.
      gql '{"query":"mutation($u:CreateUserInput!){createUser(user:$u){id}}","variables":{"u":{"id":"luca","email":"'${config.homelab.acmeEmail}'","displayName":"Luca"}}}' || true

      # password via the OPAQUE flow.
      lldap_set_password --base-url "$URL" --token "$TOKEN" --username luca --password "$LUCA_PASS"

      # the owner belongs to every group: a route whose group is not granted to
      # anyone would lock the owner out of that service. Additional accounts are
      # created in the dashboard and get only the groups they should have.
      ALL_GROUPS=$(gql '{"query":"{groups{id displayName}}"}')
      for g in ${lib.escapeShellArgs groups}; do
        gid=$(echo "$ALL_GROUPS" | jq -r --arg g "$g" '.data.groups[] | select(.displayName==$g) | .id')
        [ -n "$gid" ] || { echo "group $g not found after seeding"; exit 1; }
        gql "{\"query\":\"mutation{addUserToGroup(userId:\\\"luca\\\",groupId:$gid){ok}}\"}" || true
      done

      echo "lldap seeded: luca in ${lib.concatStringsSep ", " groups}"
    '';
  };

  # every account, password hash and group membership in the lab is in this one
  # SQLite file on vm-102's local disk. Kopia snapshots the NAS only, so without
  # this dump the directory is the single unbacked-up thing in the lab and losing
  # the VM would mean rebuilding every account by hand.
  homelab.dbBackup.databases.lldap.sqlite = "/var/lib/lldap/users.db";

  # 3890 LDAP (LAN only), 17170 web UI (behind Traefik + Authelia).
  networking.firewall.allowedTCPPorts = [ 3890 17170 ];
}
