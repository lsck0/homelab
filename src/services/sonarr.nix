# sonarr: series -> tv, anime series -> anime
{ ... }: {
  homelab.servarr.sonarr = {
    image = "lscr.io/linuxserver/sonarr:4.0.20.3014-ls325";
    port = 8989;
    hostPort = 8989;
  };
}
