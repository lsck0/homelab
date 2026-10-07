# the client-ip traefik plugin's table tests (lib/traefik-clientip), with go's standard library only, as yaegi
# runs it; the vm tests (auth-chain, edge-apps) run it inside traefik
{ pkgs, ... }:
pkgs.runCommand "traefik-clientip" { nativeBuildInputs = [ pkgs.go ]; } ''
  # yaegi interprets go without cgo, and so does this
  export HOME=$TMPDIR GOCACHE=$TMPDIR/go-cache GOFLAGS=-mod=mod GOTOOLCHAIN=local CGO_ENABLED=0
  cp -r ${../lib/traefik-clientip} src && chmod -R u+w src && cd src
  go vet ./...
  go test -v ./...
  touch $out
''
