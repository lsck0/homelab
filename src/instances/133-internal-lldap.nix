{ config, ... }: {
  networking.hostName = "vm-133";

  # Lightweight LDAP directory — one user store other services can share
  # (Authelia, Forgejo, Nextcloud, Grafana, Jellyfin). Runs standalone here;
  # pointing each consumer at it is a follow-up so the working Authelia file
  # backend is not disturbed in the same change.
  #
  # State (sqlite) is on local disk, not NFS: the auth directory must not wedge
  # on a NAS stall (same reasoning as Authelia).
  sops.secrets.lldap-jwt-secret = { owner = "lldap"; group = "lldap"; };
  sops.secrets.lldap-admin-password = { owner = "lldap"; group = "lldap"; };

  users.users.lldap = { isSystemUser = true; group = "lldap"; };
  users.groups.lldap = {};

  services.lldap = {
    enable = true;
    silenceForceUserPassResetWarning = true;
    settings = {
      ldap_base_dn = "dc=lsck0,dc=dev";
      ldap_host = "0.0.0.0";
      ldap_port = 3890;
      http_host = "0.0.0.0";
      http_port = 17170;
      http_url = "https://lldap.lsck0.dev";
      ldap_user_dn = "admin";
      ldap_user_email = "admin@lsck0.dev";
    };
    environment = {
      LLDAP_JWT_SECRET_FILE = config.sops.secrets.lldap-jwt-secret.path;
      LLDAP_LDAP_USER_PASS_FILE = config.sops.secrets.lldap-admin-password.path;
    };
  };

  # 3890 LDAP (LAN only), 17170 web UI (behind Traefik + Authelia).
  networking.firewall.allowedTCPPorts = [ 3890 17170 ];
}
