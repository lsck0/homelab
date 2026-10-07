# vm-203's ntfy as it ships (instances/203-external-ntfy/main.nix): the declared accounts and their topic grants, an
# account made by hand removed on the next start, the heartbeat check alerting once per outage and clearing when
# the beat is back, and the ingress guard admitting the edge alone. The expected grants are stated here.
{ pkgs, lib, specialArgs, ... }:
let
  lab = import ../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
  ntfy = import ../../../modules/ntfy.nix;
  inherit (ntfy) topics;

  edge = lab.inventory."200".ip;
  # another dmz guest: it must not reach ntfy past the edge
  peer = lab.inventory."208".ip;
  # ntfy tokens are tk_ and 29 of [a-z0-9]
  desktopToken = "tk_${lib.fixedWidthString 29 "0" "desktop"}";
  # the sops stub's value of a secret (tests/stubs/sops.nix)
  password = name: "test-${name}";
in
pkgs.testers.runNixOSTest {
  name = "ntfy";

  node.specialArgs = lab.specialArgs;
  nodes.vm-203 = {
    imports = [ (lab.guest "203" { instance = ../main.nix; }) ];
    testing.secretValues.ntfy-desktop-token = desktopToken;
  };
  nodes.edge = { imports = [ (lab.multi { addresses = [ "${edge}/24" ]; vlan = lab.vlans.external; }) ];
                 environment.systemPackages = [ pkgs.curl ]; };
  nodes.peer = { imports = [ (lab.multi { addresses = [ "${peer}/24" ]; vlan = lab.vlans.external; }) ];
                 environment.systemPackages = [ pkgs.curl ]; };

  testScript = ''
    import json

    passwords = {"luca": "${password "ntfy-admin-password"}", "grafana": "${password "ntfy-grafana-password"}",
                 "hermes": "${password "ntfy-hermes-password"}"}

    def publish(user, topic, auth=None):
        auth = auth or f"-u {user}:{passwords[user]}"
        return vm_203.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' {auth} -d hi http://127.0.0.1/{topic}").strip()

    def messages(topic, since="all"):
        out = vm_203.succeed(f"curl -sf -u luca:${password "ntfy-admin-password"} 'http://127.0.0.1/{topic}/json?poll=1&since={since}'")
        return [json.loads(line) for line in out.splitlines() if line.strip()]

    start_all()
    vm_203.wait_for_unit("ntfy-sh.service")
    vm_203.wait_for_unit("ntfy-users-prune.service")
    vm_203.wait_for_open_port(80)

    with subtest("no heartbeat yet: one alert per outage"):
        before = len(messages("${topics.alerts}"))
        vm_203.succeed("systemctl start heartbeat-check.service")
        vm_203.succeed("systemctl start heartbeat-check.service")
        alerts = messages("${topics.alerts}")[before:]
        assert len(alerts) == 1 and alerts[0]["title"] == "FIRING: Monitoring silent", alerts
        vm_203.succeed("test -e /var/lib/heartbeat-check/alerted")

    with subtest("each account may do exactly what 203 declares"):
        expected = [
            ("grafana", "${topics.alerts}", "200"), ("grafana", "${topics.heartbeat}", "200"),
            ("grafana", "${topics.hermes}", "403"),
            ("hermes", "${topics.hermes}", "200"), ("hermes", "${topics.alerts}", "403"),
            ("luca", "${topics.alerts}", "200"),
        ]
        for user, topic, code in expected:
            got = publish(user, topic)
            assert got == code, f"{user} -> {topic}: HTTP {got}, expected {code}"
        anonymous = publish("anonymous", "${topics.alerts}", auth=" ")
        assert anonymous in ("401", "403"), f"anonymous publish: HTTP {anonymous}"
        # grafana writes, never reads
        code = vm_203.succeed("curl -s -o /dev/null -w '%{http_code}' -u grafana:${password "ntfy-grafana-password"} 'http://127.0.0.1/${topics.alerts}/json?poll=1'").strip()
        assert code == "403", f"grafana read its alerts: HTTP {code}"
        # the desktop subscribes with its token
        vm_203.succeed("curl -sf -H 'Authorization: Bearer ${desktopToken}' 'http://127.0.0.1/${topics.alerts}/json?poll=1'")

    with subtest("the beat is back (grafana published one above): the outage is over"):
        vm_203.succeed("systemctl start heartbeat-check.service")
        vm_203.fail("test -e /var/lib/heartbeat-check/alerted")

    with subtest("every account is provisioned; one made by hand is gone after the next start"):
        vm_203.succeed("NTFY_PASSWORD=x ntfy user add stale")
        assert "user stale (" in vm_203.succeed("ntfy user list 2>&1")
        vm_203.succeed("systemctl restart ntfy-sh.service")
        vm_203.wait_for_unit("ntfy-users-prune.service")
        vm_203.wait_for_open_port(80)
        users = vm_203.succeed("ntfy user list 2>&1")
        assert "user stale " not in users, users
        for name in ["luca", "grafana", "hermes", "desktop", "heartbeat"]:
            assert f"user {name} (" in users and "server config" in users.split(f"user {name} (")[1].split(")")[0], users

    with subtest("the edge reaches ntfy, another dmz guest does not"):
        edge.wait_for_unit("network.target")
        edge.succeed("curl -s -o /dev/null --connect-timeout 5 http://${lab.inventory."203".ip}/v1/health")
        # the peer reaches the guest itself, only the port is closed to it
        peer.succeed("ping -c 1 -W 5 ${lab.inventory."203".ip}")
        peer.fail("curl -s -o /dev/null --connect-timeout 5 http://${lab.inventory."203".ip}/v1/health")
  '';
}
