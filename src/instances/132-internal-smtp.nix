{ config, lib, pkgs, ... }:
let
  # Set to your provider's submission host, then fill smtp-relay-user /
  # smtp-relay-pass in sops and enable this VM (main.tf). Until then it is a
  # scaffold: nothing points at it and it is not deployed.
  relayHost = "smtp.example.com";
  relayPort = 587;
  fromDomain = "lsck0.dev";
in {
  networking.hostName = "vm-132";

  # Null-client SMTP relay. Internal services (Authelia 2FA, Vaultwarden,
  # Paperless, Forgejo, Nextcloud) send to 10.100.0.132:25; postfix relays to
  # the upstream provider with SASL auth over TLS. One place holds the creds.
  sops.secrets.smtp-relay-user = {};
  sops.secrets.smtp-relay-pass = {};
  sops.templates."sasl_passwd".content =
    "[${relayHost}]:${toString relayPort} ${config.sops.placeholder.smtp-relay-user}:${config.sops.placeholder.smtp-relay-pass}";

  services.postfix = {
    enable = true;
    # NixOS 25.11 moved these under settings.main.
    settings.main = {
      myhostname = "mail.${fromDomain}";
      relayhost = [ "[${relayHost}]:${toString relayPort}" ];
      inet_interfaces = "all";
      inet_protocols = "ipv4";
      # Only the internal LAN may submit mail.
      mynetworks = [ "127.0.0.0/8" "10.100.0.0/24" ];
      smtp_sasl_auth_enable = "yes";
      smtp_sasl_password_maps = "lmdb:/var/lib/postfix/conf/sasl_passwd";
      smtp_sasl_security_options = "noanonymous";
      smtp_tls_security_level = "encrypt";
    };
    # postfix compiles this to its lmdb form via postmap on start.
    mapFiles."sasl_passwd" = config.sops.templates."sasl_passwd".path;
  };

  networking.firewall.allowedTCPPorts = [ 25 ];
}
