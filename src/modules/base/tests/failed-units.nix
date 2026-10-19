# every host reports the units that failed and stayed failed (modules/base), one series per unit, gone once it recovers,
# and whether it runs the generation sync.nu deployed
{
  pkgs,
  lib,
  inputs,
  specialArgs,
  ...
}:
let
  metric = "/var/lib/node-exporter-textfile/systemd_failed_units.prom";
  driftMetric = "/var/lib/node-exporter-textfile/system_drift.prom";
in
pkgs.testers.runNixOSTest {
  name = "failed-units";

  node.specialArgs = {
    inherit (specialArgs)
      inputs
      inventory
      site
      lab
      ;
  };
  nodes.vm-100 = {
    imports = [
      ../default.nix
      ../../egress-vpn.nix
      inputs.sops-nix.nixosModules.sops
      ../../../tests/stubs/platform.nix
    ];
    networking.hostName = "vm-100";
    networking.interfaces.eth0.ipv4.addresses = lib.mkForce [ ];
    networking.defaultGateway = lib.mkForce null;
    sops.validateSopsFiles = false;
    systemd.services.flaky = {
      serviceConfig.Type = "oneshot";
      script = "test -e /run/flaky-fixed";
    };
  };

  testScript = ''
    vm_100.wait_for_unit("multi-user.target")

    def report():
        vm_100.succeed("systemctl start systemd-failed-units-metric")
        return vm_100.succeed("cat ${metric}")

    with subtest("a failed unit is a series of its own"):
        vm_100.fail("systemctl start flaky")
        assert 'homelab_systemd_failed_units{unit="flaky.service"} 1' in report(), report()

    with subtest("a recovered unit leaves no series"):
        vm_100.succeed("touch /run/flaky-fixed && systemctl start flaky")
        assert "flaky" not in report(), report()

    with subtest("the timer keeps it fresh"):
        vm_100.succeed("systemctl is-active systemd-failed-units-metric.timer")

    def drift():
        vm_100.succeed("systemctl start system-drift-metric")
        return vm_100.succeed("cat ${driftMetric} 2>/dev/null || true")

    with subtest("a host sync.nu never deployed reports no drift"):
        assert drift() == "", drift()

    with subtest("the running system against the deployed one"):
        vm_100.succeed("mkdir -p /var/lib/homelab && readlink -f /run/current-system > /var/lib/homelab/deployed-toplevel")
        assert "homelab_system_drift 0" in drift(), drift()
        vm_100.succeed("echo /nix/store/00000000000000000000000000000000-nixos-system > /var/lib/homelab/deployed-toplevel")
        assert "homelab_system_drift 1" in drift(), drift()
  '';
}
