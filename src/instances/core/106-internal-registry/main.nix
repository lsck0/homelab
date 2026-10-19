# the image registry and its ui
#
# security: the registry checks the ingress's users again with its own htpasswd, so a guest that reaches the port
# gets nothing without them.
# registry-gc: collects offline, so a concurrent push cannot lose blobs. Tags are pruned on disk: the api's DELETE
# drops every tag on a digest, and it has no push time (dockerTools images say created 1970).
# workaround: the gc runs registry 3.0, not the serving 2.8.3, whose --delete-untagged also deletes the per-platform
# manifests an oci index points to (buildkit attestations, containerd store), leaving those images unpullable. Delete
# once the serving registry is 3.x.
{
  config,
  lib,
  pkgs,
  catalog,
  hostIp,
  nasMount,
  ...
}:
let
  apiPort = catalog.internal.registry-api.port;
  uiPort = catalog.internal.registry-ui.port;
  stateDir = "/var/lib/registry";

  htpasswd = import ../../../modules/traefik/lib/htpasswd.nix { inherit pkgs lib; };
  authDir = "/run/registry-auth";
  authMount = "/auth";
  # the ui's proxy on this guest (deletes included, which no ingress route carries) gets a password of its own, new
  # with every start: nothing outside this guest ever needs it
  users = catalog.internal.registry-api.basicAuth;
  uiUser = "ui";
  uiPasswordBytes = 24;

  # pinned and in the store: the 03:30 run never pulls. Refill: nix run nixpkgs#nix-prefetch-docker -- --image-name
  # registry --image-tag <tag> --os linux --arch amd64
  gcImageName = "registry";
  gcImageTag = "3.0.0";
  gcImage = pkgs.dockerTools.pullImage {
    imageName = gcImageName;
    imageDigest = "sha256:6c5666b861f3505b116bb9aa9b25175e71210414bd010d92035ff64018f9457e";
    hash = "sha256-v2O/H7Zz5hNB84N0kSktoa9bzQB55NWBQ8Q6qlmY1gw=";
    finalImageName = gcImageName;
    finalImageTag = gcImageTag;
    os = "linux";
    arch = "amd64";
  };

  registryPrune = pkgs.writeShellApplication {
    name = "registry-prune";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gawk
    ];
    text = ''
      # besides latest: the last ten builds to roll back to
      KEEP_COUNT=10
      repositories=''${1:-${stateDir}/docker/registry/v2/repositories}
      [ -d "$repositories" ] || exit 0
      # repository names nest (team/app), so a repository is any dir holding _manifests/tags
      find "$repositories" -type d -path '*/_manifests/tags' -prune -print | while IFS= read -r tags; do
        # current/link is written when the tag gets a new digest, so its mtime is the push time
        find "$tags" -mindepth 3 -maxdepth 3 -path '*/current/link' -printf '%T@ %h\n' \
          | sort -rn | cut -d' ' -f2- \
          | awk -v keep="$KEEP_COUNT" '{ sub(/\/current$/, "") } !/\/latest$/ && ++n > keep' \
          | while IFS= read -r tag; do
              echo "untag ''${tag#"$repositories"/}"
              rm -rf "$tag"
            done
      done
    '';
  };
in
{
  homelab.nasMounts = nasMount stateDir "registry";

  virtualisation.oci-containers.containers.registry = {
    image = "registry:2.8.3@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373";
    ports = [ "${toString apiPort}:5000" ];
    volumes = [
      "${stateDir}:/var/lib/registry"
      "${authDir}:${authMount}:ro"
    ];
    environment = {
      REGISTRY_AUTH = "htpasswd";
      REGISTRY_AUTH_HTPASSWD_REALM = "registry";
      REGISTRY_AUTH_HTPASSWD_PATH = "${authMount}/htpasswd";
      # without this the registry 405s on DELETE, so the ui delete button fails
      REGISTRY_STORAGE_DELETE_ENABLED = "true";
      REGISTRY_HTTP_HEADERS_Access-Control-Allow-Origin = "[\"*\"]";
      REGISTRY_HTTP_HEADERS_Access-Control-Allow-Methods = "[\"HEAD\", \"GET\", \"OPTIONS\", \"DELETE\"]";
    };
  };

  virtualisation.oci-containers.containers.registry-ui = {
    image = "joxit/docker-registry-ui:2.6.0@sha256:bb5956a6b378706f1c3a92c947d0a0c606e280460cd9e37c0198caf46399c839";
    ports = [ "${toString uiPort}:80" ];
    environment = {
      REGISTRY_TITLE = "Homelab Registry";
      SINGLE_REGISTRY = "true";
      DELETE_IMAGES = "true";
      NGINX_PROXY_PASS_URL = "http://${hostIp}:${toString apiPort}";
    };
    # NGINX_PROXY_HEADER_Authorization: the ui's credential on every request it proxies
    environmentFiles = [ "${authDir}/ui.env" ];
  };

  sops.secrets = lib.genAttrs (lib.unique (lib.attrValues users)) (_: {
    restartUnits = [ "registry-auth.service" ];
  });
  systemd.services.registry-auth = {
    description = "Render the registry's users and the ui's credential";
    before = [
      "podman-registry.service"
      "podman-registry-ui.service"
    ];
    requiredBy = [
      "podman-registry.service"
      "podman-registry-ui.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      RuntimeDirectory = baseNameOf authDir;
      RuntimeDirectoryMode = "0700";
    };
    path = [ pkgs.coreutils ];
    # printf is a builtin: a password reaches htpasswd and base64 on their stdin, never an argv
    script = ''
      set -euo pipefail
      umask 077
      head -c ${toString uiPasswordBytes} /dev/urandom | base64 -w0 > ${authDir}/ui.password
    ''
    + htpasswd.render "${authDir}/htpasswd" (
      lib.mapAttrs (_: secret: config.sops.secrets.${secret}.path) users // { ${uiUser} = "${authDir}/ui.password"; }
    )
    + ''
      printf 'NGINX_PROXY_HEADER_Authorization=Basic %s\n' \
        "$(printf '%s:%s' ${uiUser} "$(cat ${authDir}/ui.password)" | base64 -w0)" > ${authDir}/ui.env.tmp
      mv ${authDir}/ui.env.tmp ${authDir}/ui.env
      rm ${authDir}/ui.password
    '';
  };
  # a new ui password or a rotated user restarts both
  systemd.services.podman-registry.partOf = [ "registry-auth.service" ];
  systemd.services.podman-registry-ui.partOf = [ "registry-auth.service" ];

  systemd.services.registry-gc = {
    description = "Prune old registry tags and reclaim their blobs";
    path = [
      pkgs.podman
      pkgs.systemd
      registryPrune
    ];
    serviceConfig = {
      Type = "oneshot";
      # a hung prune or gc must not leave the registry down: systemd stops the run, ExecStopPost restarts it
      TimeoutStartSec = "1h";
      ExecStopPost = "${pkgs.systemd}/bin/systemctl start podman-registry";
    };
    script = ''
      systemctl stop podman-registry
      registry-prune
      podman load -q -i ${gcImage}
      podman run --rm --pull=never -v ${stateDir}:/var/lib/registry ${gcImageName}:${gcImageTag} \
        garbage-collect --delete-untagged /etc/distribution/config.yml
    '';
  };
  systemd.timers.registry-gc = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "03:30";
      Persistent = true;
    };
  };

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 1000 1000 -"
  ];
}
