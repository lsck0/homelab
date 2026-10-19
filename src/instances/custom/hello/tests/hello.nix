# hello builds from the header app.nix pins by hash, offline, and answers
{ pkgs, ... }:
let
  app = import ../app.nix { profiles = import ../../../../modules/profiles.nix; };
  inherit (app.build.web) args;
  header = pkgs.fetchurl {
    url = args.HTTPSERVER_URL;
    sha256 = args.HTTPSERVER_SHA256;
  };
  port = toString app.routes.hello.targetPort;
  # curl backs off 1, 2, 4, 8 s while the server binds
  startRetries = 4;
in
pkgs.runCommandCC "hello"
  {
    nativeBuildInputs = [
      pkgs.gnumake
      pkgs.curl
    ];
  }
  ''
    cp ${../lib/main.c} main.c
    cp ${../lib/Makefile} Makefile
    cp ${header} httpserver.h
    make CC=cc
    ./server &
    curl -sf --retry-connrefused --retry ${toString startRetries} http://127.0.0.1:${port}/ | grep -qx 'hello dino you smell like pee'
    kill %1
    touch $out
  ''
