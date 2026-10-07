# vm-105, the real instance at its real address, among three lab guests: the ingress (vm-100), a guest the ingress
# guard admits but grafana must not trust (vm-103, the dashboard), and a guest to watch (vm-121). Checks that every
# provisioned rule evaluates, the boards are there, only the ingress may name a grafana user, prometheus is read-only
# from other hosts, the watchdog beats, and a guest going down pages through both contact points and resolves.
{ pkgs, lib, specialArgs, ... }:
let
  lab = import ../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
  telemetry = import ../../../modules/telemetry.nix { inherit lib; inherit (lab) inventory; };
  inherit (telemetry) ports;
  collector = lab.inventory.${telemetry.collectorVmid}.ip;
  watched = lab.inventory."121";
  # from the other guests; on vm-105 itself grafana trusts the header from loopback only
  grafanaApi = "http://${collector}:${toString ports.grafana}/api";
  localApi = "http://127.0.0.1:${toString ports.grafana}/api";
  prometheus = "http://${collector}:${toString ports.prometheus}";
  rules = "${localApi}/prometheus/grafana/api/v1/rules";
  # what the notifier holds: alerts past their `for`, the ones that page
  activeAlerts = "${localApi}/alertmanager/grafana/api/v2/alerts?active=true";
in
pkgs.testers.runNixOSTest {
  name = "monitoring";

  node.specialArgs = lab.specialArgs;
  nodes.vm-105 = {
    imports = [ (lab.guest telemetry.collectorVmid { flat = true; instance = ../main.nix; }) ];
    virtualisation.memorySize = 3072;
    environment.systemPackages = [ pkgs.curl pkgs.jq ];
    # an empty nas copy for grafana-seed (the nas shares are local dirs, lib/nas-local.nix); rsync -a hands its owner
    # to /var/lib/grafana
    systemd.tmpfiles.rules = [ "d /srv/grafana-nas 0700 grafana grafana -" ];
  };
  nodes.vm-100 = { imports = [ (lab.guest "100" { flat = true; }) ]; environment.systemPackages = [ pkgs.curl ]; };
  nodes.vm-103 = { imports = [ (lab.guest "103" { flat = true; }) ]; environment.systemPackages = [ pkgs.curl ]; };
  nodes.vm-121 = { imports = [ (lab.guest "121" { flat = true; }) ]; environment.systemPackages = [ pkgs.curl ]; };

  testScript = ''
    import json

    def rules_state():
        out = vm_105.succeed("curl -sf -H 'Remote-User: admin' ${rules}")
        return [r for g in json.loads(out)["data"]["groups"] for r in g["rules"]]

    def active(alertname, vm):
        """the jq filter of the notifier's active alerts named alertname on vm"""
        return (f"curl -sf -H 'Remote-User: admin' '${activeAlerts}' | jq -e '[.[] | select(.labels.alertname==\"{alertname}\""
                f" and .labels.vm==\"{vm}\")] | length")

    start_all()
    vm_105.wait_for_unit("prometheus.service")
    vm_105.wait_for_unit("grafana.service")
    vm_105.wait_for_unit("nginx.service")
    vm_105.wait_for_open_port(${toString ports.grafana})
    vm_105.wait_for_open_port(${toString ports.prometheus})
    vm_121.wait_for_open_port(9100)

    with subtest("the whole pipeline runs: every unit monitoring_unit_down watches is active"):
        for unit in ("loki", "tempo", "pyroscope", "promtail", "systemd-journal-remote", "prometheus-blackbox-exporter"):
            vm_105.wait_for_unit(f"{unit}.service")

    with subtest("there is exactly one alerting path: no Alertmanager, no prometheus rules"):
        vm_105.fail("systemctl list-unit-files | grep -q '^alertmanager.service'")
        vm_105.succeed("curl -sf ${prometheus}/api/v1/rules | jq -e '.data.groups | length == 0'")

    with subtest("every provisioned rule evaluates: a typo or a renamed metric shows as health error"):
        vm_105.wait_until_succeeds(
            "curl -sf -H 'Remote-User: admin' ${rules}"
            " | jq -e '[.data.groups[].rules[] | select(.lastEvaluation | startswith(\"0001\") | not)] | length > 20'",
            timeout=300)
        broken = [(r["name"], r.get("lastError")) for r in rules_state() if r.get("health") == "error"]
        assert not broken, broken

    with subtest("the boards are provisioned"):
        boards = json.loads(vm_105.succeed("curl -sf -H 'Remote-User: admin' '${localApi}/search?type=dash-db'"))
        uids = {b["uid"] for b in boards}
        assert {"homelab", "energy"} <= uids, uids

    with subtest("only the ingress and vm-105 itself may name the grafana user"):
        vm_100.succeed("curl -sf -H 'Remote-User: admin' ${grafanaApi}/user | grep -q '\"login\":\"admin\"'")
        vm_105.succeed("curl -sf -H 'Remote-User: admin' ${localApi}/user | grep -q '\"login\":\"admin\"'")
        # vm-103 passes the ingress guard (its status dots; positive control: it gets an answer), but its header is no login
        status = vm_103.succeed("curl -s -o /dev/null -w '%{http_code}' -H 'Remote-User: admin' ${grafanaApi}/user").strip()
        assert status == "401", status

    with subtest("prometheus answers queries to other hosts and takes writes on loopback only"):
        vm_103.succeed("curl -sf '${prometheus}/api/v1/query?query=up' | grep -q success")
        vm_103.succeed("curl -sf --data-urlencode 'query=up' ${prometheus}/api/v1/query | grep -q success")
        status = vm_103.succeed("curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary x ${prometheus}/api/v1/write").strip()
        assert status == "403", status
        status = vm_103.succeed("curl -s -o /dev/null -w '%{http_code}' -X POST ${prometheus}/api/v1/admin/tsdb/snapshot").strip()
        assert status == "403", status
        # the receiver itself is up for tempo: a body that is no snappy protobuf is a bad request, not a refusal
        status = vm_105.succeed("curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/x-protobuf'"
                                " -H 'Content-Encoding: snappy' -X POST --data-binary x"
                                " http://127.0.0.1:${toString ports.prometheusLocal}/api/v1/write").strip()
        assert status == "400", status
        # a guest outside the port's sources does not get through the guard at all
        vm_121.fail("curl -sf --max-time 5 '${prometheus}/api/v1/query?query=up'")

    with subtest("the watchdog fires and beats to its own contact point only"):
        vm_105.wait_until_succeeds(
            "curl -sf -H 'Remote-User: admin' ${rules} | jq -e '.data.groups[].rules[] | select(.name==\"Watchdog\") | .state == \"firing\"'",
            timeout=300)
        # no internet: the failed delivery in the log proves the route
        vm_105.wait_until_succeeds("journalctl -u grafana | grep -i 'heartbeat' | grep -qi 'notif\\|webhook\\|deliver'", timeout=300)

    with subtest("a guest meant to run is up: no alert for it"):
        vm_105.wait_until_succeeds(
            "curl -sfG ${prometheus}/api/v1/query --data-urlencode 'query=up{vm=\"paperless\"}'"
            " | jq -e '.data.result[0].value[1] == \"1\"'",
            timeout=180)
        vm_105.succeed(active("Guest offline", "paperless") + " == 0'")

    with subtest("node-exporter down: Guest offline pages through telegram and ntfy"):
        vm_121.succeed("systemctl stop prometheus-node-exporter.service")
        vm_105.wait_until_succeeds(active("Guest offline", "paperless") + " == 1'", timeout=900)
        cps = vm_105.succeed("curl -sf -H 'Remote-User: admin' ${localApi}/v1/provisioning/contact-points")
        # one receiver of each kind: a second means duplicate notifications
        assert cps.count('"type":"telegram"') == 1 and cps.count('"type":"webhook"') == 2, cps
        assert "parse_mode" in cps and "template=yes" in cps, cps
        vm_105.wait_until_succeeds("journalctl -u grafana | grep -i 'notif' | grep -qi telegram", timeout=300)

    with subtest("back up: resolves"):
        vm_121.succeed("systemctl start prometheus-node-exporter.service")
        vm_105.wait_until_succeeds(active("Guest offline", "paperless") + " == 0'", timeout=600)
  '';
}
