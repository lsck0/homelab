# modules/upstream, case by case against a local stand-in of a third party: a call is retried, an outage exits
# EX_TEMPFAIL, a failure of the caller's own passes its status through, a hung attempt is cut at its bound
{ pkgs, lib, ... }:
let
  port = 18080;
  base = "http://127.0.0.1:${toString port}";
  upstream = (import ../default.nix {
    inherit lib pkgs;
    lab.upstreams = {
      healthy.url = "${base}/200";
      # a 4xx is an answer: the service is up, the request was wrong
      picky.url = "${base}/404";
      broken.url = "${base}/502";
      # nothing listens on port 1
      gone.url = "http://127.0.0.1:1/";
    };
  })._module.args.upstream;

  # the path names the status the stand-in answers
  standIn = pkgs.writeText "stand-in.py" ''
    import http.server
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(int(self.path.strip("/")))
            self.end_headers()
        def log_message(self, *args):
            pass
    http.server.HTTPServer(("127.0.0.1", ${toString port}), Handler).serve_forever()
  '';

  # name -> { upstream; command (sh, empty: probe only); status; attempts (runs of the command) }
  cases = {
    first-try = { upstream = "healthy"; command = "exit 0"; status = 0; attempts = 1; };
    blip-then-ok = { upstream = "broken"; command = "[ \"$n\" -ge 3 ]"; status = 0; attempts = 3; };
    own-failure = { upstream = "healthy"; command = "exit 3"; status = 3; attempts = 4; };
    own-failure-4xx-up = { upstream = "picky"; command = "exit 3"; status = 3; attempts = 4; };
    outage-5xx = { upstream = "broken"; command = "exit 3"; status = upstream.unavailable; attempts = 4; };
    outage-refused = { upstream = "gone"; command = "exit 3"; status = upstream.unavailable; attempts = 4; };
    hung-attempt = { upstream = "gone"; command = "sleep 30"; status = upstream.unavailable; attempts = 4; };
    probe-up = { upstream = "healthy"; command = ""; status = 0; attempts = 0; };
    probe-down = { upstream = "broken"; command = ""; status = upstream.unavailable; attempts = 0; };
    unknown = { upstream = "nowhere"; command = "exit 0"; status = 2; attempts = 0; };
  };

  caseScript = name: c: let
    counted = pkgs.writeShellScript "${name}-command" ''
      n=$(( $(cat "$COUNT") + 1 ))
      echo "$n" > "$COUNT"
      ${c.command}
    '';
  in ''
    echo 0 > count
    status=0
    COUNT=$PWD/count ${upstream.run} ${c.upstream} ${lib.optionalString (c.command != "") counted} 2> ${name}.log || status=$?
    if [ "$status" != ${toString c.status} ] || [ "$(cat count)" != ${toString c.attempts} ]; then
      echo "FAIL ${name}: exit $status after $(cat count) attempts, want ${toString c.status} after ${toString c.attempts}"
      cat ${name}.log
      failed=1
    fi
  '' + lib.optionalString (c.status == upstream.unavailable) ''
    grep -q "^${c.upstream} unavailable" ${name}.log || { echo "FAIL ${name}: no '${c.upstream} unavailable' line"; failed=1; }
  '';
in
pkgs.runCommand "upstream" { nativeBuildInputs = [ pkgs.python3 pkgs.curl ]; } ''
  python3 ${standIn} &
  for _ in $(seq 50); do curl -s -o /dev/null ${base}/200 && break; sleep 0.1; done
  export UPSTREAM_BACKOFF_S=0 UPSTREAM_TIMEOUT_S=1
  failed=0
  ${lib.concatStrings (lib.mapAttrsToList caseScript cases)}
  [ "$failed" = 0 ] || exit 1
  echo "${toString (lib.length (lib.attrNames cases))} cases pass" > $out
''
