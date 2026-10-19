# vm-103's ntfy query (lib/notifications.nix) rendered by the real vm-201: a grafana webhook body with one resolved
# alert whose summary grafana left raw and one firing alert reads as the rule and its labels, marked over, and the
# firing summary as is with its runbook below it; the notification opens grafana's alert list.
{
  pkgs,
  lib,
  specialArgs,
  ...
}:
let
  lab = import ../../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
  ntfy = import ../../../../modules/ntfy.nix;
  notifications = import ../lib/notifications.nix {
    inherit lib;
    grafanaUrl = "https://grafana.test";
  };
  # ntfy tokens are tk_ and 29 of [a-z0-9]
  desktopToken = "tk_${lib.fixedWidthString 29 "0" "desktop"}";
  # the sops stub's value of a secret (tests/stubs/sops.nix)
  password = name: "test-${name}";
in
pkgs.testers.runNixOSTest {
  name = "ntfy-alerts";

  node.specialArgs = lab.specialArgs;
  nodes.vm-201 = {
    imports = [ (lab.guest "201" { instance = ../../201-external-ntfy/main.nix; }) ];
    testing.secretValues.ntfy-desktop-token = desktopToken;
  };

  testScript = ''
    import json

    offline = {"alertname": "Guest offline", "vm": "paperless", "severity": "critical", "category": "offline",
               "grafana_folder": "Homelab"}
    # restored after a restart and gone at the next evaluation: the summary is the rule's own text
    body = {
        "status": "firing",
        "commonAnnotations": {"firing": "Offline", "resolved": "Back online"},
        "alerts": [
            {"status": "resolved", "labels": offline, "annotations": {"summary": "{{ $labels.vm }} is offline"}},
            {"status": "firing", "labels": dict(offline, vm="nas"),
             "annotations": {"summary": "nas is offline", "description": "`qm list` on the host."}},
        ],
    }

    vm_201.wait_for_unit("ntfy-sh.service")
    vm_201.wait_for_open_port(80)
    vm_201.succeed(f"cat > /tmp/alert.json <<'EOF'\n{json.dumps(body)}\nEOF")
    vm_201.succeed("curl -sf -u grafana:${password "ntfy-grafana-password"} --data @/tmp/alert.json"
                   " 'http://127.0.0.1/${ntfy.topics.alerts}?${notifications.ntfyQuery}'")
    out = vm_201.succeed("curl -sf -u luca:${password "ntfy-admin-password"} 'http://127.0.0.1/${ntfy.topics.alerts}/json?poll=1'")
    alert = [json.loads(line) for line in out.splitlines() if line.strip()][-1]
    assert alert["title"] == "FIRING: Offline", alert
    assert alert["message"] == "${notifications.resolvedPrefix}Guest offline: vm=paperless\nnas is offline\n`qm list` on the host.", alert
    assert alert["click"] == "${notifications.alertListUrl}", alert
  '';
}
