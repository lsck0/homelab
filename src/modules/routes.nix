# <host>.lsck0.dev -> backend. Used by both Traefiks, by Authelia to build its
# access rules, and by the router for DDNS and split-horizon DNS.
#
#   host    subdomain of lsck0.dev
#   vmid    backend VM (key in instances.tf)
#   port    backend port on that VM
#   scheme  "http" (default) or "https" (self-signed backend, verify skipped)
#
#   auth    how the route is authenticated. Nothing is reachable without one of
#           these; there is no unauthenticated route on the internal side.
#             "sso"    (default) Authelia ForwardAuth on the internal Traefik.
#                      The lldap group in `group` decides who gets in, so a
#                      service is switched on and off per person by editing
#                      group membership in the lldap dashboard.
#             "own"    the app runs its own login, backed by Authelia OIDC or
#                      lldap. No ForwardAuth (it would double-prompt), and the
#                      app is responsible for rejecting anonymous callers.
#             "token"  headless: a client presents an API token or holds an
#                      unguessable URL. Browsers cannot log in here, so these
#                      are not relayed to the internet unless publicRelay.
#             "portal" Authelia itself: must be reachable to log in.
#
#   loginRedirect  { path, to }: the internal Traefik rewrites this exact path
#                  to `to` on the same host. Used to skip an app's own login
#                  screen and drop straight into its Authelia OIDC flow, so a
#                  browser that already holds an Authelia session never sees a
#                  second login. Only for auth = "own" apps that have an OIDC
#                  entry point of their own.
#
#   group   lldap group a user must be in for an auth = "sso" route.
#           "users" = every lab account, "admins" = the owner's accounts.
#
#   proxied whether the Cloudflare A record for this host is orange-clouded.
#           Default true. The rule: a service Authelia stands in front of goes
#           through Cloudflare and gets its DDoS absorption; a service that is
#           public by design and defended by Anubis + the bot labyrinth is
#           DNS-only, because behind the edge Anubis only ever sees a rotating
#           Cloudflare address and re-challenges every single request.
#           Setting this is not enough on its own - 300-router.nix publishes the
#           record from here, so change it and redeploy the router.
#
#   publicRelay  whether the external Traefik relays this internal host in from
#                the internet. Defaults to false for auth = "token" (those have
#                no interactive login) and true otherwise. LAN and the Headscale
#                mesh always reach every internal host via split-horizon DNS.
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
    # nix clients authenticate to attic with their own token, so no browser
    # login is possible; not relayed from the internet.
    attic          = { host = "attic";       vmid = 110; port = 8080;  auth = "token"; };
    qbittorrent    = { host = "torrent";     vmid = 112; port = 80;    group = "media"; };
    # Forgejo signs in through Authelia OIDC; git clients use tokens/SSH.
    forgejo        = { host = "git";         vmid = 115; port = 80;    auth = "own";
                       loginRedirect = { path = "/user/login"; to = "/user/oauth2/authelia"; }; };
    # headless API: docker clients cannot follow a browser login. Not relayed
    # publicly, and the external Traefik denies the host explicitly as well.
    registry-api   = { host = "registry";    vmid = 118; port = 5000;  auth = "token"; };
    registry-ui    = { host = "registry-ui"; vmid = 118; port = 80;    group = "admins"; };
    vaultwarden    = { host = "vault";       vmid = 119; port = 8080;  auth = "own"; };
    nextcloud      = { host = "cloud";       vmid = 120; port = 80;    auth = "own"; };
    # the TRMNL cloud polls this and cannot log in. The feed URLs carry an
    # unguessable token instead, so this one token route stays public.
    # cal.lsck0.dev is kept as an alias for terminal.lsck0.dev: the feeds moved
    # to vm-104 with the rest of the dashboards, and an old polling URL or a
    # bookmarked upload endpoint should not break because of that.
    calendar       = { host = "cal";         vmid = 104; port = 8081; auth = "token"; publicRelay = true; proxied = false; };
    # the e-ink terminal's data feeds. Same deal as the calendar: the TRMNL
    # cloud polls them and cannot log in, so the unguessable path is the only
    # thing in front. It lives on vm-104 because Prometheus is local there and
    # the collector would otherwise need the metrics port opened up for it.
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
    # Jellyfin authenticates against lldap (LDAP plugin), Audiobookshelf and
    # Kavita through Authelia OIDC: same account as everything else, and their
    # own apps can still log in, which ForwardAuth would break.
    jellyfin       = { host = "jellyfin";    vmid = 134; port = 80;    auth = "own";
                       loginRedirect = { path = "/"; to = "/sso/OID/start/authelia"; }; };
    navidrome      = { host = "music";       vmid = 136; port = 80;    group = "media"; };
    lidarr         = { host = "lidarr";      vmid = 136; port = 8686;  group = "admins"; };
    # A tailscale client cannot log in to Authelia, so no ForwardAuth here;
    # Headscale authenticates registrations itself with pre-auth keys and its
    # own browser flow. Relayed in from the internet like any internal host.
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
    # no image exists yet: example/.github/workflows/hello.yml is a template to
    # copy into an app repo, not an active workflow here, so nothing has ever
    # pushed ghcr.io/lsck0/hello and the swarm task stays "Rejected: No such
    # image". Kept as the wiring for a GitHub-built app, but not monitored -
    # an uptime check on it is a permanent false alarm.
    hello-gh   = { host = "hello-gh"; vmid = 209; port = 8080; proxied = false; };
  };
}
