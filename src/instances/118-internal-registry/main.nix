# the image registry and its ui; no auth of its own: only the ingress reaches it, and gates pushes (100-internal-traefik)
#
# registry-gc: ci pushes :latest and :<sha> per build, the app builder :<sha> per build and :latest per good deploy
# (what the swarm runs), so tags pile up; the gc keeps latest and the newest few, then collects offline (registry
# stopped, so a concurrent push cannot lose blobs). --delete-untagged drops the manifests no tag names any more, so a
# digest latest points to always survives. Tags are pruned on disk, not through the http api: DELETE takes a digest
# and drops every tag on it, and the api has no push time (the config's created is 1970 for reproducible builds such
# as dockerTools). The gc runs registry 3.x, not the serving 2.8.3: 2.8's --delete-untagged also deletes the untagged
# per-platform manifests an index points to, so every image docker pushes as an oci index (buildkit attestations,
# containerd store) became unpullable; reproduced with both on 2026-10-05, 3.0 keeps them, same storage layout.
{ pkgs, catalog, hostIp, nasMount, ... }:
let
  apiPort = catalog.internal.registry-api.port;
  uiPort = catalog.internal.registry-ui.port;
  stateDir = "/var/lib/registry";

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
    runtimeInputs = [ pkgs.coreutils pkgs.findutils pkgs.gawk ];
    text = ''
      # tags kept per repository besides latest: one :<sha> per ci build, so the last ten builds to roll back to
      KEEP_COUNT=10
      repositories=''${1:-${stateDir}/docker/registry/v2/repositories}
      [ -d "$repositories" ] || exit 0
      # repository names nest (team/app), so a repository is any dir holding _manifests/tags
      find "$repositories" -type d -path '*/_manifests/tags' -prune -print | while IFS= read -r tags; do
        # current/link is written when the tag gets a new digest, so its mtime is the push time; newest first
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
in {
  networking.hostName = "vm-118";

  homelab.nasMounts = nasMount stateDir "registry";

  virtualisation.oci-containers.containers.registry = {
    image = "registry:2.8.3";
    ports = [ "${toString apiPort}:5000" ];
    volumes = [ "${stateDir}:/var/lib/registry" ];
    environment = {
      # without this the registry 405s on DELETE, so the ui delete button fails
      REGISTRY_STORAGE_DELETE_ENABLED = "true";
      REGISTRY_HTTP_HEADERS_Access-Control-Allow-Origin = "[\"*\"]";
      REGISTRY_HTTP_HEADERS_Access-Control-Allow-Methods = "[\"HEAD\", \"GET\", \"OPTIONS\", \"DELETE\"]";
    };
  };

  virtualisation.oci-containers.containers.registry-ui = {
    image = "joxit/docker-registry-ui:2.6.0";
    ports = [ "${toString uiPort}:80" ];
    environment = {
      REGISTRY_TITLE = "Homelab Registry";
      SINGLE_REGISTRY = "true";
      DELETE_IMAGES = "true";
      NGINX_PROXY_PASS_URL = "http://${hostIp}:${toString apiPort}";
    };
  };

  systemd.services.registry-gc = {
    description = "Prune old registry tags and reclaim their blobs";
    path = [ pkgs.podman pkgs.systemd registryPrune ];
    serviceConfig.Type = "oneshot";
    script = ''
      systemctl stop podman-registry
      # a failed prune must not leave the registry down
      trap 'systemctl start podman-registry' EXIT
      registry-prune
      podman load -q -i ${gcImage}
      podman run --rm --pull=never -v ${stateDir}:/var/lib/registry ${gcImageName}:${gcImageTag} \
        garbage-collect --delete-untagged /etc/distribution/config.yml
    '';
  };
  systemd.timers.registry-gc = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "03:30"; Persistent = true; };
  };

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ uiPort apiPort ];
  homelab.ingressOnly.ports = [ uiPort apiPort ];
}
