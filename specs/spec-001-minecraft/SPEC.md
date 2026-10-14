# spec-001: Minecraft

Implemented in:

- `src/instances/preconfigured/214-external-minecraft/`;
- partial, the wildcard host of p1 only: `src/modules/service.nix`, `src/modules/catalog.nix`,
  `src/modules/lab-export.nix`, `src/core/300-router/main.nix`.

Last reconcile: 2026-10-14 @ b66f6d0

The research and design notes behind the target are in `notes/2026-10-14-multi-server/`. Nothing in them is needed to
build this spec.

## Purpose

The owner and invited friends play Minecraft on the lab's guest vm-214. As built (R-001 to R-011), it hosts one
server, which sleeps when no one plays and wakes on a real login. One modded server needs most of the guest: 10 GiB with
a 7G heap. So the guest holds one world at a time, and switching packs means changing that world for everyone.

The target lets the guest hold several servers, one per name under `*.mc.lsck0.dev` on the one public port 25565.
All of them sleep until someone joins.

- **One at a time.** Only one server runs. A login for a sleeping server while the running one has players is refused,
  and the message says who is on. While the running one is empty, it is stopped and the requested one is started.
- **No holding.** The joining player is kicked with "starting, rejoin in about a minute", not held.

Success means three things:

- a friend can join any declared server by name without asking the owner;
- no player is cut off by someone else's switch (the one residual case is named in Security);
- adding a server is one entry in nix plus `./sync.sh`.

Non-goals:

- two servers running at once;
- holding the client while a server boots;
- Bedrock clients;
- per-server whitelists;
- a lobby server;
- moving servers off vm-214.

## Requirements

### As built

A line marked "Replaced at p3" stays true until p3 merges; the p3 PR strikes it through.

- [x] **R-001** lazymc owns 0.0.0.0:25565, answers status pings itself, and starts the server only on a real
  login. Replaced at p3 by R-040 to R-043 and R-074a.
  (`src/instances/preconfigured/214-external-minecraft/main.nix:113-142` `lazymc.toml`,
  `main.nix#systemd.services.lazymc`)
- [x] **R-002** The server is stopped after `sleepAfterS = 1800` without players, and stays up at least
  `minimumOnlineS = 60`. Replaced at p3 by R-050a to R-050c and R-051c. (`main.nix:31-32, 135-136`)
- [x] **R-003** The server is the `itzg/minecraft-server:2026.9.1-java21` image in a podman container `minecraft`,
  started by lazymc. It runs with a 7G heap, and its game and rcon ports are published on loopback only
  (127.0.0.1:25566, :25575). Replaced at p3 by R-071b. (`main.nix#mcStart`, `main.nix:15, 22-23, 29, 43-68`)
- [x] **R-004** The data dir `/var/lib/minecraft` and the pack cache `/var/lib/minecraft-modpacks` are nas mounts of
  the shares `data/minecraft` and `data/minecraft-modpacks`. (`main.nix:101`, `instance.nix:27-30`)
- [x] **R-005** The pack is a runtime choice. `mc-modpack <modrinth url|slug|curseforge url|vanilla> [version]`
  writes `modpack.env`, keeps one world per pack (`LEVEL=<slug>`) and restarts lazymc. Without arguments it shows the
  current pack. A first boot writes the vanilla default. Replaced at p3 by R-078 and R-071a.
  (`main.nix#mcModpack`, `main.nix#mcModpackDefault`, `main.nix:71-94`)
- [x] **R-006** `mc-rcon <command>` runs rcon-cli in the running container. Replaced at p3 by R-079.
  (`main.nix#mcRcon`, `main.nix:97-99`)
- [x] **R-007** The rcon password and the CurseForge key are rendered by sops under /run only, never into the data
  dir. (`main.nix:103-111`)
- [x] **R-008** The whitelist is enforced. whitelist.json and ops.json are kept on the nas, not in the repo.
  (`main.nix:4-5, 63-64`)
- [x] **R-009** The route `services.minecraft` is tcp 25565, `host = "mc"`, `publicPort = 25565`,
  `srv = "_minecraft._tcp"`, with `inflightLimit`, `accessLog`, `probe` and the observed features. The router forwards
  25565 to vm-214. Replaced at p3 by R-077. (`instance.nix:16-25`, `src/modules/flows.nix:288-293`,
  `src/core/300-router/main.nix:517-533`)
- [x] **R-010** The `probe` feature is a blackbox tcp connect to 10.200.0.214:25565 while the guest is awake.
  (`src/core/103-internal-grafana/main.nix:195-200`)
- [x] **R-011** vm-214 is always on, with 10 GiB unballooned and 10 cores. (`instance.nix:3-14`)

### p1: wildcard hosts in the platform

- [ ] **R-020** A service's `host` accepts dotted labels and an optional leading `*.`:
  `(\*\.)?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*`. Instance services and app routes share the
  type. (`src/modules/service.nix`)
- [ ] **R-021** The catalog refuses a dotted or wildcard host on an http route, of an instance or of an app.
- [ ] **R-022** The catalog refuses a wildcard host without `publicPort`.
- [ ] **R-023** The catalog refuses `srv` on a route with a wildcard host.
- [ ] **R-024** The catalog refuses an exact host that one label below another route's wildcard matches, e.g. `x.mc`
  beside `*.mc`.
- [ ] **R-025** For a wildcard forward host `*.<rest>`, the router's CoreDNS has a `template IN A` block zoned to
  `<rest>.<domain>`, matching `^[a-z0-9-]+\.<rest>\.<domain>\.$` (for `*.mc`: `^[a-z0-9-]+\.mc\.lsck0\.dev\.$`),
  answering the forward's backend address, and carrying `fallthrough`.
- [ ] **R-026** For the same names, a `template IN AAAA` block with the same zone and regex answers NOERROR with no
  records, and carries `fallthrough`.
- [ ] **R-027** `forwardHostLines` and `directHosts` skip wildcard hosts, so no `hosts` line carries a `*`.
- [ ] **R-028** DDNS publishes a wildcard forward host as the A record `*.<rest>.<domain>` with `proxied = false`.
  `ddns-cloudflare.sh` stays unchanged.
- [ ] **R-029** lab-export writes a wildcard host as its fqdn, `*.<rest>.<domain>`.

### p2: mc-gate, built and tested, not wired

- [ ] **R-040** mc-gate reads a connection's first frame within `handshakeTimeoutS = 5` and at most
  `handshakeBytesMax = 1024`.
  - The bytes `FE 01 FA`, or a first byte 0xFE followed by no valid frame, get a legacy 0xFF kick: protocol 127,
    text `lsck0.dev minecraft`.
  - Anything else must be a well-formed handshake, or the connection is closed.
