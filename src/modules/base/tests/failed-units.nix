# every host reports the units that failed and stayed failed and those the boot target pulls in that stopped
# (modules/base), one series per unit, gone once it recovers, and whether it runs the generation sync.nu deployed
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
    systemd.services = {
      flaky = {
        serviceConfig.Type = "oneshot";
        script = "test -e /run/flaky-fixed";
      };
      steady = {
        wantedBy = [ "multi-user.target" ];
        script = "sleep infinity";
      };
      once = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.Type = "oneshot";
        script = "true";
      };
      kept = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = "true";
      };
      skipped = {
        wantedBy = [ "multi-user.target" ];
        unitConfig.ConditionPathExists = "/nonexistent";
        script = "sleep infinity";
      };
      watched.script = "true";
    };
    systemd.paths.watched = {
      wantedBy = [ "paths.target" ];
      pathConfig.PathExists = "/run/watched";
    };
  };

  testScript = ''
    import re

    vm_100.wait_for_unit("multi-user.target")

    def report():
        # reset-failed: the subtests start it faster than its start limit allows
        vm_100.succeed("systemctl reset-failed systemd-failed-units-metric && systemctl start systemd-failed-units-metric")
        return vm_100.succeed("cat ${metric}")

    with subtest("a failed unit is a series of its own"):
        vm_100.fail("systemctl start flaky")
        assert 'homelab_systemd_failed_units{unit="flaky.service"} 1' in report(), report()

    with subtest("a recovered unit leaves no series"):
        vm_100.succeed("touch /run/flaky-fixed && systemctl start flaky")
        assert "flaky" not in report(), report()

    with subtest("a failed unit whose file is gone leaves no series"):
        vm_100.succeed(
            "printf '[Service]\\nType=oneshot\\nExecStart=/run/current-system/sw/bin/false\\n' > /run/systemd/system/gone.service",
            "systemctl daemon-reload",
        )
        vm_100.fail("systemctl start gone")
        vm_100.succeed("rm /run/systemd/system/gone.service && systemctl daemon-reload")
        vm_100.succeed("systemctl --failed --plain --no-legend | grep -q '^gone.service not-found failed'")
        assert "gone" not in report(), report()

    def stopped():
        return sorted(re.findall(r'homelab_systemd_stopped_units\{unit="([^"]+)"\} 1', report()))

    with subtest("a booted host reports no stopped unit"):
        assert stopped() == [], report()

    with subtest("a unit the boot target pulls in that stopped is a series of its own"):
        vm_100.succeed("systemctl stop steady.service kept.service watched.path")
        assert stopped() == ["kept.service", "steady.service", "watched.path"], report()

    with subtest("a done oneshot and a unit whose condition failed are not stopped"):
        assert "once.service" not in stopped() and "skipped.service" not in stopped(), report()

    with subtest("a started unit leaves no series"):
        vm_100.succeed("systemctl start steady.service kept.service watched.path")
        assert stopped() == [], report()

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
