# <host>.lsck0.dev -> backend.
{
  internal = {
    authelia       = { host = "auth";        vmid = 101; port = 9091;  auth = "portal"; };
    # the directory itself: only the owner may edit accounts and groups.
    lldap          = { host = "lldap";       vmid = 102; port = 17170; group = "admins"; };
    homepage       = { host = "homepage";    vmid = 103; port = 80; };
    grafana        = { host = "grafana";     vmid = 105; port = 80;    group = "admins"; };
    kopia          = { host = "backup";      vmid = 107; port = 51515; group = "admins"; };
    nas            = { host = "nas";         vmid = 109; port = 80;    group = "admins"; };
    syncthing      = { host = "sync";        vmid = 109; port = 8384;  group = "admins"; };
    # nix clients authenticate to attic with their own token
    attic          = { host = "attic";       vmid = 110; port = 8080;  auth = "token"; };
    qbittorrent    = { host = "torrent";     vmid = 112; port = 80;    group = "media"; };
    # Forgejo signs in through Authelia OIDC; git clients use tokens/SSH.
    forgejo        = { host = "git";         vmid = 115; port = 80;    auth = "own";
                       loginRedirect = { path = "/user/login"; to = "/user/oauth2/authelia"; }; };
    # headless API: docker clients cannot follow a browser login.
    registry-api   = { host = "registry";    vmid = 118; port = 5000;  auth = "token"; };
    registry-ui    = { host = "registry-ui"; vmid = 118; port = 80;    group = "admins"; };
    # the TRMNL cloud polls this and cannot log
    calendar       = { host = "cal";         vmid = 104; port = 8081; auth = "token"; publicRelay = true; proxied = false; };
    # the e-ink terminal's data feeds.
    terminal       = { host = "terminal";    vmid = 104; port = 8081; auth = "token"; publicRelay = true; proxied = false; };
    paperless      = { host = "paperless";   vmid = 121; port = 8080; };
    paperless-ai   = { host = "paperless-ai"; vmid = 122; port = 80;   group = "admins"; };
    firefly        = { host = "firefly";     vmid = 124; port = 8080;  group = "admins"; };
    homeassistant  = { host = "hass";        vmid = 125; port = 80; };
    huginn         = { host = "huginn";      vmid = 126; port = 80;    group = "admins"; };
    jellyseerr     = { host = "requests";    vmid = 128; port = 80;    group = "media"; };
    prowlarr       = { host = "prowlarr";    vmid = 129; port = 80;    group = "admins"; };
    radarr         = { host = "radarr";      vmid = 130; port = 80;    group = "admins"; };
    sonarr         = { host = "sonarr";      vmid = 131; port = 80;    group = "admins"; };
    bazarr         = { host = "subs";        vmid = 132; port = 80;    group = "admins"; };
    # Jellyfin authenticates against lldap (LDAP plugin)
    jellyfin       = { host = "jellyfin";    vmid = 134; port = 80;    auth = "own";
                       loginRedirect = { path = "/"; to = "/sso/OID/start/authelia"; }; };
    navidrome      = { host = "music";       vmid = 136; port = 80;    group = "media"; };
    lidarr         = { host = "lidarr";      vmid = 136; port = 8686;  group = "admins"; };
    # A tailscale client cannot log in to Authelia, so no ForwardAuth here; Headscale
    headscale      = { host = "hs";          vmid = 138; port = 80;    auth = "own"; };
    headplane      = { host = "hs-ui";       vmid = 138; port = 3000;  group = "admins"; };
  };

  external = {
    searxng    = { host = "search";   vmid = 204; port = 80; proxied = false; };
    shlink     = { host = "shlink";   vmid = 205; port = 80; proxied = false; };
    privatebin = { host = "paste";    vmid = 206; port = 80; proxied = false; };
    share      = { host = "share";    vmid = 207; port = 80; proxied = false; };
    ntfy       = { host = "ntfy";     vmid = 203; port = 80; };
    # CI/CD targets on the swarm host: hello <- Forgejo, hello-gh <- GitHub.
    hello      = { host = "hello";    vmid = 209; port = 80; proxied = false; };
    # no image exists yet: example/.github/workflows/hello.yml is a template to copy
    hello-gh   = { host = "hello-gh"; vmid = 209; port = 8080; proxied = false; monitor = false; };
  };
}
