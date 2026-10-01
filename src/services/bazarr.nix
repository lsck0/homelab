# bazarr: subtitles for radarr and sonarr
{ ... }: {
  homelab.servarr.bazarr = {
    image = "lscr.io/linuxserver/bazarr:v1.6.1-ls364";
    port = 6767;
    configFormat = "yaml";
  };
}
