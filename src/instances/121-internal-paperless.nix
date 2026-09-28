{ config, nasMount, nasPath, ... }: {
  networking.hostName = "vm-121";

  fileSystems = nasMount "/var/lib/paperless" "paperless"
    // nasPath "/var/lib/paperless/consume" "documents"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  services.paperless = {
    enable = true;
    address = "0.0.0.0";
    port = 8080;
    settings = {
      # authelia passes the user in Remote-User
      PAPERLESS_ENABLE_HTTP_REMOTE_USER = "true";
      PAPERLESS_HTTP_REMOTE_USER_HEADER_NAME = "HTTP_REMOTE_USER";
      PAPERLESS_URL = "https://paperless.lsck0.dev";
      PAPERLESS_CSRF_TRUSTED_ORIGINS = "https://paperless.lsck0.dev";
      PAPERLESS_TIME_ZONE = "Europe/Berlin";
      PAPERLESS_OCR_LANGUAGE = "deu+eng";
      # phone photos: no real dpi, often rotated and skewed
      PAPERLESS_OCR_IMAGE_DPI = 300;
      PAPERLESS_OCR_ROTATE_PAGES = true;
      # photos score ~6, default 12 never rotates them
      PAPERLESS_OCR_ROTATE_PAGES_THRESHOLD = 5;
      PAPERLESS_OCR_DESKEW = true;
      PAPERLESS_OCR_CLEAN = "clean";
      PAPERLESS_FILENAME_FORMAT = "{{ created_year }}/{{ correspondent }}/{{ created }} {{ title }}";
      PAPERLESS_CONSUMER_POLLING = "30";
    };
  };

  # the owner's account
  systemd.services.paperless-setup = {
    description = "Create the Paperless owner account and API token";
    after = [ "paperless-web.service" ];
    wants = [ "paperless-web.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; Restart = "on-failure"; RestartSec = 30; };
    script = ''
      TOKEN=$(${config.services.paperless.manage}/bin/paperless-manage shell -c "
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

  # documents are plain files, snapshots cover them
  homelab.dbBackup.databases.paperless.sqlite = "/var/lib/paperless/db.sqlite3";

  networking.firewall.allowedTCPPorts = [ 8080 ];

  # paperless trusts Remote-User, so ingress only
  homelab.ingressOnly = {
    ports = [ 8080 ];
    extraSources = [ "10.100.0.122/32" ];
  };
}
