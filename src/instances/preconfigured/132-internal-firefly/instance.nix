# Firefly III personal finance
{ lib, id, config, profiles, ... }: {
  vm = {
    # parked while unused; "on" brings it back
    power = "off";
    bootPhase = "apps";
    needs = [ "containers" "nfs" ];
    memoryMiB = 1024;
  };

  grants = [
    { from = [ "operator" ]; tcp = [ config.services.firefly.port ]; why = "hermes' firefly skill calls the api"; }
  ];

  tokens = [ "firefly-token" ];

  # the daily wake runs the bank import (main.nix) before it sleeps again
  idle = { stopAfter = "1h"; wakeAt = "05:00"; };

  services = let
    # statement imports
    on = lib.remove "bodyLimit" profiles.hardenedInternal ++ profiles.listed ++ profiles.observed;
  in {
    fints = {
      port = 8090;
      homepage = { icon = "mdi-bank-transfer"; name = "FinTS Import"; };
      inherit on;
    };
    firefly = {
      port = 8080;
      health = "/health";
      homepage = { icon = "firefly-iii"; name = "Firefly III"; };
      inherit on;
    };
  };

  secrets = {
    firefly-app-key = "guardsData:laravel-key"; # encrypts fields of firefly's db
    firefly-db-password = "guardsData:hex:24"; # postgres keeps the password of its first start
  };

  shares = {
    "data/db-dumps/vm-${id}" = { mode = "0700"; };
    "data/firefly" = { };
  };
}
