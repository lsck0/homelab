# document management (paperless-ngx) and paperless-ai auto-tagging
{ lib, id, config, profiles, ... }: {
  vm = {
    bootPhase = "apps";
    needs = [ "containers" "nfs" ];
    # ocr plus the paperless-ai node process
    memoryMiB = 3072;
    # ran at 98% of a 2048 floor, page cache included
    balloonMiB = 2048;
    # paperless-ai image alone is 8.3 GiB
    diskGiB = 24;
  };

  grants = [
    { from = [ "operator" ]; tcp = [ config.services.paperless.port ]; why = "hermes' paperless skill calls the api"; }
  ];

  tokens = [ "paperless-key" ];

  services = let on = profiles.hardenedInternal ++ profiles.listed ++ profiles.observed; in {
    # document uploads
    paperless = { port = 8080; homepage = { icon = "paperless-ngx"; }; on = lib.remove "bodyLimit" on; };
    paperless-ai = { port = 80; homepage = { icon = "paperless-ngx"; name = "Paperless AI"; }; inherit on; };
  };

  shares = {
    "data/db-dumps/vm-${id}" = { mode = "0700"; };
    "data/paperless".localState = true;
    "data/paperless-ai".localState = true;
    "data/paperless/media" = { };
    "documents/inbox" = { };
  };
}