- [ ] **R-041** The handshake address is normalized in this order: cut at the first `\0`, cut at the first `\`,
  strip one trailing `.`, lowercase, strip the suffix `.mc.lsck0.dev`. A result that is not a declared server name is
  unknown.
- [ ] **R-042** Status (intent 1) is answered by the gate, and the ping is echoed.
  - A running server: its live status, cached for `statusCacheS = 5`.
  - A server not running, with a cached last status (`/var/lib/mc-gate/<name>.json`): version, protocol, max players
    and favicon from the cache, `online` 0, `sample` empty, the phase's description.
  - A server not running, without a cache: the nix version and protocol (`?` and -1 when null), max players 0, no
    favicon, `online` 0, `sample` empty, the phase's description.
  - An unknown name: version `?`, protocol -1, description `no such server`.
- [ ] **R-043** A login (intent 2 or 3) reads Login Start within `handshakeTimeoutS`, then asks the decider. A relay
  writes the buffered handshake and Login Start to the backend and copies both ways. A kick sends a login-state
  Disconnect with a JSON text and closes. The player name is used for the log only.
- [ ] **R-044** One goroutine owns every record of the data model; connections reach it over a channel. Concurrent
  logins are decided one after the other.
- [ ] **R-045a** Issuing a start sets the target to `starting` and every other active server to `stopping` before any
  reply goes out.
- [ ] **R-045b** The decider runs `systemctl start --no-block <unit>` and `systemctl stop --no-block <unit>`
  synchronously, before it handles the next event.
- [ ] **R-045c** A non-zero exit of that command restores the records, grows the server's `failures`, sets its
  `lastStartFailed`, and gives the login the `failed` kick.
- [ ] **R-046a** Every `reconcileS = 5`, always, the decider reads every server unit's `ActiveState` and `Job` with
  one `systemctl show` call. `active`, `activating` and `reloading` count as started, `deactivating` as stopping,
  `inactive` and `failed` as idle.
- [ ] **R-046b** A record `starting` or `running` whose unit is idle with no job becomes `sleeping`; when the unit is
  `failed`, `failures` grows and `lastStartFailed` is set.
- [ ] **R-046c** A record `sleeping` whose unit is started becomes `starting`, and every other active record becomes
  `stopping`.
- [ ] **R-046d** A record `sleeping` whose unit is stopping becomes `stopping`.
- [ ] **R-046e** A record `stopping` whose unit is idle with no job becomes `sleeping`.
- [ ] **R-046f** A record `stopping` whose unit is started with no job becomes `running`.
- [ ] **R-046g** A record `starting` becomes `running` once its backend answers a loopback status ping.
- [ ] **R-047** A server is occupied when any of these holds:
  - its last backend `players.online` is above 0;
  - it has a live relayed session older than `loginGraceS = 60`;
  - it has a live relayed session from a source not marked as looping;
  - `now < reservedUntil`.
- [ ] **R-048a** A source whose sessions ended before `loginGraceS` three times (`loopShortSessionsMax = 3`) within
  `loopWindowS = 600` is marked as looping.
- [ ] **R-048b** A live session younger than `loginGraceS` from a marked source does not occupy.
- [ ] **R-048c** A mark clears when a session of the source outlives `loginGraceS`, or after `loopWindowS` without a
  short session.
- [ ] **R-048d** A source that is not exempt holds at most `sessionsPerSourceMax = 4` live sessions. A login beyond
  that is closed before the decision table (R-052), with the outcome `capped` and no text.
- [ ] **R-048e** Exempt from marking and from the session cap are the `allow` cidrs and the addresses of the `allow`
  names. nix feeds mc-gate the same values it feeds lab-gate (`src/modules/traefik/default.nix:467-474`): the private
  ranges, wireguard, and the names resolving to the house's public address and v6 prefix. mc-gate carries its own
  check for them: lab-gate's `allow.go` is another Go module, and code one instance uses stays in that instance's
  `lib/` (`src/tests/policy/placement.nix`).
- [ ] **R-049** A server that becomes `running` after a start gets `reservedUntil = now + rejoinS`, with
  `rejoinS = 180`.
- [ ] **R-050a** `idleSince` is the latest of the last session end, `reservedUntil`, and the moment the server became
  `running`.
- [ ] **R-050b** A `running` server not occupied for `sleepAfterS = 1800` since `idleSince` is stopped.
- [ ] **R-050c** After a gate restart, a running server gets `idleSince = now`.
- [ ] **R-051a** A source causes at most `startsPerSourcePerHourMax = 3` starts per hour.
- [ ] **R-051b** A start that stops a running server counts against `switchesPerHourMax = 6` per hour across all
  sources. A start from all-asleep does not.
- [ ] **R-051c** A server stays up `minimumOnlineS = 300` after it became `running` before a switch may stop it. This
  value replaces R-002's 60 at p3.
- [ ] **R-052** A login for server T, with O the other active server, gets the first matching row. Row 0 comes
  first: a login from a source over `sessionsPerSourceMax` (R-048d) is closed: outcome `capped`, no text.

  | T | O | outcome |
  |---|---|---|
  | unknown | any | kick `unknown` |
  | running | none | relay |
  | starting | any | kick `starting` |
  | stopping | any | kick `stopping` |
  | sleeping | starting | kick `busyStarting` |
  | sleeping | stopping | kick `stopping` |
  | sleeping | running, occupied | kick `busy` |
  | sleeping | running, under `minimumOnlineS` | kick `justStarted` |
  | sleeping | any, over a budget | kick `budget` |
  | sleeping | running, not occupied | start T, O `stopping`; kick `starting` |
  | sleeping | none | start T; kick `starting` |

- [ ] **R-053a** A start with no answering backend after `startTimeoutS = 300` is stopped, `failures` grows, and
  `lastStartFailed` is set. Every start clears `lastStartFailed`.
- [ ] **R-053b** The timeout is `firstStartTimeoutS = 1200` when the server's `modpack.env` is newer than its last
  good start, recorded as the mtime of `/var/lib/mc-gate/<name>.started`.
- [ ] **R-053c** A `sleeping` server with `lastStartFailed` set has the status description
  `failed to start, join to try again`.
- [ ] **R-054** The texts are named constants in one Go file:

  | key | text |
  |---|---|
  | `starting` | `<T> is starting, rejoin in about a minute` |
  | `stopping` | `<x> is stopping, try again in a minute` |
  | `busyStarting` | `<O> is starting for someone, try again later` |
  | `busy` | `<O> is running with <n> players, try again later` |
  | `justStarted` | `<O> just started, try again in a few minutes` |
  | `budget` | `too many server switches, try again later` |
  | `failed` | `<T> failed to start, try again later` |
  | `unknown` | `no server <x> here; servers: a, b, c` |

  The status descriptions are `sleeping, join to start it`, `starting, rejoin in about a minute`, `stopping`,
  `<O> is running with <n> players`, `failed to start, join to try again` and `no such server`.
- [ ] **R-055a** The gate reads its settings from the path given by `-settings`, in the shape of the data model.
- [ ] **R-055b** On SIGHUP it reads the settings again without closing any connection.
- [ ] **R-055c** A reload keeps every server that has sessions, until its sessions end.
- [ ] **R-056** The gate writes `/run/mc-gate/state.json` on every change, in the shape of the data model.
- [ ] **R-057** The gate logs one journal line per event:
  - `login` (source, name, server, outcome);
  - `start` and `stop` (server, reason, and the causing source for a switch);
  - `start-failed` (server, seconds);
  - `reconcile` (the correction).
- [ ] **R-058** `cmd/fake-server` in the same module is a test backend. It speaks handshake, status and login, reports
  `players.online` from its live sessions, and with a flag ignores SIGTERM.
- [ ] **R-059** The module lives in `src/instances/preconfigured/214-external-minecraft/lib/mc-gate/`, uses Go's
  standard library only, and is packaged by `lib/mc-gate.nix` with `buildGoModule`, whose check phase runs its tests.
  The check `mc-gate` (`tests/mc-gate.nix`) builds it. No unit runs it.

### p3: several servers on vm-214

- [ ] **R-070** `main.nix` declares `servers`, an attrset of name to `{ version ? null; protocol ? null; }`. Names are
  DNS labels other than `layout`, `gate` and `state`, enforced by an evaluation assert. p3 declares
  `cobblemon = { version = "1.21.1"; protocol = 767; }` alone.
- [ ] **R-071a** Each server has a unit `minecraft-<name>.service`. Its `ExecStartPre` creates
  `/var/lib/minecraft/<name>` (0750, 1000:1000) when missing, runs `podman rm --force --ignore minecraft-<name>`,
  and writes the vanilla default pack (`TYPE=VANILLA`, `VERSION=LATEST`, `LEVEL=vanilla`) when `modpack.env` is
  missing.
- [ ] **R-071b** Its `ExecStart` runs `podman run --rm --name minecraft-<name>` with exactly these options:
  - `--dns=1.1.1.1 --dns=8.8.8.8`;
  - `-p 127.0.0.1:25566:25565 -p 127.0.0.1:25575:25575`;
  - `-v /var/lib/minecraft/<name>:/data -v /var/lib/minecraft-modpacks:/modpacks:ro`;
  - the shared files of R-073;
  - `--env-file` the sops template `minecraft-server.env` (rcon password, CurseForge key), then
    `--env-file /var/lib/minecraft/<name>/modpack.env`;
  - `-e EULA=TRUE -e MEMORY=7G -e DIFFICULTY=hard`;
  - `-e ICON=${icon} -e OVERRIDE_ICON=TRUE -e "MOTD=${motd}"`, where `main.nix` keeps two let-bindings `icon` and
    `motd` holding the as-built values (`main.nix:54, 56` @ b66f6d0);
  - `-e USE_AIKAR_FLAGS=true -e VIEW_DISTANCE=12 -e SIMULATION_DISTANCE=8 -e SPAWN_PROTECTION=0`;
  - `-e MAX_PLAYERS=42069 -e ENABLE_RCON=true -e ENABLE_WHITELIST=true -e ENFORCE_WHITELIST=true`;
  - `-e REMOVE_OLD_MODS=TRUE -e MAX_TICK_TIME=-1 -e STOP_DURATION=90`;
  - the image `itzg/minecraft-server:2026.9.1-java21`.
- [ ] **R-071c** Its `ExecStop` is `podman stop --time 120 minecraft-<name>`, and its `ExecStopPost` is
  `podman rm --force --ignore minecraft-<name>`.
- [ ] **R-071d** It sets `TimeoutStopSec=150` and `TimeoutStartSec=infinity`.
- [ ] **R-071e** It has `RequiresMountsFor=/var/lib/minecraft`, and `Requires=` plus `After=` on `mc-layout.service`.
- [ ] **R-071f** It has no `wantedBy`.
- [ ] **R-072** Each server unit has `Conflicts=` on every other server unit, and `After=` exactly the server units
  whose names sort before its own.
- [ ] **R-073** `/var/lib/minecraft/whitelist.json` and `ops.json` are bind mounted file by file onto
  `/data/whitelist.json` and `/data/ops.json` in every server container.
- [ ] **R-074a** `mc-gate.service` has `ExecStart=<mc-gate package>/bin/mc-gate -settings /etc/mc-gate/settings.json`,
  listening on 0.0.0.0:25565, as the static system user `mc-gate`, with `StateDirectory=mc-gate` (0755) and
  `RuntimeDirectory=mc-gate`.
- [ ] **R-074b** It has `Restart=always`, and `Wants=` plus `After=` on `mc-layout.service`.
- [ ] **R-074c** It has `restartIfChanged = false`.
- [ ] **R-074d** It has `ExecReload=kill -HUP $MAINPID`, and `reloadTriggers` holding the settings file.
- [ ] **R-075** A polkit rule lets the user `mc-gate` run only the verbs `start` and `stop`, only on the exact server
  unit names generated from `servers`.
- [ ] **R-076a** `mc-layout.service` is a oneshot with `RemainAfterExit` and `RequiresMountsFor=/var/lib/minecraft`.
- [ ] **R-076b** It moves when `/var/lib/minecraft/cobblemon.tmp` exists, or when `/var/lib/minecraft/modpack.env`
  exists and `/var/lib/minecraft/cobblemon` does not; otherwise it does nothing.
- [ ] **R-076c** The move puts every top-level entry, dotfiles included, except `whitelist.json`, `ops.json` and
  `cobblemon.tmp`, into `cobblemon.tmp/`.
- [ ] **R-076d** After the move it renames `cobblemon.tmp` to `cobblemon`.
- [ ] **R-077** The route becomes `host = "*.mc"` without `srv`, keeping its key `minecraft`, its port, publicPort and
  `on`. lazymc, its unit, its config template and the old `mcStart` are gone.
- [ ] **R-078** `mc-modpack <server> [pack] [version]` writes that server's `modpack.env` as R-005 did and restarts
  its unit when it runs. Without arguments it lists each server with its pack and phase.
- [ ] **R-079** `mc-rcon [-s <server>] <command...>` runs rcon-cli in `minecraft-<server>`. Without `-s` it targets
  the running server, and fails with a message when none runs.
- [ ] **R-080** `mc-state` prints `/run/mc-gate/state.json`.
- [ ] **R-081a** The 214 `skill.md` gives the addresses `<server>.mc.lsck0.dev`, the servers and the switch rule.
- [ ] **R-081b** It names `mc-state`, `journalctl -u minecraft-<name> -u mc-gate`, `mc-modpack <server>` and
  `mc-rcon -s`.
- [ ] **R-081c** It says the whitelist is shared: `mc-rcon whitelist add` only while a server runs, otherwise edit
  `/var/lib/minecraft/whitelist.json`.
- [ ] **R-081d** It says `nas-restore service minecraft` restores every server at once.
- [ ] **R-081e** It says to `systemctl restart mc-gate` only when no one is on, and to remove a server only while it
  sleeps.
- [ ] **R-081f** `src/core/300-router/skill.md:31-32` and `src/scripts/init.sh:114` name the host as `*.mc`.
- [ ] **R-082** `src/instances/preconfigured/113-internal-hermes/tests/hermes-agent.sh` calls
  `mc-modpack <server> <pack>` and expects `ssh 10\.200\.0\.214`, not `.208`.
- [ ] **R-083** The kopia test fixture is `data/minecraft/cobblemon/world/level.dat`.

### p4: metrics and alert

- [ ] **R-090** The gate writes `/var/lib/mc-gate/metrics.prom` (0644) at start and on every change, atomically
  through a temp file in the same directory. It holds:
  - `homelab_mc_phase{server,phase}`;
  - `homelab_mc_sessions{server}`;
  - `homelab_mc_players{server}`;
  - `homelab_mc_starts_total{server}` and `homelab_mc_start_failures_total{server}`;
  - `homelab_mc_kicks_total{reason}`;
  - `homelab_mc_switches_total`.
- [ ] **R-091** tmpfiles links `/var/lib/node-exporter-textfile/mc-gate.prom` to that file, and vm-214 declares
  `homelab.textfiles = [ "mc-gate" ]`.
- [ ] **R-092** The alert `minecraft_start_failed` (category `service`, no telegram) fires when
  `increase(homelab_mc_start_failures_total[1h]) >= 2`. (`src/core/103-internal-grafana/lib/rules.nix`)

## Design

### Shape (R-001 to R-011 as built; R-070 to R-077 target)

As built, lazymc owns 25565 and runs one container as its child (R-001, R-003). The target replaces lazymc with
mc-gate and turns the one container into one systemd unit per declared server:

```
internet / house / lab
        |
  router dnat tcp 25565 -> 10.200.0.214:25565   (unchanged: one forward, L4)
        |
  vm-214  mc-gate  0.0.0.0:25565
        |   reads the handshake, picks a server by name, answers status itself,
        |   starts and stops servers through systemd, relays a login to the running one
        |
  minecraft-<name>.service  (one per declared server; Conflicts= with each other)
        podman container minecraft-<name>, game 127.0.0.1:25566, rcon 127.0.0.1:25575
        /var/lib/minecraft/<name>  (its data dir: modpack.env, worlds, mods, config)
        /var/lib/minecraft/whitelist.json, ops.json  (shared, file bind mounts)
