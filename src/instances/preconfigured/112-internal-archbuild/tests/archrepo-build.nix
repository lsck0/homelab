# single steps of vm-112's nightly build (lib/archrepo-build.nu) in the sandbox, driven by archrepo_build_test.nu: the
# build dependencies, the recipe key against the bash build's, repack, the skip and accept decisions, the completeness
# gate, the push to the mirror, the night's budget, outages of the aur against a stand-in, the builder's pool, a local
# recipe over an official package, the internet's tree and a skipped night (lib/archrepo-skip.nu)
{ pkgs, lib, ... }:
let
  tree = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [ ./archrepo_build_test.nu ../lib/archrepo-build.nu ../lib/archrepo-list.nu ../lib/archrepo-skip.nu ];
  };
  port = 18081;
  base = "http://127.0.0.1:${toString port}";
  upstream = (import ../../../../modules/upstream/default.nix {
    inherit lib pkgs;
    lab.upstreams = { aur.url = "${base}/probe"; keyserver.url = "${base}/probe"; };
  })._module.args.upstream;
  # a keyserver that never has the key: what is left to classify is whether the keyserver was up
  gpgStandIn = pkgs.writers.writeNuBin "gpg" "exit 2";
  # modules/upstream's run with pacman's downloads skipped: a download needs root, which the sandbox is not, and the
  # official file is in the pacman cache already; the build calls it with bash, as it does the real one
  pacmanUpstream = pkgs.writeText "pacman-upstream" ''
    shift
    case " $* " in *" -Swdd "*) exit 0 ;; esac
    exec "$@"
  '';
  # <state dir>: answers by <state dir>/mode (up, down, rpc-broken), the rpc fails <state dir>/fails times first
  standIn = pkgs.writeText "aur-stand-in.py" ''
    import http.server, json, pathlib, sys, urllib.parse
    state = pathlib.Path(sys.argv[1])
    class Handler(http.server.BaseHTTPRequestHandler):
        def answer(self, query):
            mode = (state / "mode").read_text().strip()
            fails = int((state / "fails").read_text())
            url = urllib.parse.urlparse(self.path)
            body = b""
            if url.path == "/probe":
                code = 502 if mode == "down" else 200
            elif mode == "down" or fails > 0:
                (state / "fails").write_text(str(max(fails - 1, 0)))
                code = 502
            elif mode == "rpc-broken":
                code = 404
            else:
                names = urllib.parse.parse_qs(query).get("arg[]", [])
                code = 200
                body = json.dumps({"results": [{"Name": n, "PackageBase": n} for n in names if not n.startswith("deleted")]}).encode()
            self.send_response(code)
            self.end_headers()
            self.wfile.write(body)
        def do_GET(self):
            self.answer(urllib.parse.urlparse(self.path).query)
        def do_POST(self):
            self.answer(self.rfile.read(int(self.headers["Content-Length"])).decode())
        def log_message(self, *args):
            pass
    http.server.HTTPServer(("127.0.0.1", ${toString port}), Handler).serve_forever()
  '';
in
pkgs.runCommand "archrepo-build" {
  nativeBuildInputs = [ pkgs.nushell pkgs.bash pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.rsync pkgs.curl pkgs.git
    pkgs.python3 pkgs.pacman pkgs.libarchive pkgs.zstd pkgs.gzip pkgs.gnupg ];
} ''
  export HOME=$PWD UPSTREAM_BACKOFF_S=0 UPSTREAM_TIMEOUT_S=5 GPG_STAND_IN=${gpgStandIn}/bin
  mkdir aur
  echo up > aur/mode
  echo 0 > aur/fails
  python3 ${standIn} "$PWD/aur" &
  for _ in $(seq 50); do curl -s -o /dev/null ${base}/probe && break; sleep 0.1; done
  nu --no-config-file ${tree}/tests/archrepo_build_test.nu ${upstream.run} ${toString upstream.unavailable} ${base} "$PWD/aur" ${pacmanUpstream}
  touch $out
''
