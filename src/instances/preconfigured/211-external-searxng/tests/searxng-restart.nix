# vm-211's searxng behind its host port across restarts: one inside a root login session and one after it ended
# (the deploy's ssh and its logout), and one after a container's teardown left its dnat rule behind (netavark's port
# rule ahead of the new container's). The edge reaches :80 every time and no teardown fails. Podman runs as it does in
# the unprivileged lxc, root taking itself for rootless. Images are pinned here and fetched at build time, nothing
# pulls at run time.
{
  pkgs,
  lib,
  inputs,
  specialArgs,
  ...
}:
let
  lab = import ../../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
  shippedConfig = inputs.self.nixosConfigurations."211-external-searxng".config;
  shipped = shippedConfig.virtualisation.oci-containers.containers;
  runtimeDir = shippedConfig.systemd.services.podman-searxng.environment.XDG_RUNTIME_DIR;
  inherit (shippedConfig.virtualisation.containers.storage.settings.storage) runroot;
  # podman's for uid 0, rootless or not; the alive file in it marks a boot
  libpodTmpDir = "/run/libpod";
  edge = lab.inventory."200";
  guest = lab.inventory."211";
  network = "searxng";
  # a container address nothing holds: the stale rule's target
  deadTarget = "10.89.204.250";

  imageOf =
    {
      container,
      hash,
    }:
    let
      parts = lib.splitString "@" shipped.${container}.image;
      name = lib.head parts;
      repository = lib.head (lib.splitString ":" name);
    in
    {
      inherit name;
      file = pkgs.dockerTools.pullImage {
        imageName = repository;
        imageDigest = lib.last parts;
        inherit hash;
        finalImageName = repository;
        finalImageTag = lib.last (lib.splitString ":" name);
        os = "linux";
        arch = "amd64";
      };
    };
  # bump with the instance (nix-prefetch-docker, see tests/lib/images.nix): a stale hash fails the fetch
  images = {
    searxng = imageOf {
      container = "searxng";
      hash = "sha256-DZiiLOf+EmjmdBKgg1vr1+uvseARu2+4iw3sgwbi5MA=";
    };
    searxng-valkey = imageOf {
      container = "searxng-valkey";
      hash = "sha256-BRaselrq/jeRYAMr768OfC1a15gPh443q+XfEeuiqYU=";
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "searxng-restart";

  node.specialArgs = lab.specialArgs;
  nodes.vm-211 = {
    imports = [ (lab.guest "211" { instance = ../main.nix; }) ];
    virtualisation = {
      memorySize = 2048;
      diskSize = 4096;
    };
    # no collector in this test
    services.journald.upload.enable = lib.mkForce false;
    # what the lxc's partial uid map does: storage's unshare takes root for rootless, and the netns go to the runtime dir
    systemd.globalEnvironment._CONTAINERS_USERNS_CONFIGURED = "1";
    virtualisation.oci-containers.containers = lib.mapAttrs (_: i: {
      image = lib.mkForce i.name;
      imageFile = i.file;
    }) images;
  };

  nodes.edge = lab.multi {
    addresses = [ "${edge.ip}/${toString guest.prefix}" ];
    vlan = lab.vlans.external;
  };

  testScript = ''
    def restart():
        vm_211.succeed("systemctl restart podman-searxng.service")
        vm_211.wait_for_unit("podman-searxng.service")
        edge.wait_until_succeeds("curl -sf -m 5 http://${guest.ip}/healthz", timeout=180)
        vm_211.fail("journalctl -u podman-searxng.service | grep -F 'Control process exited'")

    def nat_rules(pattern):
        return vm_211.succeed(f"iptables-save -t nat | grep -e '{pattern}' || true").strip()

    start_all()
    vm_211.wait_for_unit("podman-searxng.service")
    edge.wait_until_succeeds("curl -sf -m 5 http://${guest.ip}/healthz", timeout=300)

    with subtest("a restart inside a root login session and one after it ended keep the host port"):
        vm_211.succeed("systemd-run --unit=root-session -p PAMName=login -p User=root sleep infinity")
        vm_211.wait_until_succeeds("findmnt /run/user/0")
        restart()
        vm_211.succeed("systemctl stop root-session.service")
        vm_211.wait_until_fails("findmnt /run/user/0")
        restart()
        sandbox = vm_211.succeed("podman inspect -f '{{.NetworkSettings.SandboxKey}}' searxng").strip()
        assert sandbox.startswith("${runtimeDir}/netns/"), sandbox
        assert vm_211.succeed("podman info -f '{{.Store.RunRoot}}'").strip() == "${runroot}"
        vm_211.succeed("test -e ${libpodTmpDir}/alive")

    with subtest("a dnat rule a failed teardown left ahead of the new container's is cleared on start"):
        current = vm_211.succeed("podman inspect -f '{{.Id}}' searxng").strip()
        jump = f"dnat name: ${network} id: {current}"
        assert nat_rules(jump), "netavark's port rules carry no comment the cleanup matches"
        stale = "0" * 64
        vm_211.succeed(
            f"{{ echo '*nat'; iptables-save -t nat | grep -e '{jump}' -e '^-A NETAVARK-DN-.* -j DNAT '"
            f" | sed -e 's/{current}/{stale}/' -e 's/--to-destination [0-9.]*:/--to-destination ${deadTarget}:/';"
            " echo COMMIT; } | iptables-restore --noflush")
        assert nat_rules(stale) and nat_rules("${deadTarget}")
        restart()
        assert not nat_rules(stale) and not nat_rules("${deadTarget}"), nat_rules("NETAVARK")
  '';
}
