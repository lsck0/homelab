# Tailscale control server (VPN mesh) + Headplane UI; internal, not dmz: it controls mesh membership
{
  lib,
  id,
  config,
  profiles,
  ...
}:
{
  vm = {
    # parked so atm gets its 8 GiB unballooned; "on" brings it back
    power = "off";
    bootPhase = "network";
    needs = [
      "containers"
      "nfs"
    ];
  };

  grants = [
    {
      from = [
        "lan"
        "wireguard"
      ];
      tcp = [ config.services.headscale.port ];
      why = "its direct tailscale clients: the house and the owner's devices; no lab guest runs tailscale";
    }
  ];

  tokens = [ "headplane-key" ];

  services = {
    headplane = {
      host = "hs-ui";
      port = 3000;
      health = "/admin/healthz";
      loginRedirect = {
        path = "/";
        to = "/admin/";
      };
      homepage = {
        group = "Core";
        icon = "headscale";
      };
      oidc = {
        callback = "/admin/oidc/callback";
        name = "Headplane";
        pkce = false;
        tokenAuthMethod = "client_secret_post";
      };
      on = profiles.hardenedInternal ++ profiles.listed ++ profiles.observed;
    };
    headscale = {
      host = "hs";
      port = 80;
      health = "/health";
      homepage = {
        group = "Public";
        icon = "headscale";
      };
      oidc = {
        callback = "/oidc/callback";
        name = "Headscale";
        pkce = true;
        tokenAuthMethod = "client_secret_basic";
      };
      # tailscale clients log in to no portal, solve no captcha, and speak a control protocol the waf rules misread
      on = lib.subtractLists [ "sso" "captcha" "waf" ] profiles.hardenedInternal ++ profiles.listed ++ profiles.observed;
    };
  };

  shares = {
    "data/db-dumps/vm-${id}" = {
      mode = "0700";
    };
    "data/headscale".localState = true;
  };
}
