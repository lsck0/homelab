# minecraft on vm-214: modpack switching, the server's secrets rendered under /run and never on the nas share
{ pkgs, lib, specialArgs, ... }:
let
  lab = import ../../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
  serverEnv = "/run/secrets/rendered/minecraft-server.env";
  secrets = { RCON_PASSWORD = "test-minecraft-rcon-password"; CF_API_KEY = "test-minecraft-cf-api-key"; };
in
pkgs.testers.runNixOSTest {
  name = "minecraft";

  node.specialArgs = lab.specialArgs;
  nodes.vm-214 = {
    imports = [ (lab.guest "214" { instance = ../main.nix; }) ];
    # lazymc would boot the real server; record the env mc-start would hand it instead
    systemd.services.lazymc.serviceConfig = {
      # env files in mc-start's order; the pack one optional because ExecStartPre writes it on first boot
      EnvironmentFile = [ serverEnv "-/var/lib/minecraft/modpack.env" ];
      ExecStart = lib.mkForce (pkgs.writeShellScript "fake-lazymc" ''
        env | grep -E '^(TYPE|MODRINTH_MODPACK|CF_PAGE_URL|VERSION|LEVEL|RCON_PASSWORD|CF_API_KEY)=' | sort > /tmp/server-env
        exec sleep infinity
      '');
    };
  };

  testScript = ''
    secrets = ${builtins.toJSON secrets}

    def env():
        vm_214.wait_until_succeeds("test -s /tmp/server-env")
        out = vm_214.succeed("cat /tmp/server-env")
        vm_214.succeed("rm /tmp/server-env")
        return dict(l.split("=", 1) for l in out.strip().splitlines())

    vm_214.wait_for_unit("lazymc.service")

    with subtest("first boot writes the default pack; the secrets and the lazymc config live under /run only"):
        e = env()
        assert e == {"TYPE": "VANILLA", "VERSION": "LATEST", "LEVEL": "vanilla", **secrets}, e
        vm_214.succeed("grep -q 'password = \"test-minecraft-rcon-password\"' /run/secrets/rendered/lazymc.toml")
        vm_214.fail("grep -rq test-minecraft /var/lib/minecraft /var/lib/minecraft-modpacks")

    with subtest("switch to another Modrinth pack"):
        vm_214.succeed("mc-modpack https://modrinth.com/modpack/fabulously-optimized 1.21.4")
        e = env()
        assert e == {"TYPE": "MODRINTH", "MODRINTH_MODPACK": "https://modrinth.com/modpack/fabulously-optimized",
                     "VERSION": "1.21.4", "LEVEL": "fabulously-optimized", **secrets}, e

    with subtest("CurseForge URL"):
        vm_214.succeed("mc-modpack https://www.curseforge.com/minecraft/modpacks/all-the-mods-10/")
        e = env()
        assert e["TYPE"] == "AUTO_CURSEFORGE", e
        assert e["CF_PAGE_URL"] == "https://www.curseforge.com/minecraft/modpacks/all-the-mods-10/", e
        assert e["LEVEL"] == "all-the-mods-10" and e["VERSION"] == "LATEST", e
        assert "MODRINTH_MODPACK" not in e, e

    with subtest("back to vanilla"):
        vm_214.succeed("mc-modpack vanilla")
        e = env()
        assert e["TYPE"] == "VANILLA" and e["LEVEL"] == "vanilla", e

    with subtest("no argument shows the current pack and changes nothing"):
        out = vm_214.succeed("mc-modpack")
        assert "TYPE=VANILLA" in out, out
        vm_214.fail("test -e /tmp/server-env")

    with subtest("choice and secrets survive a restart (pre-start re-runs)"):
        vm_214.succeed("systemctl restart lazymc.service")
        e = env()
        assert e["TYPE"] == "VANILLA" and e["CF_API_KEY"] == secrets["CF_API_KEY"], e
  '';
}
