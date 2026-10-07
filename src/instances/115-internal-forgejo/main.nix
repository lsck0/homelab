# forgejo: the git forge, logins through authelia oidc, github mirrors, api tokens for the lab
{ config, pkgs, lib, inventory, catalog, nasMount, retry, setupUnit, site, ... }:
let
  net = import ../../modules/net.nix { inherit lib inventory site; };
  route = catalog.internal.forgejo;
  autheliaHost = net.fqdn catalog.internal.authelia.host;
  localUrl = "http://127.0.0.1:${toString route.port}";
  api = "${localUrl}/api";
  containerHttpPort = 3000;
  # the container's git user, which owns the data dir
  containerUid = 1000;
  sshPort = 2222;
  data = "/var/lib/forgejo";
  db = "${data}/gitea/gitea.db";
  owner = "luca";

  # LTS line, security fixes until 2027-07-15 (forgejo.org/releases). forgejo migrates the db at start and refuses
  # an older version afterwards, so forgejo-upgrade-backup keeps the db before every new image. Before a major bump:
  # `forgejo manager flush-queues` on the running version, read the release notes' "When upgrading from" list,
  # deploy, then `forgejo doctor check --all`.
  image = "codeberg.org/forgejo/forgejo:15.0.9";

  # the forgejo cli inside the container, after the web side answers
  forgejoPrelude = ''
    forgejo_cli() { podman exec -u git forgejo forgejo "$@"; }
    ${retry} 60 2 curl -sf ${api}/healthz
    # <token>: 200 when forgejo accepts it, the header from a pipe so the token stays off argv
    forgejo_token_status() {
      printf 'Authorization: token %s\n' "$1" | curl -s -o /dev/null -w '%{http_code}' -H @- ${api}/v1/user
    }
  '';

  # a bot user and its api token, exported as a lab token. The stored token stays while forgejo accepts it; only
  # a 401 (revoked, or the db restored to a time before it) mints a new one, so tokens do not pile up
  botToken = { name, token, scopes, admin ? false }: setupUnit {
    description = "Export a Forgejo API token for ${name}";
    after = [ "podman-forgejo.service" "forgejo-init.service" ];
    path = [ pkgs.curl pkgs.podman pkgs.coreutils pkgs.gawk pkgs.gnugrep ];
    script = ''
      ${forgejoPrelude}
      if current=$(token_read ${token}); then
        case "$(forgejo_token_status "$current")" in
          200) echo "${name} token valid"; exit 0 ;;
          401) echo "${name} token rejected, minting a new one" ;;
          *) echo "${name} token check inconclusive, retrying" >&2; exit 1 ;;
        esac
      fi
      if ! forgejo_cli admin user list | awk 'NR > 1 { print $2 }' | grep -qx ${name}-bot; then
        # its password is never used: the bot works through tokens
        forgejo_cli admin user create --username ${name}-bot --email ${name}@${site.domain} \
          --random-password ${lib.optionalString admin "--admin "}--must-change-password=false
      fi
      # timestamped: a token name is unique per user
      forgejo_cli admin user generate-access-token --raw --username ${name}-bot --token-name "${name}-$(date +%s)" \
        --scopes ${scopes} | tr -d '\r\n' | token_write ${token}
    '';
  };
