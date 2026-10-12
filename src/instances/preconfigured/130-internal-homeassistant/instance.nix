# home automation hub
{ lib, config, profiles, ... }: {
  vm = {
    # parked while unused; "on" brings it back
    power = "off";
    bootPhase = "apps";
    needs = [ "containers" "nfs" ];
    # large python process, squeezed it stalls: 739 MiB peak over 7d, so the floor stays above it
    memoryMiB = 1536;
    balloonMiB = 768;
    # image alone does not fit in 8 GiB
    diskGiB = 16;
  };

  tokens = [ "hass-key" ];

  grants = [
    { from = [ "collector" ]; tcp = [ config.services.homeassistant.port ]; why = "prometheus scrapes /api/prometheus for the hand-typed gas and water readings"; }
  ];

  shares = {
    "data/homeassistant".localState = true;
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
      # the companion app calls /auth/token and /api/websocket natively, past no portal or captcha, with api calls the
      # waf rules misread; backup uploads
      on = lib.subtractLists [ "sso" "captcha" "waf" "bodyLimit" ] profiles.hardenedInternal ++ profiles.listed ++ profiles.observed;
    };
  };
}
