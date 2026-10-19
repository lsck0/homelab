# the platform's static sites (modules/apps-catalog `static`): one server image for every site, and the image a
# site's build runs in, its toolchain bind-mounted from this host's store (lib/app-builder.py static_site_build)
{ pkgs, lib }:
let
  # what the builder copies a site into, and serves it from
  root = "/srv/site";
  # the swarm backend's default target port (modules/service.nix): a static app's route names none
  port = 8000;
  # nobody: the server writes nothing and owns nothing
  user = "65534:65534";

  # html, css, js and the pdf are rebuilt in place: revalidated on every load, a 304 when unchanged. Fonts and
  # images keep their bytes under one name (lwarp names its images by content hash)
  cacheRevalidate = "no-cache";
  cacheLong = "public, max-age=31536000";
  longExtensions = [
    "woff"
    "woff2"
    "otf"
    "ttf"
    "svg"
    "png"
    "jpg"
    "jpeg"
    "gif"
    "webp"
    "avif"
    "ico"
  ];

  serverConfig = (pkgs.formats.toml { }).generate "static-web-server.toml" {
    general = {
      host = "0.0.0.0";
      inherit port root;
      # gzip, brotli and zstd as the client accepts; the edge's compress middleware leaves an encoded body alone
      compression = true;
      directory-listing = false;
      # its own guesses would override the headers below
      cache-control-headers = false;
      # the edge sets them for every route (secureHeaders)
      security-headers = false;
      log-level = "warn";
      health = true;
    };
    advanced.headers = [
      {
        source = "**/*";
        headers.Cache-Control = cacheRevalidate;
      }
      {
        source = "**/*.{${lib.concatStringsSep "," longExtensions}}";
        headers.Cache-Control = cacheLong;
      }
    ];
  };

  serverImage = pkgs.dockerTools.buildLayeredImage {
    name = "static-site-server";
    contents = [ pkgs.dockerTools.fakeNss ];
    extraCommands = "mkdir -p .${root}";
    config = {
      Entrypoint = [
        (lib.getExe pkgs.static-web-server)
        "--config-file"
        "${serverConfig}"
      ];
      User = user;
      ExposedPorts."${toString port}/tcp" = { };
    };
  };

  # empty but for names: the toolchain's bin becomes /bin and /usr/bin at run time, the store is mounted read-only
  buildImage = pkgs.dockerTools.buildImage {
    name = "static-site-build";
    copyToRoot = [ pkgs.dockerTools.fakeNss ];
  };

  toolchainOf =
    name: packages:
    pkgs.buildEnv {
      name = "static-site-toolchain-${name}";
      paths = [
        pkgs.bash
        pkgs.coreutils
      ]
      ++ packages pkgs;
      pathsToLink = [ "/bin" ];
    };

  imageRef = image: "${image.imageName}:${image.imageTag}";
in
{
  inherit root toolchainOf;
  server = {
    archive = "${serverImage}";
    ref = imageRef serverImage;
  };
  build = {
    archive = "${buildImage}";
    ref = imageRef buildImage;
  };
}