```

Two primitives carry it.

- **At most one active unit, enforced by systemd** (R-072). `Conflicts=` makes starting B stop A. The ordering
  dependency, `After=` only towards names that sort earlier, makes systemd order the stop job before the start job,
  whichever direction the ordering runs (systemd.unit(5), Before=/After=). Ordering both ways would form a cycle,
  which systemd breaks by deleting a job. Because two servers never run together, every server reuses the same
  loopback ports. A unit started by hand cannot break the invariant.
- **A gate that owns the port** (R-040 to R-057). It is the only way in, since the backends listen on loopback. So
  its view of sessions is complete.

The guest keeps 10 GiB and 10 cores (R-011): one heap fits, and only one server runs.

### The servers in nix (R-070 to R-073)

`servers` in `main.nix` is the single source. It derives:

- the server units (R-071a to R-071f, R-072);
- the polkit unit list (R-075);
- the gate's settings file (R-055a);
- the eval assert on names (R-070).

`version` and `protocol` only matter for a server that has never answered a status ping (R-042).

The whitelist and ops files are shared by bind mounting each file onto every container's `/data/` (R-073). For this to
work, two facts must hold on the real image:

- the image touches whitelist.json only when `WHITELIST` or `WHITELIST_FILE` is set (neither is);
- the server rewrites the file in place, because a rename onto a file bind mount fails with EBUSY.

Rollout p3 step 3 checks both before a second server is declared.

### Data model (R-044 to R-057, R-090)

The decider's records, owned by its goroutine:

```
Server {
  name           string
  unit           string            // minecraft-<name>.service
  phase          sleeping | starting | running | stopping
  sessions       []Session
  playersOnline  int               // last backend status; 0 when not running
  reservedUntil  time              // zero when none
  idleSince      time
  startedAt      time              // when the current start was issued
  runningSince   time              // when it became running
  failures       int
  lastStartFailed bool             // set by R-045c, R-046b (unit failed), R-053a; cleared on the next start
  status         []byte            // the backend's last live status JSON (R-042)
  statusAt       time              // when status was fetched; reused within statusCacheS
}
Session { id uint64; source netip.Addr; startedAt time }
Source  { shortSessionEnds []time; markedLooping bool; starts []time }   // per address, pruned past an hour
Budget  { switches []time }                                              // pruned past an hour
```

The settings file, `/etc/mc-gate/settings.json`, generated from nix:

```
{
  "listen":     string,                 // "0.0.0.0:25565"
  "suffix":     string,                 // ".mc.lsck0.dev"
  "backend":    string,                 // "127.0.0.1:25566"
  "stateDir":   string,                 // "/var/lib/mc-gate"
  "runtimeDir": string,                 // "/run/mc-gate"
  "servers": [ { "name": string, "unit": string, "version": string|null, "protocol": int|null,
                 "modpackEnv": string } ],
  "limits": { "handshakeTimeoutS": int, "handshakeBytesMax": int, "statusCacheS": int, "reconcileS": int,
              "loginGraceS": int, "loopWindowS": int, "loopShortSessionsMax": int, "sessionsPerSourceMax": int,
              "rejoinS": int, "sleepAfterS": int, "minimumOnlineS": int, "startsPerSourcePerHourMax": int,
              "switchesPerHourMax": int, "startTimeoutS": int, "firstStartTimeoutS": int },
  "allow": { "cidrs": [string], "hosts": [ { "name": string, "network": "ip4"|"ip6", "bits": int } ] }
}
```

The state file, `/run/mc-gate/state.json`, written by the gate:

```
{
  "updatedAt": string,                  // RFC 3339
  "servers": [ { "name": string, "phase": string, "sessions": int, "players": int,
                 "reservedUntil": string|null, "idleSince": string|null, "failures": int } ],
  "switchesLastHour": int
}
```

The status cache, `/var/lib/mc-gate/<name>.json`, is the backend's last status JSON as received. The marker
`/var/lib/mc-gate/<name>.started` is an empty file whose mtime is the server's last good start (R-053b).

### mc-gate (R-040 to R-059, R-090)

A Go module with the standard library only, beside the instance in `lib/mc-gate/` (code one instance uses stays in
its `lib/`, `src/tests/policy/placement.nix`). It is packaged like lab-gate (`src/modules/traefik/lib/gate.nix:40-48`)
and has its own name.

**Per connection** (R-040 to R-043). The frame reader takes the first frame. Its layout is
`VarInt length | VarInt id | data`; a VarInt has at most 5 bytes, and a String is a VarInt byte length plus UTF-8.

- The handshake is id 0x00: protocol VarInt, address String (at most 255 chars), port u16, intent VarInt. Intent 1
  is status; 2 and 3 (transfer) are login.
- The client sends the SRV target as the address, else the name it dialed. The wildcard A record has no SRV, so the
  gate sees the typed name.
- Forge clients append `\0FML\0` or `\0FML2\0`, and proxies append `\`-separated parts. Normalization cuts both
  (R-041). NeoForge 1.21.1 sends no suffix.
- Legacy pings start with 0xFE without a length prefix. Checking three bytes (`FE 01 FA`) avoids mistaking a modern
  frame of length 126 for one.
- A kick happens in the login state, where Disconnect takes JSON. In the configuration and play states it takes NBT.

**Decider** (R-044 to R-053c).

- **One owner.** One goroutine owns every record, so the rules below need no locks and two logins cannot race.
- **Phase before systemd.** The decider sets phases before it talks to systemd, and it calls systemd synchronously.
  So a reconcile poll never sees a unit idle while the start job is unqueued (R-045a, R-045b). systemd's view only
  corrects the records in the cases R-046b to R-046f list: a crash, a hand-started unit, a stop that never got
  queued.
- **Occupancy** (R-047, R-048a to R-048e). It decides what a switch or sleep may stop. A young session occupies,
  because a player who joined seconds ago is not yet in `players.online`, and may still be in the configuration phase
  where it may not count.
- **Forged logins.** A forged Login Start is unauthenticated, and the online-mode server drops it within its login
  timeout. That timeout is 600 ticks, nominally 30 s, longer on a lagging server; `loginGraceS = 60` sits above it.
- **Reconnect loops.** A loop of forged logins would keep a server occupied forever, so a source with repeated short
  sessions is marked, and its young sessions stop occupying.
- **The house is exempt.** House players who dial the public name arrive hairpinned with the house's public address
  (`src/core/300-router/main.nix:187`). One friend's failed joins must not mark the whole house.
- **Reservation** (R-049). It gives the kicked player three minutes to rejoin before anyone can switch the server
  away.
- **Budgets** (R-051a to R-051c). They bound forged starts per source. Only switches count globally, so forged traffic
  can never lock real players out of a sleeping lab.
- **Start timeout** (R-053a, R-053b). It is lazymc's own default, 300 s. The first start after a pack change downloads
  the pack, which takes several minutes (214 `skill.md`), hence 1200 s then.

**Status** (R-042). A running backend is asked at most once per `statusCacheS`, so a ping flood costs it one status
per five seconds. The status JSON is:

- `version.name` and `version.protocol`;
- `players.max`, `online` and `sample`;
- `description` (a text component);
- `favicon` (a 64x64 png data uri).

The ping, id 0x01 with a Long, is echoed. NeoForge 1.21.1 adds only an optional `isModded`. The status of an unknown
name never lists server names, since scanners read it; only a login kick does.

**Settings and lifetime** (R-055a to R-055c, R-074a to R-074d). A gate restart cuts every relay, since it is the only
path. Settings changes reload on SIGHUP through `reloadTriggers`. A switch that changes the binary skips the unit
entirely, reload included, and the owner restarts it when no one is on.

### Starting and stopping (R-071a to R-071f, R-075, R-053a)

- **Stopping.** `podman stop --time 120` stops the container itself. A stop of the `podman run` client alone would
  leave conmon and the JVM in their own scope, holding the loopback ports. `mc-server-runner` in the image turns
  SIGTERM into `stop` and waits `STOP_DURATION` before killing. podman's own `--stop-timeout` defaults to 10 s, hence
  the explicit 120 (https://docs.podman.io/en/latest/markdown/podman-run.1.html).
- **Leftovers.** `ExecStopPost` and the next `ExecStartPre` remove any leftover container by name.
- **Polkit** (R-075). It follows the `swarm-deploy@` rule
  (`src/core/107-internal-swarm/lib/app-builder.nix:203-211`), but with exact unit names, not a pattern. A pattern
  like `^minecraft-.*` would also match units that are not servers.

### Migration (R-076a to R-076d)

As built (R-004, R-005), `/var/lib/minecraft` holds one server's data at its top level: `modpack.env`, one world per
pack, mods and config. `mc-layout` moves all of it into `cobblemon/` once, through `cobblemon.tmp` so a crash halfway
resumes.

Server dirs do not exist yet when it runs: units create them after `mc-layout` succeeded (R-071a, R-071e). So an old
top-level world named like a server, such as the default pack's `vanilla`, moves into `cobblemon` with the rest. The
final rename is the commit point. The nas share stays `data/minecraft`, so kopia and `nas-restore service minecraft`
cover every server at once.

### DNS (R-020 to R-029)

The route `*.mc` resolves as follows:

- **Outside.** Cloudflare's `*.mc.lsck0.dev` record resolves it, written by the DDNS service. Cloudflare accepts
  wildcards below the apex
  (https://developers.cloudflare.com/dns/manage-dns-records/reference/wildcard-dns-records/).
- **Inside the lab.** The router's CoreDNS template resolves it, pointing at vm-214 directly.

**DDNS.** `ddns-cloudflare.sh` compares names as exact strings in its name filter (`lib/ddns-cloudflare.sh:82`) and its
stale filter (`:119`). Both hold for `*.mc.lsck0.dev`. The old bare `mc.lsck0.dev` leaves the list, so the stale filter
deletes it, which is the intended drop.

**CoreDNS** (R-025 to R-027).

- **Plugin order.** CoreDNS runs `template` before `hosts`, whatever the config order. So a template must be zoned to
  `mc.lsck0.dev` and fall through, or it would answer NXDOMAIN for the whole lab zone.
- **AAAA.** The AAAA template gives the NODATA that the `hosts` plugin gives exact names. Without it, AAAA queries
  would go upstream to blocky.
- **Deeper names.** Public DNS answers names several labels deep (RFC 4592). The gate kicks undeclared names anyway.

**Catalog** (R-021 to R-024). The ingress certificate covers `*.lsck0.dev`, one level, and the ingress routes by exact
host. So dotted and wildcard hosts are tcp/udp only. The `srv` goes away: the default port needs none, and an SRV
target would change the address the gate sees.

## Workflows

**Added:**

- **A player joins a sleeping server.** They connect to `cobblemon.mc.lsck0.dev` and get "cobblemon is starting,
  rejoin in about a minute". They rejoin within three minutes and play.
- **A player asks for another server while one runs.**
  - If the running server has players, the kick says "cobblemon is running with 3 players, try again later".
  - If it is empty, it stops and the requested one starts: "vanilla is starting, rejoin in about a minute".
- **The owner adds a server.** These steps run in order.
  1. Add `vanilla = { };` to `servers` and run `./sync.sh`.
  2. If the same sync changed the gate's binary, run `ssh 10.200.0.214 systemctl restart mc-gate` when no one is on.
     Otherwise the settings reload adds the server by itself.
  3. Run `ssh 10.200.0.214 mc-modpack vanilla <pack>`. The first start downloads the pack.
- **The owner looks at the state.** `ssh 10.200.0.214 mc-state`.

**Changed:**

- **Switching a pack.** `mc-modpack <pack>` becomes `mc-modpack <server> <pack>`.
- **rcon.** `mc-rcon <cmd>` targets the running server, and `-s <server>` names one.
- **The address.** It changes from `mc.lsck0.dev` to `<server>.mc.lsck0.dev`. Players re-add the server once, using
  `cobblemon.mc.lsck0.dev` for the as-built world.
- **Whitelisting.** `mc-rcon whitelist add <name>` admits the player on all servers. While all servers sleep, the owner
  edits `/var/lib/minecraft/whitelist.json` directly.
- **Restoring.** `nas-restore service minecraft` restores every server at once.

**Removed:**

- `mc.lsck0.dev` and its SRV record.
- `journalctl -u lazymc`, which becomes `journalctl -u mc-gate -u minecraft-<name>`.

## Impact

- **Platform** (p1).
  - Changed: `src/modules/service.nix` (the host type), `src/modules/catalog.nix` (four checks),
    `src/core/300-router/main.nix` (CoreDNS templates, `forwardHostLines`, `directHosts`, the DDNS list),
    `src/modules/lab-export.nix`.
  - Tests: new `policy-eval` cases, `src/tests/router-zones.nix`,
    `src/core/300-router/tests/ddns_cloudflare_test.py` and `src/modules/lab/tests/lab.nix`.
  - Existing exact hosts behave as before. Constraint later: dotted hosts stay tcp/udp only until the ingress
    certificate covers more levels.
- **Guest** (p2 to p4). Everything else lives in `src/instances/preconfigured/214-external-minecraft/`.
  - Outside it: hermes' test script, the router's skill.md, `src/scripts/init.sh`, the kopia test fixture and the
    alert rule.
  - Hermes' `mc` tool binds to `lab.routes.minecraft`
    (`src/instances/preconfigured/113-internal-hermes/main.nix:76-78`), which keeps its key.
- **Dependencies.** Go's standard library only. lazymc leaves the guest.
- **Data migration.** One-way move into `cobblemon/` (R-076a to R-076d), with a snapshot first and a written reverse
  step (Rollback p3).
- **Compatibility.** Clients must re-add the server under its new name. The Minecraft protocol is untouched: the
  gate relays bytes after the login decision.

## Failure modes

1. **Gate down.** The router's dnat hits a closed port, and clients see "connection refused". `service_down` fires
   through the tcp probe after 10 m. Fails closed: no server starts.
2. **A server crashes while players are on.** Their relays end and the unit goes `failed`. Reconcile sets the record
   to `sleeping` and grows `failures`, and the next login starts it again. Fails open: nothing is stuck.
3. **A start hangs (a bad pack).** After `startTimeoutS` or `firstStartTimeoutS`, the gate stops the unit, and status
   says "failed to start". `minecraft_start_failed` fires on the second failure in an hour. Fails closed.
4. **Two logins for different sleeping servers at once.** The decider is serial. The first starts its server; the
   second gets `busyStarting`.
5. **A login for the old server during a switch.** The decider set it to `stopping` before answering the switching
   login, so the login gets `stopping`. It is never relayed into a server about to stop.
6. **A player kicked with "rejoin" never rejoins.** The reservation lapses after `rejoinS`. The server idles until
   `sleepAfterS`, or until a switch after `minimumOnlineS`.
7. **The old server is slow to save.** systemd orders the stop before the start, and the new unit waits with a queued
   job for at most `TimeoutStopSec = 150`. During that wait its `ActiveState` is `inactive` with a job. The gate holds
   it as `starting` from the moment it issued the start, and reconcile changes a record only when the unit is idle
   with no job (R-046b), so no state is read from the unit meanwhile.
8. **A container outlives its unit (SIGKILL of the client).** `ExecStopPost` and the next `ExecStartPre` remove it by
   name, so the ports are free before the next server starts.
9. **The nas mount is late or down at boot.** The server units and `mc-layout` need the mount. The gate only wants
   `mc-layout`, so it listens anyway: status works, and a start fails into mode 3.
10. **A scanner sends garbage or holds the socket.** `handshakeTimeoutS` and `handshakeBytesMax` close it, and the
    router's `inflightLimit` caps connections at 256. Status for an unknown name reveals no server names.
11. **Forged logins switching servers.**
    - A forged name starts a server only within the per-source budget, and never stops an occupied one.
    - Switches are capped at six an hour across all sources.
    - A TCP source cannot be spoofed. Many real sources can each spend their own budget, though: starts from
      all-asleep have no global cap, and each holds a server for at most `rejoinS + sleepAfterS`.
12. **A reconnect loop holding a server.** Its sessions occupy until the source is marked, after three short sessions
    within `loopWindowS`. After that they only relay. A loop delays a switch or a sleep; the house and the lab are
    never marked.
13. **A start command refused by systemd or polkit.** The decider rolls its records back, the login gets `failed`, and
    `failures` grows. No record is left `stopping` for a unit systemd never stops.
14. **A gate restart with players on.** The relays are cut and the players rejoin. `restartIfChanged = false` keeps a
    switch from causing it, and settings changes reload instead.
15. **A crash during the migration.** `cobblemon.tmp` remains. The next `mc-layout` run continues the move, and the
    servers do not start until it has succeeded.
16. **A deploy that changes a server unit while it runs.** The switch restarts it, as a changed lazymc config does
    as built (R-001), and its players rejoin. A server unit keeps the default `restartIfChanged`: it needs the nas
    mount, and the law `src/tests/policy/mounts.nix` forbids a unit that outlives deploys from `RequiresMountsFor` a
    nas mount. mc-gate, which outlives deploys, needs no mount and only `Wants=` `mc-layout`.

## Security

- **Assets.** The worlds and their backups, the shared whitelist and ops, the rcon password and the CurseForge key,
  and vm-214's CPU and memory.
- **Trust boundaries.**
  - The internet reaches only 25565, through the router's L4 forward with `inflightLimit`.
  - Only mc-gate listens there. The backends and rcon listen on loopback.
  - The gate's user may only `start` and `stop` the exact server units (R-075).
  - The gate runs unprivileged: 25565 is above 1024.
- **Authentication.** The gate authenticates no one. Admission stays with the server: online-mode authentication plus
  the enforced, shared whitelist (R-008, R-073). Login Start names are unauthenticated, so the gate uses them for logs
  only, never for a decision.
- **Threats and mitigations.**
  - **Malformed frames.** Size and time caps (R-040), and a fuzzed reader.
  - **Server-name enumeration.** Status for unknown names lists nothing (R-042).
  - **Forced boots and switches.** Per-source start budget, global switch budget, `minimumOnlineS` (R-051a to
    R-051c).
  - **Holding a server against switches.** Looping marks (R-048a to R-048c).
  - **Cutting players off.** No stop while occupied (R-047). The one residual case is a player sharing one CGNAT
    address with a loop who joins in the 60 s before a switch and is not yet counted.
  - **Privilege escalation through systemd.** The polkit rule names exact units and two verbs.
  - **Supply chain.** No Go dependency; the image tag is pinned (R-071b).
- **Secrets.** Unchanged: rendered by sops under /run (R-007). The gate reads none.
- **Logging.** The gate logs source addresses, names, servers and outcomes. It never logs packet payloads beyond
  those fields.

## Performance

- **Handshake decision.** Under 1 ms of gate CPU per connection, with no allocation beyond the frame buffer of at most
  1 KiB. Measured with a Go benchmark of the frame reader and decider.
- **Relay.** Bytes are copied with `io.Copy` between two TCP sockets. Throughput is bounded by the network, and the
  gate adds no per-packet work after the login decision.
- **Memory.** The gate stays under 32 MiB RSS with 256 connections (the router's cap). Measured in the VM test
  with `systemctl show -p MemoryCurrent mc-gate`.
- **Status.** At most one backend status per `statusCacheS = 5` per server, whatever the ping rate.
- **Polling.** Every `reconcileS = 5` the gate runs one `systemctl show` over all server units, also while all sleep,
  since a hand-started unit must be seen (R-046c). That is one short-lived process and one D-Bus round trip per five
  seconds, under 10 ms of CPU each, about 0.2% of one core. A backend status ping runs on the same tick only while a
  server is `starting` or `running` (R-046g).
- **Start latency.** Bounded by the server's own boot. The gate adds the kick and rejoin, about one client
  reconnect.
- **Scaling limit.** One running server, by design and by the guest's memory.

## Accessibility

No UI of its own. It feeds the Minecraft client's server list and kick screen, through plain English texts that are
named constants (R-054). The client renders them in its own font and scaling. The texts are English only, as the
server is.

## Observability

- **Asserts.** The decider asserts its invariants after every event:
  - at most one record is `starting` or `running`;
  - no record is `stopping` without a stop issued or observed;
  - the budget counters are never negative.

  A failed assert crashes the gate (`Restart=always`), and the panic line names the invariant and the records.
- **Log events.** R-057.
- **State.** `mc-state` (R-056, R-080).
- **Metrics.** R-090, through the node exporter (R-091).
- **Alerts.**
  - `minecraft_start_failed` (R-092).
  - `service_down` from the tcp probe for the gate itself (R-010). It proves only that the gate listens.
- **Failing tests.**
  - A failing simulation prints the seed, the event trace up to the failing step, and the records.
  - A failing VM subtest prints `mc-state` and the gate's journal.

## Testing

Every test of this spec carries the requirement in its name: Go tests `Test_spec001_rNNN[x]_<what>`, the fuzz target
`Fuzz_spec001_r040_frame`, VM subtests `spec001_rNNN[x] <what>`, and policy, DNS and script cases `spec001_rNNN`.

- **As built.** These tests predate the spec and keep their names until p3 rewrites them:
  - `tests/minecraft.nix` subtests "first boot writes the default pack; the secrets and the lazymc config live under
    /run only" (R-005, R-007), "switch to another Modrinth pack", "CurseForge URL", "back to vanilla", "no argument
    shows the current pack and changes nothing" and "choice and secrets survive a restart" (R-005);
  - the laws `src/tests/policy/guests.nix` (R-004 shares equal mounts, R-011 memory budget).

  R-001 to R-003, R-006, R-008, R-009 and R-010 have no test.
- **p1.**
  - `nix build ./src#checks.x86_64-linux.policy-eval`: cases `spec001_r020` (an accepted wildcard tcp route) and
    `spec001_r021` to `spec001_r024` (each refusal).
  - `nix build ./src#checks.x86_64-linux.router-zones`: subtests `spec001_r025` (a name one label below answers the
    backend; a two-label name never gets the backend from the template; every other lab name resolves as before),
    `spec001_r026` (AAAA NODATA) and `spec001_r027` (no `*` in the hosts block).
  - `nix build ./src#checks.x86_64-linux.ddns-cloudflare`: case `spec001_r028`, with the fake API accepting `*` in a
    name query.
  - `nix build ./src#checks.x86_64-linux.lab`: case `spec001_r029`, a wildcard route's export.
