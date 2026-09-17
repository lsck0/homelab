# The on-host part of src/scripts/renumber.sh: renaming VMs in place on
# Proxmox storage. Real LVM thin volumes (data + a snapshot) and a directory
# storage; `qm` and `pvesm` are stubs that read /etc/pve like Proxmox does.
# Ids collide (105 -> 108 while 108 -> 115 exists), which is why the script goes
# through temporary 9xxx ids.
{ pkgs, ... }:
let
  stubs = pkgs.runCommand "pve-stubs" { } ''
    mkdir -p $out/bin
    cat > $out/bin/qm <<'EOF2'
    #!/bin/sh
    [ "$1" = status ] && [ -f "/etc/pve/qemu-server/$2.conf" ] && { echo "status: stopped"; exit 0; }
    exit 2
    EOF2
    cat > $out/bin/pvesm <<'EOF2'
    #!/bin/sh
    # pvesm status --storage <name>
    type=$(awk -v s="$3" '$2==s {sub(":", "", $1); print $1}' /etc/pve/storage.cfg)
    printf 'Name Type Status Total Used Available %%\n%s %s active 1 1 1 1%%\n' "$3" "$type"
    EOF2
    chmod +x $out/bin/*
  '';
in
pkgs.testers.runNixOSTest {
  name = "renumber";

  nodes.machine = {
    virtualisation.emptyDiskImages = [ 2048 ];
    services.lvm.boot.thin.enable = true;
    environment.systemPackages = [ stubs pkgs.lvm2 pkgs.gawk pkgs.qemu-utils ];
    environment.etc."renumber.sh".source = ../scripts/renumber.sh;
  };

  testScript = ''
    m = machine
    m.wait_for_unit("multi-user.target")

    with subtest("fake Proxmox: storage config, VM configs, volumes with data"):
        m.succeed(
            "mkdir -p /etc/pve/qemu-server /etc/pve/firewall /var/lib/vz/images/131",
            "printf 'dir: local\\n\\tpath /var/lib/vz\\n\\tcontent iso,images\\n\\nlvmthin: local-lvm\\n\\tthinpool data\\n\\tvgname pve\\n\\tcontent images,rootdir\\n' > /etc/pve/storage.cfg",
            "pvcreate /dev/vdb && vgcreate pve /dev/vdb && lvcreate -L 1G -T pve/data",
        )
        for vm, marker in [("105", "nas-data"), ("108", "runner-data")]:
            m.succeed(
                f"lvcreate -V 64M -T pve/data -n vm-{vm}-disk-0",
                f"lvcreate -V 4M -T pve/data -n vm-{vm}-cloudinit",
                f"echo {marker} | dd of=/dev/pve/vm-{vm}-disk-0 conv=notrunc",
                f"printf 'name: {vm}-test\\nscsi0: local-lvm:vm-{vm}-disk-0,discard=on,size=64M\\nide2: local-lvm:vm-{vm}-cloudinit,media=cdrom\\n' > /etc/pve/qemu-server/{vm}.conf",
            )
        m.succeed("lvcreate -s -n snap_vm-105-disk-0_before pve/vm-105-disk-0")
        m.succeed("echo 'fw-105' > /etc/pve/firewall/105.fw")
        m.succeed(
            "qemu-img create -f qcow2 /var/lib/vz/images/131/vm-131-disk-0.qcow2 16M",
            "printf 'name: 131-test\\nscsi0: local:131/vm-131-disk-0.qcow2,size=16M\\n' > /etc/pve/qemu-server/131.conf",
        )

    def renum(pairs):
        # same two passes as the script: all to 9<new>, then to <new>.
        script = "; ".join([f"renum {o} 9{n}" for o, n in pairs] + [f"renum 9{n} {n}" for o, n in pairs])
        return m.succeed(
            "set -e; eval \"$(sed -n \"/^RENAME_FN='/,/^'$/p\" /etc/renumber.sh)\"; eval \"$RENAME_FN\"; " + script
        )

    with subtest("rename with colliding ids"):
        print(renum([("105", "108"), ("108", "115"), ("131", "109")]))

    with subtest("configs moved and rewritten"):
        m.fail("test -e /etc/pve/qemu-server/105.conf")
        m.fail("test -e /etc/pve/qemu-server/131.conf")
        m.fail("ls /etc/pve/qemu-server/9*")
        m.succeed("grep -q 'scsi0: local-lvm:vm-108-disk-0,' /etc/pve/qemu-server/108.conf")
        m.succeed("grep -q 'ide2: local-lvm:vm-108-cloudinit' /etc/pve/qemu-server/108.conf")
        m.succeed("grep -q 'name: 105-test' /etc/pve/qemu-server/108.conf")
        m.succeed("grep -q 'scsi0: local-lvm:vm-115-disk-0,' /etc/pve/qemu-server/115.conf")
        m.succeed("grep -q 'scsi0: local:109/vm-109-disk-0.qcow2' /etc/pve/qemu-server/109.conf")
        m.succeed("grep -q fw-105 /etc/pve/firewall/108.fw")

    with subtest("volumes renamed, data intact, snapshot follows"):
        lvs = m.succeed("lvs --noheadings -o lv_name pve | tr -d ' ' | sort")
        print(lvs)
        for lv in ["vm-108-disk-0", "vm-108-cloudinit", "snap_vm-108-disk-0_before", "vm-115-disk-0", "vm-115-cloudinit"]:
            assert lv in lvs.split(), f"{lv} missing"
        assert "vm-105" not in lvs and "vm-9" not in lvs, lvs
        assert m.succeed("head -c 8 /dev/pve/vm-108-disk-0").startswith("nas-data")
        assert m.succeed("head -c 11 /dev/pve/vm-115-disk-0").startswith("runner-data")
        m.succeed("qemu-img info /var/lib/vz/images/109/vm-109-disk-0.qcow2")
        m.fail("test -d /var/lib/vz/images/131")

    with subtest("refuses to overwrite an existing id"):
        m.succeed("printf 'scsi0: local-lvm:vm-115-disk-0\\n' > /etc/pve/qemu-server/120.conf")
        m.fail("eval \"$(sed -n \"/^RENAME_FN='/,/^'$/p\" /etc/renumber.sh)\"; eval \"$RENAME_FN\"; renum 120 108")
  '';
}
