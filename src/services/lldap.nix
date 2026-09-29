# lldap: the lab's single account store, authelia binds to it
{ config, lib, pkgs, retry, ... }:
let
  # admins reach everything; everyone else gets one app-<service> group per service
  routes = (import ../modules/routes.nix).internal;
  ssoRoutes = lib.filterAttrs (_: r: (r.auth or "sso") == "sso") routes;
  # own-login routes (forgejo, jellyfin, hass, headscale) check the same groups through oidc or ldap
  ownRoutes = lib.filterAttrs (_: r: (r.auth or "sso") == "own") routes;
  appGroups = map (n: "app-${n}") (lib.attrNames ssoRoutes ++ lib.attrNames ownRoutes);
  groups = lib.unique ([ "admins" ] ++ appGroups);

  # example account, three pages
  guestGroups = [ "app-homepage" "app-jellyfin" "app-jellyseerr" ];

  # accounts are a username and a password; lldap insists on an email, so it is derived
  labUser = pkgs.writeShellApplication {
    name = "lab-user";
    runtimeInputs = [ pkgs.curl pkgs.jq pkgs.lldap pkgs.coreutils ];
    text = ''
      usage() {
        cat <<USAGE
      lab-user list                      users and their groups
      lab-user add <name> [group...]     asks for the password; groups: admins or app-<service>
      lab-user passwd <name>             asks for the new password
      lab-user groups <name> <group...>  add groups
      lab-user del <name>
      USAGE
        exit 1
      }
      URL=http://127.0.0.1:17170
      TOKEN=$(curl -sf -X POST "$URL/auth/simple/login" -H 'Content-Type: application/json' \
        -d "$(jq -cn --rawfile p ${config.sops.secrets.lldap-admin-password.path} '{username:"admin", password:($p|rtrimstr("\n"))}')" \
        | jq -r .token)
      gql() { curl -sf -X POST "$URL/api/graphql" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$1"; }
      ask() {
        local a b
        read -rsp "password for $1: " a; echo >&2
        read -rsp "again: " b; echo >&2
        [ -n "$a" ] && [ "$a" = "$b" ] || { echo "passwords empty or different" >&2; exit 1; }
        printf %s "$a"
      }
      join() { # user group...
        local u=$1 all g gid; shift
        all=$(gql '{"query":"{groups{id displayName}}"}')
        for g in "$@"; do
          gid=$(echo "$all" | jq -r --arg g "$g" '.data.groups[] | select(.displayName==$g) | .id')
          [ -n "$gid" ] || { echo "no group $g" >&2; exit 1; }
          gql "$(jq -cn --arg u "$u" --argjson g "$gid" '{query:"mutation($u:String!,$g:Int!){addUserToGroup(userId:$u,groupId:$g){ok}}",variables:{u:$u,g:$g}}')" >/dev/null
        done
      }
      cmd=''${1:-}; shift || true
      case "$cmd" in
        list)   gql '{"query":"{users{id groups{displayName}}}"}' \
                  | jq -r '.data.users[] | "\(.id)\t\([.groups[].displayName] | join(" "))"' ;;
        add)    name=''${1:?name}; shift
                pass=$(ask "$name")
                gql "$(jq -cn --arg u "$name" '{query:"mutation($u:CreateUserInput!){createUser(user:$u){id}}",variables:{u:{id:$u,email:($u+"@lsck0.dev")}}}')" \
                  | jq -e '.data.createUser.id' >/dev/null || { echo "could not create $name" >&2; exit 1; }
                lldap_set_password --base-url "$URL" --token "$TOKEN" --username "$name" --password "$pass" >/dev/null
                [ $# -eq 0 ] || join "$name" "$@"
                echo "created $name" ;;
        passwd) name=''${1:?name}
                lldap_set_password --base-url "$URL" --token "$TOKEN" --username "$name" --password "$(ask "$name")" >/dev/null
                echo "password set for $name" ;;
        groups) name=''${1:?name}; shift; join "$name" "$@"; echo "groups added to $name" ;;
        del)    name=''${1:?name}
                gql "$(jq -cn --arg u "$name" '{query:"mutation($u:String!){deleteUser(userId:$u){ok}}",variables:{u:$u}}')" \
                  | jq -e '.data.deleteUser.ok' >/dev/null && echo "deleted $name" ;;
        *)      usage ;;
      esac
    '';
  };
in {
  environment.systemPackages = [ labUser ];

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
  # server_key derives every opaque password: a restored users.db is useless without it
  sops.secrets.lldap-server-key = { owner = "lldap"; group = "lldap"; };
  systemd.services.lldap.preStart = lib.mkBefore ''
    [ -s /var/lib/lldap/server_key ] || ${pkgs.coreutils}/bin/base64 -d ${config.sops.secrets.lldap-server-key.path} > /var/lib/lldap/server_key
  '';

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
      gql '{"query":"mutation($u:CreateUserInput!){createUser(user:$u){id}}","variables":{"u":{"id":"luca","email":"'${config.homelab.acmeEmail}'"}}}' || true

      # password via opaque
      lldap_set_password --base-url "$URL" --token "$TOKEN" --username luca --password "$LUCA_PASS"

      # example user guest
      gql '{"query":"mutation($u:CreateUserInput!){createUser(user:$u){id}}","variables":{"u":{"id":"guest","email":"guest@lsck0.dev"}}}' || true
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
      join luca admins
      # lldap's own rights come only from its built-in lldap_admin, so every admin gets it too
      ADMINS_GID=$(echo "$ALL_GROUPS" | jq -r '.data.groups[] | select(.displayName=="admins") | .id')
      for u in $(gql "{\"query\":\"{group(groupId:$ADMINS_GID){users{id}}}\"}" | jq -r '.data.group.users[].id'); do
        join "$u" lldap_admin
      done
      join guest ${lib.escapeShellArgs guestGroups}

      echo "lldap seeded: admins are lldap admins, guest in ${lib.concatStringsSep ", " guestGroups}"
    '';
  };

  # every account lives in this sqlite file
  homelab.dbBackup.databases.lldap.sqlite = "/var/lib/lldap/users.db";

  # 3890 ldap (lan), 17170 web ui (traefik + authelia)
  networking.firewall.allowedTCPPorts = [ 3890 17170 ];
}
