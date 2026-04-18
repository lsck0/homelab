{ pkgs, nasMount, nasPath, ... }: {
  networking.hostName = "vm-119";

  fileSystems = nasMount "/var/lib/paperless" "paperless"
    // nasPath "/var/lib/paperless/consume" "documents";

  services.paperless = {
    enable = true;
    address = "0.0.0.0";
    port = 8080;
    settings = {
      PAPERLESS_ENABLE_HTTP_REMOTE_USER = "true";
      PAPERLESS_HTTP_REMOTE_USER_HEADER_NAME = "HTTP_X_AUTHENTIK_USERNAME";
      PAPERLESS_URL = "https://paperless.internal";
      PAPERLESS_CSRF_TRUSTED_ORIGINS = "https://paperless.internal,https://paperless.lsck0.dev";
      PAPERLESS_TIME_ZONE = "Europe/Berlin";
      PAPERLESS_OCR_LANGUAGE = "deu+eng";
      PAPERLESS_CONSUMER_POLLING = "30";
    };
  };

  # Promote remote-users to superuser (retries until users exist)
  systemd.services.paperless-promote-admin = {
    description = "Promote Paperless users to superuser";
    after = [ "paperless-web.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.paperless-ngx ];
    serviceConfig = {
      Type = "oneshot";
      User = "paperless";
      Group = "paperless";
      WorkingDirectory = "/var/lib/paperless";
      Restart = "on-failure";
      RestartSec = 30;
    };
    environment = {
      PAPERLESS_URL = "https://paperless.internal";
    };
    script = ''
      # Wait for web service to be ready
      sleep 10
      PROMOTED=$(paperless-ngx shell -c "
      from django.contrib.auth.models import User
      users = User.objects.filter(is_superuser=False)
      count = 0
      for u in users:
          u.is_staff = True
          u.is_superuser = True
          u.save()
          print(f'Promoted {u.username} to superuser')
          count += 1
      print(f'TOTAL:{count}')
      " 2>/dev/null)
      echo "$PROMOTED"
      # If no users exist yet, exit 1 to trigger restart
      if echo "$PROMOTED" | grep -q "TOTAL:0"; then
        echo "No users yet, will retry..."
        exit 1
      fi
    '';
  };

  networking.firewall.allowedTCPPorts = [ 8080 ];
}
