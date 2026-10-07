# the edge's promtail redaction (modules/base) over access log paths: feed and upload tokens and share links go,
# ordinary paths stay; the expression as the edge renders it, run by python's re (the same syntax as promtail's RE2 here)
{ pkgs, lib, inputs, ... }:
let
  edge = inputs.self.nixosConfigurations."200-external-traefik".config;
  accessJob = lib.findFirst (j: j.job_name == "traefik-access") (throw "the edge ships no access log")
    edge.services.promtail.configuration.scrape_configs;
  stage = lib.findFirst (s: s ? replace) (throw "the access log pipeline has no redaction") accessJob.pipeline_stages;
  cases = builtins.toJSON {
    expression = stage.replace.expression;
    replacement = stage.replace.replace;
    redacted = [
      "/${lib.fixedWidthString 64 "a" ""}/stats.json"
      "/upload/${lib.fixedWidthString 48 "0" ""}/work.ics"
      "/s/share?token=${lib.fixedWidthString 40 "Z" ""}"
    ];
    kept = [ "/api/v1/query" "/otlp/v1/traces" "/static/app.4f9c2e1b.js" "/" ];
  };
in
pkgs.runCommand "url-redaction" { nativeBuildInputs = [ pkgs.python3 ]; inherit cases; passAsFile = [ "cases" ]; } ''
  python3 - "$casesPath" <<'EOF'
  import json
  import re
  import sys

  cases = json.load(open(sys.argv[1]))
  pattern = re.compile(cases["expression"])

  def redact(path):
      # promtail replaces the capture group, keeping the rest of the line
      return pattern.sub(lambda m: m.group(0).replace(m.group(1), cases["replacement"]), path)

  for path in cases["redacted"]:
      assert cases["replacement"] in redact(path) and len(redact(path)) < len(path), path
  for path in cases["kept"]:
      assert redact(path) == path, path
  print(f"{len(cases['redacted'])} redacted, {len(cases['kept'])} kept")
  EOF
  touch $out
''
