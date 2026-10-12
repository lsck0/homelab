# the nas's smb (lib/samba.nix) as the owner's machines mount it: cifs, credentials file, seal, SMB 3.1.1. Claims: the
# homelab share is the whole tree, a service's files read and written as that service's; a share acting as nobody
# takes the same login; guests, anonymous listings, a wrong password, an older dialect and a host outside hosts allow
# are refused; the passdb holds the owner alone.
{ pkgs, lib, ... }:
let
  site = lib.importJSON ../../../generated/site.json;
  # the nas on the house lan beside the owner's machines; any address hosts allow does not name
  nasAddress = "192.168.178.104";
  strangerAddress = "192.168.178.99";
  lanPrefix = 24;
  user = "luca";
  password = "test-samba-password";
  credentials = "/etc/samba/homelab.cred";
  # a service's state: its own uid, closed to every other
  serviceUid = "315";
  serviceDir = "/srv/nas/data/demo";

  lanAt = address: { lib, ... }: {
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [ { inherit address; prefixLength = lanPrefix; } ];
  };
  client = address: {
    imports = [ (lanAt address) ];
    boot.supportedFilesystems = [ "cifs" ];
    environment.systemPackages = [ pkgs.samba ];
    environment.etc."samba/homelab.cred" = { mode = "0600"; text = "username=${user}\npassword=${password}\n"; };
  };
in
pkgs.testers.runNixOSTest {
  name = "samba";

  nodes.nas = {
    imports = [ ../../../tests/stubs.nix ../lib/samba.nix (lanAt nasAddress) ];
    homelab.smb.user = user;
    homelab.smb.shares.public = { path = "/srv/nas/public"; writable = true; };
    testing.secretValues.samba-homelab = "username=${user}\npassword=${password}";
    systemd.tmpfiles.rules = [
      "d /srv/nas 0755 root root -"
      "d /srv/nas/public 0775 nobody nogroup -"
      "d /srv/nas/BACKUPS 0700 root root -"
      "d ${serviceDir} 0700 ${serviceUid} ${serviceUid} -"
      "f ${serviceDir}/state 0600 ${serviceUid} ${serviceUid} - demo-state"
    ];
  };
  nodes.workstation = client site.lan.workstation;
  nodes.stranger = client strangerAddress;

  testScript = ''
    sealed = "credentials=${credentials},seal,vers=3.1.1"

    def mount(node, share, options):
        return node.execute(f"mkdir -p /mnt/{share} && mount -t cifs //${nasAddress}/{share} /mnt/{share} -o {options} 2>&1")

    start_all()
    nas.wait_for_unit("samba-user.service")
    nas.wait_for_unit("samba-smbd.service")
    nas.wait_for_open_port(445)
    workstation.wait_for_unit("multi-user.target")
    stranger.wait_for_unit("multi-user.target")

    with subtest("the passdb holds the owner alone"):
        nas.succeed("useradd --system stray && printf 'x\\nx\\n' | smbpasswd -s -a stray")
        nas.succeed("systemctl restart samba-user")
        assert nas.succeed("pdbedit -L | cut -d: -f1").split() == ["${user}"]

    with subtest("homelab, sealed over 3.1.1, is the whole tree; a service's files stay that service's"):
        rc, out = mount(workstation, "homelab", sealed)
        assert rc == 0, out
        assert {"data", "public", "BACKUPS"} <= set(workstation.succeed("ls /mnt/homelab").split())
        assert workstation.succeed("cat /mnt/homelab/data/demo/state").strip() == "demo-state"
        workstation.succeed("echo added > /mnt/homelab/data/demo/added")
        owner = nas.succeed("stat -c '%u %a' ${serviceDir}/added").split()
        assert owner == ["${serviceUid}", "600"], owner
        session = nas.succeed("smbstatus --brief")
        print(session)
        assert "SMB3_11" in session and "AES-" in session, "the session is not an encrypted 3.1.1 one"
        workstation.succeed("umount /mnt/homelab")

    with subtest("a share acting as nobody takes the same login"):
        rc, out = mount(workstation, "public", sealed)
        assert rc == 0, out
        workstation.succeed("echo dropped > /mnt/public/dropped")
        assert nas.succeed("stat -c %U /srv/nas/public/dropped").strip() == "nobody"
        workstation.succeed("umount /mnt/public")

    with subtest("guests, anonymous listings, a wrong password and an older dialect are refused"):
        for share in ["homelab", "public"]:
            rc, out = mount(workstation, share, "guest,vers=3.1.1")
            assert rc != 0, f"guest mounted {share}: {out}"
        # no smb.conf on the client: its own defaults
        out = workstation.fail("smbclient --configfile=/dev/null --no-pass --list //${nasAddress} 2>&1")
        assert "NT_STATUS_ACCESS_DENIED" in out, out
        rc, out = mount(workstation, "homelab", "username=${user},password=wrong,seal,vers=3.1.1")
        assert rc != 0, out
        rc, out = mount(workstation, "homelab", "credentials=${credentials},seal,vers=3.0")
        assert rc != 0, out

    with subtest("a host outside hosts allow is refused"):
        rc, out = mount(stranger, "homelab", sealed)
        assert rc != 0, out
  '';
}
