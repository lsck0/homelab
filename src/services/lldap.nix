# lldap: the lab's single account store, authelia binds to it
{ config, lib, pkgs, inventory, retry, site, ... }:
let
  # admins reach everything; everyone else gets one app-<service> group per service
  routes = (import ../modules/catalog.nix { inherit inventory lib; }).internal;
  ssoRoutes = lib.filterAttrs (_: r: (r.auth or "sso") == "sso") routes;
  # own-login routes (forgejo, jellyfin, hass, headscale) check the same groups through oidc or ldap
  ownRoutes = lib.filterAttrs (_: r: (r.auth or "sso") == "own") routes;
  appGroups = map (n: "app-${n}") (lib.attrNames ssoRoutes ++ lib.attrNames ownRoutes);
  groups = lib.unique ([ "admins" ] ++ appGroups);

  # example account, three pages
  guestGroups = [ "app-homepage" "app-jellyfin" "app-jellyseerr" ];

  # admin session helpers for lab-user and the bootstrap; set -e callers stop on any failure
  lldapApi = pkgs.writeText "lldap-api.sh" ''
    URL=http://127.0.0.1:17170
    lldap_login() {
      TOKEN=$(curl -sf -X POST "$URL/auth/simple/login" -H 'Content-Type: application/json' \
        -d "$(jq -cn --rawfile p ${config.sops.secrets.lldap-admin-password.path} '{username:"admin", password:($p|rtrimstr("\n"))}')" \
        | jq -r .token)
      [ -n "$TOKEN" ] && [ "$TOKEN" != null ] || { echo "lldap admin login failed" >&2; return 1; }
    }
    # graphql answers 200 with an errors array, so check it
    gql() {
      local out
      out=$(curl -sf -X POST "$URL/api/graphql" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$1")
      if echo "$out" | jq -e .errors >/dev/null; then echo "$out" | jq -r '.errors[].message' >&2; return 1; fi
      echo "$out"
    }
    user_create() { # id email
      gql "$(jq -cn --arg u "$1" --arg e "$2" '{query:"mutation($u:CreateUserInput!){createUser(user:$u){id}}",variables:{u:{id:$u,email:$e}}}')" >/dev/null
    }
    join() { # user group..., skips groups the user is already in
      local u=$1 all have g gid; shift
      all=$(gql '{"query":"{groups{id displayName}}"}')
      have=$(gql "$(jq -cn --arg u "$u" '{query:"query($u:String!){user(userId:$u){groups{displayName}}}",variables:{u:$u}}')" \
        | jq -r '.data.user.groups[].displayName')
      for g in "$@"; do
        grep -qxF "$g" <<<"$have" && continue
        gid=$(echo "$all" | jq -r --arg g "$g" '.data.groups[] | select(.displayName==$g) | .id')
        [ -n "$gid" ] || { echo "no group $g" >&2; return 1; }
        gql "$(jq -cn --arg u "$u" --argjson g "$gid" '{query:"mutation($u:String!,$g:Int!){addUserToGroup(userId:$u,groupId:$g){ok}}",variables:{u:$u,g:$g}}')" >/dev/null
      done
    }
  '';

  # accounts are a username and a password; lldap insists on an email, so it is derived
  labUser = pkgs.writeShellApplication {
    name = "lab-user";
    runtimeInputs = [ pkgs.curl pkgs.jq pkgs.lldap pkgs.coreutils pkgs.gnugrep ];
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
      # shellcheck disable=SC1091
      source ${lldapApi}
      lldap_login
      ask() {
        local a b
        read -rsp "password for $1: " a; echo >&2
        read -rsp "again: " b; echo >&2
        [ -n "$a" ] && [ "$a" = "$b" ] || { echo "passwords empty or different" >&2; exit 1; }
        printf %s "$a"
      }
      cmd=''${1:-}; shift || true
      case "$cmd" in
        list)   gql '{"query":"{users{id groups{displayName}}}"}' \
                  | jq -r '.data.users[] | "\(.id)\t\([.groups[].displayName] | join(" "))"' ;;
        add)    name=''${1:?name}; shift
                pass=$(ask "$name")
                user_create "$name" "$name@lsck0.dev"
                lldap_set_password --base-url "$URL" --token "$TOKEN" --username "$name" --password "$pass" >/dev/null
                [ $# -eq 0 ] || join "$name" "$@"
                echo "created $name" ;;
        passwd) name=''${1:?name}
                lldap_set_password --base-url "$URL" --token "$TOKEN" --username "$name" --password "$(ask "$name")" >/dev/null
                echo "password set for $name" ;;
        groups) name=''${1:?name}; shift; join "$name" "$@"; echo "groups added to $name" ;;
        del)    name=''${1:?name}
                gql "$(jq -cn --arg u "$name" '{query:"mutation($u:String!){deleteUser(userId:$u){ok}}",variables:{u:$u}}')" >/dev/null
                echo "deleted $name" ;;
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
    path = [ pkgs.curl pkgs.jq pkgs.lldap pkgs.coreutils pkgs.gnugrep ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 10;
    };
    script = ''
      set -euo pipefail
      source ${lldapApi}

      ${retry} 60 2 curl -sf "$URL/health"
      lldap_login

      # create only what is missing, lldap rejects duplicates
      have=$(gql '{"query":"{groups{displayName}}"}' | jq -r '.data.groups[].displayName')
      for g in ${lib.escapeShellArgs groups}; do
        grep -qxF "$g" <<<"$have" && continue
        gql "$(jq -cn --arg g "$g" '{query:"mutation($g:String!){createGroup(name:$g){id}}",variables:{g:$g}}')" >/dev/null
      done
      users=$(gql '{"query":"{users{id}}"}' | jq -r '.data.users[].id')
      grep -qxF luca <<<"$users" || user_create luca ${config.homelab.acmeEmail}
      # example user
      grep -qxF guest <<<"$users" || user_create guest guest@lsck0.dev

      # passwords via opaque
      lldap_set_password --base-url "$URL" --token "$TOKEN" --username luca --password "$(cat ${config.sops.secrets.authelia-admin-pass.path})"
      lldap_set_password --base-url "$URL" --token "$TOKEN" --username guest --password "$(cat ${config.sops.secrets.lldap-guest-password.path})"

      join luca admins
      # lldap's own rights come only from its built-in lldap_admin, so every admin gets it too
      admins=$(gql '{"query":"{groups{displayName users{id}}}"}' | jq -r '.data.groups[] | select(.displayName=="admins") | .users[].id')
      for u in $admins; do
        join "$u" lldap_admin
      done
      join guest ${lib.escapeShellArgs guestGroups}

      echo "lldap seeded: admins are lldap admins, guest in ${lib.concatStringsSep ", " guestGroups}"
    '';
  };

  # every account lives in this sqlite file
  homelab.dbBackup.databases.lldap.sqlite = "/var/lib/lldap/users.db";

  # 3890 ldap, 17170 web ui (traefik + authelia)
  networking.firewall.allowedTCPPorts = [ 3890 17170 ];
  homelab.ingressOnly = {
    ports = [ 3890 17170 ];
    portSources."3890" = [
      "10.100.0.134/32"    # jellyfin ldap plugin
      "${site.lan.proxmox}/32" # proxmox lldap realm (scripts/pve-install.sh)
    ];
  };
}
