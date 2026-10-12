# the escalation ladder: what crowdsec decides for a client that tripped a signal, as data, rendered into crowdsec's
# scenarios (the signals, read off traefik's access log) and profiles (the rungs)
#
# A signal's alert puts its client on a rung: the signal's entry rung, one higher for every decision the client got
# in the window, the top rung for every repeat beyond. A suspicious client is first asked the captcha, a misbehaving
# one banned for minutes, then hours, a repeat offender for a day. The gate (lib/gate) answers each decision: a
# captcha decision with its captcha, a ban with the ban page and its remaining time.
#
# credit: decisions the signal itself implies and does not count; a failed captcha always follows the captcha
# decision that asked it, so its first overflow lands on its entry rung, not one above.
#
# Any scenario no signal names (the hub's probing, cve and waf scenarios) climbs the ladder as a strong signal.
{ lib, yamlDocs }:
let
  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  rungs = [
    { name = "captcha"; type = "captcha"; duration = "4h"; }
    { name = "softBan"; type = "ban"; duration = "15m"; }
    { name = "hardBan"; type = "ban"; duration = "1h"; }
    { name = "repeatBan"; type = "ban"; duration = "24h"; }
  ];
  # how far back a client's decisions raise its rung
  window = "24h";

  # the owner's limit: wrong or late captcha answers an hour, past which the client is banned (the hardBan rung)
  captchaRegenerationsMax = 5;
  minutesPerHour = 60;
  # what the gate's answers say in the access log (lib/gate page.go headerOutcome, challenge.go outcomeNames)
  outcomeHeader = "X-Lab-Gate";
  captchaFailures = [ "wrong" "expired" ];

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
      class = "strong";
      type = "trigger";
      filter = "${httpFilter} && ${routerIs "honeypot-"}";
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

  # where each class enters the ladder, in crowdsec's order; the last takes every alert the others did not
  classes = [
    { name = "weak"; entry = "captcha"; credit = 0; }
    { name = "captchaFailed"; entry = "hardBan"; credit = 1; }
    { name = "strong"; entry = "softBan"; credit = 0; }
  ];

  scenarioName = name: "homelab/${name}";
  # a client's alerts within one burst raise one decision, not one per event
  blackhole = "1m";

  # -----------------------------------------------------------------------------
  # INTERNAL
  # -----------------------------------------------------------------------------

  rungIndex = name: lib.lists.findFirstIndex (r: r.name == name) (throw "ladder: no rung ${name}") rungs;
  lastRung = lib.length rungs - 1;

  scenarioOf = name: s: {
    inherit (s) type filter;
    name = scenarioName name;
    description = "homelab ladder signal ${name} (modules/traefik/lib/ladder.nix)";
    groupby = "evt.Meta.source_ip";
    inherit blackhole;
    labels = { remediation = true; service = "http"; label = "homelab ${name}"; };
  } // lib.optionalAttrs (s.type == "leaky") { inherit (s) capacity leakspeed; };

  scenariosOf = class: map scenarioName (lib.attrNames (lib.filterAttrs (_: s: s.class == class) signals));

  # one profile per rung a class can reach; the client's count of decisions in the window picks it
  profilesOf = class: let
    entry = rungIndex class.entry;
    fallback = class.name == (lib.last classes).name;
    count = "GetDecisionsSinceCount(Alert.GetValue(), '${window}')";
  in lib.genList (offset: let
    rung = lib.elemAt rungs (entry + offset);
    seen = toString (class.credit + offset);
    first = offset == 0;
    last = entry + offset == lastRung;
    countFilter =
      if first && last then [ ]
      else if first then [ "${count} <= ${seen}" ]
      else if last then [ "${count} >= ${seen}" ]
      else [ "${count} == ${seen}" ];
  in {
    name = "homelab/${class.name}-${rung.name}";
    filters = [ (lib.concatStringsSep " && " ([ "Alert.Remediation == true" "Alert.GetScope() == 'Ip'" ]
      ++ lib.optional (!fallback) "Alert.GetScenario() in ${builtins.toJSON (scenariosOf class.name)}"
      ++ countFilter)) ];
    decisions = [ { inherit (rung) type duration; } ];
    on_success = "break";
  }) (lastRung - entry + 1);

  # crowdsec's stock range profile: a range is banned outright
  rangeProfile = {
    name = "default_range_remediation";
    filters = [ "Alert.Remediation == true && Alert.GetScope() == 'Range'" ];
    decisions = [ { type = "ban"; duration = (lib.elemAt rungs lastRung).duration; } ];
    on_success = "break";
  };
in
assert lib.assertMsg (lib.all (s: lib.any (c: c.name == s.class) classes) (lib.attrValues signals)) "ladder: a signal names no class";
assert lib.assertMsg (lib.all (s: s.type == "trigger" || s.type == "leaky") (lib.attrValues signals)) "ladder: a signal is neither trigger nor leaky";
{
  inherit rungs window captchaRegenerationsMax outcomeHeader;
  # file name -> its scenario, for crowdsec's config/scenarios
  scenarios = lib.mapAttrs' (name: s: lib.nameValuePair "homelab-${name}.yaml" (yamlDocs "homelab-${name}.yaml" [ (scenarioOf name s) ])) signals;
  profiles = yamlDocs "profiles.yaml" (lib.concatMap profilesOf classes ++ [ rangeProfile ]);
}
