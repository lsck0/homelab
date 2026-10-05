{ config, lib, pkgs, nasMount, nasPath, ... }:
let
  # pre-consume: straighten and crop image uploads (contracts photographed/scanned) to the
  # document, so the stored file and its ocr are not full of background. pdfs are left alone.
  cropImages = pkgs.writeShellScript "paperless-crop-images" ''
    set -eu
    f="''${DOCUMENT_WORKING_PATH:-''${1:-}}"
    [ -n "$f" ] && [ -f "$f" ] || exit 0
    case "$(${pkgs.file}/bin/file --mime-type -b "$f")" in
      image/*) ;;
      *) exit 0 ;;
    esac
    tmp="$f.cropped"
    # auto-orient, deskew, then trim the near-uniform border so the page fills the frame
    if ${pkgs.imagemagick}/bin/magick "$f" -auto-orient -deskew 40% -fuzz 12% -trim +repage "$tmp" 2>/dev/null \
       && [ -s "$tmp" ]; then
      mv "$tmp" "$f"
    else
      rm -f "$tmp"
    fi
  '';
  # fixed vocabulary; paperless-ai may only pick from these
  tags = [
    "Steuern" "Versicherung" "Bank" "Wohnen" "Nebenkosten" "Energie" "Wasser" "Auto"
    "Gesundheit" "Arbeit" "Behörde" "Einkauf" "Telefon & Internet" "Bildung" "Familie" "Reise"
  ];
  # document types match by keyword here: paperless-ai 3.0.9 only restricts tags and correspondents in code
  documentTypes = {
    "Rechnung" = "Rechnung Gebührenbescheid Abrechnung";
    "Bescheid" = "Bescheid Steuerbescheid Festsetzung";
    "Vertrag" = "Vertrag Vereinbarung";
    "Kontoauszug" = "Kontoauszug Kontostand";
    "Gehaltsabrechnung" = "Gehaltsabrechnung Entgeltabrechnung Lohnabrechnung Verdienstabrechnung";
    "Versicherungsschein" = "Versicherungsschein Police Versicherungsnachweis";
    "Quittung" = "Quittung Kassenbon Beleg";
    "Mahnung" = "Mahnung Zahlungserinnerung";
    "Kündigung" = "Kündigung";
    "Angebot" = "Angebot Kostenvoranschlag";
    "Zeugnis" = "Zeugnis Zertifikat";
  };
  pyList = xs: "[" + lib.concatMapStringsSep ", " (x: "'${x}'") xs + "]";
  pyDict = d: "{" + lib.concatStringsSep ", " (lib.mapAttrsToList (k: v: "'${k}': '${v}'") d) + "}";
in {
  imports = [ ../services/paperless-ai.nix ];

  networking.hostName = "vm-121";

  # documents stay plain files on the nas, the inbox is the smb documents share
  fileSystems = nasMount "/srv/paperless-media" "paperless/media"
    // nasPath "/srv/paperless-consume" "documents/inbox";

  # db and index local, the nas keeps a nightly copy
  homelab.localState.paperless = {
    path = "/var/lib/paperless";
    share = "paperless";
    unit = "paperless-scheduler";
    sqlite = [ "db.sqlite3" ];
    # the beat schedule and logs regenerate
    exclude = [ "media" "consume" "log" "celerybeat-schedule.db*" ];
  };

  services.paperless = {
    enable = true;
    mediaDir = "/srv/paperless-media";
    consumptionDir = "/srv/paperless-consume";
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
      # crop/deskew photographed or scanned images before consuming (see cropImages)
      PAPERLESS_PRE_CONSUME_SCRIPT = toString cropImages;
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
      from documents.models import Tag, DocumentType, MatchingModel
      # MATCH_NONE: paperless's own matcher must not assign these
      for n in ${pyList tags}:
          Tag.objects.get_or_create(name=n, defaults={'matching_algorithm': MatchingModel.MATCH_NONE, 'owner': owner})
      for n, words in ${pyDict documentTypes}.items():
          DocumentType.objects.update_or_create(name=n, defaults={'matching_algorithm': MatchingModel.MATCH_ANY, 'match': words, 'is_insensitive': True, 'owner': owner})
      print(Token.objects.get_or_create(user=bot)[0].key)
      " | tail -1)
      [ -n "$TOKEN" ] || { echo "no API token from paperless-manage"; exit 1; }
      echo -n "$TOKEN" > ${config.homelab.tokens.dir}/paperless-key.token
    '';
  };

  networking.firewall.allowedTCPPorts = [ 8080 ];

  # paperless trusts Remote-User, so ingress only
  homelab.ingressOnly.ports = [ 8080 ];
}
