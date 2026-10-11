# Firefly III personal finance
{ id, config, ... }: {
  vm = {
    bootPhase = "apps";
    needs = [ "containers" "nfs" ];
    memoryMiB = 1024;
  };

  grants = [
    { from = [ "114" ]; tcp = [ config.services.firefly.port ]; why = "hermes' firefly skill calls the api"; }
  ];

  tokens = [ "firefly-token" ];

  # the daily wake runs the bank import (main.nix) before it sleeps again
  idle = { stopAfter = "1h"; wakeAt = "05:00"; };

  services = {
    fints = {
      port = 8090;
      homepage = { icon = "mdi-bank-transfer"; name = "FinTS Import"; };
      off = { bodyLimit = "statement imports"; };
    };
    firefly = {
      port = 8080;
      health = "/health";
      homepage = { icon = "firefly-iii"; name = "Firefly III"; };
      off = { bodyLimit = "statement imports"; };
    };
  };

  secrets = {
    firefly-app-key = "guardsData:laravel-key"; # encrypts fields of firefly's db
    firefly-db-password = "hex:24";
  };

  shares = {
    "data/db-dumps/vm-${id}" = { mode = "0700"; };
    "data/firefly" = { };
  };
}
