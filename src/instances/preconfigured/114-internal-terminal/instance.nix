# e-ink terminal feeds: calendar, homelab stats, arXiv
{ lib, profiles, ... }:
let
  # one nginx serves both hosts, polled by the trmnl cloud
  feedPort = 8081;
  # the trmnl cloud fetches it directly with a token in the path, which the access log would keep, and solves no captcha
  feedOn =
    lib.subtractLists [ "sso" "captcha" "cloudflare" "accessLog" ] profiles.hardenedInternal
    ++ [ "probe" ]
    ++ profiles.observed;
in
{
  vm = {
    bootPhase = "apps";
    needs = [ "nfs" ];
    # 308 MiB peak over 35d
    memoryMiB = 448;
  };

  services = {
    calendar = {
      host = "cal";
      port = feedPort;
      on = feedOn;
    };
    terminal = {
      port = feedPort;
      on = feedOn;
    };
  };

  secrets = {
    calendar-sources = "manual";
    calendar-upload-token = "hex:24"; # unguessable url segment of the calendar feed
    terminal-token = "hex:32";
    trmnl-api-key = "manual";
  };

  shares = {
    "data/calendar" = { };
  };
}
