import re

with open("src/instances/102-internal-homepage.nix", "r") as f:
    content = f.read()

# Define the new services.yaml content for Internal block
services_yaml = """    - Infra:
        - Cloudflare:
            icon: cloudflare
            href: https://dash.cloudflare.com
        - FritzBox:
            icon: mdi-router-wireless
            href: http://192.168.178.1
            ping: http://192.168.178.1
        - Proxmox:
            icon: proxmox
            href: https://proxmox.internal
            ping: http://192.168.178.200:8006
        - Router:
            icon: nixos
            ping: http://10.100.0.1

    - Internal:
        - Traefik:
            icon: traefik
            href: https://traefik.internal
            ping: http://10.100.0.100
        - Authentik:
            icon: authentik
            href: https://auth.internal
            ping: http://10.100.0.101
        - Grafana:
            icon: grafana
            href: https://grafana.internal
            ping: http://10.100.0.104
        - Status:
            icon: uptime-kuma
            href: https://status.internal
            ping: http://10.100.0.103
        - NAS:
            icon: mdi-nas
            href: https://nas.internal
            ping: http://10.100.0.111
        - sccache:
            icon: mdi-cached
        - Forgejo:
            icon: forgejo
            href: https://git.internal
            ping: http://10.100.0.105
        - Forgejo Runner:
            icon: forgejo
            ping: http://10.100.0.106
        - Tasks:
            icon: mdi-checkbox-marked-outline
            href: https://tasks.internal
            ping: http://10.100.0.109:8080
        - Nextcloud:
            icon: nextcloud
            href: https://cloud.internal
            ping: http://10.100.0.112
        - Vaultwarden:
            icon: vaultwarden
            href: https://vault.internal
            ping: http://10.100.0.110:8080
        - Registry:
            icon: docker-moby
            href: https://registry.internal
            ping: http://10.100.0.108
        - Paperless:
            icon: paperless-ngx
            href: https://paperless.internal
            ping: http://10.100.0.119:8080
        - Wiki.js:
            icon: wikijs
            href: https://wiki.internal
            ping: http://10.100.0.120
        - Home Assistant:
            icon: home-assistant
            href: https://hass.internal
            ping: http://10.100.0.122
        - Huginn:
            icon: huginn
            href: https://huginn.internal
            ping: http://10.100.0.121
        - Jellyfin:
            icon: jellyfin
            href: https://jellyfin.internal
            ping: http://10.100.0.117
        - qBittorrent:
            icon: qbittorrent
            href: https://torrent.internal
            ping: http://10.100.0.113
        - Sonarr:
            icon: sonarr
            href: https://sonarr.internal
            ping: http://10.100.0.115
        - Radarr:
            icon: radarr
            href: https://radarr.internal
            ping: http://10.100.0.116
        - Prowlarr:
            icon: prowlarr
            href: https://prowlarr.internal
            ping: http://10.100.0.114
        - Navidrome:
            icon: navidrome
            href: https://music.internal
            ping: http://10.100.0.123
        - Audiobookshelf:
            icon: audiobookshelf
            href: https://abs.internal
            ping: http://10.100.0.118
        - Kavita:
            icon: kavita
            href: https://read.internal
            ping: http://10.100.0.124

    - External:
        - Ext Traefik:
            icon: traefik
            href: https://traefik.external
            ping: http://10.200.0.200
        - Headscale:
            icon: headscale
            href: https://hs.lsck0.dev
            ping: http://10.200.0.201
        - Shlink:
            icon: shlink
            href: https://shlink.external
            ping: http://10.200.0.202
        - PrivateBin:
            icon: privatebin
            href: https://paste.external
            ping: http://10.200.0.203
        - Share:
            icon: filebrowser
            href: https://share.external
            ping: http://10.200.0.204
        - Minecraft:
            icon: minecraft
            ping: http://10.200.0.205"""

widgets_yaml = """    - greeting:
        text_size: xl
        text: Homelab
    - datetime:
        text_size: l
        format:
          dateStyle: long
          timeStyle: short
          hour12: false
    - openmeteo:
        label: Weather
        latitude: 51.23
        longitude: 6.78
        timezone: Europe/Berlin
        units: metric
    - search:
        provider: google
        target: _blank
    - proxmox:
        url: https://192.168.178.200:8006
        username: {{HOMEPAGE_VAR_PROXMOX_USER}}
        password: {{HOMEPAGE_VAR_PROXMOX_PASS}}
        node: luca-server"""

content = re.sub(r'  servicesYaml = pkgs\.writeText "services\.yaml" \'\'.*?\'\';\n\n  settingsYaml', f"  servicesYaml = pkgs.writeText \"services.yaml\" ''\n{services_yaml}\n  '';\n\n  settingsYaml", content, flags=re.DOTALL)
content = re.sub(r'  widgetsYaml = pkgs\.writeText "widgets\.yaml" \'\'.*?\'\';\n\n  bookmarksYaml', f"  widgetsYaml = pkgs.writeText \"widgets.yaml\" ''\n{widgets_yaml}\n  '';\n\n  bookmarksYaml", content, flags=re.DOTALL)

with open("src/instances/102-internal-homepage.nix", "w") as f:
    f.write(content)
