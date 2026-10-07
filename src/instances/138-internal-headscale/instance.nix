# Tailscale control server (VPN mesh) + Headplane UI; internal, not dmz: it controls mesh membership
{ ... }: {
  vm = {
    bootPhase = "network";
    needs = [ "containers" "nfs" ];
  };

  tokens = [ "headplane-key" ];

  services = {
    headplane = {
      host = "hs-ui";
      port = 3000;
      health = "/admin/healthz";
      loginRedirect = { path = "/"; to = "/admin/"; };
      homepage = { group = "Core"; icon = "headscale"; };
      oidc = {
        callback = "/admin/oidc/callback";
        name = "Headplane";
        pkce = false;
        tokenAuthMethod = "client_secret_post";
      };
    };
    headscale = {
      host = "hs";
      port = 80;
      health = "/health";
      homepage = { group = "Public"; icon = "headscale"; };
      oidc = {
        callback = "/oidc/callback";
        name = "Headscale";
        pkce = true;
        tokenAuthMethod = "client_secret_basic";
      };
      off = {
        guard = "open to the lab until its direct clients are grants";
        sso = "tailscale clients cannot log in to authelia";
        anubis = "tailscale clients run no proof of work";
        waf = "tailscale's control protocol the rules misread";
      };
    };
  };
}
