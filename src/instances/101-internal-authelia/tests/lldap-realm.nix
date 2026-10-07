# the proxmox realm's view of lldap (lib/lldap.nix, scripts/pve-install.sh realm_converge): ldaps from the hypervisor's
# address, verified against the certificate the guest made for its own address, as the read-only bind user; no
# plaintext ldap and no ldaps for anyone else; a lost key gives a new certificate
{ pkgs, lib, specialArgs, ... }:
let
  lab = import ../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
  net = import ../../../modules/net.nix { inherit lib; inherit (specialArgs) inventory site; };
  realm = (import ../../../modules/lab-export.nix { lib = lib; lab = specialArgs.lab; }).ldap;
  proxmox = net.wan.proxmox;
  # a lab address the guard admits to nothing: the flat lab's internal gateway
  stranger = "10.100.0.1";
  ldapPlainPort = 3890;
  ldapTimeoutS = 5;
in
pkgs.testers.runNixOSTest {
  name = "lldap-realm";
  node.specialArgs = lab.specialArgs;

  nodes.vm-101 = {
    imports = [ (lab.guest "101" { flat = true; instance = ../main.nix; }) ];
    virtualisation.memorySize = 1024;
  };
  nodes.world = {
    imports = [ (lab.multi { addresses = [ "${stranger}/8" "${proxmox}/24" ]; }) ];
    environment.systemPackages = [ pkgs.openldap pkgs.openssl pkgs.netcat ];
  };

  testScript = lab.driverPython + ''
    start_all()
    vm_101.wait_for_unit("lldap-bootstrap.service")
    vm_101.wait_for_open_port(${toString realm.port})
    # what the hypervisor sends from: its own lan address, as the realm does in the lab
    world.succeed("ip route add ${realm.host}/32 dev eth1 src ${proxmox}")

    def ldaps_search(ca):
        password = vm_101.succeed("cat /run/secrets/lldap-proxmox-bind-password").strip()
        world.succeed(f"printf %s '{password}' > /tmp/bind.pw")
        return world.execute(
            f"LDAPTLS_CACERT={ca} LDAPTLS_REQCERT=demand ldapsearch -o nettimeout=${toString ldapTimeoutS} -LLL "
            "-H ldaps://${realm.host}:${toString realm.port} -D uid=${realm.bindUser},ou=people,${realm.baseDn} -y /tmp/bind.pw "
            "-b ou=groups,${realm.baseDn} cn=${realm.adminGroup} cn")

    with subtest("the certificate names the guest's address"):
        world.succeed(f"cat > /tmp/realm.pem <<'EOF'\n{vm_101.succeed('cat ${realm.certFile}')}EOF")
        world.succeed("openssl x509 -in /tmp/realm.pem -noout -ext subjectAltName | grep -qw 'IP Address:${realm.host}'")

    with subtest("the realm's bind user reads the directory over ldaps, verified against that certificate"):
        status, out = ldaps_search("/tmp/realm.pem")
        assert status == 0 and "cn: ${realm.adminGroup}" in out, out

    with subtest("verification is on: another certificate is refused"):
        world.succeed("openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 -subj /CN=other "
                      "-addext subjectAltName=IP:${realm.host} -keyout /tmp/other.key -out /tmp/other.pem")
        status, out = ldaps_search("/tmp/other.pem")
        assert status != 0, out

    with subtest("no plaintext ldap from the hypervisor, no ldaps from anyone the guard does not name"):
        world.succeed("nc -z -w ${toString ldapTimeoutS} -s ${proxmox} ${realm.host} ${toString realm.port}")
        world.fail("nc -z -w ${toString ldapTimeoutS} -s ${proxmox} ${realm.host} ${toString ldapPlainPort}")
        world.fail("nc -z -w ${toString ldapTimeoutS} -s ${stranger} ${realm.host} ${toString realm.port}")

    with subtest("a lost key makes a new certificate, which the old pin refuses"):
        vm_101.succeed("rm ${dirOf realm.certFile}/ldaps-key.pem")
        vm_101.succeed("systemctl restart lldap.service")
        vm_101.wait_for_open_port(${toString realm.port})
        status, out = ldaps_search("/tmp/realm.pem")
        assert status != 0, out
  '';
}
