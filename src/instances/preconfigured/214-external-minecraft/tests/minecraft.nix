# minecraft on vm-214: mc-gate owns the public port and wakes one server at a time
#
# The guest boots as it does in the lab, with two servers declared instead of one (a Conflicts= and a switch need a
# second one) and the container swapped for cmd/fake-server: a vm test has no image, no world and no jvm, but
# every other property of the units is the production one and is really exercised. What runs no container is read off
# the unmodified guest's own unit text instead (node `plain`), so the run options and the podman stop verbs are
# asserted against what the lab would run, never against something the test wrote itself. The settings file is the
# generated one with only the waiting times shortened, through a mutable path so a reload can add a server to it.
{
  pkgs,
  lib,
  specialArgs,
  ...
}:
let
  lab = import ../../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
  mcGate = import ../lib/mc-gate.nix { inherit pkgs lib; };

  # the test's servers: cobblemon is the lab's (mc-layout moves the old data dir into it), vanilla declares neither a
  # version nor a protocol, which is the other half of the status answer
  servers = {
    cobblemon = {
      version = "1.21.1";
      protocol = 767;
    };
    vanilla = { };
  };
  # whose fake backend ignores SIGTERM: a stop that has to kill is what the stop and fake-server subtests want to see
  stubborn = [ "cobblemon" ];

  guestIp = lab.inventory."214".ip;
  gatePort = 25565;
  backendPort = 25566;
  suffix = "mc.lsck0.dev";

  # the gate reads its settings through /etc as in the lab, but the file below it is the test's, so the reload subtest can add a
  # server to it and reload
  settingsPath = "/var/lib/mc-gate-test/settings.json";
  settingsDir = builtins.dirOf settingsPath;
  probeDir = "/run/mc-probe";
  stateFile = "/run/mc-gate/state.json";
  data = "/var/lib/minecraft";
  extraMods = "/var/lib/minecraft-modpacks/extra";
  # the gate's metrics; the link the node exporter reads them through is the guest's own option
  metricsFile = "/var/lib/mc-gate/metrics.prom";

  # only the bounds a test would otherwise have to sit out; every other limit stays the lab's. The budgets are raised
  # because one test drives more starts in ten minutes than a household does in an hour (they are decided in Go tests).
  testLimits = {
    statusCacheS = 1;
    reconcileS = 1;
    loginGraceS = 2;
    rejoinS = 5;
    minimumOnlineS = 5;
    startsPerSourcePerHourMax = 100;
    switchesPerHourMax = 100;
  };

  # how long the stand-in stop gives a backend before it kills it, below the unit's TimeoutStopSec and long enough
  # for the test to look at a server while it stops
  stopGraceS = 8;

  probe = pkgs.writers.writePython3Bin "mc-probe" {
    flakeIgnore = [
      "E501"
      "E203"
      "W503"
    ];
  } (builtins.readFile ./mc-probe.py);

  # the version name vanilla's backend reports after the deploy the stale subtest switches to
  deployedVersion = "vanilla-deployed";

  # what the server unit runs instead of `podman run`: the same port, a version name the status ping shows, and for
  # the stubborn one the flag that makes its stop a kill
  fakeStart =
    name: version:
    lib.concatStringsSep " " (
      [
        "${mcGate.package}/bin/fake-server"
        "-listen 127.0.0.1:${toString backendPort}"
        "-version ${version}"
        "-protocol 767"
      ]
      ++ lib.optional (lib.elem name stubborn) "-ignore-sigterm"
    );

  # stands in for `podman stop --time 120 <container>`: there is no container to stop, and a backend that ignores
  # SIGTERM must still end, which is what the container's own stop does for the jvm
  fakeStop = pkgs.writeShellScript "minecraft-fake-stop" ''
    kill -TERM "$MAINPID" 2>/dev/null || exit 0
    for _ in $(seq ${toString stopGraceS}); do
      kill -0 "$MAINPID" 2>/dev/null || exit 0
      sleep 1
    done
    kill -KILL "$MAINPID"
  '';

  # mods for mc-mod: litematicatool for 1.21 to 1.21.1 under two file names, and one for 1.21.0 alone
  modJars =
    let
      toml = id: minecraft: ''
        [[mods]]
        modId = "${id}"
        version = "2.0.0"

        [[dependencies.${id}]]
        modId = "neoforge"
        type = "required"
        versionRange = "[21.0,)"

        [[dependencies.${id}]]
        modId = "minecraft"
        type = "required"
        versionRange = "${minecraft}"
      '';
      jar = name: id: minecraft: ''
        mkdir -p ${name}/META-INF
        printf '%s' ${lib.escapeShellArg (toml id minecraft)} > ${name}/META-INF/neoforge.mods.toml
        (cd ${name} && zip -q -r $out/${name}.jar META-INF)
      '';
    in
    pkgs.runCommand "mc-mod-jars" { nativeBuildInputs = [ pkgs.zip ]; } ''
      mkdir -p $out
      ${jar "fits" "litematicatool" "[1.21,1.21.2)"}
      ${jar "fits-2" "litematicatool" "[1.21,1.21.2)"}
      ${jar "old" "oldmod" "[1.21,1.21.1)"}
    '';

  settingsFor =
    production:
    pkgs.runCommand "mc-gate-settings-test.json" { nativeBuildInputs = [ pkgs.jq ]; } ''
      jq --argjson limits ${lib.escapeShellArg (builtins.toJSON testLimits)} '.limits += $limits' ${production} > $out
    '';

  guest = {
    imports = [ (lab.guest "214" { instance = ../main.nix; }) ];
    _module.args.mcServers = servers;
  };
