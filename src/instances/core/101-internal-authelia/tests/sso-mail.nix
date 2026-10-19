# authelia with the mail relay site.json may name (main.nix `mail`), through the real internal ingress: a user's
# identity verification code and a password reset link reach their mailbox over starttls, the reset sets a password
# lldap takes, and an admin's password stays out of reach of a reset by mail. The relay is mailpit on the world node,
# behind the test ca's *.lsck0.dev certificate.
{
  pkgs,
  lib,
  specialArgs,
  ...
}:
let
  lab = import ../../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
  net = import ../../../../modules/net.nix {
    inherit lib;
    inherit (specialArgs) inventory site;
  };
  ip = id: lab.inventory.${id}.ip;
  routes = lab.routes.internal;
  relay = {
    address = "192.168.178.150";
    host = "mail.${net.domain}";
    port = 587;
    apiPort = 8025;
  };
  mail = {
    inherit (relay) host port;
    username = "authelia";
    sender = "Lab <auth@${net.domain}>";
  };
  client = "192.168.178.151";
  user = "carol";
  admin = "boss";
  userPassword = "carol-first-password";
  newPassword = "carol-second-password";
in
pkgs.testers.runNixOSTest {
  name = "sso-mail";
  node.specialArgs = lab.specialArgs // {
    site = lab.site // {
      smtp = mail;
    };
  };

  nodes.vm-100 = {
    imports = [
      (lab.guest "100" {
        flat = true;
        instance = ../../100-internal-traefik/main.nix;
      })
      ../../../../tests/lib/offline-traefik.nix
    ];
    virtualisation.memorySize = 1024;
  };
  nodes.vm-101 = {
    imports = [
      (lab.guest "101" {
        flat = true;
        instance = ../main.nix;
      })
    ];
    networking.hosts.${relay.address} = [ relay.host ];
    virtualisation.memorySize = 1024;
  };
  nodes.world = {
    imports = [
      (lab.multi {
        addresses = [
          "10.100.0.1/8"
          "${relay.address}/24"
          "${client}/24"
        ];
      })
    ];
    environment.systemPackages = [
      pkgs.curl
      pkgs.jq
    ];
    systemd.services.mailpit = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = lib.concatStringsSep " " [
        (lib.getExe pkgs.mailpit)
        "--smtp ${relay.address}:${toString relay.port}"
        "--listen 127.0.0.1:${toString relay.apiPort}"
        "--smtp-tls-cert ${lab.pki.lsck0.cert}"
        "--smtp-tls-key ${lab.pki.lsck0.key}"
        "--smtp-require-starttls"
        "--smtp-auth-accept-any"
      ];
    };
  };

  testScript = ''
    import json
    import re

    PORTAL = "https://${net.fqdn routes.authelia.host}"
    API = "http://127.0.0.1:${toString relay.apiPort}/api/v1"

    def curl(url, jar, data):
        host = url.split("/")[2]
        out = world.succeed(f"curl -s -o /tmp/body -w '%{{http_code}}' --interface ${client} --resolve {host}:443:${ip "100"} "
                            f"-b {jar} -c {jar} -H 'Content-Type: application/json' --data '{json.dumps(data)}' '{url}'")
        return int(out), world.succeed("cat /tmp/body")

    def mail_read(pattern):
        """the first match of pattern in the one mail the relay holds, which it then drops"""
        world.wait_until_succeeds(f"curl -sf '{API}/messages' | jq -e '.messages | length == 1'", timeout=60)
        newest = json.loads(world.succeed(f"curl -sf '{API}/messages'"))["messages"][0]
        text = json.loads(world.succeed(f"curl -sf '{API}/message/{newest['ID']}'"))["Text"]
        found = re.search(pattern, text)
        assert found, text
        world.succeed(f"curl -sf -X DELETE '{API}/messages'")
        return newest["To"][0]["Address"], found.group(1)

    start_all()
    world.wait_for_open_port(${toString relay.port}, "${relay.address}")
    vm_101.wait_for_unit("authelia-main.service")
    vm_101.wait_for_unit("lldap-bootstrap.service")
    vm_100.wait_for_unit("traefik.service")
    vm_100.wait_for_file("/var/lib/crowdsec/data/stub-ready")
    vm_100.wait_for_open_port(443)
    vm_101.succeed("printf '%s\\n%s\\n' ${userPassword} ${userPassword} | lab-user add ${user}")
    # an admin is an lldap admin from the next bootstrap on
    vm_101.succeed("printf '%s\\n%s\\n' ${userPassword} ${userPassword} | lab-user add ${admin} admins")
    vm_101.succeed("systemctl restart lldap-bootstrap.service")

    with subtest("the bind user may set passwords, of non-admins alone"):
        vm_101.succeed("journalctl -u lldap-bootstrap | grep -q 'authelia-bind in lldap_password_manager'")

    with subtest("a user's identity verification code arrives by mail"):
        status, body = curl(f"{PORTAL}/api/firstfactor", "/tmp/jar", {"username": "${user}", "password": "${userPassword}"})
        assert status == 200, body
        status, body = curl(f"{PORTAL}/api/user/session/elevation", "/tmp/jar", {})
        assert status == 200, body
        recipient, _ = mail_read(r"(\S+)")
        assert recipient == "${user}@${net.domain}", recipient

    with subtest("a forgotten password is reset by mail"):
        status, body = curl(f"{PORTAL}/api/reset-password/identity/start", "/tmp/reset", {"username": "${user}"})
        assert status == 200, body
        recipient, token = mail_read(r"token=([A-Za-z0-9._-]+)")
        assert recipient == "${user}@${net.domain}", recipient
        status, body = curl(f"{PORTAL}/api/reset-password/identity/finish", "/tmp/reset", {"token": token})
        assert status == 200, body
        status, body = curl(f"{PORTAL}/api/reset-password", "/tmp/reset", {"password": "${newPassword}"})
        assert status == 200, body
        # the user hears of the change, whoever made it
        recipient, _ = mail_read(r"(\S+)")
        assert recipient == "${user}@${net.domain}", recipient
        status, body = curl(f"{PORTAL}/api/firstfactor", "/tmp/new", {"username": "${user}", "password": "${newPassword}"})
        assert status == 200, body

    with subtest("an admin's password is not reset by mail"):
        status, body = curl(f"{PORTAL}/api/reset-password/identity/start", "/tmp/admin", {"username": "${admin}"})
        assert status == 200, body
        _, token = mail_read(r"token=([A-Za-z0-9._-]+)")
        curl(f"{PORTAL}/api/reset-password/identity/finish", "/tmp/admin", {"token": token})
        curl(f"{PORTAL}/api/reset-password", "/tmp/admin", {"password": "${newPassword}"})
        status, body = curl(f"{PORTAL}/api/firstfactor", "/tmp/admin-new", {"username": "${admin}", "password": "${newPassword}"})
        assert status != 200, body
        status, body = curl(f"{PORTAL}/api/firstfactor", "/tmp/admin-kept", {"username": "${admin}", "password": "${userPassword}"})
        assert status == 200, body
  '';
}