in {
  networking.hostName = "vm-115";

  homelab.nasMounts = nasMount data "forgejo";

  sops.secrets.forgejo-oidc-secret = {};

  virtualisation.oci-containers.containers.forgejo = {
    inherit image;
    ports = [ "${toString route.port}:${toString containerHttpPort}" "${toString sshPort}:${toString net.ports.ssh}" ];
    volumes = [ "${data}:/data" ];
    # authelia's discovery document through the internal ingress
    extraOptions = [ "--add-host=${autheliaHost}:${net.ipOf net.zones.internal.ingress}" ];
    environment = {
      FORGEJO__server__HTTP_PORT = toString containerHttpPort;
      FORGEJO__server__ROOT_URL = "https://${net.fqdn route.host}/";
      FORGEJO__security__INSTALL_LOCK = "true";
      FORGEJO__actions__ENABLED = "true";
      # sso-only, nothing visible without login
      FORGEJO__service__DISABLE_REGISTRATION = "true";
      FORGEJO__service__ALLOW_ONLY_EXTERNAL_REGISTRATION = "true";
      FORGEJO__service__REQUIRE_SIGNIN_VIEW = "true";
      FORGEJO__service__ENABLE_BASIC_AUTHENTICATION = "false";
      FORGEJO__openid__ENABLE_OPENID_SIGNIN = "false";
      FORGEJO__oauth2_client__ENABLE_AUTO_REGISTRATION = "true";
      FORGEJO__oauth2_client__ACCOUNT_LINKING = "auto";
      FORGEJO__oauth2_client__USERNAME = "nickname";
    };
  };

  # before every container start (no RemainAfterExit): a new or unknown previous image keeps the db as
  # gitea.db.before-<tag>, never overwritten
  systemd.services.forgejo-upgrade-backup = {
    description = "Keep the Forgejo database before an image upgrade migrates it";
    before = [ "podman-forgejo.service" ];
    requiredBy = [ "podman-forgejo.service" ];
    unitConfig.RequiresMountsFor = [ data ];
    path = [ pkgs.sqlite pkgs.coreutils ];
    serviceConfig.Type = "oneshot";
    script = let running = config.virtualisation.oci-containers.containers.forgejo.image; in ''
      stamp=${data}/.image
      [ "$(cat "$stamp" 2>/dev/null)" = ${lib.escapeShellArg running} ] && exit 0
      if [ -f ${db} ]; then
        keep=${db}.before-${lib.last (lib.splitString ":" running)}
        if [ ! -e "$keep" ]; then
          sqlite3 ${db} ".backup '$keep.tmp'"
          mv "$keep.tmp" "$keep"
          echo "kept the database as $keep before upgrading to ${running}"
        fi
      fi
      printf '%s' ${lib.escapeShellArg running} > "$stamp.tmp"
      mv "$stamp.tmp" "$stamp"
    '';
  };

  # the owner's account on a fresh forge with a random password: logins go through authelia (ACCOUNT_LINKING auto),
  # the break-glass is `forgejo admin user change-password`
  systemd.services.forgejo-init = setupUnit {
    description = "Create the Forgejo owner account on a fresh forge";
    after = [ "podman-forgejo.service" ];
    path = [ pkgs.curl pkgs.podman pkgs.gawk pkgs.coreutils ];
    script = ''
      ${forgejoPrelude}
      # the header line, then one line per user
      users=$(forgejo_cli admin user list | awk 'NR > 1 && NF' | wc -l)
      [ "$users" -gt 0 ] && { echo "$users users exist, nothing to create"; exit 0; }
      forgejo_cli admin user create --admin --username ${owner} --email ${config.homelab.acmeEmail} \
        --random-password --must-change-password=false
      echo "owner account created"
    '';
  };

  # the authelia login source, created once and corrected every run
  systemd.services.forgejo-oauth2-setup = setupUnit {
    description = "Configure Forgejo OAuth2 with Authelia";
    after = [ "podman-forgejo.service" "forgejo-init.service" ];
    path = [ pkgs.curl pkgs.podman pkgs.gawk ];
    script = ''
      ${forgejoPrelude}
      # the cli takes the client secret only as a flag; it stays inside this vm
      secret=$(cat ${config.sops.secrets.forgejo-oidc-secret.path})
      discover="https://${autheliaHost}/.well-known/openid-configuration"
      # name is the button label; explicit scopes, "openid" alone breaks signup
      id=$(forgejo_cli admin auth list | awk '$2 == "authelia" { print $1 }')
      if [ -n "$id" ]; then
        forgejo_cli admin auth update-oauth --id "$id" --name authelia --secret "$secret" \
          --auto-discover-url "$discover" --scopes openid --scopes profile --scopes email
        echo "authelia login source $id updated"
      else
        forgejo_cli admin auth add-oauth --name authelia --provider openidConnect --key forgejo --secret "$secret" \
          --auto-discover-url "$discover" --scopes openid --scopes profile --scopes email --skip-local-2fa
        echo "authelia login source created"
      fi
    '';
  };

  # api tokens for consumers outside the vm, shared via the nas
  systemd.services.forgejo-homepage-token = botToken {
    name = "homepage";
    token = "forgejo-key";
    scopes = "read:activitypub,read:issue,read:misc,read:notification,read:organization,read:package,read:repository,read:user";
  };
  # hermes operates the forge
  systemd.services.forgejo-hermes-token = botToken {
    name = "hermes";
    token = "forgejo-hermes";
    scopes = "all";
    admin = true;
  };

  # the runner registration token, read by the runner on vm-117; regenerated each run, a used one is spent
  systemd.services.forgejo-runner-token = setupUnit {
    description = "Export a Forgejo runner registration token";
    after = [ "podman-forgejo.service" "forgejo-oauth2-setup.service" ];
    path = [ pkgs.curl pkgs.podman pkgs.coreutils ];
    script = ''
      ${forgejoPrelude}
      forgejo_cli actions generate-runner-token | tr -d '\r\n' | token_write forgejo-runner
    '';
  };

  # GitHub mirrors: github is the source, forgejo pull-mirrors each repo
  sops.secrets.github-mirror-token = {};

  systemd.services.forgejo-mirror = {
    description = "Mirror every GitHub repository into Forgejo";
    after = [ "podman-forgejo.service" "forgejo-init.service" ];
    path = [ pkgs.curl pkgs.jq pkgs.podman pkgs.coreutils pkgs.gawk ];
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "forgejo-mirror";
    };
    environment = {
      FORGEJO_URL = localUrl;
      FORGEJO_OWNER = owner;
      # forgejo's own re-fetch interval
      MIRROR_INTERVAL = "8h";
      FORGEJO_TOKEN_FILE = "/var/lib/forgejo-mirror/token";
      GITHUB_TOKEN_FILE = config.sops.secrets.github-mirror-token.path;
    };
    script = ''
      set -euo pipefail
      ${forgejoPrelude}
      # its own write token on the owner's account, local to this vm; reissued only when forgejo rejects it
      if [ ! -s "$FORGEJO_TOKEN_FILE" ] || [ "$(forgejo_token_status "$(cat "$FORGEJO_TOKEN_FILE")")" = 401 ]; then
        forgejo_cli admin user generate-access-token --raw --username "$FORGEJO_OWNER" --token-name "mirror-$(date +%s)" \
          --scopes write:repository,read:user | tr -d '\r\n' > "$FORGEJO_TOKEN_FILE.tmp"
        [ -s "$FORGEJO_TOKEN_FILE.tmp" ] || { echo "no token from generate-access-token" >&2; exit 1; }
        chmod 600 "$FORGEJO_TOKEN_FILE.tmp"
        mv "$FORGEJO_TOKEN_FILE.tmp" "$FORGEJO_TOKEN_FILE"
      fi
      exec ${pkgs.bash}/bin/bash ${./lib/forgejo-mirror.sh}
    '';
  };

  # daily repo discovery, forgejo fetches on MIRROR_INTERVAL
  systemd.timers.forgejo-mirror = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
  };

  systemd.tmpfiles.rules = [
    "d ${data} 0750 ${toString containerUid} ${toString containerUid} -"
  ];

  networking.firewall.allowedTCPPorts = [ route.port sshPort ];
  # the web login is behind authelia; git ssh stays open
  homelab.ingressOnly.ports = [ route.port ];

  # consistent copy for the snapshot, the live file may be mid-write
  homelab.dbBackup.databases.forgejo.sqlite = db;
}
