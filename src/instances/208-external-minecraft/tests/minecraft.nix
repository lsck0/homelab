# minecraft modpack switching on vm-208
{ pkgs, lib, specialArgs, ... }:
let
  lab = import ../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
in
pkgs.testers.runNixOSTest {
  name = "minecraft";

  node.specialArgs = lab.specialArgs;
  nodes.vm-208 = {
    imports = [ (lab.guest "208" { instance = ../main.nix; }) ];
    # lazymc would boot the real server; record the env mc-start would hand it instead
    systemd.services.lazymc.serviceConfig = {
      # env files in mc-start's order; optional because ExecStartPre writes them on first boot
      EnvironmentFile = [ "-/var/lib/minecraft/rcon.env" "-/var/lib/minecraft/modpack.env" ];
      ExecStart = lib.mkForce (pkgs.writeShellScript "fake-lazymc" ''
        env | grep -E '^(TYPE|MODRINTH_MODPACK|CF_PAGE_URL|VERSION|LEVEL|RCON_PASSWORD)=' | sort > /tmp/server-env
        exec sleep infinity
      '');
    };
  };

  testScript = ''
    def env():
        vm_208.wait_until_succeeds("test -s /tmp/server-env")
        out = vm_208.succeed("cat /tmp/server-env")
        vm_208.succeed("rm /tmp/server-env")
        return dict(l.split("=", 1) for l in out.strip().splitlines())

    vm_208.wait_for_unit("lazymc.service")

    with subtest("first boot writes the default pack and the lazymc config"):
        e = env()
        assert e == {"TYPE": "VANILLA", "VERSION": "LATEST", "LEVEL": "vanilla",
                     "RCON_PASSWORD": "test-minecraft-rcon-password"}, e
        vm_208.succeed("grep -q 'password = \"test-minecraft-rcon-password\"' /var/lib/minecraft/lazymc.toml")

    with subtest("switch to another Modrinth pack"):
        vm_208.succeed("mc-modpack https://modrinth.com/modpack/fabulously-optimized 1.21.4")
        e = env()
        assert e == {"TYPE": "MODRINTH", "MODRINTH_MODPACK": "https://modrinth.com/modpack/fabulously-optimized",
                     "VERSION": "1.21.4", "LEVEL": "fabulously-optimized",
                     "RCON_PASSWORD": "test-minecraft-rcon-password"}, e

    with subtest("CurseForge URL"):
        vm_208.succeed("mc-modpack https://www.curseforge.com/minecraft/modpacks/all-the-mods-10/")
        e = env()
        assert e["TYPE"] == "AUTO_CURSEFORGE", e
        assert e["CF_PAGE_URL"] == "https://www.curseforge.com/minecraft/modpacks/all-the-mods-10/", e
        assert e["LEVEL"] == "all-the-mods-10" and e["VERSION"] == "LATEST", e
        assert "MODRINTH_MODPACK" not in e, e

    with subtest("back to vanilla"):
        vm_208.succeed("mc-modpack vanilla")
        e = env()
        assert e["TYPE"] == "VANILLA" and e["LEVEL"] == "vanilla", e

    with subtest("no argument shows the current pack and changes nothing"):
        out = vm_208.succeed("mc-modpack")
        assert "TYPE=VANILLA" in out, out
        vm_208.fail("test -e /tmp/server-env")

    with subtest("choice survives a redeploy (pre-start re-runs)"):
        vm_208.succeed("systemctl restart lazymc.service")
        e = env()
        assert e["TYPE"] == "VANILLA", e
  '';
}
