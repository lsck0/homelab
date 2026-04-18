{ pkgs, ... }:
let
  servicesYaml = pkgs.writeText "services.yaml" ''
    - Infrastructure:
        - Traefik:
            icon: traefik
            href: https://home.internal.local
            description: Reverse Proxy
        - Authentik:
            icon: authentik
            href: https://auth.internal.local
            description: Identity Provider
        - Uptime Kuma:
            icon: uptime-kuma
            href: https://status.internal.local
            description: Status Monitoring
        - Router:
            icon: nixos
            description: NixOS Router & DNS

    - Applications:
        - Nextcloud:
            icon: nextcloud
            href: https://cloud.internal.local
            description: File Sync & Collaboration
        - Forgejo:
            icon: forgejo
            href: https://git.internal.local
            description: Git Forge
        - Vaultwarden:
            icon: vaultwarden
            href: https://vault.internal.local
            description: Password Manager
        - Paperless:
            icon: paperless-ngx
            href: https://paperless.internal.local
            description: Document Management

    - Media & Automation:
        - Jellyfin:
            icon: jellyfin
            href: https://jellyfin.internal.local
            description: Media Server
        - Huginn:
            icon: huginn
            href: https://huginn.internal.local
            description: Task Automation
        - Home Assistant:
            icon: home-assistant
            href: https://hass.internal.local
            description: Home Automation

    - External:
        - Shlink:
            icon: shlink
            href: https://shlink.lsck0.dev
            description: URL Shortener
        - PrivateBin:
            icon: privatebin
            href: https://paste.lsck0.dev
            description: Encrypted Pastebin
        - Share:
            href: https://share.lsck0.dev
            description: File Sharing
        - Minecraft:
            icon: minecraft
            description: Forge 1.20.1
  '';

  settingsYaml = pkgs.writeText "settings.yaml" ''
    title: Homelab
    favicon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/heimdall.png
    headerStyle: clean
    layout:
      Infrastructure:
        style: row
        columns: 4
      Applications:
        style: row
        columns: 4
      Media & Automation:
        style: row
        columns: 3
      External:
        style: row
        columns: 4
  '';

  bookmarksYaml = pkgs.writeText "bookmarks.yaml" "[]";
  widgetsYaml = pkgs.writeText "widgets.yaml" "[]";
in {
  networking.hostName = "vm-108";

  virtualisation.oci-containers.containers.homepage = {
    image = "ghcr.io/gethomepage/homepage:latest";
    ports = [ "80:3000" ];
    volumes = [ "/var/lib/homepage:/app/config" ];
    environment = {
      HOMEPAGE_ALLOWED_HOSTS = "home.internal.local,home.lsck0.dev";
    };
  };

  # Sync Nix-generated config into the volume before the container starts
  systemd.services.homepage-config-sync = {
    description = "Sync Homepage config from Nix store";
    before = [ "docker-homepage.service" ];
    requiredBy = [ "docker-homepage.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "homepage-config-sync" ''
        install -m 644 ${servicesYaml} /var/lib/homepage/services.yaml
        install -m 644 ${settingsYaml} /var/lib/homepage/settings.yaml
        install -m 644 ${bookmarksYaml} /var/lib/homepage/bookmarks.yaml
        install -m 644 ${widgetsYaml} /var/lib/homepage/widgets.yaml
      '';
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/homepage 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
