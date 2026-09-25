# vm-104 alerting: the provisioned Grafana "Instance down" rule is Normal while everything
{ pkgs, lib, ... }:
pkgs.testers.runNixOSTest {
  name = "monitoring";

  nodes.target = {
    services.prometheus.exporters.node = { enable = true; openFirewall = true; };
  };

  nodes.monitor = {
    imports = [ ./stubs.nix ../instances/105-internal-grafana.nix ];
    _module.args.inventory = { };
    virtualisation.memorySize = 3072;
    environment.systemPackages = [ pkgs.curl pkgs.jq ];
    # scrape the test target instead of the lab subnets.
    services.prometheus.scrapeConfigs = lib.mkForce [{
      job_name = "homelab-node-exporter";
      scrape_interval = "10s";
      static_configs = [{ targets = [ "target:9100" ]; }];
    }];
  };

  testScript = ''
    import json

    def rule_state():
        out = vm_104.succeed(
            "curl -sf -H 'Remote-User: admin' http://127.0.0.1:80/api/prometheus/grafana/api/v1/rules"
        )
        for g in json.loads(out)["data"]["groups"]:
            for r in g["rules"]:
                if r["name"] == "Instance down":
                    return r["state"], r.get("health"), [a.get("labels", {}).get("instance") for a in r.get("alerts", [])]
        return None

    start_all()
    target.wait_for_open_port(9100)
    vm_104.wait_for_unit("prometheus.service")
    vm_104.wait_for_unit("grafana.service")
    vm_104.wait_for_open_port(80)

    with subtest("there is exactly one alerting path: no Alertmanager"):
        vm_104.fail("systemctl list-unit-files | grep -q '^alertmanager.service'")
        vm_104.fail("curl -sf --max-time 5 http://127.0.0.1:9093/api/v2/status")
        # and Prometheus has no alerting rules of its own to send anywhere.
        vm_104.wait_for_unit("prometheus.service")
        vm_104.succeed(
            "curl -sf http://127.0.0.1:9090/api/v1/rules | jq -e '.data.groups | length == 0'")

    with subtest("target is scraped"):
        vm_104.wait_until_succeeds(
            "curl -sf 'http://127.0.0.1:9090/api/v1/query?query=up' | jq -e '.data.result[0].value[1] == \"1\"'", timeout=120)

    with subtest("all up: Instance down is normal, not No data"):
        vm_104.wait_until_succeeds("curl -sf -H 'Remote-User: admin' http://127.0.0.1:80/api/prometheus/grafana/api/v1/rules | grep -q 'Instance down'", timeout=120)
        vm_104.sleep(150)  # a few 1m evaluations
        state = rule_state()
        print("state while up:", state)
        assert state[0] == "inactive" and state[1] == "ok", state

    with subtest("node-exporter down: Grafana alerts"):
        target.succeed("systemctl stop prometheus-node-exporter.service")
        vm_104.wait_until_succeeds(
            "curl -sf -H 'Remote-User: admin' http://127.0.0.1:80/api/prometheus/grafana/api/v1/rules"
            " | jq -e '.data.groups[].rules[] | select(.name==\"Instance down\") | .state == \"firing\"'", timeout=900)
        print("state while down:", rule_state())

    with subtest("the firing alert is sent to Telegram and ntfy, once each"):
        # no internet in the test VM: a failed delivery attempt through the
        # telegram integration proves the routing.
        cps = vm_104.succeed("curl -sf -H 'Remote-User: admin' http://127.0.0.1:80/api/v1/provisioning/contact-points")
        print(cps)
        assert '"telegram"' in cps and '"webhook"' in cps, cps
        # one receiver of each type, not two of either: a second one would mean
        # the duplicate-notification bug is back.
        assert cps.count('"telegram"') == 1 and cps.count('"webhook"') == 1, cps
        # the Telegram receiver carries the HTML template, not Grafana's default.
        assert "parse_mode" in cps and "FIRING" in cps, cps
        # ntfy is published to as a real user with its message template.
        assert "template=yes" in cps and "grafana" in cps, cps
        vm_104.wait_until_succeeds(
            "journalctl -u grafana | grep -i 'notif' | grep -qi telegram", timeout=300)

    with subtest("back up: resolves"):
        target.succeed("systemctl start prometheus-node-exporter.service")
        vm_104.wait_until_succeeds(
            "curl -sf -H 'Remote-User: admin' http://127.0.0.1:80/api/prometheus/grafana/api/v1/rules"
            " | jq -e '.data.groups[].rules[] | select(.name==\"Instance down\") | .state == \"inactive\"'", timeout=600)
  '';
}
