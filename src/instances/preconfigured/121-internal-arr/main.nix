# the *arr media stack, one app per port (instance.nix services); imports land under /data/media: radarr movies,
# sonarr tv and anime, lidarr music, bazarr subtitles them
{ ... }:
{
  imports = [
    ./lib/servarr.nix
    ./lib/prowlarr.nix
    ./lib/recyclarr.nix
  ];

  homelab.servarr = {
    radarr.image = "lscr.io/linuxserver/radarr:6.4.4.10685-ls317@sha256:c960f2b52ec6542dbe6707c5a21e696a7c74fd8b17997454f4d10a55dacee133";
    sonarr.image = "lscr.io/linuxserver/sonarr:4.0.20.3014-ls325@sha256:a5c1a5fecbef946927ab90ad68df319ac5fe644057e5fc18cd993f01ac07b2b2";
    lidarr.image = "lscr.io/linuxserver/lidarr:3.1.0.4875-ls41@sha256:8ab0fd370b604ae034d9a9c261a9d8d873bece33d9736852e7ce4f3566e4a35d";
    bazarr = {
      image = "lscr.io/linuxserver/bazarr:v1.6.1-ls364@sha256:d24bd0048c759a468970989e9df11a6b96a7628d556d00f923e60a35ba59237b";
      configFormat = "yaml";
    };
  };
}
