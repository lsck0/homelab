# container images for test vms, all in the store: nothing pulls at run time
#
# The images the lab pulls from docker hub are pinned by digest and hash here (fixed-output, fetched once at build
# time); stand-ins are built from nixpkgs. Set one as the real container's imageFile, keeping the real image name:
#
#   images = import ./images.nix { inherit pkgs; };
#   virtualisation.oci-containers.containers.registry.imageFile = images.registry;      # on the real vm-118
#   virtualisation.oci-containers.containers.registry-ui.imageFile = images.registry-ui;
#
# A pinned image changes with its instance: bump the tag there, then refill digest and hash here with
# `nix run nixpkgs#nix-prefetch-docker -- --image-name <name> --image-tag <tag> --os linux --arch amd64`.
{ pkgs }:
let
  labprobe = import ./labprobe.nix { inherit pkgs; };
in {
  # instances/118-internal-registry/main.nix
  registry = pkgs.dockerTools.pullImage {
    imageName = "registry";
    imageDigest = "sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373";
    hash = "sha256-pHt+Uy6fRV95BxoUAPOe/IjotDHpH6QUxqL7SD9qugI=";
    finalImageName = "registry";
    finalImageTag = "2.8.3";
    os = "linux";
    arch = "amd64";
  };
  registry-ui = pkgs.dockerTools.pullImage {
    imageName = "joxit/docker-registry-ui";
    imageDigest = "sha256:bb5956a6b378706f1c3a92c947d0a0c606e280460cd9e37c0198caf46399c839";
    hash = "sha256-nF2ptBF5at6AwPueDDUuW46qV0Swnz9LLiu0YM2UE4k=";
    finalImageName = "joxit/docker-registry-ui";
    finalImageTag = "2.6.0";
    os = "linux";
    arch = "amd64";
  };

  # labprobe inside a container: a probe from a container's network namespace (ci jobs, swarm tasks)
  labprobe = pkgs.dockerTools.buildLayeredImage {
    name = "labprobe";
    tag = "test";
    contents = [ labprobe pkgs.busybox ];
    config.Entrypoint = [ "/bin/labprobe" ];
  };

  # the crowdsec container of modules/traefik, answering the bouncer plugin (lib/crowdsec-stub.py); cscli
  # answers the bouncer registration and nothing else
  crowdsec-stub = pkgs.dockerTools.buildLayeredImage {
    name = "crowdsec-stub";
    tag = "test";
    contents = [
      pkgs.busybox
      (pkgs.writeShellScriptBin "cscli" ''
        case "$*" in
          "bouncers list -o json") echo '[{"name": "traefik-bouncer"}]' ;;
          *) echo "crowdsec-stub: cscli $*" >&2 ;;
        esac
      '')
    ];
    config = {
      Cmd = [ "${pkgs.python3}/bin/python3" "${./crowdsec-stub.py}" ];
      Env = [ "PATH=/bin" ];
    };
  };
}
