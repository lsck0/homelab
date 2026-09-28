# <host>.lsck0.dev -> backend
{
  internal = {
    authelia       = { host = "auth";        vmid = 101; port = 9091;  auth = "portal"; };
    # only admins edit accounts
    lldap          = { host = "lldap";       vmid = 101; port = 17170; };
    homepage       = { host = "homepage";    vmid = 103; port = 80; };
    grafana        = { host = "grafana";     vmid = 105; port = 80; };
    kopia          = { host = "backup";      vmid = 109; port = 51515; };
    nas            = { host = "nas";         vmid = 109; port = 80; };
    syncthing      = { host = "sync";        vmid = 109; port = 8384; };
    # nix clients use attic tokens
    attic          = { host = "attic";       vmid = 110; port = 8080;  auth = "token"; };
    qbittorrent    = { host = "torrent";     vmid = 112; port = 80; };
    # authelia oidc; git clients use tokens/ssh
    forgejo        = { host = "git";         vmid = 115; port = 80;    auth = "own";
                       loginRedirect = { path = "/user/login"; to = "/user/oauth2/authelia"; }; };
    # docker clients cannot follow a browser login
    registry-api   = { host = "registry";    vmid = 118; port = 5000;  auth = "token"; };
    registry-ui    = { host = "registry-ui"; vmid = 118; port = 80; };
    # the trmnl cloud polls this, cannot log in
    calendar       = { host = "cal";         vmid = 104; port = 8081; auth = "token"; publicRelay = true; proxied = false; };
    # e-ink terminal data feeds
    terminal       = { host = "terminal";    vmid = 104; port = 8081; auth = "token"; publicRelay = true; proxied = false; };
    paperless      = { host = "paperless";   vmid = 121; port = 8080; };
    paperless-ai   = { host = "paperless-ai"; vmid = 121; port = 80; };
    firefly        = { host = "firefly";     vmid = 124; port = 8080; };
    homeassistant  = { host = "hass";        vmid = 125; port = 80; };
    huginn         = { host = "huginn";      vmid = 126; port = 80; };
    jellyseerr     = { host = "requests";    vmid = 128; port = 80; };
    prowlarr       = { host = "prowlarr";    vmid = 130; port = 9696; };
    radarr         = { host = "radarr";      vmid = 130; port = 7878; };
    sonarr         = { host = "sonarr";      vmid = 130; port = 8989; };
    bazarr         = { host = "bazarr";      vmid = 130; port = 6767; };
    # authenticates via lldap plugin
    jellyfin       = { host = "jellyfin";    vmid = 134; port = 80;    auth = "own";
                       loginRedirect = { path = "/"; to = "/sso/OID/start/authelia"; }; };
    navidrome      = { host = "music";       vmid = 136; port = 80; };
    lidarr         = { host = "lidarr";      vmid = 130; port = 8686; };
    # tailscale clients cannot log in to authelia
    headscale      = { host = "hs";          vmid = 138; port = 80;    auth = "own"; health = "/health"; };
    headplane      = { host = "hs-ui";       vmid = 138; port = 3000; health = "/admin/healthz";
                       loginRedirect = { path = "/"; to = "/admin/"; }; };
  };

  external = {
    searxng    = { host = "search";   vmid = 204; port = 80; proxied = false; };
    privatebin = { host = "paste";    vmid = 206; port = 80; proxied = false; };
    share      = { host = "share";    vmid = 207; port = 80; proxied = false; };
    ntfy       = { host = "ntfy";     vmid = 203; port = 80; };
    # ci targets: hello <- forgejo, hello-gh <- github
    hello      = { host = "hello";    vmid = 209; port = 80; proxied = false; };
    hello-gh   = { host = "hello-gh"; vmid = 209; port = 8080; proxied = false; };
  };
}
