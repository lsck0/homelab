# the *arr media stack, one app per port (instance.nix services); imports land under /data/media: radarr movies,
# sonarr tv and anime, lidarr music, bazarr subtitles them
{ ... }: {
  imports = [
    ./lib/servarr.nix
    ./lib/prowlarr.nix
    ./lib/recyclarr.nix
  ];

  homelab.servarr = {
    radarr.image = "lscr.io/linuxserver/radarr:6.4.4.10685-ls317";
    sonarr.image = "lscr.io/linuxserver/sonarr:4.0.20.3014-ls325";
    lidarr.image = "lscr.io/linuxserver/lidarr:3.1.0.4875-ls41";
    bazarr = {
      image = "lscr.io/linuxserver/bazarr:v1.6.1-ls364";
      configFormat = "yaml";
    };
  };
}
