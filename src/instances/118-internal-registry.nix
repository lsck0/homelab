{ pkgs, nasMount, ... }: {
  networking.hostName = "vm-118";

  fileSystems = nasMount "/var/lib/registry" "registry";

  virtualisation.oci-containers.containers.registry = {
    image = "registry:2.8.3";
    ports = [ "5000:5000" ];
    volumes = [ "/var/lib/registry:/var/lib/registry" ];
    environment = {
      # without this the registry 405s on DELETE, so the ui delete button fails
      REGISTRY_STORAGE_DELETE_ENABLED = "true";
      REGISTRY_HTTP_HEADERS_Access-Control-Allow-Origin = "[\"*\"]";
      REGISTRY_HTTP_HEADERS_Access-Control-Allow-Methods = "[\"HEAD\", \"GET\", \"OPTIONS\", \"DELETE\"]";
    };
  };

  virtualisation.oci-containers.containers.registry-ui = {
    image = "joxit/docker-registry-ui:2.6.0";
    ports = [ "80:80" ];
    environment = {
      REGISTRY_TITLE = "Homelab Registry";
      SINGLE_REGISTRY = "true";
      DELETE_IMAGES = "true";
      NGINX_PROXY_PASS_URL = "http://10.100.0.118:5000";
    };
  };

  # ci pushes :latest and :<sha> per build, so tags pile up forever; keep latest and the newest few, then gc
  # offline (registry stopped so a concurrent push cannot lose blobs). --delete-untagged drops the manifests no tag
  # names any more (pruned, ui-deleted), so a digest latest points to always survives.
  # pruned on disk, not through the http api: DELETE takes a digest and drops every tag on it, and the api has no
  # push time (the config's created is 1970 for reproducible builds such as dockerTools).
  systemd.services.registry-gc = let
    registryPrune = pkgs.writeShellApplication {
      name = "registry-prune";
      runtimeInputs = [ pkgs.coreutils pkgs.findutils pkgs.gawk ];
      text = ''
        # tags kept per repository besides latest: one :<sha> per ci build, so the last ten builds to roll back to
        KEEP_COUNT=10
        repositories=''${1:-/var/lib/registry/docker/registry/v2/repositories}
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
    description = "Prune old registry tags and reclaim their blobs";
    path = [ pkgs.podman pkgs.systemd registryPrune ];
    serviceConfig.Type = "oneshot";
    script = ''
      systemctl stop podman-registry
      # a failed prune must not leave the registry down
      trap 'systemctl start podman-registry' EXIT
      registry-prune
      # 3.x, not the serving 2.8.3: 2.8's --delete-untagged also deletes the untagged per-platform manifests an
      # index points to, so every image docker pushes as an oci index (buildkit attestations,
      # containerd store) became unpullable; reproduced with both on 2026-10-05, 3.0 keeps them. same storage layout.
      podman run --rm -v /var/lib/registry:/var/lib/registry registry:3.0.0 \
        garbage-collect --delete-untagged /etc/distribution/config.yml || true
    '';
  };
  systemd.timers.registry-gc = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "03:30"; Persistent = true; };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/registry 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 5000 ];

  # the registry has no auth of its own: only the ingress reaches it, and gates pushes (100-internal-traefik.nix)
  homelab.ingressOnly.ports = [ 80 5000 ];
}
