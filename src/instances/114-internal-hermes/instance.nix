# hermes: telegram agent, cloud models only, root on the lab
{ ... }: {
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
}
