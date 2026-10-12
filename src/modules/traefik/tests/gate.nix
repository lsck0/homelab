# lib/gate's go tests (gate_test.go: the puzzle's bound over seeds, the cookie, the verdict table, the one-try
# challenge, the limiter, the tarpit's bounds, the captcha flow end to end) and go vet; the vm test edge-antibot runs
# it inside the edge with the real crowdsec
{ pkgs, ... }:
pkgs.runCommand "gate" { nativeBuildInputs = [ pkgs.go ]; } ''
  export HOME=$TMPDIR GOCACHE=$TMPDIR/go-cache GOFLAGS=-mod=mod GOTOOLCHAIN=local CGO_ENABLED=0
  cp -r ${../lib/gate} src && chmod -R u+w src && cd src
  test -z "$(gofmt -l .)" || { gofmt -l .; exit 1; }
  go vet ./...
  go test -count=1 ./...
  touch $out
''
