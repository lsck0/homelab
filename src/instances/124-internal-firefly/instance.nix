# Firefly III personal finance
{ config, ... }: {
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
    firefly-app-key = "manual"; # init.sh: base64: and 32 random bytes
    firefly-db-password = "hex:24";
  };
}
