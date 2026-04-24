{ config, pkgs, lib, nasMount, ... }:
let
  protectedApps = [
    { slug = "traefik";        name = "Traefik";          domain = "traefik.lsck0.dev"; }
    { slug = "registry-ui";    name = "Registry";         domain = "registry-ui.lsck0.dev"; }
    { slug = "paperless";      name = "Paperless";        domain = "paperless.lsck0.dev"; }
    { slug = "jellyfin";       name = "Jellyfin";         domain = "jellyfin.lsck0.dev"; }
    { slug = "huginn";         name = "Huginn";           domain = "huginn.lsck0.dev"; }
    { slug = "homeassistant";  name = "Home Assistant";   domain = "hass.lsck0.dev"; }
    { slug = "grafana";        name = "Grafana";          domain = "grafana.lsck0.dev"; }
    { slug = "wikijs";         name = "Wiki.js";          domain = "wiki.lsck0.dev"; }
    { slug = "audiobookshelf"; name = "Audiobookshelf";   domain = "abs.lsck0.dev"; }
    { slug = "qbittorrent";    name = "qBittorrent";      domain = "torrent.lsck0.dev"; }
    { slug = "prowlarr";       name = "Prowlarr";         domain = "prowlarr.lsck0.dev"; }
    { slug = "sonarr";         name = "Sonarr";           domain = "sonarr.lsck0.dev"; }
    { slug = "radarr";         name = "Radarr";           domain = "radarr.lsck0.dev"; }
    { slug = "navidrome";      name = "Navidrome";        domain = "music.lsck0.dev"; }
    { slug = "kavita";         name = "Kavita";           domain = "read.lsck0.dev"; }
    { slug = "nas";            name = "NAS";              domain = "nas.lsck0.dev"; }
    { slug = "taskchampion";   name = "Tasks";            domain = "tasks.lsck0.dev"; }
    { slug = "proxmox";        name = "Proxmox";          domain = "proxmox.lsck0.dev"; }
  ];

  mkProviderAndApp = app: ''
    - model: authentik_providers_proxy.proxyprovider
      id: provider-${app.slug}
      identifiers:
        name: ${app.slug}-provider
      attrs:
        authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
        mode: forward_single
        external_host: https://${app.domain}
    - model: authentik_core.application
      id: app-${app.slug}
      identifiers:
        slug: ${app.slug}
      attrs:
        name: "${app.name}"
        provider: !KeyOf provider-${app.slug}
        meta_launch_url: https://${app.domain}
  '';

  appEntries = builtins.concatStringsSep "" (
    builtins.map mkProviderAndApp protectedApps
  );

  outpostProvidersList = builtins.concatStringsSep "\n" (
    builtins.map (app: "    - !KeyOf provider-${app.slug}") protectedApps
  );

  # OIDC entries use __PLACEHOLDER__ tokens replaced at runtime by blueprint-sync
  oidcEntries = ''
    # --- Nextcloud OIDC ---
    - model: authentik_providers_oauth2.oauth2provider
      id: provider-nextcloud-oidc
      identifiers:
        name: nextcloud-oidc-provider
      attrs:
        authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
        client_type: confidential
        client_id: nextcloud
        client_secret: __NEXTCLOUD_OIDC_SECRET__
        signing_key: !Find [authentik_crypto.certificatekeypair, [name, authentik Self-signed Certificate]]
        redirect_uris: |
          https://cloud.lsck0.dev/apps/user_oidc/code
        property_mappings:
          - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-openid]]
          - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-email]]
          - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-profile]]
        sub_mode: hashed_user_id
    - model: authentik_core.application
      id: app-nextcloud
      identifiers:
        slug: nextcloud
      attrs:
        name: Nextcloud
        provider: !KeyOf provider-nextcloud-oidc
        meta_launch_url: https://cloud.lsck0.dev

    # --- Vaultwarden OIDC ---
    - model: authentik_providers_oauth2.oauth2provider
      id: provider-vaultwarden-oidc
      identifiers:
        name: vaultwarden-oidc-provider
      attrs:
        authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
        client_type: confidential
        client_id: vaultwarden
        client_secret: __VAULTWARDEN_OIDC_SECRET__
        signing_key: !Find [authentik_crypto.certificatekeypair, [name, authentik Self-signed Certificate]]
        redirect_uris: |
          https://vault.lsck0.dev/identity/connect/oidc-signin
        property_mappings:
          - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-openid]]
          - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-email]]
          - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-profile]]
        sub_mode: hashed_user_id
    - model: authentik_core.application
      id: app-vaultwarden
      identifiers:
        slug: vaultwarden
      attrs:
        name: Vaultwarden
        provider: !KeyOf provider-vaultwarden-oidc
        meta_launch_url: https://vault.lsck0.dev

    # --- Forgejo OIDC ---
    - model: authentik_providers_oauth2.oauth2provider
      id: provider-forgejo-oidc
      identifiers:
        name: forgejo-oidc-provider
      attrs:
        authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
        client_type: confidential
        client_id: forgejo
        client_secret: __FORGEJO_OIDC_SECRET__
        signing_key: !Find [authentik_crypto.certificatekeypair, [name, authentik Self-signed Certificate]]
        redirect_uris: |
          https://git.lsck0.dev/user/oauth2/authentik/callback
        property_mappings:
          - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-openid]]
          - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-email]]
          - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-profile]]
        sub_mode: hashed_user_id
    - model: authentik_core.application
      id: app-forgejo
      identifiers:
        slug: forgejo-oidc
      attrs:
        name: Forgejo
        provider: !KeyOf provider-forgejo-oidc
        meta_launch_url: https://git.lsck0.dev
  '';

  blueprintYaml = ''
    version: 1
    metadata:
      name: Homelab ForwardAuth Apps
      labels:
        blueprints.goauthentik.io/instantiate: "true"
    entries:
    ${appEntries}${oidcEntries}
    - model: authentik_outposts.outpost
      identifiers:
        managed: goauthentik.io/outposts/embedded
      state: present
      attrs:
        name: "authentik Embedded Outpost"
        type: proxy
        config:
          authentik_host: https://auth.lsck0.dev
          authentik_host_insecure: false
        providers:
    ${outpostProvidersList}
  '';

  blueprintFile = pkgs.writeText "homelab-apps-blueprint.yaml" blueprintYaml;
