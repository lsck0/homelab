# push notifications (alert delivery)
{ ... }: {
  vm = {
    bootPhase = "public";
    kind.lxc = "pending migration, see the restructure report";
  };

  services = {
    ntfy = {
      port = 80;
      homepage = { group = "Public"; icon = "ntfy"; name = "ntfy"; };
      off = {
        sso = "public push notifications; ntfy checks its own accounts";
        anubis = "the phone app and vm-105 publish natively";
        waf = "publishers and subscribers are api clients the rules misread";
        bodyLimit = "attachments";
      };
    };
  };

  secrets = {
    ntfy-admin-password = "hex:24";
    ntfy-desktop-token = "ntfy-token"; # mirrored to the dotfiles' ntfy client
  };
}
