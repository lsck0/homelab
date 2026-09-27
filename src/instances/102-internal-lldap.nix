{ config, lib, pkgs, retry, ... }:
let
  # bundle groups plus one app-<route> group per page
  routes = (import ../modules/routes.nix).internal;
  ssoRoutes = lib.filterAttrs (_: r: (r.auth or "sso") == "sso") routes;
  routeGroups = lib.unique (lib.mapAttrsToList (_: r: r.group or "users") ssoRoutes);
  appGroups = map (n: "app-${n}") (lib.attrNames ssoRoutes ++ [ "forgejo" "jellyfin" ]);
  groups = lib.unique ([ "admins" "users" ] ++ routeGroups ++ appGroups);

  # example account, three pages
  guestGroups = [ "app-homepage" "app-jellyfin" "app-jellyseerr" ];
in {
  networking.hostName = "vm-102";

  # lldap: the lab's single account store
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

  # luca's password, reused from authelia admin
  sops.secrets.authelia-admin-pass = { owner = "lldap"; group = "lldap"; };
  sops.secrets.lldap-guest-password = { owner = "lldap"; group = "lldap"; };

  # seed groups and the admin user
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
      GUEST_PASS=$(cat ${config.sops.secrets.lldap-guest-password.path})

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

      # every referenced group, ignore "already exists"
      ${lib.concatMapStrings (g: ''
        gql '{"query":"mutation{createGroup(name:\"${g}\"){id}}"}' || true
      '') groups}

      # admin user luca
      gql '{"query":"mutation($u:CreateUserInput!){createUser(user:$u){id}}","variables":{"u":{"id":"luca","email":"'${config.homelab.acmeEmail}'","displayName":"Luca"}}}' || true

      # password via opaque
      lldap_set_password --base-url "$URL" --token "$TOKEN" --username luca --password "$LUCA_PASS"

      # example user guest
      gql '{"query":"mutation($u:CreateUserInput!){createUser(user:$u){id}}","variables":{"u":{"id":"guest","email":"guest@lsck0.dev","displayName":"Guest"}}}' || true
      lldap_set_password --base-url "$URL" --token "$TOKEN" --username guest --password "$GUEST_PASS"

      ALL_GROUPS=$(gql '{"query":"{groups{id displayName}}"}')
      join() { # user group...
        u=$1; shift
        for g in "$@"; do
          gid=$(echo "$ALL_GROUPS" | jq -r --arg g "$g" '.data.groups[] | select(.displayName==$g) | .id')
          [ -n "$gid" ] || { echo "group $g not found after seeding"; exit 1; }
          gql "{\"query\":\"mutation{addUserToGroup(userId:\\\"$u\\\",groupId:$gid){ok}}\"}" || true
        done
      }
      # owner gets every group
      join luca ${lib.escapeShellArgs groups}
      join guest ${lib.escapeShellArgs guestGroups}

      echo "lldap seeded: luca in all groups, guest in ${lib.concatStringsSep ", " guestGroups}"
    '';
  };

  # every account lives in this sqlite file
  homelab.dbBackup.databases.lldap.sqlite = "/var/lib/lldap/users.db";

  # 3890 ldap (lan), 17170 web ui (traefik + authelia)
  networking.firewall.allowedTCPPorts = [ 3890 17170 ];
}