in
pkgs.testers.runNixOSTest {
  name = "minecraft";

  node.specialArgs = lab.specialArgs;

  # the guest as the lab builds it, never booted: the test reads the unit text of the things a vm cannot run. Only
  # its hostname differs, because the driver names a machine after it and vm-214 is taken; no unit below reads it.
  nodes.plain = {
    imports = [ guest ];
    networking.hostName = lib.mkForce "plain";
  };

  nodes.vm-214 =
    { nodes, ... }:
    let
      testSettings = settingsFor nodes.plain.environment.etc."mc-gate/settings.json".source;
    in
    {
      imports = [ guest ];
      # podman, two java-less servers and a relay: the driver's default is tight for the pre-start alone
      virtualisation.memorySize = 2048;
      environment.systemPackages = [
        probe
        pkgs.jq
      ];

      # no collector in this test: a failing upload would fail the switch below for a reason outside the servers
      services.journald.upload.enable = lib.mkForce false;
      # a deploy that changes vanilla's unit under it, for the stale subtest
      specialisation.deployed.configuration.systemd.services.minecraft-vanilla.serviceConfig.ExecStart = lib.mkOverride 40 (
        fakeStart "vanilla" deployedVersion
      );

      environment.etc."mc-gate/settings.json".source = lib.mkForce settingsPath;
      systemd.tmpfiles.rules = [
        "d ${settingsDir} 0755 root root -"
        "C ${settingsPath} 0644 root root - ${testSettings}"
        "d ${probeDir} 0755 root root -"
      ];

      systemd.services = {
        # a unit of this guest that is no server, for the polkit refusal
        notaserver = {
          description = "a unit the gate has no business starting";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };
      }
      // lib.mapAttrs' (
        name: _:
        lib.nameValuePair "minecraft-${name}" {
          serviceConfig = {
            ExecStart = lib.mkForce (fakeStart name name);
            ExecStop = lib.mkForce "${fakeStop}";
          };
        }
      ) servers;
    };

  testScript =
    { nodes, ... }:
    ''
      import json
      import re
      import time

      GUEST = "${guestIp}"
      GATE = "${guestIp}:${toString gatePort}"
      BACKEND = "127.0.0.1:${toString backendPort}"
      SUFFIX = "${suffix}"
      PROBE = "${probe}/bin/mc-probe"
      PROBE_DIR = "${probeDir}"
      DATA = "${data}"
      EXTRA_MODS = "${extraMods}"
      JARS = "${modJars}"
      DATA_AUTOMOUNT = "${lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" data)}.automount"
      STATE = "${stateFile}"
      METRICS = "${metricsFile}"
      TEXTFILE = "${nodes.vm-214.homelab.textfileDir}/mc-gate.prom"
      SETTINGS = "${settingsPath}"
      DEPLOY_PENDING_DIR = "/var/lib/homelab"
      DEPLOY_PENDING = f"{DEPLOY_PENDING_DIR}/deploy-pending"
      MINIMUM_ONLINE_S = ${toString testLimits.minimumOnlineS}
      DEPLOYED_VERSION = "${deployedVersion}"
      # the unit files of the guest with nothing forced: what the lab would really run
      PLAIN_UNITS = ${
        builtins.toJSON (
          lib.mapAttrs (
            name: _: "${nodes.plain.systemd.units."minecraft-${name}.service".unit}/minecraft-${name}.service"
          ) servers
        )
      }
      SERVERS = sorted(PLAIN_UNITS)

      def last_line(out):
          # the driver merges stderr into the output, so the answer is the last line, never the whole of it
          lines = [line for line in out.strip().splitlines() if line.strip()]
          assert lines, "no output"
          return lines[-1].strip()

      def plain_unit(name):
          with open(PLAIN_UNITS[name]) as handle:
              return handle.read()

      def plain_property(name, key):
          for line in plain_unit(name).splitlines():
              if line.startswith(key + "="):
                  return line[len(key) + 1:].strip()
          raise AssertionError(f"{name}: no {key} in its unit")

      def plain_start_script(name):
          with open(plain_property(name, "ExecStart")) as handle:
              return handle.read()

      def show(unit, *properties):
          out = vm_214.succeed("systemctl show %s %s" % (unit, " ".join("-p " + p for p in properties)))
          return dict(line.split("=", 1) for line in out.strip().splitlines() if "=" in line)

      def status(name, target=GATE, address=None):
          address = address if address is not None else f"{name}.{SUFFIX}"
          return json.loads(last_line(vm_214.succeed(f"mc-probe status {target} {address}")))

      def modpack(name):
          text = vm_214.succeed(f"cat {DATA}/{name}/modpack.env").strip()
          return dict(line.split("=", 1) for line in text.splitlines())

      def login(name, player="tester"):
          address = f"{name}.{SUFFIX}"
          return last_line(vm_214.succeed(f"mc-probe login {GATE} {address} --player {player}"))

      def session_open(tag, name, target=GATE, player="tester", hold=600):
          """A player sitting on a server: a login held open in its own transient unit, so the gate counts a session."""
          log = f"{PROBE_DIR}/{tag}.log"
          address = f"{name}.{SUFFIX}"
          vm_214.succeed(f"rm -f {log}")
          vm_214.succeed(
              f"systemd-run --unit={tag} --collect -p StandardOutput=file:{log} -p StandardError=file:{log} "
              f"{PROBE} login {target} {address} --player {player} --hold {hold}"
          )
          vm_214.wait_until_succeeds(f"test -s {log}", timeout=120)
          return last_line(vm_214.succeed(f"cat {log}"))

      def session_close(tag):
          vm_214.succeed(f"systemctl stop {tag}.service || true")

      def state():
          return json.loads(vm_214.succeed("mc-state"))

      def server_state(name):
          for server in state()["servers"]:
              if server["name"] == name:
                  return server
          raise AssertionError(f"{name} is in no state file")

      def retry_ok(check):
          """retry() over a check that talks to the guest: a command that errors is one more try, not the verdict."""
          def attempt(_):
              try:
                  return check()
              except Exception:
                  return False
          retry(attempt)

      def phases():
          return {server["name"]: server["phase"] for server in state()["servers"]}

      def wait_phase(name, phase):
          retry_ok(lambda: phases().get(name) == phase)

      def servers_sleep():
          """Back to the ground state: nothing runs, nothing failed, every server sleeps."""
          for name in SERVERS:
              vm_214.succeed(f"systemctl stop minecraft-{name}.service")
              vm_214.succeed(f"systemctl reset-failed minecraft-{name}.service || true")
          for name in SERVERS:
              wait_phase(name, "sleeping")

      def layout_restart(journal=False):
          """mc-layout again. reset-failed clears the start rate limit the repeated runs below would hit."""
          vm_214.succeed("systemctl reset-failed mc-layout.service")
          cmd = "systemctl restart mc-layout.service"
          if journal:
              cmd += "; journalctl -u mc-layout.service -n 5 --no-pager"
          return vm_214.succeed(cmd)

      def login_until(name, pattern, tries=60):
          """The gate answers a login by what it knows now, so a decision the test waits for is asked for again."""
          last = ""
          for _ in range(tries):
              last = login(name)
              if re.fullmatch(pattern, last):
                  return last
              time.sleep(1)
          raise AssertionError(f"login {name}: {last!r} never matched {pattern!r}")

      vm_214.wait_for_unit("mc-layout.service")
      vm_214.wait_for_unit("mc-gate.service")
      vm_214.wait_for_open_port(${toString gatePort}, GUEST)

      with subtest("route"):
          # lazymc and everything it owned are gone, and the public port is the gate's own
          vm_214.fail("systemctl cat lazymc.service")
          vm_214.fail("test -e /run/secrets/rendered/lazymc.toml")
          listener = vm_214.succeed("ss -Hltnp 'sport = :${toString gatePort}'")
          assert "mc-gate" in listener, listener
          # ss renders the unspecified address as a star: the gate takes the port on every address
          assert "*:${toString gatePort}" in listener, listener
          # and it is the gate that answers there, not a server: a sleeping name still gets a status
          answer = status("cobblemon")
          assert answer["description"]["text"] == "[cobblemon] sleeping, join to start it", answer

      with subtest("user"):
          gate = show("mc-gate.service", "ExecStart", "User", "Group", "StateDirectory", "StateDirectoryMode",
                      "RuntimeDirectory")
          assert "/bin/mc-gate -settings /etc/mc-gate/settings.json" in gate["ExecStart"], gate["ExecStart"]
          assert gate["User"] == "mc-gate" and gate["Group"] == "mc-gate", gate
          assert gate["StateDirectory"] == "mc-gate" and gate["StateDirectoryMode"] == "0755", gate
          assert gate["RuntimeDirectory"] == "mc-gate", gate
          assert vm_214.succeed("id -u mc-gate") and "mc-gate" in vm_214.succeed("stat -c %U /var/lib/mc-gate")
          vm_214.succeed("test -d /run/mc-gate")
          # the settings it reads are the generated ones, only the waiting times shortened
          settings = json.loads(vm_214.succeed(f"cat {SETTINGS}"))
          assert settings["listen"] == "0.0.0.0:${toString gatePort}", settings["listen"]
          assert settings["suffix"] == ".${suffix}", settings["suffix"]
          assert [server["name"] for server in settings["servers"]] == SERVERS, settings["servers"]

      with subtest("restart"):
          gate = show("mc-gate.service", "Restart", "Wants", "After")
          assert gate["Restart"] == "always", gate
          assert "mc-layout.service" in gate["Wants"], gate
          assert "mc-layout.service" in gate["After"], gate

      with subtest("no restart"):
          # a restart would cut every player, so a changed binary waits for the owner
          unit = vm_214.succeed("systemctl cat mc-gate.service")
          assert "X-RestartIfChanged=false" in unit, unit
          # nor does a deploy restart a running server, or mc-layout, which its Requires= would carry over
          for name in SERVERS:
              assert "X-RestartIfChanged=false" in plain_unit(name), plain_unit(name)
          assert "X-RestartIfChanged=false" in vm_214.succeed("systemctl cat mc-layout.service")

      with subtest("status"):
          # nothing has started yet, so no server has ever answered a status of its own: these are the declared values
          sleeping = status("cobblemon")
          assert sleeping["version"] == {"name": "1.21.1", "protocol": 767}, sleeping
          assert sleeping["players"]["online"] == 0 and not sleeping["players"]["sample"], sleeping
          assert sleeping["description"]["text"] == "[cobblemon] sleeping, join to start it", sleeping
          # a server that declares neither falls back to the same unknown as a name that is no server
          undeclared = status("vanilla")
          assert undeclared["version"] == {"name": "?", "protocol": -1}, undeclared
          assert undeclared["description"]["text"] == "[vanilla] sleeping, join to start it", undeclared
          unknown = status("nope")
          assert unknown["version"] == {"name": "?", "protocol": -1}, unknown
          assert unknown["description"]["text"] == "no such server", unknown

      with subtest("layout"):
          layout = show("mc-layout.service", "Type", "RemainAfterExit", "Requires", "After")
          assert layout["Type"] == "oneshot" and layout["RemainAfterExit"] == "yes", layout
          assert DATA_AUTOMOUNT in layout["Requires"] and DATA_AUTOMOUNT in layout["After"], layout
          assert "active" in vm_214.succeed("systemctl is-active mc-layout.service")

      with subtest("move"):
          # a data dir that holds no old layout is left alone, which is every boot after the one move
          out = layout_restart(journal=True)
          assert "holds no old layout" in out, out
          vm_214.fail(f"test -e {DATA}/cobblemon")
          # the as-built layout: the world and the pack straight in the data dir, the shared files beside them
          vm_214.succeed(f"mkdir -p {DATA}/world {DATA}/mods")
          vm_214.succeed(f"echo level > {DATA}/world/level.dat")
          vm_214.succeed(f"printf 'TYPE=VANILLA\\n' > {DATA}/modpack.env")
          vm_214.succeed(f"echo cached > {DATA}/.cache")
          vm_214.succeed(f"echo '[]' > {DATA}/whitelist.json; echo '[]' > {DATA}/ops.json")
          layout_restart()
          vm_214.succeed(f"test -d {DATA}/cobblemon")
          # and the move happens once: the dir it made is not moved into itself on the next run
          vm_214.succeed(f"rm -rf {DATA}/cobblemon")

      with subtest("entries"):
          # the same old layout again, with a move that was cut halfway: the temp dir already holds part of it
          vm_214.succeed(f"mkdir -p {DATA}/world {DATA}/mods")
          vm_214.succeed(f"echo level > {DATA}/world/level.dat")
          vm_214.succeed(f"printf 'TYPE=VANILLA\\n' > {DATA}/modpack.env")
          vm_214.succeed(f"echo cached > {DATA}/.cache")
          vm_214.succeed(f"install -d -m 0750 -o 1000 -g 1000 {DATA}/cobblemon.tmp")
          vm_214.succeed(f"mv {DATA}/mods {DATA}/cobblemon.tmp/")
          layout_restart()
          left = sorted(vm_214.succeed(f"ls -A {DATA}").split())
          assert left == ["cobblemon", "ops.json", "whitelist.json"], left
          moved = sorted(vm_214.succeed(f"ls -A {DATA}/cobblemon").split())
          assert moved == [".cache", "modpack.env", "mods", "world"], moved
          assert vm_214.succeed(f"cat {DATA}/cobblemon/world/level.dat").strip() == "level"

      with subtest("rename"):
          vm_214.fail(f"test -e {DATA}/cobblemon.tmp")
          assert vm_214.succeed(f"stat -c '%a %u %g' {DATA}/cobblemon").strip() == "750 1000 1000"
          out = layout_restart(journal=True)
          assert "holds no old layout" in out, out
          assert sorted(vm_214.succeed(f"ls -A {DATA}/cobblemon").split()) == [".cache", "modpack.env", "mods", "world"]
          # a temp dir left by a snapshot of a half-done move is no reason to move a migrated layout again
          vm_214.succeed(f"install -d -m 0750 -o 1000 -g 1000 {DATA}/cobblemon.tmp")
          out = layout_restart(journal=True)
          assert "holds no old layout" in out, out
          assert sorted(vm_214.succeed(f"ls -A {DATA}/cobblemon").split()) == [".cache", "modpack.env", "mods", "world"]
          vm_214.succeed(f"rmdir {DATA}/cobblemon.tmp")
          # and a world dir that is merely named like the server is not a migrated layout either: it is moved in
          vm_214.succeed(f"rm -rf {DATA}/cobblemon")
          vm_214.succeed(f"mkdir -p {DATA}/cobblemon/world")
          vm_214.succeed(f"echo level > {DATA}/cobblemon/world/level.dat")
          vm_214.succeed(f"printf 'TYPE=VANILLA\\n' > {DATA}/modpack.env")
          layout_restart()
          assert sorted(vm_214.succeed(f"ls -A {DATA}/cobblemon").split()) == ["cobblemon", "modpack.env"]
          assert vm_214.succeed(f"cat {DATA}/cobblemon/cobblemon/world/level.dat").strip() == "level"
          vm_214.succeed(f"rm -rf {DATA}/cobblemon")

      with subtest("pre start"):
          # the script is the lab's own, run here unforced: it makes the dir, clears a leftover container and writes
          # the default pack
          found = re.search(r"path=(\S+)", show("minecraft-vanilla.service", "ExecStartPre")["ExecStartPre"])
          assert found, "the unit has no ExecStartPre path"
          text = vm_214.succeed(f"cat {found.group(1)}")
          assert f"install -d -m 0750 -o 1000 -g 1000 {DATA}/vanilla" in text, text
          assert "podman rm --force --ignore minecraft-vanilla" in text, text
          vm_214.fail(f"test -e {DATA}/vanilla")
          # a jar copied in by root as 0600, which the container's user could not read
          vm_214.succeed(f"mkdir -p {EXTRA_MODS}/vanilla && install -m 0600 {JARS}/fits.jar {EXTRA_MODS}/vanilla/")
          vm_214.succeed("systemctl start minecraft-vanilla.service")
          assert vm_214.succeed(f"stat -c '%a %u %g' {DATA}/vanilla").strip() == "750 1000 1000"
          for path, mode in [(EXTRA_MODS, "750"), (f"{EXTRA_MODS}/vanilla", "750"), (f"{EXTRA_MODS}/vanilla/fits.jar", "640")]:
              assert vm_214.succeed(f"stat -c '%a %u %G' {path}").strip() == f"{mode} 1000 minecraft", path
          vm_214.succeed(f"rm {EXTRA_MODS}/vanilla/fits.jar")
          pack = modpack("vanilla")
          assert pack == {"TYPE": "VANILLA", "VERSION": "LATEST", "LEVEL": "vanilla"}, pack
          # it also writes the shared files when they are missing, empty and readable by the container's user
          for shared in ["whitelist.json", "ops.json"]:
              assert vm_214.succeed(f"cat {DATA}/{shared}").strip() == "[]"
          vm_214.succeed("systemctl stop minecraft-vanilla.service")

      with subtest("run"):
          # no container runs in a vm test, so the option list is read off the unit the lab would run
          for name in SERVERS:
              start = plain_start_script(name)
              for option in [
                  f"podman run --rm --name minecraft-{name} --log-driver=passthrough",
                  "--dns=1.1.1.1 --dns=8.8.8.8",
                  "-p 127.0.0.1:25566:25565",
                  "-p 127.0.0.1:25575:25575",
                  f"-v {DATA}/{name}:/data -v /var/lib/minecraft-modpacks:/modpacks:ro",
                  f"--env-file /run/secrets/rendered/minecraft-server.env --env-file {DATA}/{name}/modpack.env",
                  "itzg/minecraft-server:2026.9.1-java21",
              ]:
                  assert option in start, f"{name}: {option} missing from {start}"
              # a cap below the guest's memory, so an overrun ends in the container and not in sshd or the gate
              assert re.search(r"--memory=\d+m ", start), start
              # the secrets come before the pack, so a pack file could never shadow the rcon password
              assert start.index("minecraft-server.env") < start.index(f"{DATA}/{name}/modpack.env"), start
              options = re.findall(r'-e "?([A-Z_]+)=([^"\n\\]*)', start)
              environment = {key: value.strip() for key, value in options}
              assert environment == {
                  "EULA": "TRUE", "MEMORY": "5G", "DIFFICULTY": "hard", "ALLOW_FLIGHT": "false",
                  "ICON": "/modpacks/server-icon.png",
                  "OVERRIDE_ICON": "TRUE", "MOTD": f"[{name}] nya~ minecwaft sewvew 🐾✨",
                  "USE_AIKAR_FLAGS": "true", "VIEW_DISTANCE": "12", "SIMULATION_DISTANCE": "8",
                  "SPAWN_PROTECTION": "0", "MAX_PLAYERS": "42069", "ENABLE_RCON": "true",
                  "ENABLE_WHITELIST": "true", "ENFORCE_WHITELIST": "true", "REMOVE_OLD_MODS": "TRUE",
                  "MAX_TICK_TIME": "-1", "STOP_DURATION": "90", "MODS": f"/modpacks/extra/{name}",
              }, environment

      with subtest("gate stats the pack"):
          # the start timeout reads modpack.env's mtime through the 0750 data dirs, as the unit's supplementary group
          assert show("mc-gate.service", "SupplementaryGroups")["SupplementaryGroups"] == "minecraft"
          vm_214.succeed(
              f"systemd-run --wait --pipe -p User=mc-gate -p SupplementaryGroups=minecraft stat {DATA}/vanilla/modpack.env"
          )

      with subtest("timeouts"):
          for name in SERVERS:
              unit = show(f"minecraft-{name}.service", "TimeoutStopUSec", "TimeoutStartUSec")
              assert unit["TimeoutStopUSec"] == "2min 30s", unit
              assert unit["TimeoutStartUSec"] == "infinity", unit

      with subtest("requires"):
          for name in SERVERS:
              unit = show(f"minecraft-{name}.service", "Requires", "After")
              assert DATA_AUTOMOUNT in unit["Requires"] and DATA_AUTOMOUNT in unit["After"], unit
              assert "mc-layout.service" in unit["Requires"], unit
              assert "mc-layout.service" in unit["After"], unit

      with subtest("deploy pending"):
          # marked before this boot, as a sync marks the guest terraform then reboots: nothing starts, nothing fails
          vm_214.succeed(
              f"mkdir -p {DEPLOY_PENDING_DIR} && "
              f"touch -d @$(( $(date +%s) - $(cut -d. -f1 /proc/uptime) - 60 )) {DEPLOY_PENDING}"
          )
          vm_214.succeed("systemctl start minecraft-vanilla.service")
          unit = show("minecraft-vanilla.service", "ActiveState", "Result")
          assert unit == {"ActiveState": "inactive", "Result": "success"}, unit
          vm_214.succeed("journalctl -u minecraft-vanilla.service --grep 'rebooted under a sync' --no-pager")
          # marked since this boot: no reboot put it on the old generation
          vm_214.succeed(f"touch {DEPLOY_PENDING}")
          vm_214.succeed("systemctl start minecraft-vanilla.service")
          vm_214.succeed("systemctl is-active --quiet minecraft-vanilla.service")
          servers_sleep()
          # a run that died before the deploy: its mark expires
          vm_214.succeed(f"touch -d '1 day ago' {DEPLOY_PENDING}")
          vm_214.succeed("systemctl start minecraft-vanilla.service")
          vm_214.succeed("systemctl is-active --quiet minecraft-vanilla.service")
          vm_214.succeed(f"rm {DEPLOY_PENDING}")
          servers_sleep()

      with subtest("no wantedby"):
          # only the gate starts a server, so nothing pulls one in at boot
          for name in SERVERS:
              unit = show(f"minecraft-{name}.service", "WantedBy", "RequiredBy", "ActiveState")
              assert unit["WantedBy"] == "", unit
              assert unit["RequiredBy"] == "", unit
              assert "WantedBy=" not in plain_unit(name), plain_unit(name)

      with subtest("conflicts"):
          for name in SERVERS:
              others = [f"minecraft-{other}.service" for other in SERVERS if other != name]
              earlier = [f"minecraft-{other}.service" for other in SERVERS if other < name]
              unit = show(f"minecraft-{name}.service", "Conflicts", "After")
              for other in others:
                  assert other in unit["Conflicts"], unit
              after = [word for word in unit["After"].split() if word.startswith("minecraft-")]
              assert sorted(after) == earlier, (name, after, earlier)
          # and a hand start of the second really stops the first: one heap, one game port
          vm_214.succeed("systemctl start minecraft-cobblemon.service")
          vm_214.succeed("systemctl start minecraft-vanilla.service")
          vm_214.succeed("systemctl is-active minecraft-vanilla.service")
          vm_214.fail("systemctl is-active --quiet minecraft-cobblemon.service")

      with subtest("stop"):
          # again the lab's own unit: the client is left alone and the container is stopped and removed
          for name in SERVERS:
              assert plain_property(name, "ExecStop").endswith(f"/bin/podman stop --time 120 minecraft-{name}")
              assert plain_property(name, "ExecStopPost").endswith(f"/bin/podman rm --force --ignore minecraft-{name}")
          # what that stop has to survive: a backend that ignores SIGTERM. It is killed, and the next server binds
          vm_214.succeed("systemctl stop minecraft-vanilla.service")
          vm_214.succeed("systemctl start minecraft-cobblemon.service")
          vm_214.wait_until_succeeds(f"mc-probe status {BACKEND} direct", timeout=120)
          pid = int(show("minecraft-cobblemon.service", "MainPID")["MainPID"])
          vm_214.succeed(f"kill -TERM {pid}")
          vm_214.sleep(3)
          vm_214.succeed(f"kill -0 {pid}")
          vm_214.succeed("systemctl stop minecraft-cobblemon.service")
          vm_214.fail(f"kill -0 {pid}")
          vm_214.succeed("systemctl start minecraft-vanilla.service")
          vm_214.wait_until_succeeds(f"mc-probe status {BACKEND} direct", timeout=120)
          assert status("vanilla", target=BACKEND, address="direct")["version"]["name"] == "vanilla"

      with subtest("fake server"):
          # the fake answers with its live sessions, which is what the gate's occupancy reads back
          assert status("vanilla", target=BACKEND, address="direct")["players"]["online"] == 0
          assert session_open("r058", "vanilla", target=BACKEND) == "success tester"
          retry_ok(lambda: status("vanilla", target=BACKEND, address="direct")["players"]["online"] == 1)
          session_close("r058")
          retry_ok(lambda: status("vanilla", target=BACKEND, address="direct")["players"]["online"] == 0)
          # and without the flag it dies of SIGTERM, which is what made the kill above a real difference
          pid = int(show("minecraft-vanilla.service", "MainPID")["MainPID"])
          vm_214.succeed(f"kill -TERM {pid}")
          vm_214.wait_until_fails("systemctl is-active --quiet minecraft-vanilla.service", timeout=60)
          servers_sleep()

      with subtest("shared whitelist"):
          # every server mounts the same two files, file by file, onto /data
          mounts = {}
          for name in SERVERS:
              mounts[name] = dict(re.findall(r"-v (\S+):(/data/\S+)", plain_start_script(name)))
              assert mounts[name] == {f"{DATA}/whitelist.json": "/data/whitelist.json",
                                      f"{DATA}/ops.json": "/data/ops.json"}, mounts[name]
          # a vm test runs no container, so the test performs exactly the bind mounts those options ask for
          for name, pairs in mounts.items():
              for host, target in pairs.items():
                  inside = f"/run/mc-shared/{name}{target}"
                  vm_214.succeed(f"mkdir -p $(dirname {inside}) && touch {inside} && mount --bind {host} {inside}")
          vm_214.succeed("""printf '[{"name":"friend"}]' > /run/mc-shared/cobblemon/data/whitelist.json""")
          assert "friend" in vm_214.succeed("cat /run/mc-shared/vanilla/data/whitelist.json")
          assert "friend" in vm_214.succeed(f"cat {DATA}/whitelist.json")
          for name, pairs in mounts.items():
              for target in pairs.values():
                  vm_214.succeed(f"umount /run/mc-shared/{name}{target}")
          vm_214.succeed(f"echo '[]' > {DATA}/whitelist.json")

      with subtest("login"):
          # a login for a sleeping server wakes it and is kicked with the text that says so
          assert login("cobblemon") == "kick cobblemon is starting, rejoin in about a minute", "the wrong kick"
          wait_phase("cobblemon", "running")
          # the rejoin lands on the backend: the gate relays, it does not answer a login itself
          assert session_open("r043", "cobblemon") == "success tester"
          retry_ok(lambda: server_state("cobblemon")["sessions"] == 1)
          session_close("r043")

      with subtest("decisions"):
          # one player on cobblemon: the other server is refused rather than taking the heap away from them
          assert session_open("r052", "cobblemon") == "success tester"
          retry_ok(lambda: server_state("cobblemon")["sessions"] == 1)
          refused = login_until("vanilla", r"kick cobblemon is running with \d+ players, try again later", tries=30)
          # they leave; once cobblemon has had its minimum online time the switch is allowed
          session_close("r052")
          switch = login_until("vanilla", r"kick vanilla is starting, rejoin in about a minute",
                               tries=MINIMUM_ONLINE_S + 30)
          assert switch == "kick vanilla is starting, rejoin in about a minute", switch
          # during the switch the old server is stopping, and says so
          assert login("cobblemon") == "kick cobblemon is stopping, try again in a minute", "the wrong kick"
          # and a name that is no server is told which ones are
          unknown = login("nope")
          assert unknown == "kick no server nope here; servers: %s" % ", ".join(SERVERS), unknown
          wait_phase("vanilla", "running")

      with subtest("reload"):
          gate = show("mc-gate.service", "ExecReload")
          assert "/bin/kill -HUP $MAINPID" in gate["ExecReload"], gate
          unit = vm_214.succeed("systemctl cat mc-gate.service")
          trigger = re.search(r"X-Reload-Triggers=(\S+)", unit)
          assert trigger, unit
          # nixos keeps the triggers in a file of their own and names it here; the generated settings is one of them
          triggers = vm_214.succeed(f"cat {trigger.group(1)}")
          assert "mc-gate-settings.json" in triggers, triggers
          # a player is on vanilla while the server list grows: the reload must not touch their connection
          assert session_open("r074", "vanilla") == "success tester"
          retry_ok(lambda: server_state("vanilla")["sessions"] == 1)
          added = json.dumps({"name": "extra", "unit": "minecraft-extra.service", "version": None, "protocol": None,
                              "modpackEnv": f"{DATA}/extra/modpack.env", "startedUnit": "/run/minecraft-extra/unit"})
          vm_214.succeed(f"jq '.servers += [{added}]' {SETTINGS} > {SETTINGS}.tmp && mv {SETTINGS}.tmp {SETTINGS}")
          vm_214.succeed("systemctl reload mc-gate.service")
          retry_ok(lambda: "extra" in phases())
          assert phases()["extra"] == "sleeping", phases()
          extra = status("extra")
          assert extra["version"] == {"name": "?", "protocol": -1}, extra
          # a ping of a sleeping server names the one that is awake instead, and vanilla still is
          assert re.fullmatch(r"\[extra\] vanilla is running with \d+ players", extra["description"]["text"]), extra
          # the session is still there, and still relayed: the reload reloaded, it did not restart
          assert "active" in vm_214.succeed("systemctl is-active r074.service")
          assert server_state("vanilla")["sessions"] == 1
          session_close("r074")
          # back to the declared servers, so the texts below name those
          vm_214.succeed(f"jq '.servers |= map(select(.name != \"extra\"))' {SETTINGS} > {SETTINGS}.tmp"
                         f" && mv {SETTINGS}.tmp {SETTINGS}")
          vm_214.succeed("systemctl reload mc-gate.service")
          retry_ok(lambda: "extra" not in phases())

      with subtest("stale"):
          def stale_metric():
              text = vm_214.succeed(f"cat {METRICS}")
              found = re.search(r'^homelab_minecraft_server_stale\{server="vanilla"\} (\d+)$', text, re.M)
              assert found, text
              return int(found.group(1))

          # the start recorded the unit file it ran from, the unit's own store path rather than the whole unit dir's
          started = vm_214.succeed("cat /run/minecraft-vanilla/unit").strip()
          assert re.fullmatch(r"/nix/store/[^/]+-unit-minecraft-vanilla\.service/minecraft-vanilla\.service", started), started
          assert not server_state("vanilla")["stale"] and stale_metric() == 0
          # a player is on vanilla while a deploy changes its unit: the server keeps running the old one
          assert session_open("r090", "vanilla") == "success tester"
          retry_ok(lambda: server_state("vanilla")["sessions"] == 1)
          pid = show("minecraft-vanilla.service", "MainPID")["MainPID"]
          vm_214.succeed("/run/booted-system/specialisation/deployed/bin/switch-to-configuration test")
          retry_ok(lambda: server_state("vanilla")["stale"] and stale_metric() == 1)
          # several reconcile passes with the player still on
          time.sleep(5)
          assert show("minecraft-vanilla.service", "MainPID")["MainPID"] == pid
          assert server_state("vanilla")["phase"] == "running", state()
          assert status("vanilla", target=BACKEND, address="direct")["version"]["name"] == "vanilla"
          # they leave, and the gate restarts it onto the deployed unit
          session_close("r090")
          retry_ok(lambda: status("vanilla", target=BACKEND, address="direct")["version"]["name"] == DEPLOYED_VERSION)
          wait_phase("vanilla", "running")
          retry_ok(lambda: not server_state("vanilla")["stale"] and stale_metric() == 0)
          assert vm_214.succeed("cat /run/minecraft-vanilla/unit").strip() != started
          vm_214.succeed("journalctl -u mc-gate.service --no-pager --grep '\"msg\":\"restart\".*\"reason\":\"stale\"'")

      with subtest("polkit"):
          # the gate's own user may start, stop and restart a server, and nothing else
          vm_214.succeed("runuser -u mc-gate -- systemctl start minecraft-vanilla.service")
          vm_214.succeed("runuser -u mc-gate -- systemctl restart minecraft-vanilla.service")
          vm_214.succeed("runuser -u mc-gate -- systemctl stop minecraft-vanilla.service")
          for command in ["start notaserver.service", "restart notaserver.service"]:
              out = vm_214.fail(f"runuser -u mc-gate -- systemctl {command} 2>&1").lower()
              assert "denied" in out or "authentication" in out, out
          vm_214.fail("systemctl is-active --quiet notaserver.service")

      with subtest("modpack"):
          servers_sleep()
          listing = vm_214.succeed("mc-modpack")
          for name in SERVERS:
              assert re.search(rf"^{name}: sleeping: .*TYPE=", listing, re.M), listing
          assert "usage: mc-modpack <server>" in listing, listing
          vm_214.fail("mc-modpack nope https://modrinth.com/modpack/fabulously-optimized")
          # a sleeping server takes the pack at its next start
          vm_214.succeed("mc-modpack vanilla https://modrinth.com/modpack/fabulously-optimized 1.21.4")
          pack = modpack("vanilla")
          assert pack == {"TYPE": "MODRINTH", "MODRINTH_MODPACK": "https://modrinth.com/modpack/fabulously-optimized",
                          "VERSION": "1.21.4", "LEVEL": "fabulously-optimized"}, pack
          # a running one is restarted into it
          vm_214.succeed("systemctl start minecraft-vanilla.service")
          before = show("minecraft-vanilla.service", "MainPID")["MainPID"]
          out = vm_214.succeed("mc-modpack vanilla vanilla")
          assert "was restarted into it" in out, out
          vm_214.wait_until_succeeds(
              f"test \"$(systemctl show -p MainPID --value minecraft-vanilla.service)\" != {before}", timeout=120)
          assert vm_214.succeed(f"cat {DATA}/vanilla/modpack.env").strip().startswith("TYPE=VANILLA")

      with subtest("rcon"):
          # it runs in the container of the running server, named after it
          out = vm_214.fail("mc-rcon list 2>&1")
          assert "minecraft-vanilla" in out, out
          out = vm_214.fail("mc-rcon -s cobblemon list 2>&1")
          assert "minecraft-cobblemon" in out, out
          servers_sleep()
          out = vm_214.fail("mc-rcon list 2>&1")
          assert "no server runs" in out, out

      with subtest("mods"):
          vm_214.succeed(f"printf 'TYPE=NEOFORGE\\nVERSION=1.21.1\\nNEOFORGE_VERSION=21.1.249\\n' > {DATA}/cobblemon/modpack.env")
          out = vm_214.fail(f"mc-mod add cobblemon {JARS}/old.jar 2>&1")
          assert "it needs minecraft [1.21,1.21.1), cobblemon runs 1.21.1" in out, out
          vm_214.fail(f"test -e {EXTRA_MODS}/cobblemon/old.jar")
          out = vm_214.fail(f"mc-mod add vanilla {JARS}/fits.jar 2>&1")
          assert "vanilla runs vanilla, which loads no mods" in out, out
          vm_214.fail(f"mc-mod add nope {JARS}/fits.jar")
          # installed for the container's user, and nothing restarted: the command to do it is printed
          out = vm_214.succeed(f"mc-mod add cobblemon {JARS}/fits.jar")
          assert "systemctl restart minecraft-cobblemon.service" in out, out
          vm_214.fail("systemctl is-active --quiet minecraft-cobblemon.service")
          assert vm_214.succeed(f"stat -c '%a %u %G' {EXTRA_MODS}/cobblemon/fits.jar").strip() == "640 1000 minecraft"
          listing = vm_214.succeed("mc-mod list")
          assert "fits.jar" in listing and "litematicatool" in listing, listing
          # another jar of the same mod replaces it, so two versions never load side by side
          out = vm_214.succeed(f"mc-mod add cobblemon {JARS}/fits-2.jar")
          assert "removed fits.jar" in out, out
          assert vm_214.succeed(f"ls {EXTRA_MODS}/cobblemon").split() == ["fits-2.jar"]
          out = vm_214.fail("mc-mod remove cobblemon nope 2>&1")
          assert "it has: fits-2.jar" in out, out
          vm_214.succeed("mc-mod remove cobblemon litematicatool")
          assert vm_214.succeed(f"ls -A {EXTRA_MODS}/cobblemon").strip() == ""

      with subtest("metrics"):
          # the file the gate keeps beside its state: every metric family, and a phase that is no longer true at 0
          text = vm_214.succeed(f"cat {METRICS}")
          series = {}
          for line in text.splitlines():
              if line.startswith("#") or not line.strip():
                  continue
              key, value = line.rsplit(" ", 1)
              series[key] = float(value)
          for name in SERVERS:
              assert series[f'homelab_mc_phase{{server="{name}",phase="sleeping"}}'] == 1, text
              assert series[f'homelab_mc_phase{{server="{name}",phase="running"}}'] == 0, text
              assert f'homelab_mc_sessions{{server="{name}"}}' in series, text
              assert f'homelab_mc_players{{server="{name}"}}' in series, text
              assert series[f'homelab_mc_starts_total{{server="{name}"}}'] >= 1, text
              assert f'homelab_mc_start_failures_total{{server="{name}"}}' in series, text
          assert [key for key in series if key.startswith("homelab_mc_kicks_total{")], text
          assert series["homelab_mc_switches_total"] >= 1, text
          # one # HELP and one # TYPE per family, so the exporter takes it
          for family in ["homelab_mc_phase", "homelab_mc_sessions", "homelab_mc_players", "homelab_mc_starts_total",
                         "homelab_mc_start_failures_total", "homelab_mc_kicks_total", "homelab_mc_switches_total",
                         "homelab_minecraft_server_stale"]:
              assert f"# TYPE {family} " in text, (family, text)
          mode = vm_214.succeed(f"stat -c %a {METRICS}").strip()
          assert mode == "644", mode

      with subtest("textfile"):
          # the exporter reads the gate's own file through the link, so a scrape never sees a copy
          target = vm_214.succeed(f"readlink -f {TEXTFILE}").strip()
          assert target == METRICS, target
          scraped = vm_214.succeed("curl -fsS localhost:9100/metrics")
          assert "homelab_mc_phase{" in scraped, scraped[-2000:]
          assert 'node_textfile_scrape_error 0' in scraped, scraped[-2000:]

      with subtest("state"):
          printed = state()
          assert printed == json.loads(vm_214.succeed(f"cat {STATE}")), printed
          assert sorted(server["name"] for server in printed["servers"]) == SERVERS, printed
          assert "updatedAt" in printed and "switchesLastHour" in printed, printed
          vm_214.succeed("systemctl stop mc-gate.service")
          vm_214.succeed(f"rm -f {STATE}")
          out = vm_214.fail("mc-state 2>&1")
          assert STATE in out, out
    '';
}
