{ config, pkgs, lib, ... }:
let
  # All services protected by authentik ForwardAuth.
  protectedApps = [
    { slug = "uptime-kuma";    name = "Uptime Kuma";      local = "status.internal.home";     external = "status.lsck0.dev"; }
    { slug = "forgejo";        name = "Forgejo";          local = "git.internal.home";        external = "git.lsck0.dev"; }
    { slug = "registry";       name = "Registry";         local = "registry.internal.home";   external = "registry.lsck0.dev"; }
    { slug = "homepage";       name = "Homepage";         local = "homepage.internal.home";       external = "homepage.lsck0.dev"; }
    { slug = "vaultwarden";    name = "Vaultwarden";      local = "vault.internal.home";      external = "vault.lsck0.dev"; }
    # Nextcloud uses native OIDC, not ForwardAuth — see oidcEntries below
    { slug = "paperless";      name = "Paperless";        local = "paperless.internal.home";  external = "paperless.lsck0.dev"; }
    { slug = "jellyfin";       name = "Jellyfin";         local = "jellyfin.internal.home";   external = "jellyfin.lsck0.dev"; }
    { slug = "huginn";         name = "Huginn";           local = "huginn.internal.home";     external = "huginn.lsck0.dev"; }
    { slug = "homeassistant";  name = "Home Assistant";   local = "hass.internal.home";       external = "hass.lsck0.dev"; }
    { slug = "grafana";        name = "Grafana";          local = "grafana.internal.home";    external = "grafana.lsck0.dev"; }
    { slug = "wikijs";         name = "Wiki.js";          local = "wiki.internal.home";       external = "wiki.lsck0.dev"; }
    { slug = "audiobookshelf"; name = "Audiobookshelf";   local = "abs.internal.home";        external = "abs.lsck0.dev"; }
    { slug = "qbittorrent";    name = "qBittorrent";      local = "torrent.internal.home";    external = "torrent.lsck0.dev"; }
    { slug = "prowlarr";       name = "Prowlarr";         local = "prowlarr.internal.home";   external = "prowlarr.lsck0.dev"; }
    { slug = "sonarr";         name = "Sonarr";           local = "sonarr.internal.home";     external = "sonarr.lsck0.dev"; }
    { slug = "radarr";         name = "Radarr";           local = "radarr.internal.home";      external = "radarr.lsck0.dev"; }
    { slug = "navidrome";      name = "Navidrome";        local = "music.internal.home";       external = "music.lsck0.dev"; }
    { slug = "kavita";         name = "Kavita";           local = "read.internal.home";        external = "read.lsck0.dev"; }
  ];

  mkProviderAndApp = variant: app:
    let
      host = if variant == "local" then app.local else app.external;
      suffix = variant;
    in ''
      - model: authentik_providers_proxy.proxyprovider
        id: provider-${app.slug}-${suffix}
        identifiers:
          name: ${app.slug}-${suffix}-provider
        attrs:
          authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
          mode: forward_single
          external_host: https://${host}
      - model: authentik_core.application
        id: app-${app.slug}-${suffix}
        identifiers:
          slug: ${app.slug}-${suffix}
        attrs:
          name: "${app.name} (${suffix})"
          provider: !KeyOf provider-${app.slug}-${suffix}
          meta_launch_url: https://${host}
    '';

  appEntries = builtins.concatStringsSep "" (
    builtins.concatMap (app: [
      (mkProviderAndApp "local" app)
      (mkProviderAndApp "external" app)
    ]) protectedApps
  );

  outpostProvidersList = builtins.concatStringsSep "\n" (
    builtins.concatMap (app: [
      "    - !KeyOf provider-${app.slug}-local"
      "    - !KeyOf provider-${app.slug}-external"
    ]) protectedApps
  );

  # Nextcloud OIDC provider — uses OAuth2 instead of ForwardAuth
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
        client_secret: nextcloud-oidc-secret-changeme
        signing_key: !Find [authentik_crypto.certificatekeypair, [name, authentik Self-signed Certificate]]
        redirect_uris: |
          https://cloud.internal.home/apps/user_oidc/code
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
        meta_launch_url: https://cloud.internal.home

    # --- Forgejo OIDC ---
    - model: authentik_providers_oauth2.oauth2provider
      id: provider-forgejo-oidc
      identifiers:
        name: forgejo-oidc-provider
      attrs:
        authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
        client_type: confidential
        client_id: forgejo
        client_secret: forgejo-oidc-secret-changeme
        signing_key: !Find [authentik_crypto.certificatekeypair, [name, authentik Self-signed Certificate]]
        redirect_uris: |
          https://git.internal.home/user/oauth2/authentik/callback
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
        meta_launch_url: https://git.internal.home
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
          authentik_host: https://auth.internal.home
          authentik_host_insecure: true
        providers:
    ${outpostProvidersList}
  '';

  blueprintFile = pkgs.writeText "homelab-apps-blueprint.yaml" blueprintYaml;
in {
  networking.hostName = "vm-101";

  sops.secrets.authentik-secret-key = {};
  sops.templates."authentik.env".content = ''
    AUTHENTIK_SECRET_KEY=${config.sops.placeholder.authentik-secret-key}
    AUTHENTIK_ERROR_REPORTING__ENABLED=true
    AUTHENTIK_REDIS__HOST=redis
    AUTHENTIK_POSTGRESQL__HOST=postgresql
    AUTHENTIK_POSTGRESQL__USER=authentik
    AUTHENTIK_POSTGRESQL__NAME=authentik
    AUTHENTIK_POSTGRESQL__PASSWORD=authentik
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
          environment:
            POSTGRES_PASSWORD: authentik
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
            AUTHENTIK_REDIS__HOST: redis
            AUTHENTIK_POSTGRESQL__HOST: postgresql
            AUTHENTIK_POSTGRESQL__USER: authentik
            AUTHENTIK_POSTGRESQL__NAME: authentik
            AUTHENTIK_POSTGRESQL__PASSWORD: authentik
            AUTHENTIK_HOST: https://auth.internal.home
            AUTHENTIK_INSECURE: "true"
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
            AUTHENTIK_REDIS__HOST: redis
            AUTHENTIK_POSTGRESQL__HOST: postgresql
            AUTHENTIK_POSTGRESQL__USER: authentik
            AUTHENTIK_POSTGRESQL__NAME: authentik
            AUTHENTIK_POSTGRESQL__PASSWORD: authentik
            AUTHENTIK_HOST: https://auth.internal.home
            AUTHENTIK_INSECURE: "true"
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

  # Copy Nix-generated blueprint into the Docker volume before the stack starts
  systemd.services.authentik-blueprint-sync = {
    description = "Sync authentik blueprints from Nix store";
    before = [ "docker-stack-authentik.service" ];
    requiredBy = [ "docker-stack-authentik.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.coreutils}/bin/install -m 644 ${blueprintFile} /var/lib/authentik/blueprints/homelab-apps.yaml";
    };
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
