# lidarr: music -> /data/media/music
{ ... }: {
  homelab.servarr.lidarr = {
    image = "lscr.io/linuxserver/lidarr:3.1.0.4875-ls41";
    port = 8686;
    hostPort = 8686;
  };
}
