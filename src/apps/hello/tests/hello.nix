# hello builds from the header app.nix pins by hash, offline, and answers
{ pkgs, ... }:
let
  args = (import ../app.nix).build.web.args;
  header = pkgs.fetchurl { url = args.HTTPSERVER_URL; sha256 = args.HTTPSERVER_SHA256; };
  # main.c's HELLO_PORT
  port = 8000;
in
pkgs.runCommandCC "hello" { nativeBuildInputs = [ pkgs.gnumake pkgs.curl ]; } ''
  cp ${../lib/main.c} main.c
  cp ${../lib/Makefile} Makefile
  cp ${header} httpserver.h
  make CC=cc
  ./server &
  for _ in $(seq 50); do curl -s -o /dev/null http://127.0.0.1:${toString port}/ && break; sleep 0.1; done
  curl -sf http://127.0.0.1:${toString port}/ | grep -qx 'Hello, World!'
  kill %1
  touch $out
''
