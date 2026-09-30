# <host>.lsck0.dev -> one line of sh, plain http on the external traefik, so a bare arch iso can run
# `curl <host>.lsck0.dev | sh`: curl defaults to http and follows no redirect
let
  bootstrap = machine:
    "curl -fsSL https://raw.githubusercontent.com/lsck0/arch-dotfiles/master/bootstrap.sh | bash -s -- ${machine}";
in {
  install-pc = bootstrap "luca-pc";
  install-notebook = bootstrap "luca-notebook";
}
