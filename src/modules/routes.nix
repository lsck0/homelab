# <host>.lsck0.dev -> backend. Used by both Traefiks and by the router for
# DDNS and split-horizon DNS.
#
#   host    subdomain of lsck0.dev
#   vmid    backend VM (key in instances.tf)
#   port    backend port on that VM
#   sso     Authelia ForwardAuth in front (internal only, default true)
#   scheme  "http" (default) or "https" (self-signed backend, verify skipped)
{
  internal = {
    authelia       = { host = "auth";        vmid = 101; port = 9091;  sso = false; };
    lldap          = { host = "lldap";       vmid = 102; port = 17170; };
    homepage       = { host = "homepage";    vmid = 103; port = 80; };
    grafana        = { host = "grafana";     vmid = 104; port = 80; };
    uptime-kuma    = { host = "status";      vmid = 105; port = 80; };
    kopia          = { host = "backup";      vmid = 106; port = 51515; };
    wazuh          = { host = "wazuh";       vmid = 107; port = 443; scheme = "https"; };
    nas            = { host = "nas";         vmid = 108; port = 80; };
    syncthing      = { host = "sync";        vmid = 108; port = 8384; };
    # no SSO: nix clients authenticate to attic with their own token.
    attic          = { host = "attic";       vmid = 109; port = 8080;  sso = false; };
    qbittorrent    = { host = "torrent";     vmid = 111; port = 80; };
    # Forgejo is SSO-only through its own OIDC login; git clients use tokens/SSH.
    forgejo        = { host = "git";         vmid = 114; port = 80;    sso = false; };
    # headless API: docker clients cannot follow a browser login. The external
    # Traefik blocks this host from the internet.
    registry-api   = { host = "registry";    vmid = 116; port = 5000;  sso = false; };
    registry-ui    = { host = "registry-ui"; vmid = 116; port = 80; };
    vaultwarden    = { host = "vault";       vmid = 117; port = 8080;  sso = false; };
    nextcloud      = { host = "cloud";       vmid = 118; port = 80;    sso = false; };
    # no SSO: the TRMNL cloud polls this and cannot log in. The feed URLs
    # carry an unguessable token instead.
    calendar       = { host = "cal";         vmid = 119; port = 80;    sso = false; };
    paperless      = { host = "paperless";   vmid = 120; port = 8080; };
    paperless-ai   = { host = "paperless-ai"; vmid = 121; port = 80; };
    wikijs         = { host = "wiki";        vmid = 122; port = 80; };
    firefly        = { host = "firefly";     vmid = 123; port = 8080; };
    homeassistant  = { host = "hass";        vmid = 124; port = 80; };
    huginn         = { host = "huginn";      vmid = 125; port = 80; };
    jellyseerr     = { host = "requests";    vmid = 127; port = 80; };
    prowlarr       = { host = "prowlarr";    vmid = 128; port = 80; };
    radarr         = { host = "radarr";      vmid = 129; port = 80; };
    sonarr         = { host = "sonarr";      vmid = 130; port = 80; };
    bazarr         = { host = "subs";        vmid = 131; port = 80; };
    jellyfin       = { host = "jellyfin";    vmid = 133; port = 80; };
    audiobookshelf = { host = "abs";         vmid = 134; port = 80; };
    bookshelf      = { host = "books";       vmid = 134; port = 8787; };
    navidrome      = { host = "music";       vmid = 135; port = 80; };
    lidarr         = { host = "lidarr";      vmid = 135; port = 8686; };
    kavita         = { host = "read";        vmid = 136; port = 80; };
    suwayomi       = { host = "manga";       vmid = 136; port = 4567; };
  };

  external = {
    headscale  = { host = "hs";       vmid = 201; port = 80; };
    searxng    = { host = "search";   vmid = 204; port = 80; };
    shlink     = { host = "shlink";   vmid = 205; port = 80; };
    privatebin = { host = "paste";    vmid = 206; port = 80; };
    share      = { host = "share";    vmid = 207; port = 80; };
    ntfy       = { host = "ntfy";     vmid = 203; port = 80; };
    # CI/CD targets on the swarm host: hello <- Forgejo, hello-gh <- GitHub.
    hello      = { host = "hello";    vmid = 209; port = 80; };
    hello-gh   = { host = "hello-gh"; vmid = 209; port = 8080; };
  };
}
