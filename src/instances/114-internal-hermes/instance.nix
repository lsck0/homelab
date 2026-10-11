# hermes: telegram agent, cloud models only, root on the lab
{ id, ... }: {
  vm = {
    bootPhase = "dev";
    needs = [ "nfs" ];
    memoryMiB = 1536;
    diskGiB = 60;
    machine = "q35";
  };

  # filled by lib/hermes-secrets.sh
  secrets = {
    hermes-github-app-key = "manual";
    hermes-claude-token = "dotfiles:claude-oauth-token";
    hermes-ssh-key = "manual";
  };

  # reads every token: the skills call every api (modules/lab)
  roles = [ "operator" ];

  shares = {
    "bulk/media" = { };
    "data/db-dumps/vm-${id}" = { mode = "0700"; };
    "syncthing/sync" = { };
  };
}
