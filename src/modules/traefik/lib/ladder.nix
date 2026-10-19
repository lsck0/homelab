# the escalation ladder: what crowdsec decides for a client that tripped a signal, as data, rendered into crowdsec's
# scenarios (the signals, read off traefik's access log) and profiles (the rungs)
#
# A signal's alert puts its client on a rung of its class's path: the first, one further for every decision the
# client got in the window, the last for every repeat beyond. A suspicious client is first asked the captcha, a
# misbehaving one banned for minutes, then hours, a repeat offender for a day. A scanner is deceived for a few minutes
# and banned in the same alert: crowdsec decides both at once, the gate (lib/gate) serves the deception while the
# deceive lasts and the ban page after, so the ban comes whether the scanner stops or not; a scanner seen again later
# is banned for the day. Brute force and the waf keep their bans at once. The gate answers each decision: a captcha
# decision with its captcha, a ban with the ban page and its remaining time, a deceive with fakes and the labyrinth.
#
# A day's ban hits everyone behind the address, so only a signal nothing but a scanner trips (the honeypot's exact
# paths, path traversal) bans for the day on its first alert. A browser can trip the others: broken links trip
# http-probing and http-crawl-non_statics, a user-triggered fetcher on a shared egress (an ai assistant's, a cloudflare
# worker's) the labyrinth, so these start at the captcha or a short ban. A user agent switcher or paywall extension
# names a search crawler (forged-crawler), and http-sensitive-files matches suffixes (.bak, .exe, .config) an app may
# serve, in the query too, so these are deceived and then banned for minutes; only a repeat costs the day.
#
# credit: decisions the signal itself implies and does not count; a failed captcha always follows the captcha
# decision that asked it, so its first overflow lands on its first rung, not one further.
#
# Any scenario no class names (the hub's cve, brute force and waf scenarios) climbs the ladder as a strong signal.
{
  lib,
  yamlDocs,
  # how long a scanner is deceived before its ban
  deceiveWindow,
  # the access log's service of the gate's forged-crawler deception (lib/gate.nix)
  forgedCrawlerService,
}:
let

  repeatBanDuration = "24h";
  softBan = [
    {
      type = "ban";
      duration = "15m";
    }
  ];
  rungs = {
    inherit softBan;
    captcha = [
      {
        type = "captcha";
        duration = "4h";
      }
    ];
    hardBan = [
      {
        type = "ban";
        duration = "1h";
      }
    ];
    repeatBan = [
      {
        type = "ban";
        duration = repeatBanDuration;
      }
    ];
    deceive = [
      {
        type = "deceive";
        duration = deceiveWindow;
      }
      {
        type = "ban";
        duration = repeatBanDuration;
      }
    ];
    deceiveSoftBan = [
      {
        type = "deceive";
        duration = deceiveWindow;
      }
    ]
    ++ softBan;
  };
  # how far back a client's decisions raise its rung
  window = "24h";

  # the owner's limit: wrong or late captcha answers an hour, past which the client is banned (the hardBan rung)
  captchaRegenerationsMax = 5;
  minutesPerHour = 60;
  # what the gate's answers say in the access log (lib/gate page.go headerOutcome, challenge.go outcomeNames)
  outcomeHeader = "X-Lab-Gate";
  captchaFailures = [
    "wrong"
    "expired"
  ];
  # the deception's outcome for a forged crawler (lib/gate deception.go); a backend answering its status itself has none
  forgedCrawlerOutcome = "forged-crawler";

  # anubis' proof-of-work verdict endpoint; it answers 4xx or 5xx to a failed proof
  anubisVerdictPath = "/.within.website/x/cmd/anubis/api/pass-challenge";
  failureStatusMin = 400;
  rateLimitedStatus = 429;

  # the client crowdsec's traefik parser names: X-Real-Ip's client, behind cloudflare too (modules/traefik accessLog)
  httpFilter = "evt.Meta.log_type == 'http_access-log'";
  routerIs = prefix: "evt.Parsed.traefik_router_name startsWith '${prefix}'";

  # each signal: a scenario on the access log; trigger fires on the first event, leaky past capacity in a burst
  signals = {
    # nothing legitimate requests a honeypot path (modules/traefik honeypotPaths)
    honeypot = {
      class = "deceive";
      type = "trigger";
      filter = "${httpFilter} && ${routerIs "honeypot-"}";
    };
    # a search crawler's name from outside its ranges and names, which the gate answered with the deception
    forged-crawler = {
      class = "deceiveBrief";
      type = "trigger";
      filter = lib.concatStringsSep " && " [
        httpFilter
        "evt.Unmarshaled.traefik.ServiceName == '${forgedCrawlerService}'"
        "evt.Unmarshaled.traefik['downstream_${outcomeHeader}'] == '${forgedCrawlerOutcome}'"
      ];
    };
    # a crawler that keeps walking the labyrinth after robots.txt said no
    labyrinth = {
      class = "weak";
      type = "leaky";
      filter = "${httpFilter} && ${routerIs "labyrinth-"}";
      capacity = 10;
      leakspeed = "5m";
    };
    anubis-failed = {
      class = "weak";
      type = "leaky";
      filter = "${httpFilter} && evt.Meta.http_path startsWith '${anubisVerdictPath}' && int(evt.Meta.http_status) >= ${toString failureStatusMin}";
      capacity = 3;
      leakspeed = "10m";
    };
    # a streak of 429s: a client that keeps going past the limits, the gate's included
    rate-limited = {
      class = "weak";
      type = "leaky";
      filter = "${httpFilter} && evt.Meta.http_status == '${toString rateLimitedStatus}'";
      capacity = 30;
      leakspeed = "2s";
    };
    # the owner's captcha rule: the bucket holds an hour's allowance and leaks it evenly
    captcha-failed = {
      class = "captchaFailed";
      type = "leaky";
      filter = "${httpFilter} && evt.Unmarshaled.traefik['downstream_${outcomeHeader}'] in ${builtins.toJSON captchaFailures}";
      capacity = captchaRegenerationsMax;
      leakspeed = "${toString (minutesPerHour / captchaRegenerationsMax)}m";
    };
  };

  # each class's path up the ladder, in crowdsec's order; the last takes every alert the others did not.
  # hubScenarios: the hub's scenarios (crowdsecurity/base-http-scenarios) the class takes beside its signals
  classes = [
    {
      name = "weak";
      path = [
        "captcha"
        "softBan"
        "hardBan"
        "repeatBan"
      ];
      credit = 0;
      hubScenarios = [ ];
    }
    {
      name = "captchaFailed";
      path = [
        "hardBan"
        "repeatBan"
      ];
      credit = 1;
      hubScenarios = [ ];
    }
    {
      name = "deceive";
      path = [
        "deceive"
        "repeatBan"
      ];
      credit = 0;
      hubScenarios = [ "crowdsecurity/http-path-traversal-probing" ];
    }
    {
      name = "deceiveBrief";
      path = [
        "deceiveSoftBan"
        "repeatBan"
      ];
      credit = 0;
      hubScenarios = [ "crowdsecurity/http-sensitive-files" ];
    }
    {
      name = "strong";
      path = [
        "softBan"
        "hardBan"
        "repeatBan"
      ];
      credit = 0;
      hubScenarios = [ ];
    }
  ];

  scenarioName = name: "homelab/${name}";
  # a client's alerts within one burst raise one decision, not one per event
  blackhole = "1m";

  scenarioOf =
    name: s:
    {
      inherit (s) type filter;
      name = scenarioName name;
      description = "homelab ladder signal ${name} (modules/traefik/lib/ladder.nix)";
      groupby = "evt.Meta.source_ip";
      inherit blackhole;
      labels = {
        remediation = true;
        service = "http";
        label = "homelab ${name}";
      };
    }
    // lib.optionalAttrs (s.type == "leaky") { inherit (s) capacity leakspeed; };

  scenariosOf =
    class: map scenarioName (lib.attrNames (lib.filterAttrs (_: s: s.class == class.name) signals)) ++ class.hubScenarios;

  # one profile per rung of a class's path; the client's count of decisions in the window picks it
  profilesOf =
    class:
    let
      fallback = class.name == (lib.last classes).name;
      count = "GetDecisionsSinceCount(Alert.GetValue(), '${window}')";
      lastOffset = lib.length class.path - 1;
    in
    lib.imap0 (
      offset: rung:
      let
        seen = toString (class.credit + offset);
        first = offset == 0;
        last = offset == lastOffset;
        countFilter =
          if first && last then
            [ ]
          else if first then
            [ "${count} <= ${seen}" ]
          else if last then
            [ "${count} >= ${seen}" ]
          else
            [ "${count} == ${seen}" ];
      in
      {
        name = "homelab/${class.name}-${rung}";
        filters = [
          (lib.concatStringsSep " && " (
            [
              "Alert.Remediation == true"
              "Alert.GetScope() == 'Ip'"
            ]
            ++ lib.optional (!fallback) "Alert.GetScenario() in ${builtins.toJSON (scenariosOf class)}"
            ++ countFilter
          ))
        ];
        decisions = rungs.${rung};
        on_success = "break";
      }
    ) class.path;

  # crowdsec's stock range profile: a range is banned outright
  rangeProfile = {
    name = "default_range_remediation";
    filters = [ "Alert.Remediation == true && Alert.GetScope() == 'Range'" ];
    decisions = rungs.repeatBan;
    on_success = "break";
  };
  profiles = lib.concatMap profilesOf classes ++ [ rangeProfile ];
in
assert lib.assertMsg (lib.all (s: lib.any (c: c.name == s.class) classes) (
  lib.attrValues signals
)) "ladder: a signal names no class";
assert lib.assertMsg (lib.all (s: s.type == "trigger" || s.type == "leaky") (
  lib.attrValues signals
)) "ladder: a signal is neither trigger nor leaky";
assert lib.assertMsg (lib.all (
  c: lib.all (rung: rungs ? ${rung}) c.path
) classes) "ladder: a class's path names no rung";
{
  inherit
    window
    captchaRegenerationsMax
    outcomeHeader
    ;
  # the profiles as data, for tests/policy
  profileList = profiles;
  # file name -> its scenario, for crowdsec's config/scenarios
  scenarios = lib.mapAttrs' (
    name: s: lib.nameValuePair "homelab-${name}.yaml" (yamlDocs "homelab-${name}.yaml" [ (scenarioOf name s) ])
  ) signals;
  profiles = yamlDocs "profiles.yaml" profiles;
}
