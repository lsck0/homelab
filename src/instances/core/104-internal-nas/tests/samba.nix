# the nas's smb (lib/samba.nix) as the owner's machines mount it: cifs, credentials file, seal, SMB 3.1.1. Claims: the
# homelab share is the whole tree, a service's files read and written as that service's; a share acting as nobody
# takes the same login; guests, anonymous listings, a wrong password, an older dialect and a host outside hosts allow
# are refused, and the firewall drops a host outside hosts allow before smbd sees it; the passdb holds the owner alone.
# The real nas's cold-storage share and folder (main.nix) take the owner's writes, as nobody, and refuse a guest.
{
  pkgs,
  lib,
  inputs,
  ...
}:
let
  nas = inputs.self.nixosConfigurations."104-internal-nas".config;
  coldStorage = nas.homelab.smb.shares.cold-storage;
  # a share acting as nobody on a folder closed to nobody lists nothing, as BACKUPS did on its 0700 root folder
  closedShares = lib.attrNames (
    lib.filterAttrs (
      _: share:
      let
        rule = lib.findFirst (r: lib.hasPrefix "d ${share.path} " r) null nas.systemd.tmpfiles.rules;
        fields = lib.splitString " " rule;
        otherBits = lib.toInt (lib.substring 3 1 (lib.elemAt fields 2));
      in
      rule != null && lib.elemAt fields 3 != "nobody" && otherBits < 5
    ) nas.homelab.smb.shares
  );
  site = lib.importJSON ../../../../generated/site.json;
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

  lanAt =
    address:
    { lib, ... }:
    {
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
        {
          inherit address;
          prefixLength = lanPrefix;
        }
      ];
    };
  client = address: {
    imports = [ (lanAt address) ];
    boot.supportedFilesystems = [ "cifs" ];
    environment.systemPackages = [
      pkgs.samba
      pkgs.netcat
    ];
    environment.etc."samba/homelab.cred" = {
      mode = "0600";
      text = "username=${user}\npassword=${password}\n";
    };
  };
in
assert lib.assertMsg (closedShares == [ ]) "smb shares nobody can list: ${toString closedShares}";
pkgs.testers.runNixOSTest {
  name = "samba";

  nodes.nas = {
    imports = [
      ../../../../tests/stubs.nix
      ../lib/samba.nix
      (lanAt nasAddress)
    ];
    homelab.smb.shares = {
      public = {
        path = "/srv/nas/public";
        writable = true;
      };
      cold-storage = coldStorage;
    };
    testing.secretValues.samba-homelab = "username=${user}\npassword=${password}";
    systemd.tmpfiles.rules = [
      "d /srv/nas 0755 root root -"
      "d /srv/nas/public 0775 nobody nogroup -"
      "d /srv/nas/BACKUPS 0700 root root -"
      "d ${serviceDir} 0700 ${serviceUid} ${serviceUid} -"
      "f ${serviceDir}/state 0600 ${serviceUid} ${serviceUid} - demo-state"
      "d /srv/nas/bulk 0775 1000 1000 -"
    ]
    ++ lib.filter (lib.hasPrefix "d ${coldStorage.path} ") nas.systemd.tmpfiles.rules;
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

    with subtest("cold storage takes the owner's writes, as nobody"):
        rc, out = mount(workstation, "cold-storage", sealed)
        assert rc == 0, out
        workstation.succeed("mkdir /mnt/cold-storage/schule && echo essay > /mnt/cold-storage/schule/essay.txt")
        owner = nas.succeed("stat -c %U:%G ${coldStorage.path} ${coldStorage.path}/schule/essay.txt").split()
        assert owner == ["nobody:nogroup"] * 2, owner
        workstation.succeed("umount /mnt/cold-storage")

    with subtest("guests, anonymous listings, a wrong password and an older dialect are refused"):
        for share in ["homelab", "public", "cold-storage"]:
            rc, out = mount(workstation, share, "guest,vers=3.1.1")
            assert rc != 0, f"guest mounted {share}: {out}"
        # no smb.conf on the client: its own defaults
        out = workstation.fail("smbclient --configfile=/dev/null --no-pass --list //${nasAddress} 2>&1")
        assert "NT_STATUS_ACCESS_DENIED" in out, out
        rc, out = mount(workstation, "homelab", "username=${user},password=wrong,seal,vers=3.1.1")
        assert rc != 0, out
        rc, out = mount(workstation, "homelab", "credentials=${credentials},seal,vers=3.0")
        assert rc != 0, out

    with subtest("a host outside hosts allow is refused, its packets dropped before smbd"):
        rc, out = mount(stranger, "homelab", sealed)
        assert rc != 0, out
        stranger.fail("nc -z -w 3 ${nasAddress} 445")
        workstation.succeed("nc -z -w 3 ${nasAddress} 445")
  '';
}
