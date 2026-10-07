# SSO: authelia (OIDC + ForwardAuth) and lldap, its identity store
{ id, net, ... }: {
  vm = {
    bootPhase = "network";
    needs = [ "nfs" ];
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

  alerts.sso_bruteforce = {
    title = "Failed SSO logins";
    category = "attack";
    datasource = "loki";
    rangeSeconds = 900;
    # one failed login a week is normal; authelia's own host, not whatever host a journal claims
    expr = "sum(count_over_time({host=\"vm-${id}\", unit=\"authelia-main.service\"} |= \"Unsuccessful 1FA\" [15m]))";
    threshold = 4;
    for = "0m";
    telegram = true;
    summary = "{{ $values.A.Value }} failed SSO logins in 15 minutes";
    description = "Authelia rejected these passwords; it bans the client address after 3 tries in 2 minutes.";
  };

  grants = [ { from = [ "proxmox" ]; tcp = [ net.ports.ldaps ]; why = "the proxmox realm's logins and sync, over ldaps (scripts/pve-install.sh)"; } ];

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
    lldap-proxmox-bind-password = "hex:24"; # lldap user proxmox-bind, read-only: the proxmox realm (scripts/pve-install.sh)
    lldap-server-key = "manual"; # base64 of lldap's server key
  };

  shares = {
    "data/db-dumps/vm-${id}" = { mode = "0700"; };
  };
}