- **p2.** `nix build ./src#checks.x86_64-linux.mc-gate`, from `tests/mc-gate.nix`. It has two derivations:
  - `spec001_r059`, the package, whose `buildGoModule` check phase runs plain `go test` with the stdlib only:
    - `Test_spec001_r040_frame` and `Test_spec001_r041_normalize`: VarInt edges and overlong encodings, a 255-char
      address, `\0FML2\0`, a trailing dot, upper case, `FE 01 FA`, and a modern frame of length 126 starting with
      0xFE;
    - `Test_spec001_r042_status`: each status case, and the status JSON round trip;
    - `Test_spec001_r043_login`: relay and kick over a pipe pair;
    - `Test_spec001_r045a_phase`, `Test_spec001_r045b_sync` and `Test_spec001_r045c_rollback`;
    - `Test_spec001_r046a_mapping` to `Test_spec001_r046g_running`, one per reconcile rule;
    - `Test_spec001_r047_occupied`;
    - `Test_spec001_r048a_mark` to `Test_spec001_r048e_exempt`;
    - `Test_spec001_r049_reservation`;
    - `Test_spec001_r050a_idle_since`, `Test_spec001_r050b_sleep` and `Test_spec001_r050c_restart`;
    - `Test_spec001_r051a_source`, `Test_spec001_r051b_switches` and `Test_spec001_r051c_minimum_online`;
    - `Test_spec001_r052_table`, every row;
    - `Test_spec001_r053a_timeout`, `Test_spec001_r053b_first_start` and `Test_spec001_r053c_failed`;
    - `Test_spec001_r054_texts`;
    - `Test_spec001_r055a_settings`, `Test_spec001_r055b_reload` and `Test_spec001_r055c_keep`;
    - `Test_spec001_r056_state` and `Test_spec001_r057_log`;
    - `Test_spec001_r044_sim`, the seeded simulation over 1000 seeds, against a fake systemd that honours
      `Conflicts=` and stop-before-start with random delays. Its events are real and forged logins, leaves, crashes,
      slow starts and stops, gate restarts, hand-started units and refused commands. After every step it asserts:
      - at most one unit active or activating (R-072);
      - no stop while a server holds a session from an unmarked or exempt source, or any session older than
        `loginGraceS` (R-047);
      - exactly one outcome per login (R-044);
      - phases set before replies (R-045a);
      - switches per hour within `switchesPerHourMax`, starts per source within `startsPerSourcePerHourMax` (R-051a,
        R-051b).
  - A fuzz derivation running `go test -fuzz=Fuzz_spec001_r040_frame -fuzztime=30s`, seeded with the table inputs.
