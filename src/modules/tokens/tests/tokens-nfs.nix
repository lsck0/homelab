# runtime tokens over the nas as shipped: modules/tokens on lab guests at their real addresses, a test nas that
# exports exactly what they mount by the real rules (104-internal-nas's lib/nas-exports.nix). The oracle is the policy itself, as a
# table: who may mount which producer's directory, and how.
#
#   vm-121  producer of bazarr-key                    rw tokens/vm-121
#   vm-122  producer of the jellyfin keys, reads bazarr-key  ro tokens/vm-121
#   vm-131  producer of paperless-key, reads nothing of vm-121
#   vm-250  apps zone, reads swarm-worker-token                    ro tokens/vm-107 (subtree checked)
#
# Every refusal has its positive control in the same run: the same mount from the entitled guest works. Faults: the
# nas unreachable mid-write and restarted under a reader; a token rewritten 300 times under a concurrent reader.
{ pkgs, lib, specialArgs, ... }:
let
  lab = import ../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
  ip = id: lab.inventory.${id}.ip;
  nasIp = ip "104";

  guest = id: reads: {
    imports = [ (lab.guest id { flat = true; nas = true; }) ];
    homelab.tokens.reads = reads;
  };

  # the oracle: token share -> { client vmid: "rw" | "ro" }, and which clients sit outside the internal zone
  exportsWanted = {
    "/srv/nas/data/tokens/vm-121" = { "121" = "rw"; "122" = "ro"; };
    "/srv/nas/data/tokens/vm-122" = { "122" = "rw"; };
    "/srv/nas/data/tokens/vm-131" = { "131" = "rw"; };
    "/srv/nas/data/tokens/vm-107" = { "250" = "ro"; };
  };
  subtreeChecked = [ (ip "250") ];
  exportsJson = builtins.toJSON (lib.mapAttrs (_: clients: lib.mapAttrs' (id: mode: lib.nameValuePair (ip id) mode) clients)
    exportsWanted);

  # a 4 KiB token version: its number, padded, so every version is distinct and a torn read is visible
  rotations = 300;
  tokenBytes = 4096;
  # the outage is the fault's length, the one time-based claim: a hard mount holds the writer that long
  outageS = 30;
in
pkgs.testers.runNixOSTest {
  name = "tokens-nfs";

  node.specialArgs = lab.specialArgs;
  nodes.vm-104 = lab.nas { flat = true; };
  nodes.vm-121 = guest "121" [ ];
  nodes.vm-122 = guest "122" [ "bazarr-key" ];
  nodes.vm-131 = guest "131" [ ];
  nodes.vm-250 = guest "250" [ "swarm-worker-token" ];

  testScript = ''
    import json, re

    WANTED = json.loads('${exportsJson}')
    SUBTREE_CHECKED = ${builtins.toJSON subtreeChecked}
    NAS = "${nasIp}"
    OWN_130 = "/var/lib/lab-tokens.d/vm-121"

    def exports():
        """path -> {client: options} from exportfs -v, which repeats a path once per client"""
        out = {}
        listing = vm_104.succeed("exportfs -v")
        print(listing)
        for path, clients in re.findall(r"^(/\S+)\s+((?:\S+\([^)]*\)\s*)+)", listing, re.M):
            out.setdefault(path, {}).update({c: o.split(",") for c, o in re.findall(r"(\S+)\(([^)]*)\)", clients)})
        return out

    def denied(machine, share, opts="ro"):
        machine.succeed("mkdir -p /mnt/probe")
        machine.fail(f"timeout 30 mount -t nfs4 -o {opts},soft,timeo=10,retrans=1 {NAS}:{share} /mnt/probe")

    def mounts(machine, share, opts="ro"):
        machine.succeed("mkdir -p /mnt/probe")
        machine.succeed(f"timeout 30 mount -t nfs4 -o {opts} {NAS}:{share} /mnt/probe")

    def unmount(machine):
        machine.succeed("umount /mnt/probe")

    def token_write(value):
        # how a producer writes: a temp file in its own dir, renamed into place
        vm_121.succeed(f"printf %s {value} > {OWN_130}/bazarr-key.token.tmp && mv {OWN_130}/bazarr-key.token.tmp {OWN_130}/bazarr-key.token")

    start_all()
    vm_104.wait_for_unit("nfs-exports-reload.service")

    with subtest("the nas exports exactly the token table"):
        got = exports()
        tokens = {p: c for p, c in got.items() if "/tokens/" in p}
        assert set(tokens) == set(WANTED), f"token exports {sorted(tokens)} != {sorted(WANTED)}"
        for path, clients in WANTED.items():
            assert set(tokens[path]) == set(clients), f"{path}: clients {sorted(tokens[path])} != {sorted(clients)}"
            for client, mode in clients.items():
                opts = tokens[path][client]
                assert mode in opts, f"{path} {client}: {opts} lacks {mode}"
                # exportfs -v names only no_subtree_check; checking subtrees is its default
                checked = "no_subtree_check" not in opts
                assert checked == (client in SUBTREE_CHECKED), f"{path} {client}: subtree check {checked} in {opts}"
        for vmid in ("121", "122", "131"):
            mode = vm_104.succeed(f"stat -c '%a %U' /srv/nas/data/tokens/vm-{vmid}").strip()
            assert mode == "755 root", f"tokens/vm-{vmid} is {mode}, not root's 0755"

    with subtest("a producer's write lands in its own dir on the nas"):
        vm_121.wait_for_unit("multi-user.target")
        token_write("k1")
        assert vm_104.succeed("cat /srv/nas/data/tokens/vm-121/bazarr-key.token") == "k1"

    with subtest("a consumer reads exactly what it lists"):
        vm_122.wait_until_succeeds("[ \"$(cat /var/lib/lab-tokens/bazarr-key.token)\" = k1 ]", timeout=60)
        vm_122.fail("test -e /var/lib/lab-tokens/paperless-key.token")

    with subtest("a consumer cannot write, even as root"):
        d = "/var/lib/lab-tokens.d/vm-121"
        for cmd in (f"touch {d}/new", f"echo x > {d}/bazarr-key.token", f"rm {d}/bazarr-key.token",
                    f"mv {d}/bazarr-key.token {d}/moved", "echo x > /var/lib/lab-tokens/bazarr-key.token"):
            out = vm_122.fail(f"( {cmd} ) 2>&1")
            assert "Read-only file system" in out, f"{cmd}: {out}"
        vm_122.succeed(f"findmnt -no OPTIONS {d} | tr , '\\n' | grep -qx ro")
        assert vm_104.succeed("cat /srv/nas/data/tokens/vm-121/bazarr-key.token") == "k1"

    with subtest("a guest that reads nothing of vm-121 cannot mount it; the entitled one can"):
        denied(vm_131, "/srv/nas/data/tokens/vm-121")
        mounts(vm_122, "/srv/nas/data/tokens/vm-121")
        assert vm_122.succeed("cat /mnt/probe/bazarr-key.token") == "k1"
        unmount(vm_122)

    with subtest("the pseudo-root shows a guest only its own exports"):
        mounts(vm_131, "/")
        listed = vm_131.succeed("ls /mnt/probe/srv/nas/data/tokens").split()
        assert listed == ["vm-131"], f"vm-131 sees {listed}"
        unmount(vm_131)

    with subtest("a producer cannot reach another producer; a reader mounting read-write still gets read-only"):
        denied(vm_121, "/srv/nas/data/tokens/vm-131")
        mounts(vm_131, "/srv/nas/data/tokens/vm-131", "rw")
        vm_131.succeed("touch /mnt/probe/own-write && rm /mnt/probe/own-write")
        unmount(vm_131)
        mounts(vm_122, "/srv/nas/data/tokens/vm-121", "rw")
        out = vm_122.fail("( touch /mnt/probe/x ) 2>&1")
        assert "Read-only file system" in out, out
        unmount(vm_122)

    with subtest("the apps zone reads its token and nothing else"):
        vm_104.succeed("printf w1 > /srv/nas/data/tokens/vm-107/swarm-worker-token.token")
        vm_250.wait_until_succeeds("[ \"$(cat /var/lib/lab-tokens/swarm-worker-token.token)\" = w1 ]", timeout=60)
        denied(vm_250, "/srv/nas/data/tokens/vm-121")
        # nfsv4 serves the path to an export as a pseudo directory: it may mount, but shows nothing else
        vm_250.succeed("mkdir -p /mnt/probe")
        if vm_250.execute(f"timeout 30 mount -t nfs4 -o ro,soft,timeo=10,retrans=1 {NAS}:/srv/nas/data /mnt/probe")[0] == 0:
            seen = vm_250.succeed("cd /mnt/probe && find . -maxdepth 2 | sort").split()
            assert seen == [".", "./tokens", "./tokens/vm-107"], f"vm-250 sees {seen} under /srv/nas/data"
            unmount(vm_250)

    with subtest("${toString rotations} rotations under a concurrent reader: every read is one whole version"):
        versions = {f"{i:08d}" * (${toString tokenBytes} // 8) for i in range(${toString rotations})}
        # the reader runs for as long as the rotation does. Each read drops the dentry and attribute caches first: a
        # cached lookup would serve the old version for up to a minute and prove nothing. A read that errs (a name
        # replaced mid-lookup) records nothing: an error is no wrong value
        vm_122.succeed("systemd-run --unit=token-reader --setenv=PATH=$PATH bash -c 'while :; do "
                       "echo 2 > /proc/sys/vm/drop_caches; if t=$(cat /var/lib/lab-tokens/bazarr-key.token); then printf \"%s\\n\" \"$t\"; fi; "
                       "done > /tmp/reads'")
        vm_121.succeed(
            "systemd-run --unit=token-rotate --remain-after-exit --setenv=PATH=$PATH bash -euc '"
            "for i in $(seq 0 ${toString (rotations - 1)}); do "
            "yes $(printf %08d $i) | tr -d \"\\\\n\" | head -c ${toString tokenBytes} > " + OWN_130 + "/bazarr-key.token.tmp "
            "&& mv " + OWN_130 + "/bazarr-key.token.tmp " + OWN_130 + "/bazarr-key.token; done'"
        )
        vm_121.wait_until_succeeds("systemctl show -p SubState token-rotate | grep -qx SubState=exited", timeout=300)
        vm_121.succeed("systemctl show -p Result token-rotate | grep -qx Result=success")
        vm_122.succeed("systemctl stop token-reader")
        reads = vm_122.succeed("cat /tmp/reads").split("\n")[:-1]
        assert len(reads) > 0, "the reader read nothing"
        torn = [r[:32] for r in reads if r not in versions and r != "k1"]
        assert torn == [], f"{len(torn)} torn or empty reads, first: {torn[:3]}"
        distinct = len({r for r in reads if r in versions})
        assert distinct > 1, f"the reads saw {distinct} versions: they did not overlap the rotation"
        print(f"{len(reads)} reads saw {distinct} distinct whole versions, none torn")

    with subtest("nas outage: the producer's write waits and lands, the reader errs and recovers"):
        token_write("before-outage")
        vm_122.wait_until_succeeds("[ \"$(cat /var/lib/lab-tokens/bazarr-key.token)\" = before-outage ]", timeout=60)
        vm_104.block()
        vm_121.succeed("systemd-run --unit=outage-write --remain-after-exit --setenv=PATH=$PATH bash -euc 'printf after-outage > " + OWN_130
                       + "/bazarr-key.token.tmp && mv " + OWN_130 + "/bazarr-key.token.tmp " + OWN_130 + "/bazarr-key.token'")
        # the hard mount blocks the writer instead of failing it, for as long as the outage lasts
        vm_121.succeed("sleep ${toString outageS}; systemctl show -p SubState outage-write | grep -qx SubState=running")
        # a soft read-only reader fails, or still answers with a whole version; never empty
        out = vm_122.execute("timeout 60 cat /var/lib/lab-tokens/bazarr-key.token")[1]
        assert out in ("", "before-outage"), f"read during the outage: {out!r}"
        vm_104.unblock()
        vm_121.wait_until_succeeds("systemctl show -p SubState outage-write | grep -qx SubState=exited", timeout=180)
        vm_121.succeed("systemctl show -p Result outage-write | grep -qx Result=success")
        assert vm_104.succeed("cat /srv/nas/data/tokens/vm-121/bazarr-key.token") == "after-outage"
        vm_122.wait_until_succeeds("[ \"$(cat /var/lib/lab-tokens/bazarr-key.token)\" = after-outage ]", timeout=180)

    with subtest("nas restart under a reader: reads resume"):
        vm_104.succeed("systemctl restart nfs-server")
        vm_122.wait_until_succeeds("[ \"$(cat /var/lib/lab-tokens/bazarr-key.token)\" = after-outage ]", timeout=180)
        token_write("after-restart")
        vm_122.wait_until_succeeds("[ \"$(cat /var/lib/lab-tokens/bazarr-key.token)\" = after-restart ]", timeout=180)
  '';
}