in {
  networking.hostName = "vm-101";

  fileSystems = nasMount "/var/lib/authentik" "authentik"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  sops.secrets.authentik-secret-key = {};
  sops.secrets.authentik-db-password = {};
  sops.secrets.nextcloud-oidc-secret = {};
  sops.secrets.vaultwarden-oidc-secret = {};
  sops.secrets.forgejo-oidc-secret = {};
  sops.templates."authentik.env".content = ''
    AUTHENTIK_SECRET_KEY=${config.sops.placeholder.authentik-secret-key}
    AUTHENTIK_ERROR_REPORTING__ENABLED=true
    AUTHENTIK_REDIS__HOST=redis
    AUTHENTIK_POSTGRESQL__HOST=postgresql
    AUTHENTIK_POSTGRESQL__USER=authentik
    AUTHENTIK_POSTGRESQL__NAME=authentik
    AUTHENTIK_POSTGRESQL__PASSWORD=${config.sops.placeholder.authentik-db-password}
  '';
  sops.templates."postgres.env".content = ''
    POSTGRES_PASSWORD=${config.sops.placeholder.authentik-db-password}
  '';

  homelab.dockerStack = {
    enable = true;
    stackName = "authentik";
    composeFile = ''
      version: "3.4"
      services:
        postgresql:
          image: docker.io/library/postgres:16-alpine
          restart: unless-stopped
          healthcheck:
            test: ["CMD-SHELL", "pg_isready -d $${POSTGRES_DB} -U $${POSTGRES_USER}"]
            start_period: 20s
            interval: 30s
            retries: 5
            timeout: 5s
          volumes:
            - /var/lib/authentik/db:/var/lib/postgresql/data
          env_file:
            - ${config.sops.templates."postgres.env".path}
          environment:
            POSTGRES_USER: authentik
            POSTGRES_DB: authentik
        redis:
          image: docker.io/library/redis:alpine
          command: --save 60 1 --loglevel warning
          restart: unless-stopped
          healthcheck:
            test: ["CMD-SHELL", "redis-cli ping | grep PONG"]
            start_period: 20s
            interval: 30s
            retries: 5
            timeout: 3s
          volumes:
            - /var/lib/authentik/redis:/data
        server:
          image: ghcr.io/goauthentik/server:2024.2.2
          restart: unless-stopped
          command: server
          environment:
            AUTHENTIK_HOST: https://auth.lsck0.dev
            AUTHENTIK_INSECURE: "false"
          env_file:
            - ${config.sops.templates."authentik.env".path}
          volumes:
            - /var/lib/authentik/media:/media
            - /var/lib/authentik/custom-templates:/templates
            - /var/lib/authentik/blueprints:/blueprints/custom
          ports:
            - "80:9000"
            - "443:9443"
          depends_on:
            - postgresql
            - redis
        worker:
          image: ghcr.io/goauthentik/server:2024.2.2
          restart: unless-stopped
          command: worker
          environment:
            AUTHENTIK_HOST: https://auth.lsck0.dev
            AUTHENTIK_INSECURE: "false"
          env_file:
            - ${config.sops.templates."authentik.env".path}
          user: root
          volumes:
            - /var/run/docker.sock:/var/run/docker.sock
            - /var/lib/authentik/media:/media
            - /var/lib/authentik/certs:/certs
            - /var/lib/authentik/custom-templates:/templates
            - /var/lib/authentik/blueprints:/blueprints/custom
          depends_on:
            - postgresql
            - redis
    '';
  };

  sops.templates."blueprint-secrets.env".content = ''
    NEXTCLOUD_OIDC_SECRET=${config.sops.placeholder.nextcloud-oidc-secret}
    VAULTWARDEN_OIDC_SECRET=${config.sops.placeholder.vaultwarden-oidc-secret}
    FORGEJO_OIDC_SECRET=${config.sops.placeholder.forgejo-oidc-secret}
  '';

  systemd.services.authentik-blueprint-sync = {
    description = "Sync authentik blueprints from Nix store";
    before = [ "docker-stack-authentik.service" ];
    requiredBy = [ "docker-stack-authentik.service" ];
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      # triggers NFS automount by accessing the path
      ${pkgs.coreutils}/bin/mkdir -p /var/lib/authentik/blueprints

      # Inject OIDC secrets into blueprint at deploy time
      . ${config.sops.templates."blueprint-secrets.env".path}
      ${pkgs.gnused}/bin/sed \
        -e "s|__NEXTCLOUD_OIDC_SECRET__|$NEXTCLOUD_OIDC_SECRET|g" \
        -e "s|__VAULTWARDEN_OIDC_SECRET__|$VAULTWARDEN_OIDC_SECRET|g" \
        -e "s|__FORGEJO_OIDC_SECRET__|$FORGEJO_OIDC_SECRET|g" \
        ${blueprintFile} > /var/lib/authentik/blueprints/homelab-apps.yaml
      chmod 644 /var/lib/authentik/blueprints/homelab-apps.yaml
    '';
  };

  # Generate API token for Homepage widget
  systemd.services.authentik-homepage-token = {
    description = "Generate Authentik API token for Homepage";
    after = [ "docker-stack-authentik.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.docker-compose pkgs.docker pkgs.gnugrep pkgs.gawk ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      TOKEN_FILE="/var/lib/homepage-tokens/authentik-key.token"
      [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ] && exit 0
      # Wait for Authentik to be ready
      for i in $(seq 1 120); do
        docker exec authentik-server-1 ak healthcheck >/dev/null 2>&1 && break
        sleep 2
      done
      sleep 10
      # Create API token via Django ORM
      TOKEN=$(docker exec authentik-server-1 ak shell -c "
      from authentik.core.models import User, Token, TokenIntents
      user = User.objects.get(username='akadmin')
      token, created = Token.objects.get_or_create(
          identifier='homepage-api',
          defaults={'user': user, 'intent': TokenIntents.INTENT_API, 'expiring': False}
      )
      print(token.key)
      " 2>/dev/null | tail -1)
      if [ -n "$TOKEN" ]; then
        echo -n "$TOKEN" > "$TOKEN_FILE"
        echo "Authentik Homepage token created"
      fi
    '';
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/authentik/db 0750 70 70 -"
    "d /var/lib/authentik/redis 0750 999 999 -"
    "d /var/lib/authentik/media 0750 1000 1000 -"
    "d /var/lib/authentik/custom-templates 0750 1000 1000 -"
    "d /var/lib/authentik/certs 0750 1000 1000 -"
    "d /var/lib/authentik/blueprints 0755 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