- **p3.** `nix build ./src#checks.x86_64-linux.minecraft`, the rewritten VM test. The server units run
  `cmd/fake-server` (R-058) instead of the image. Subtests:
  - `spec001_r058 fake server`: the fake answers status with its live session count, and with its flag ignores
    SIGTERM;
  - `spec001_r042 status` of a sleeping server and of an unknown name;
  - `spec001_r043 login`: a login, its kick, and a rejoin that relays;
  - `spec001_r052 decisions`: a second server refused while the first has a session; a switch after
    `minimumOnlineS` (shortened by the test's settings); a login for the old server during the switch, kicked with
    `stopping`; an unknown name in login;
  - `spec001_r071a pre start` to `spec001_r071f no wantedby`, one per unit property, including a fake backend
    ignoring SIGTERM that is killed while the next server still binds (R-071c);
  - `spec001_r072 conflicts`: a hand start of a second unit stops the first;
  - `spec001_r073 shared whitelist`: written through one container, read in another;
  - `spec001_r074a user` to `spec001_r074d reload`, the last adding a server on SIGHUP without cutting a session
    (also R-055b);
  - `spec001_r075 polkit`: the gate's user is refused a unit not in `servers`;
  - `spec001_r076a layout` to `spec001_r076d rename`: on a fake old data dir, interrupted once and run again;
  - `spec001_r077 route`: no lazymc unit, and 25565 answered by mc-gate;
  - `spec001_r078 modpack`, `spec001_r079 rcon` and `spec001_r080 state`;
  - `spec001_r090 metrics` and `spec001_r091 textfile` (added at p4).

  Also, for p3:
  - `nix build ./src#checks.x86_64-linux.policy-eval`, case `spec001_r070` (a reserved server name is refused);
  - `nix build ./src#checks.x86_64-linux.router-zones`, case `spec001_r077` (`cobblemon.mc.lsck0.dev` answers
    vm-214);
  - `nix build ./src#checks.x86_64-linux.kopia`, subtest `spec001_r083 restore` over
    `data/minecraft/cobblemon/world/level.dat`;
  - `src/instances/preconfigured/113-internal-hermes/tests/hermes-agent.sh minecraft`, run by hand: its case
    `spec001_r082`;
  - R-081a to R-081f are proven by the phase's review against the listed docs.
- **p4.** The `minecraft` VM subtests `spec001_r090 metrics` (the file's metrics) and `spec001_r091 textfile` (the
  node exporter serves `homelab_mc_phase` through the link). `nix build ./src#checks.x86_64-linux.alert-rules`, case
  `spec001_r092`.
- **Before a phase merges.** `nix flake check ./src`, and `shellcheck` passing.

## Roadmap

| Phase | Delivers (requirements) | Depends on | PRs | State |
|---|---|---|---|---|
| p1 | R-020 to R-029: the platform accepts and resolves wildcard tcp hosts; no route uses one, so the lab runs as before | none | none | planned |
| p2 | R-040 to R-059: mc-gate builds with its tests under the check `mc-gate`; nothing runs it, vm-214 still runs lazymc | none | none | planned |
| p3 | R-070 to R-083: vm-214 runs mc-gate and `cobblemon` at `cobblemon.mc.lsck0.dev`; lazymc and `mc.lsck0.dev` are gone; replaces R-001, R-002, R-003, R-005, R-006, R-009 | p1, p2 | none | planned |
| p4 | R-090 to R-092: the gate's metrics reach Prometheus, and failed starts alert | p3 | none | planned |

## Rollout

- **p1.** Merge, then `./sync.sh`. The router and the catalog change, and no route uses a wildcard. Check:
  - `dig +short grafana.lsck0.dev @10.100.0.1` still answers;
  - `nft list table ip port-forwards` on the router is unchanged.
- **p2.** Merge only. Nothing deploys a new unit.
- **p3.** These steps run in order.
  1. On vm-104: `nas-restore now` (`src/core/104-internal-nas/lib/kopia.nix:270`). Note the snapshot id.
  2. Merge, then `./sync.sh` while no one plays. `mc-layout` moves the data, and `mc-gate` takes 25565.
     - Check `ssh 10.200.0.214 'ls /var/lib/minecraft'`: it shows `cobblemon whitelist.json ops.json`.
     - Check `ssh 10.200.0.214 mc-state`: it shows cobblemon `sleeping`.
     - A join to `cobblemon.mc.lsck0.dev` gets the starting kick, and the rejoin plays.
     - The router's next DDNS run creates `*.mc.lsck0.dev` and deletes `mc.lsck0.dev`:
       `journalctl -u ddns-cloudflare -n 30` on the router.
  3. While a player is on: `ssh 10.200.0.214 mc-rcon whitelist add <name>`. Then check that
     `/var/lib/minecraft/whitelist.json` changed, and that `journalctl -u minecraft-cobblemon` shows no EBUSY. Only then
     declare a second server.
  4. Tell the players the new address.
- **Signals.**
  - **It works.** `mc-state` phases match `systemctl is-active minecraft-*`, and the journal shows `login` lines with
    `relay`.
  - **Stop.** `start-failed` lines, a unit active without a gate record, or EBUSY in a server journal.
- **p4.** Merge, `./sync.sh`, then `systemctl restart mc-gate` on vm-214 while no one plays, since the binary changed.
  Check `curl -s 10.200.0.214:9100/metrics | grep homelab_mc_phase` and the rule in Grafana.

## Rollback

- **p1.** `git revert <merge>` and `./sync.sh`. No data.
- **p2.** `git revert <merge>`. Nothing deployed.
- **p3.** The point of no return is the `cobblemon.tmp` rename. Before the revert's sync, on vm-214:
  ```
  systemctl stop mc-gate 'minecraft-*'
  find /var/lib/minecraft/cobblemon -mindepth 1 -maxdepth 1 -exec mv -t /var/lib/minecraft {} +
  rmdir /var/lib/minecraft/cobblemon
  ```
  Then run `git revert <merge>` and `./sync.sh`. Other servers' dirs stay, and the old layout ignores them. As an
  alternative, `nas-restore service minecraft <snapshot id of step 1> --yes` on vm-104 restores the old layout. The
  next DDNS run restores `mc.lsck0.dev` and removes the wildcard.
- **p4.** `git revert <merge>`, `./sync.sh`, then `systemctl restart mc-gate` when no one is on. Activation prunes the
  textfile.
- **Removing a server later.** While it sleeps (`mc-state`), remove it from `servers` and run `./sync.sh`. Its data
  dir stays on the nas.

## Gaps

| Requirements | What the code does instead | Closed by |
|---|---|---|
| R-020 to R-029 | `host` is a single DNS label; no wildcard names exist in DNS | p1 |
| R-040 to R-059, with R-045a to R-045c, R-046a to R-046g, R-048a to R-048e, R-050a to R-050c, R-051a to R-051c, R-053a to R-053c, R-055a to R-055c | no mc-gate; lazymc fronts one server (R-001, R-002) | p2 |
| R-070 to R-083, with R-071a to R-071f, R-074a to R-074d, R-076a to R-076d, R-081a to R-081f | one server, one data dir, lazymc on 25565, `mc.lsck0.dev`, tools without a server argument, hermes test expects .208 | p3 |
| R-090 to R-092 | no Minecraft metrics or alert beyond the tcp probe | p4 |

## Decisions

- 2026-10-14: Several servers on vm-214, each `<name>.mc.lsck0.dev` from one wildcard record, one running at a time.
  The bare `mc.lsck0.dev` is dropped. Rejected: exact DNS records per server (a DNS change per server).
- 2026-10-14: A login that starts a server is kicked with "rejoin", not held. Rejected: holding (the owner's choice;
  the client's own 30 s timeout against a modded boot).
- 2026-10-14: A gate of our own, in Go. Rejected:
  - lazymc per server plus a coordinator (fixed kick text, no refusal for a busy server, a second front still
    needed);
  - itzg/mc-router with its webhook scaler (exact names only, holds the client, no exclusion across routes);
  - Velocity with plugins (a full proxy and a JVM in front of every connection);
  - Python (an interpreter copying every player's bytes).
- 2026-10-14: The servers are declared in nix; each pack stays a runtime choice. Rejected: servers created at runtime
  (the repo would not know what runs).
- 2026-10-14: Whitelist and ops shared by file bind mounts. Rejected: one whitelist per server.
- 2026-10-14: The as-built world becomes `cobblemon`. Rejected: `main`.
- 2026-10-14: Exclusion enforced by systemd `Conflicts=` with ordering only towards earlier names. Rejected: `After=`
  both ways (an ordering cycle, which systemd breaks by deleting a job).
- 2026-10-14: Players counted from the backend's `players.online` plus the gate's own sessions. Rejected:
  - rcon `list` (text parsing that mods and locales change, unreachable until up);
  - sessions older than the login timeout only (a just-joined player could be stopped).
- 2026-10-14: Polkit by exact unit names. Rejected: a `^minecraft-.*` pattern (matches non-server units).
- 2026-10-14: Gate settings reload on SIGHUP, the binary only on a manual restart. Rejected: restart on every switch
  (cuts every player).

## Coverage

| ID | implemented at | proven by | state |
|---|---|---|---|
| R-001 | `214-external-minecraft/main.nix:113-142`, `main.nix#systemd.services.lazymc` | none | done |
| R-002 | `main.nix:31-32, 135-136` | none | done |
| R-003 | `main.nix#mcStart` | none | done |
| R-004 | `main.nix:101`, `instance.nix:27-30` | `src/tests/policy/guests.nix` (pre-spec law) | done |
| R-005 | `main.nix#mcModpack`, `main.nix#mcModpackDefault` | `tests/minecraft.nix` pre-spec subtests listed in Testing | done |
| R-006 | `main.nix#mcRcon` | none | done |
| R-007 | `main.nix:103-111` | `tests/minecraft.nix` pre-spec subtest "first boot ..." | done |
| R-008 | `main.nix:63-64` | none | done |
| R-009 | `instance.nix:16-25`, `src/modules/flows.nix:288-293` | none | done |
| R-010 | `src/core/103-internal-grafana/main.nix:195-200` | none | done |
| R-011 | `instance.nix:3-14` | `src/tests/policy/guests.nix` (pre-spec law) | done |
| R-020 | `src/modules/service.nix` | `policy-eval` spec001_r020 | gap |
| R-021 | `src/modules/catalog.nix` | `policy-eval` spec001_r021 | gap |
| R-022 | `src/modules/catalog.nix` | `policy-eval` spec001_r022 | gap |
| R-023 | `src/modules/catalog.nix` | `policy-eval` spec001_r023 | gap |
| R-024 | `src/modules/catalog.nix` | `policy-eval` spec001_r024 | gap |
| R-025 | `src/core/300-router/main.nix` | `router-zones` spec001_r025 | gap |
| R-026 | `src/core/300-router/main.nix` | `router-zones` spec001_r026 | gap |
| R-027 | `src/core/300-router/main.nix` | `router-zones` spec001_r027 | gap |
| R-028 | `src/core/300-router/main.nix` | `ddns-cloudflare` spec001_r028 | gap |
| R-029 | `src/modules/lab-export.nix` | `lab` spec001_r029 | gap |
| R-040 | `lib/mc-gate/frame.go` | `Test_spec001_r040_frame`, `Fuzz_spec001_r040_frame` | gap |
| R-041 | `lib/mc-gate/frame.go` | `Test_spec001_r041_normalize` | gap |
| R-042 | `lib/mc-gate/status.go` | `Test_spec001_r042_status`, VM `spec001_r042 status` | gap |
| R-043 | `lib/mc-gate/conn.go` | `Test_spec001_r043_login`, VM `spec001_r043 login` | gap |
| R-044 | `lib/mc-gate/decider.go` | `Test_spec001_r044_sim` | gap |
| R-045a | `lib/mc-gate/decider.go` | `Test_spec001_r045a_phase`, `Test_spec001_r044_sim` | gap |
| R-045b | `lib/mc-gate/decider.go` | `Test_spec001_r045b_sync` | gap |
| R-045c | `lib/mc-gate/decider.go` | `Test_spec001_r045c_rollback` | gap |
| R-046a | `lib/mc-gate/reconcile.go` | `Test_spec001_r046a_mapping` | gap |
| R-046b | `lib/mc-gate/reconcile.go` | `Test_spec001_r046b_idle` | gap |
| R-046c | `lib/mc-gate/reconcile.go` | `Test_spec001_r046c_hand_start` | gap |
| R-046d | `lib/mc-gate/reconcile.go` | `Test_spec001_r046d_stopping` | gap |
| R-046e | `lib/mc-gate/reconcile.go` | `Test_spec001_r046e_stopped` | gap |
| R-046f | `lib/mc-gate/reconcile.go` | `Test_spec001_r046f_unqueued_stop` | gap |
| R-046g | `lib/mc-gate/reconcile.go` | `Test_spec001_r046g_running` | gap |
| R-047 | `lib/mc-gate/decider.go` | `Test_spec001_r047_occupied`, `Test_spec001_r044_sim` | gap |
| R-048a | `lib/mc-gate/sources.go` | `Test_spec001_r048a_mark` | gap |
| R-048b | `lib/mc-gate/sources.go` | `Test_spec001_r048b_young` | gap |
| R-048c | `lib/mc-gate/sources.go` | `Test_spec001_r048c_clear` | gap |
| R-048d | `lib/mc-gate/sources.go` | `Test_spec001_r048d_cap` | gap |
| R-048e | `lib/mc-gate/allow.go` | `Test_spec001_r048e_exempt` | gap |
| R-049 | `lib/mc-gate/decider.go` | `Test_spec001_r049_reservation` | gap |
| R-050a | `lib/mc-gate/decider.go` | `Test_spec001_r050a_idle_since` | gap |
| R-050b | `lib/mc-gate/decider.go` | `Test_spec001_r050b_sleep` | gap |
| R-050c | `lib/mc-gate/decider.go` | `Test_spec001_r050c_restart` | gap |
| R-051a | `lib/mc-gate/decider.go` | `Test_spec001_r051a_source`, `Test_spec001_r044_sim` | gap |
| R-051b | `lib/mc-gate/decider.go` | `Test_spec001_r051b_switches`, `Test_spec001_r044_sim` | gap |
| R-051c | `lib/mc-gate/decider.go` | `Test_spec001_r051c_minimum_online` | gap |
| R-052 | `lib/mc-gate/decider.go` | `Test_spec001_r052_table`, VM `spec001_r052 decisions` | gap |
| R-053a | `lib/mc-gate/decider.go` | `Test_spec001_r053a_timeout` | gap |
| R-053b | `lib/mc-gate/decider.go` | `Test_spec001_r053b_first_start` | gap |
| R-053c | `lib/mc-gate/decider.go` | `Test_spec001_r053c_failed` | gap |
| R-054 | `lib/mc-gate/texts.go` | `Test_spec001_r054_texts` | gap |
| R-055a | `lib/mc-gate/settings.go` | `Test_spec001_r055a_settings` | gap |
| R-055b | `lib/mc-gate/settings.go` | `Test_spec001_r055b_reload`, VM `spec001_r074d reload` | gap |
| R-055c | `lib/mc-gate/settings.go` | `Test_spec001_r055c_keep` | gap |
| R-056 | `lib/mc-gate/state.go` | `Test_spec001_r056_state` | gap |
| R-057 | `lib/mc-gate/decider.go` | `Test_spec001_r057_log` | gap |
| R-058 | `lib/mc-gate/cmd/fake-server/` | VM `spec001_r058 fake server` | gap |
| R-059 | `lib/mc-gate.nix`, `tests/mc-gate.nix` | check `mc-gate`, derivation `spec001_r059` | gap |
| R-070 | `main.nix#servers` | `policy-eval` spec001_r070 | gap |
| R-071a | `main.nix` server units | VM `spec001_r071a pre start` | gap |
| R-071b | `main.nix` server units | VM `spec001_r071b start` | gap |
| R-071c | `main.nix` server units | VM `spec001_r071c stop` | gap |
| R-071d | `main.nix` server units | VM `spec001_r071d timeouts` | gap |
| R-071e | `main.nix` server units | VM `spec001_r071e dependencies` | gap |
| R-071f | `main.nix` server units | VM `spec001_r071f no wantedby` | gap |
| R-072 | `main.nix` server units | VM `spec001_r072 conflicts`, `Test_spec001_r044_sim` | gap |
| R-073 | `main.nix` server units | VM `spec001_r073 shared whitelist` | gap |
| R-074a | `main.nix#systemd.services.mc-gate` | VM `spec001_r074a user` | gap |
| R-074b | `main.nix#systemd.services.mc-gate` | VM `spec001_r074b restart` | gap |
| R-074c | `main.nix#systemd.services.mc-gate` | VM `spec001_r074c no restart on switch` | gap |
| R-074d | `main.nix#systemd.services.mc-gate` | VM `spec001_r074d reload` | gap |
| R-075 | `main.nix` polkit rule | VM `spec001_r075 polkit` | gap |
| R-076a | `main.nix#systemd.services.mc-layout` | VM `spec001_r076a layout` | gap |
| R-076b | `main.nix#systemd.services.mc-layout` | VM `spec001_r076b trigger` | gap |
| R-076c | `main.nix#systemd.services.mc-layout` | VM `spec001_r076c move` | gap |
| R-076d | `main.nix#systemd.services.mc-layout` | VM `spec001_r076d rename` | gap |
| R-077 | `instance.nix#services.minecraft` | `router-zones` spec001_r077, VM `spec001_r077 route` | gap |
| R-078 | `main.nix#mcModpack` | VM `spec001_r078 modpack` | gap |
| R-079 | `main.nix#mcRcon` | VM `spec001_r079 rcon` | gap |
| R-080 | `main.nix#mcState` | VM `spec001_r080 state` | gap |
| R-081a | `214-external-minecraft/skill.md` | phase review | gap |
| R-081b | `214-external-minecraft/skill.md` | phase review | gap |
| R-081c | `214-external-minecraft/skill.md` | phase review | gap |
| R-081d | `214-external-minecraft/skill.md` | phase review | gap |
| R-081e | `214-external-minecraft/skill.md` | phase review | gap |
| R-081f | `src/core/300-router/skill.md`, `src/scripts/init.sh` | phase review | gap |
| R-082 | `113-internal-hermes/tests/hermes-agent.sh` | `hermes-agent.sh minecraft` case spec001_r082 | gap |
| R-083 | `src/core/104-internal-nas/tests/kopia.nix` | `kopia` subtest `spec001_r083 restore` over `data/minecraft/cobblemon/world/level.dat` | gap |
| R-090 | `lib/mc-gate/metrics.go` | VM `spec001_r090 metrics` | gap |
| R-091 | `main.nix` tmpfiles, `homelab.textfiles` | VM `spec001_r091 textfile` | gap |
| R-092 | `src/core/103-internal-grafana/lib/rules.nix` | `alert-rules` spec001_r092 | gap |
