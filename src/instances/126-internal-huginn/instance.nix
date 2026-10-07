# automation agents / scraping
{ ... }: {
  vm = {
    bootPhase = "apps";
    needs = [ "containers" "nfs" ];
    # off until there is a use for it
    power = "off";
    # rails plus postgres, measured 1003 MiB
    memoryMiB = 2048;
    balloonMiB = 1536;
    # image plus postgres left 396 MiB free on 8 GiB
    diskGiB = 16;
  };

  services = {
    huginn = { port = 80; homepage = { icon = "huginn"; }; };
  };
}
