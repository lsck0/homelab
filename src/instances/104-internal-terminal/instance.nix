# e-ink terminal feeds: calendar, homelab stats, arXiv
{ ... }:
let
  # one nginx serves both hosts, polled by the trmnl cloud
  feedPort = 8081;
  feedOff = {
    sso = "the trmnl cloud polls it with a token";
    anubis = "the trmnl cloud runs no proof of work";
    cloudflare = "the trmnl cloud fetches it directly";
    homepage = "a feed, no page";
  };
in {
  vm = {
    bootPhase = "apps";
    needs = [ "nfs" ];
    kind.lxc = "pending migration, see the restructure report";
    privileged = true;
    features = "nesting=1,mount=nfs";
  };

  services = {
    calendar = { host = "cal"; port = feedPort; off = feedOff; };
    terminal = { port = feedPort; off = feedOff; };
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
