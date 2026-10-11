# <host>.lsck0.dev -> the bootstrap line a bare arch iso runs as `curl https://<host>.lsck0.dev | sh`
let
  bootstrapLine = "curl -fsSL https://raw.githubusercontent.com/lsck0/arch-dotfiles/master/bootstrap.sh | bash";
  bootstrap = machine: "${bootstrapLine} -s -- ${machine}";
in {
  install-pc = bootstrap "luca-pc";
  install-notebook = bootstrap "luca-notebook";
  install-wsl = bootstrap "luca-wsl";
  # anyone else's machine: bootstrap.sh asks which one on the terminal
  install-generic = bootstrapLine;
}
