# <host>.lsck0.dev -> the bootstrap line a bare arch iso runs as `curl https://<host>.lsck0.dev | sh`
{
  # bootstrap.sh asks which machine on the terminal
  install-linux = "curl -fsSL https://raw.githubusercontent.com/lsck0/arch-dotfiles/master/bootstrap.sh | bash";
}
