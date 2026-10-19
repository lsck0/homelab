# lib/gate's go tests (gate_test.go: the puzzle's bound over seeds, the cookie, the verdict table, the one-try
# challenge, the limiter, the tarpit's bounds, the captcha flow end to end; deception_test.go: crawler verification,
# the deception's verdicts, its fakes' caps, determinism and canaries, the trickle's pace) and go vet; the vm tests
# edge-antibot and deception run it inside the edge with the real crowdsec
{ pkgs, ... }:
pkgs.runCommand "gate" { nativeBuildInputs = [ pkgs.go ]; } ''
  export HOME=$TMPDIR GOCACHE=$TMPDIR/go-cache GOFLAGS=-mod=mod GOTOOLCHAIN=local CGO_ENABLED=0
  cp -r ${../lib/gate} src && chmod -R u+w src && cd src
  test -z "$(gofmt -l .)" || { gofmt -l .; exit 1; }
  go vet ./...
  go test -count=1 ./...
  touch $out
''
