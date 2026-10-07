# lldap: the lab's single account store; authelia and the proxmox realm read it through read-only bind users
#
# Passwords reach lldap_set_password through its environment (LLDAP_USER_PASSWORD), never its command line, and the
# admin session the helpers open is logged out (its tokens blacklisted) when the script exits, so the token that
# does sit on a command line for a moment is dead afterwards.
{ config, lib, pkgs, retry, inventory, site, catalog, ... }:
let
  net = import ../../../modules/net.nix { inherit lib inventory site; };
  routes = catalog.internal;
  ldapPort = 3890;
  httpPort = routes.lldap.port;
  stateDir = "/var/lib/lldap";
  adminUser = "luca";
  guestUser = "guest";
  apiInputs = [ pkgs.curl pkgs.jq pkgs.lldap pkgs.coreutils pkgs.gnugrep ];

  # every group authelia admits, forwardauth and oidc (modules/catalog.nix access)
  inherit (catalog.access) admins;
  groups = [ admins ] ++ lib.attrValues catalog.access.groups;

  # the example account: the pages a route opens to it (its `guest`)
  guestGroups = map (name: catalog.access.groups.${name}) (lib.attrNames (lib.filterAttrs (_: r: r.guest) routes));

  # services that read the directory: a user each in lldap's built-in read-only group, never the admin
  readonlyGroup = "lldap_strict_readonly";
  bindUsers = {
    authelia-bind = "lldap-authelia-bind-password";
    # the proxmox realm's sync (scripts/pve-install.sh)
    proxmox-bind = "lldap-proxmox-bind-password";
  };

  # admin session helpers for lab-user and the bootstrap; set -e callers stop on any failure
  lldapApi = pkgs.writeText "lldap-api.sh" ''
    URL=http://127.0.0.1:${toString httpPort}
    # the login body from a file on stdin: the admin password never reaches an argv
    lldap_login() {
      JAR=$(mktemp)
      trap lldap_logout EXIT
      TOKEN=$(jq -cn --rawfile p ${config.sops.secrets.lldap-admin-password.path} '{username:"admin", password:($p|rtrimstr("\n"))}' \
        | curl -sf -c "$JAR" -X POST "$URL/auth/simple/login" -H 'Content-Type: application/json' --data-binary @- \
        | jq -r .token)
      [ -n "$TOKEN" ] && [ "$TOKEN" != null ] || { echo "lldap admin login failed" >&2; return 1; }
    }
    # blacklists every token of the session, the one lldap_set_password saw on its command line included
    lldap_logout() {
      [ -n "''${JAR:-}" ] || return 0
      curl -sf -b "$JAR" -o /dev/null "$URL/auth/logout" || echo "lldap logout failed" >&2
      rm -f "$JAR"
    }
    # user, password file
    password_set() {
      LLDAP_USER_PASSWORD=$(cat "$2") lldap_set_password --base-url "$URL" --token "$TOKEN" --username "$1" >/dev/null
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
    runtimeInputs = apiInputs;
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
      # the password into the environment of lldap_set_password alone
      ask_and_set() {
        local a b
        read -rsp "password for $1: " a; echo >&2
        read -rsp "again: " b; echo >&2
        [ -n "$a" ] && [ "$a" = "$b" ] || { echo "passwords empty or different" >&2; exit 1; }
        LLDAP_USER_PASSWORD=$a lldap_set_password --base-url "$URL" --token "$TOKEN" --username "$1" >/dev/null
      }
      [ $# -gt 0 ] || usage
      cmd=$1; shift
      case "$cmd" in
        list)   gql '{"query":"{users{id groups{displayName}}}"}' \
                  | jq -r '.data.users[] | "\(.id)\t\([.groups[].displayName] | join(" "))"' ;;
        add)    name=''${1:?name}; shift
                user_create "$name" "$name@${net.domain}"
                ask_and_set "$name"
                [ $# -eq 0 ] || join "$name" "$@"
                echo "created $name" ;;
        passwd) name=''${1:?name}
                ask_and_set "$name"
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

  sops.secrets = lib.genAttrs [
    "lldap-jwt-secret"
    "lldap-admin-password"
    # the admin's password, reused from authelia admin
    "authelia-admin-pass"
    "lldap-guest-password"
    # derives every opaque password: a restored users.db is useless without it
    "lldap-server-key"
  ] (_: { owner = "lldap"; group = "lldap"; })
  # the bootstrap (root) sets them; a reader on this host declares its own owner (authelia)
  // lib.mapAttrs' (_: secret: lib.nameValuePair secret { }) bindUsers;

  users.users.lldap = { isSystemUser = true; group = "lldap"; };
  users.groups.lldap = {};

  services.lldap = {
    enable = true;
    silenceForceUserPassResetWarning = true;
    settings = {
      ldap_base_dn = net.domainDn;
      ldap_host = "0.0.0.0";
      ldap_port = ldapPort;
      http_host = "0.0.0.0";
      http_port = httpPort;
      http_url = "https://${net.fqdn routes.lldap.host}";
      ldap_user_dn = "admin";
      ldap_user_email = "admin@${net.domain}";
    };
    environment = {
      LLDAP_JWT_SECRET_FILE = config.sops.secrets.lldap-jwt-secret.path;
      LLDAP_LDAP_USER_PASS_FILE = config.sops.secrets.lldap-admin-password.path;
    };
  };

  systemd.services.lldap.preStart = lib.mkBefore ''
    [ -s ${stateDir}/server_key ] || ${pkgs.coreutils}/bin/base64 -d ${config.sops.secrets.lldap-server-key.path} > ${stateDir}/server_key
  '';

  systemd.services.lldap-bootstrap = {
    description = "Seed lldap groups and users";
    after = [ "lldap.service" ];
    requires = [ "lldap.service" ];
    wantedBy = [ "multi-user.target" ];
    path = apiInputs;
    # the groups as data, so tests/policy/sso.nix can hold them against authelia's rules
    environment.BOOTSTRAP_GROUPS = toString groups;
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
      for g in $BOOTSTRAP_GROUPS; do
        grep -qxF "$g" <<<"$have" && continue
        gql "$(jq -cn --arg g "$g" '{query:"mutation($g:String!){createGroup(name:$g){id}}",variables:{g:$g}}')" >/dev/null
      done
      users=$(gql '{"query":"{users{id}}"}' | jq -r '.data.users[].id')
      grep -qxF ${adminUser} <<<"$users" || user_create ${adminUser} ${config.homelab.acmeEmail}
      grep -qxF ${guestUser} <<<"$users" || user_create ${guestUser} ${guestUser}@${net.domain}
      ${lib.concatMapStrings (user: ''
        grep -qxF ${user} <<<"$users" || user_create ${user} ${user}@${net.domain}
      '') (lib.attrNames bindUsers)}

      # passwords via opaque, from the secret files
      password_set ${adminUser} ${config.sops.secrets.authelia-admin-pass.path}
      password_set ${guestUser} ${config.sops.secrets.lldap-guest-password.path}
      ${lib.concatStrings (lib.mapAttrsToList (user: secret: ''
        password_set ${user} ${config.sops.secrets.${secret}.path}
        join ${user} ${readonlyGroup}
      '') bindUsers)}

      join ${adminUser} ${admins}
      # lldap's own rights come only from its built-in lldap_admin, so every admin gets it too
      admin_ids=$(gql '{"query":"{groups{displayName users{id}}}"}' | jq -r '.data.groups[] | select(.displayName=="${admins}") | .users[].id')
      for u in $admin_ids; do
        join "$u" lldap_admin
      done
      join ${guestUser} ${lib.escapeShellArgs guestGroups}

      echo "lldap seeded: admins are lldap admins, ${guestUser} in ${lib.concatStringsSep ", " guestGroups}, ${lib.concatStringsSep " and " (lib.attrNames bindUsers)} read only"
    '';
  };

  # every account lives in this sqlite file
  homelab.dbBackup.databases.lldap.sqlite = "${stateDir}/users.db";

  # ldap for authelia on this host and the proxmox realm, the web ui through the ingress
  networking.firewall.allowedTCPPorts = [ ldapPort httpPort ];
  homelab.ingressOnly.ports = [ ldapPort httpPort ];
}
