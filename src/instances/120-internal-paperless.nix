{ config, nasMount, nasPath, ... }: {
  networking.hostName = "vm-120";

  fileSystems = nasMount "/var/lib/paperless" "paperless"
    // nasPath "/var/lib/paperless/consume" "documents"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  services.paperless = {
    enable = true;
    address = "0.0.0.0";
    port = 8080;
    settings = {
      # Authelia ForwardAuth gates access and passes the user in Remote-User
      PAPERLESS_ENABLE_HTTP_REMOTE_USER = "true";
      PAPERLESS_HTTP_REMOTE_USER_HEADER_NAME = "HTTP_REMOTE_USER";
      PAPERLESS_URL = "https://paperless.lsck0.dev";
      PAPERLESS_CSRF_TRUSTED_ORIGINS = "https://paperless.lsck0.dev";
      PAPERLESS_TIME_ZONE = "Europe/Berlin";
      PAPERLESS_OCR_LANGUAGE = "deu+eng";
      PAPERLESS_CONSUMER_POLLING = "30";
    };
  };

  # the owner's account (the lldap user Authelia passes in Remote-User, see
  # 102-internal-lldap.nix) as superuser, and the API token Homepage, Hermes
  # and paperless-ai use. Remote-user logins create plain users, so the
  # account is created here first. Idempotent.
  systemd.services.paperless-setup = {
    description = "Create the Paperless owner account and API token";
    after = [ "paperless-web.service" ];
    wants = [ "paperless-web.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; Restart = "on-failure"; RestartSec = 30; };
    script = ''
      TOKEN=$(${config.services.paperless.manage} shell -c "
      from django.contrib.auth.models import User
      from rest_framework.authtoken.models import Token
      owner, _ = User.objects.get_or_create(username='luca')
      owner.is_staff = owner.is_superuser = True
      owner.save()
      bot, _ = User.objects.get_or_create(username='homepage-bot', defaults={'email': 'homepage@internal'})
      bot.is_staff = bot.is_superuser = True
      bot.save()
      print(Token.objects.get_or_create(user=bot)[0].key)
      " | tail -1)
      [ -n "$TOKEN" ] || { echo "no API token from paperless-manage"; exit 1; }
      echo -n "$TOKEN" > /var/lib/homepage-tokens/paperless-key.token
    '';
  };

  networking.firewall.allowedTCPPorts = [ 8080 ];
}
