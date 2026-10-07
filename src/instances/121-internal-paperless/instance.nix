# document management (paperless-ngx) and paperless-ai auto-tagging
{ id, config, ... }: {
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

  services = {
    paperless = { port = 8080; homepage = { icon = "paperless-ngx"; }; off = { bodyLimit = "document uploads"; }; };
    paperless-ai = { port = 80; homepage = { icon = "paperless-ngx"; name = "Paperless AI"; }; };
  };

  shares = {
    "data/db-dumps/vm-${id}" = { mode = "0700"; };
    "data/paperless" = { };
    "data/paperless-ai" = { };
    "data/paperless/media" = { };
    "documents/inbox" = { };
  };
}
