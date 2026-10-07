# home automation hub
{ ... }: {
  vm = {
    bootPhase = "apps";
    needs = [ "containers" "nfs" ];
    # large python process, squeezed it stalls: 739 MiB peak over 7d, so the floor stays above it
    memoryMiB = 1536;
    balloonMiB = 768;
    # image alone does not fit in 8 GiB
    diskGiB = 16;
  };

  tokens = [ "hass-key" ];

  shares = {
    "data/homeassistant" = { };
  };

  services = {
    homeassistant = {
      host = "hass";
      port = 80;
      loginPaths = [ "/auth/login_flow" ];
      homepage = {
        icon = "home-assistant";
        name = "Home Assistant";
        widget = { tokens = { key = "hass-key"; }; type = "homeassistant"; };
      };
      oidc = {
        callback = "/auth/oidc/callback";
        name = "Home Assistant";
        pkce = false;
        tokenAuthMethod = "client_secret_post";
      };
      off = {
        sso = "the companion app calls /auth/token and /api/websocket natively, it cannot pass a portal";
        anubis = "the companion app runs no proof of work";
        waf = "the companion app's api calls the rules misread";
        bodyLimit = "backup uploads";
      };
    };
  };
}
