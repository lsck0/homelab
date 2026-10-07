# SSO: authelia (OIDC + ForwardAuth) and lldap, its identity store
{ ... }: {
  vm = {
    bootPhase = "network";
    needs = [ "nfs" ];
    memoryMiB = 1024;
  };

  services = {
    authelia = {
      host = "auth";
      port = 9091;
      loginPaths = [ "/api/firstfactor" "/api/secondfactor" ];
      homepage = { group = "Core"; icon = "authelia"; };
      off = { sso = "authelia is the portal itself"; anubis = "the login portal; authelia regulates logins itself"; };
    };
    lldap = { port = 17170; homepage = { group = "Core"; icon = "mdi-account-group"; name = "LLDAP"; }; };
  };

  secrets = {
    authelia-admin-pass = "hex:24";
    authelia-jwt-secret = "hex:32";
    authelia-oidc-hmac = "hex:32";
    authelia-oidc-issuer-key = "manual"; # openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096
    authelia-session-secret = "hex:32";
    authelia-storage-key = "hex:32";
    lldap-admin-password = "hex:24";
    lldap-authelia-bind-password = "hex:24"; # lldap user authelia-bind, read-only (lldap_strict_readonly)
    lldap-guest-password = "hex:24";
    lldap-jwt-secret = "hex:24";
    lldap-proxmox-bind-password = "hex:24"; # lldap user proxmox-bind, read-only: the proxmox realm sync (init.sh)
    lldap-server-key = "manual"; # base64 of lldap's server key
  };
}
