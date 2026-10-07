# <host>.lsck0.dev -> the bootstrap line a bare arch iso runs as `curl https://<host>.lsck0.dev | sh`
let
  bootstrap = machine:
    "curl -fsSL https://raw.githubusercontent.com/lsck0/arch-dotfiles/master/bootstrap.sh | bash -s -- ${machine}";
in {
  install-pc = bootstrap "luca-pc";
  install-notebook = bootstrap "luca-notebook";
  install-wsl = bootstrap "luca-wsl";
}
