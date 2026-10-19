# taskchampion-sync-server, nixpkgs' module: the owner's taskwarrior replicas meet here. Clients encrypt every
# version with their sync.encryption_secret before upload, so the server only ever holds ciphertext; it admits the
# one client id of the dotfiles' secret taskwarrior-client-id and refuses to create any other.
{ config, catalog, ... }:
let
  route = catalog.internal.taskchampion;
  stateDir = "/var/lib/taskchampion-sync-server";
  db = "taskchampion-sync-server.sqlite3";
in
{
  homelab.localState.taskchampion = {
    path = stateDir;
    unit = "taskchampion-sync-server";
    sqlite = [ db ];
  };

  services.taskchampion-sync-server = {
    enable = true;
    host = "0.0.0.0";
    inherit (route) port;
    dataDir = stateDir;
  };

  # the allowlist through the server's own env (CLIENT_ID), never on the public command line
  sops.secrets.taskchampion-client-id.restartUnits = [ "taskchampion-sync-server.service" ];
  sops.templates."taskchampion.env".content = ''
    CLIENT_ID=${config.sops.placeholder.taskchampion-client-id}
  '';
  systemd.services.taskchampion-sync-server.serviceConfig.EnvironmentFile = config.sops.templates."taskchampion.env".path;

  # consistent copy for the snapshot, the live file may be mid-write
  homelab.dbBackup.databases.taskchampion.sqlite = "${stateDir}/${db}";
}
