# feed_io.py as a python module, for the feed and export scripts of vm-104 and vm-105
{ pkgs }:
pkgs.python3Packages.toPythonModule (pkgs.runCommand "feed-io" { } ''
  install -Dm644 ${./lib/feed_io.py} $out/${pkgs.python3.sitePackages}/feed_io.py
'')
