# Design: several Minecraft servers, one running at a time

Builds on RESEARCH.md (same folder). The owner decided these on 2026-10-14:

- **Names.** Each server is `<name>.mc.lsck0.dev`, from one wildcard name. The bare `mc.lsck0.dev` is dropped.
- **Startup.** A login that starts a server is kicked with "starting, rejoin in about a minute". It is not held.
- **Gate.** The new listener is written in Go.
- **Declaration.** The set of servers is declared in nix. Each server's pack stays a runtime choice.
- **Whitelist.** Whitelist and ops are shared by all servers.
- **Migration.** Today's world becomes the server `cobblemon`.

## 1. Shape

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

Two primitives carry the design:

- **A set of systemd units, at most one active.** systemd enforces that, not the gate. Each unit has `Conflicts=` on
  every other server's unit. Ordering is a total order by name: a unit is `After=` the units whose names sort before
  its own, and only those, so no ordering cycle exists. With an ordering dependency in either direction, a stop job is
  ordered before a start job (systemd.unit(5), Before=/After=). So starting B stops A, and B's start waits for A's stop
  to finish. Every server reuses the same loopback ports, because two never run together. A unit started by hand
  cannot break the invariant either.
- **A gate that owns the port.** It decides when to start or stop a unit, and it is the only way in. lazymc goes away:
  it fronts one server only and cannot refuse with a reason (RESEARCH 5).

## 2. The servers (nix)

`main.nix` declares the servers as data:

```nix
servers = {
  cobblemon = { version = "1.21.1"; protocol = 767; };
  vanilla = { };
};
```

`version` and `protocol` are optional and default to null. They are what the gate advertises for a server that has
never answered a status ping; without them it advertises version `?`. After the first answer, the gate shows the
server's own, cached on disk (section 3.5). A server name is a DNS label. It must not be `layout`, `gate` or `state`:
those names would collide with the guest's own units and tools, and an evaluation assert refuses them.

Each server `<name>` derives the following.

- **Unit `minecraft-<name>.service`.**
  - `ExecStartPre` creates `/var/lib/minecraft/<name>` (0750, 1000:1000) when missing, runs
    `podman rm --force --ignore minecraft-<name>`, then writes the default pack when `modpack.env` is missing.
  - `ExecStart=podman run --rm --name minecraft-<name>`, with what `mcStart` passes today plus:
    - `-v /var/lib/minecraft/<name>:/data`;
    - `-v /var/lib/minecraft/whitelist.json:/data/whitelist.json` and the same for `ops.json`;
    - `--env-file /var/lib/minecraft/<name>/modpack.env`;
    - `-e STOP_DURATION=90`.
  - `ExecStop=podman stop --time 120 minecraft-<name>`, which stops the container itself, not only the client.
    `ExecStopPost=podman rm --force --ignore minecraft-<name>`, so a container that outlived its unit cannot keep
    the loopback ports (main.nix:162 does the same for lazymc today).
  - `TimeoutStopSec=150`, above the podman timeout. `TimeoutStartSec=infinity`: the gate owns the start timeout.
  - `RequiresMountsFor=/var/lib/minecraft`. `Requires=` and `After=` `mc-layout.service`. `Conflicts=` every other
    server unit. `After=` the server units sorting before it. No `wantedBy`, so only the gate starts it.
- **No tmpfiles entry for a server dir.** Activation would create it before `mc-layout` runs (section 5).
- **Entry in `/etc/mc-gate/settings.json`.** It holds the name, the unit, the version and protocol, and the backend
  address. The file also holds the limits of section 3.

Only one server runs, and the guest's 10 GiB are sized for one heap (RESEARCH 1). So the vm shape stays as it is.

**Shared whitelist and ops.** The files are `/var/lib/minecraft/whitelist.json` and `ops.json`, bind mounted file by
file into every container. `mc-rcon whitelist add` on the running server thereby admits the player on all of them.
While all servers sleep, the owner edits the file itself. The image touches whitelist.json only when `WHITELIST` or
`WHITELIST_FILE` is set (neither is). The server must write the file in place: a rename onto a file bind mount fails
with EBUSY. Both facts are unverified (RESEARCH 6), so rollout step 3 checks them on the real image before the second
server is declared.

## 3. mc-gate

`src/instances/preconfigured/214-external-minecraft/lib/mc-gate/` is a Go module using the standard library only. It
is packaged with `buildGoModule`, which runs its tests, the way `lab-gate` is
(`src/modules/traefik/lib/gate.nix:40-48`). The name avoids `lab-gate`.

It runs as `mc-gate.service` under a static system user `mc-gate`, so the polkit rule can name it. The unit sets
`StateDirectory=mc-gate` (0755), `RuntimeDirectory=mc-gate`, `Restart=always`, and `Wants=` plus `After=`
`mc-layout.service`: the gate waits for the migration but still listens when the nas is down.

A restart of the gate cuts every relayed session, so a switch must not cause one:

- `restartIfChanged = false`. A new gate binary takes effect at the next reboot or on `systemctl restart mc-gate`,
  which kicks the players on. Rollout and skill.md say to run it when no one is on.
- Settings reload in place. The gate reads `/etc/mc-gate/settings.json` again on SIGHUP (`ExecReload=kill -HUP
  $MAINPID`), and `reloadTriggers` holds the settings file, so a switch that adds a server or changes a limit reloads
  without cutting anyone. A switch that also changes the gate's unit (a new binary) skips the unit entirely, reload
  included; the manual restart then loads the new settings too.
- Removing a server is done while it sleeps (`mc-state`). The switch deletes its unit, and systemd would stop a
  running one with its players on.

Every limit below is a named constant in the settings file, with its reason.

### 3.1 Per connection

1. **Read the first frame**, within `handshakeTimeoutS = 5`.
   - If the first three bytes are `FE 01 FA`, or the first byte is 0xFE and no valid frame follows, the gate answers
     a legacy 0xFF kick with protocol 127 and the text `lsck0.dev minecraft`, then closes.
   - Anything else must be a well-formed handshake of at most `handshakeBytesMax = 1024`, or the gate closes.
2. **Normalize the address** (RESEARCH 4): cut at the first `\0`, cut at the first `\`, strip one trailing `.`,
   lowercase. Then strip the suffix `.mc.lsck0.dev`. What remains must be a declared server name, else it is unknown.
3. **Intent 1 (status).** The gate answers it (section 3.5) and echoes the ping.
4. **Intent 2 or 3 (login).** The gate reads Login Start within `handshakeTimeoutS`; the name is used for the log only.
   It then asks the decider (section 3.2). The answer is either relay or kick:
   - **Relay** writes the buffered handshake and Login Start to the backend, then copies both ways.
   - **Kick** answers a login-state Disconnect with a JSON text and closes.

### 3.2 The decider

One goroutine owns every record; connections send it requests over a channel. Two logins in the same instant are thus
decided one after the other, and the second sees the first's start.

**State.** Each server record holds:

- `phase`: `sleeping`, `starting`, `running` or `stopping`;
- `sessions`: the relayed connections, each with its start time;
- `playersOnline`: the backend's last `players.online`;
- `reservedUntil`, `idleSince`, `startedAt` and `failures`.

The decider is the source of truth for `phase`, and it sets the phase the moment it acts. Issuing a start sets the
target to `starting` and every other active server to `stopping`, before any reply goes out.

The decider runs `systemctl start --no-block` (or `stop`) itself, synchronously. When the command returns, systemd has
queued the job, so no later reconcile can read the unit as idle with no job. A non-zero exit (polkit denies it, the
start limit is hit, the unit is broken) rolls the records back to what they were. It also grows `failures`, and the
login gets the `failed` kick.

systemd's own view is read every `reconcileS = 5` for the units (`ActiveState` and `Job` from `systemctl show`). Its
`ActiveState` maps as follows:

- `active`, `activating` and `reloading` count as started;
- `deactivating` counts as stopping;
- `inactive` and `failed` count as idle.

The view corrects the records only in these cases:

- a record `starting` or `running` whose unit is idle with no job becomes `sleeping`; `failures` grows when the unit
  failed;
- a record `sleeping` whose unit is started (by hand) becomes `starting`, and the other records become `stopping`;
- a record `sleeping` whose unit is stopping becomes `stopping`;
- a record `stopping` whose unit is idle with no job becomes `sleeping`;
- a record `stopping` whose unit is started with no job becomes `running` again: the stop never got queued.

A `starting` server becomes `running` once its backend answers a status ping over loopback (every `reconcileS`).

**Occupied.** A server is occupied when any of these holds:

- its last `playersOnline` is above 0;
- it has a live relayed session older than `loginGraceS`;
- it has a live relayed session of any age from a source that is not marked as looping (below);
- `now < reservedUntil`.

A young session blocks a stop, because a player who joined seconds ago is not yet in `playersOnline` and may still be
in the configuration phase (RESEARCH 6).

A forged Login Start opens a session too. The online-mode server drops it without authentication within its login
timeout. That timeout is counted in ticks, so a lagging modded server takes longer than its nominal 30 s;
`loginGraceS = 60` sits clearly above it.

**Looping sources.** A source whose sessions ended before `loginGraceS` three times within `loopWindowS = 600` is marked
as looping. Its young sessions still relay but occupy nothing; once one of them outlives `loginGraceS` it occupies like
any other. The mark clears when a session of the source outlives `loginGraceS`, or after `loopWindowS` without a short
session. Each unexempt source may hold at most `sessionsPerSourceMax = 4` live sessions.

The house and the lab are exempt from marking and from the session cap: private ranges, wireguard, and the house's
public address and v6 prefix. A house player who dials the public name arrives hairpinned with the house's public
address (`src/core/300-router/main.nix:187`). nix feeds mc-gate the same `allow` settings lab-gate gets: the
cidrs, and the names resolved to the house's changing address (`src/modules/traefik/default.nix:467-474`). mc-gate
carries its own small check for them: lab-gate's `allow.go` lives in another Go module, and code one instance uses
stays in that instance's `lib/` (`src/tests/policy/placement.nix`).

The guarantee is therefore: no server is stopped while it holds a session from an unmarked source, or any session older
than `loginGraceS`. The one case left is a player of an external source shared with a loop (one CGNAT address) who
joins in the 60 s before a switch and is not yet counted. A reconnect loop can delay a switch or a sleep by at most the
time it takes to mark it.

**Reservation.** When a started server becomes `running`, `reservedUntil = now + rejoinS`, with `rejoinS = 180`. The
player kicked with "rejoin" then has three minutes in which no one can take the server away.

**Idle and sleep.** `idleSince` is the latest of: the last session end, `reservedUntil`, and the moment the server
became `running`. A `running` server that is not occupied for `sleepAfterS = 1800` is stopped. The value is lazymc's
today (RESEARCH 1). After a restart of the gate, a running server gets `idleSince = now`, and its players are counted
again by the next status poll.

**Budgets.** Each source address may cause at most `startsPerSourcePerHourMax = 3` starts per hour. A switch, a start
that stops a running server, also counts against `switchesPerHourMax = 6` per hour across all sources. A start from
all-asleep does not, so forged switches can never lock real players out of a sleeping lab. A server stays up at least
`minimumOnlineS = 300` after it became `running` before a switch may stop it. Together these bound what forged logins
cost: one modded boot per five minutes at worst, and six switches an hour.

**Decision.** A login for server T, with O the other active server (if any). The first row that matches wins.

| T | O | outcome |
|---|---|---|
| unknown name | any | kick `unknown`, listing the servers |
| running | none | relay |
| starting | any | kick `starting` |
| stopping | any | kick `stopping` |
| sleeping | starting | kick `busyStarting` (O) |
| sleeping | stopping | kick `stopping` (O) |
| sleeping | running and occupied | kick `busy` (O, its players) |
| sleeping | running, under `minimumOnlineS` | kick `justStarted` (O) |
| sleeping | any, over a budget | kick `budget` |
| sleeping | running, not occupied | start T, O becomes `stopping`; kick `starting` |
| sleeping | none | start T; kick `starting` |

### 3.3 Starting and stopping

- **Commands.** The gate runs `systemctl start --no-block minecraft-<T>.service` and `systemctl stop --no-block`.
  A polkit rule lets the `mc-gate` user run only the verbs `start` and `stop`, and only on the exact unit names
  generated from `servers`. This is the `swarm-deploy@` pattern
  (`src/core/107-internal-swarm/lib/app-builder.nix:203-211`).
- **Start timeout.** A start that has no answering backend after `startTimeoutS = 300` (lazymc's own default,
  RESEARCH 5) is stopped, and `failures` grows. The first start after a pack change downloads the pack, which takes
  several minutes (RESEARCH 5). So the timeout is `firstStartTimeoutS = 1200` when `modpack.env` is newer than the
  server's last good start, recorded as `/var/lib/mc-gate/<name>.started`.
- **After a failure.** A failed start or a crashed unit leaves the server `sleeping`, and its status says it failed.
  The next login tries again, within the budget.

### 3.4 Kick texts

Each text is a named constant in one Go file. `<x>` is filled in.

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

### 3.5 Status

- **Running.** The live status of the backend, fetched over loopback and cached for `statusCacheS = 5`. A ping flood
  therefore costs the backend one status per five seconds at most.
- **Not running.** A status built from the server's cached last answer: its version, protocol, max players and
  favicon, with 0 online. The cache is `/var/lib/mc-gate/<name>.json`. A server with no cache falls back to the nix
  version and protocol and no favicon. The description line is one of:
  - `sleeping, join to start it`;
  - `starting, rejoin in about a minute`;
  - `stopping`;
  - `<O> is running with <n> players`;
  - `failed to start, join to try again`.
- **Unknown name.** Version `?`, protocol -1, and the description `no such server`. Scanners see no list of names;
  only a login kick lists them.

### 3.6 Observability

- **Metrics.** The gate writes `/var/lib/mc-gate/metrics.prom` (mode 0644) at start and on every change, atomically
  through a temp file in the same directory. The state directory survives a stop of the gate, so the file never
  dangles once written. tmpfiles links `${textfileDir}/mc-gate.prom` to it, the guest declares
  `homelab.textfiles = [ "mc-gate" ]` (`src/modules/textfile/default.nix`), and the node exporter, already scraped,
  reads it. The VM test proves the link is followed (section 8). The metrics are:
  - `homelab_mc_phase{server,phase}` (1 for the current phase);
  - `homelab_mc_sessions{server}`;
  - `homelab_mc_players{server}`;
  - `homelab_mc_starts_total{server}` and `homelab_mc_start_failures_total{server}`;
  - `homelab_mc_kicks_total{reason}`;
  - `homelab_mc_switches_total`.
- **Alert.** `minecraft_start_failed` fires when `increase(homelab_mc_start_failures_total[1h]) >= 2`, in category
  `service`, without telegram (`src/core/103-internal-grafana/lib/rules.nix`).
- **Log events**, one line each, to the journal:
  - `login` (source, name, server, outcome);
  - `start` and `stop` (server, reason);
  - `start-failed` (server, after how long);
  - `reconcile` (a correction from systemd's view).

  A switch logs the source address that caused it.
- **Probe.** The tcp probe stays and still proves only that the gate listens (RESEARCH 2).

## 4. DNS and the route

The route stays `services.minecraft`, so hermes' `mc` tool and `lab.routes.minecraft` keep their key (RESEARCH 1). It
becomes:

```nix
services.minecraft = {
  host = "*.mc";
  protocol = "tcp"; port = 25565; publicPort = 25565;
  on = [ "inflightLimit" "accessLog" "probe" ] ++ profiles.observed;
};
```

The `srv` goes away. No SRV record exists in Cloudflare (RESEARCH 2), the default port needs none, and an SRV target
would change the address the gate sees (RESEARCH 4).

Platform changes:

- **`service.nix`.** `host` accepts dotted labels and an optional leading `*.`: `(\*\.)?label(\.label)*`. The same
  type covers instance services and app routes.
- **Catalog checks** (`src/modules/catalog.nix`, beside `hostProblems`):
  - a dotted or wildcard host on an http route, of an instance or an app, is refused. The ingress certificate covers
    one level only (RESEARCH 2), and the ingress routes by exact host;
  - a wildcard host without `publicPort` is refused, since only a port forward gives it an address;
  - `srv` with a wildcard host is refused;
  - an exact host matching another route's wildcard (`x.mc` beside `*.mc`) is refused, as two owners of one name.
- **Router CoreDNS** (`src/core/300-router/main.nix`):
  - `forwardHostLines` and `directHosts` skip wildcard hosts.
  - Each wildcard forward host gets two `template` blocks, zoned to the name below the star (`mc.lsck0.dev`), so they
    never see another name of the lab zone. `template IN A` matches `^[a-z0-9-]+\.mc\.lsck0\.dev\.$` and answers the
    backend address. `template IN AAAA` matches the same and answers NOERROR with no records, the NODATA the `hosts`
    plugin gives exact names. Both carry `fallthrough`: `template` runs before `hosts` in CoreDNS's plugin order, so
    an unmatched name must fall through.
- **DDNS.** No script change: its name filter (`lib/ddns-cloudflare.sh:82`) and stale filter (`:119`) compare exact
  strings, which holds for `*.mc.lsck0.dev`. The forward host is written as that record name, `proxied = false`.
  Because the old bare `mc.lsck0.dev` record leaves the list, the stale filter deletes it on the first run. That is
  the intended drop. `ddns_cloudflare_test.py` expects the wildcard name, and its fake API accepts `*` in a name query.
- **lab-export.** It exports the host as `*.mc.lsck0.dev`. The desktop clients read only http routes' hosts
  (`homelab-status.nu:48`, `setup-dns.sh:18`).
- **router-zones test** (`src/tests/router-zones.nix:44-53`). For a wildcard forward host, the A and AAAA expectations
  dig one concrete name below it. Public DNS answers deeper names too (RFC 4592), and the gate kicks any undeclared
  name, so the test asserts only that the template never answers a two-label name with the backend address.

## 5. Tools and data

- **`mc-modpack <server> [pack]`.** It writes `/var/lib/minecraft/<server>/modpack.env` as today and, when that server
  runs, restarts its unit. With no arguments it lists each server with its pack and phase.
- **`mc-rcon -s <server> <command...>`.** It runs `podman exec minecraft-<server> rcon-cli`. Without `-s` it targets
  the running server, and says so when none runs. A flag keeps a server name from being read as an rcon verb.
- **`mc-state`.** It prints `/run/mc-gate/state.json`, which the gate writes on every change: each server, its phase,
  sessions and players.
- **Migration, `mc-layout.service`.** A oneshot (`RemainAfterExit`) with `RequiresMountsFor=/var/lib/minecraft`.
  Every server unit `Requires=` it and is ordered `After=` it; `mc-gate` `Wants=` it and is ordered `After=` it.
  - It moves when `/var/lib/minecraft/cobblemon.tmp` exists, or when `/var/lib/minecraft/modpack.env` exists and
    `/var/lib/minecraft/cobblemon` does not. Otherwise it does nothing.
  - The move takes every top-level entry, dotfiles included, except `whitelist.json`, `ops.json` and `cobblemon.tmp`,
    into `cobblemon.tmp/`. Then it renames `cobblemon.tmp` to `cobblemon`. No server dir exists yet: each is created by
    its unit, which runs only after `mc-layout` succeeded. So an old top-level world named like a server (the default
    pack's `vanilla`, main.nix:38) moves into `cobblemon` with the rest and never becomes a server's data dir.
  - A crash halfway leaves `cobblemon.tmp`, which alone triggers the next run to continue. Entries already moved are
    not at the top level any more.
  - The final rename is the commit point.
  - Rollout step 1 takes a kopia snapshot of the share first.
  - The reverse step is in section 9.
- **NAS.** The share stays `data/minecraft`, and kopia snapshots the same path. `nas-restore service minecraft`
  therefore restores every server at once; skill.md says so.
- **Kopia test.** The fixture in `src/core/104-internal-nas/tests/kopia.nix` moves from `data/minecraft/world/level.dat`
  to `data/minecraft/cobblemon/world/level.dat`.

## 6. Docs, hermes and other touched files

- **214 `skill.md`.** The addresses `<name>.mc.lsck0.dev`, the server list, the switch rule, `mc-state`,
  `journalctl -u minecraft-<name> -u mc-gate`, `mc-modpack <server>`, `mc-rcon -s`, and the shared whitelist (rcon
  only while a server runs; otherwise edit the file).
- **Hermes.** The `mc` tool keeps its route key. `hermes-agent.sh:81-102, 250-252` move to `mc-modpack <server>`, and
  the stale `10.200.0.208` assertion becomes `10.200.0.214`.
- **Router `skill.md:31-32` and `src/scripts/init.sh:114`.** Unchanged in substance: 25565 still goes to vm-214. Both
  say `*.mc` where they name the host.
- **`tests/minecraft.nix`.** Its fake lazymc goes away (section 8).

## 7. Failure modes

1. **Gate down.** The router's dnat hits a closed port, and clients see "connection refused". `service_down` fires
   through the tcp probe after 10 m. Fails closed: no server starts.
2. **A server crashes while players are on.** Their relays end, and the unit goes `failed`. The reconcile sets the
   record to `sleeping` and grows `failures`. The next login starts it again. Fails open: nothing is stuck.
3. **A start hangs (a bad pack).** After `startTimeoutS` or `firstStartTimeoutS`, the gate stops the unit, and status
   says "failed to start". `minecraft_start_failed` fires on the second failure in an hour. Fails closed.
4. **Two logins for different sleeping servers at once.** The decider is serial. The first starts its server, which is
   `starting`; the second gets `busyStarting`.
5. **A login for the old server during a switch.** The decider set it to `stopping` before answering the switching
   login, so the login gets `stopping`, never a relay into a server about to stop.
6. **A player kicked with "rejoin" never rejoins.** The reservation lapses after `rejoinS`. The server then idles from
   `reservedUntil` until `sleepAfterS`, or until another login switches it after `minimumOnlineS`.
7. **The old server is slow to save.** systemd orders the stop before the start. The new unit waits with a queued start
   job, at most `TimeoutStopSec = 150`. The gate holds it as `starting` from the moment it issued the start, so no state
   is read from the unit meanwhile.
8. **A container outlives its unit (SIGKILL of the client).** `ExecStopPost` and the next `ExecStartPre` remove it by
   name, so the ports are free before the next server starts.
9. **The nas mount is late or down at boot.** The server units and `mc-layout` need the mount (`RequiresMountsFor`).
   The gate only wants `mc-layout`, so it listens anyway: status works, and a start fails into rule 3.
10. **A scanner sends garbage or holds the socket.** `handshakeTimeoutS` and `handshakeBytesMax` close it, and the
    router's `inflightLimit` caps connections at 256. Status for an unknown name reveals no server names.
11. **Forged logins switching servers.** A forged name starts a server only within the budgets, and never stops an
    occupied one. Its cost is bounded per source: `startsPerSourcePerHourMax` starts an hour per source, and
    `switchesPerHourMax` switches an hour in all. A TCP source cannot be spoofed, but many real sources can each
    spend their own budget; starts from all-asleep have no global cap, and each holds a server for at most
    `rejoinS` plus `sleepAfterS`.
12. **A reconnect loop holding a server.** Its sessions occupy until the source is marked as looping, after three
    short sessions within `loopWindowS`. It then only relays. A loop delays a switch or a sleep; the house and lab
    are never marked.
13. **A start command refused by systemd or polkit.** The decider rolls its records back, the login gets `failed`, and
    `failures` grows. No record is left `stopping` for a unit systemd never stops.
14. **A gate restart with players on.** A restart cuts the relays, since the gate is the only path, and the players
    rejoin. `restartIfChanged = false` keeps a switch from causing it, and settings changes reload instead.

## 8. Testing

- **Go unit tests, table-driven.**
  - Frame reader: VarInt edge cases, overlong encodings, the 255-character address, the `\0FML2\0` suffix, a trailing
    dot, an uppercase name, the legacy `FE 01 FA`, and a modern frame of length 126 whose first byte is 0xFE.
  - Decider: every row of the decision table, the budgets, `minimumOnlineS`, the reservation, and every reconcile
    correction.
  - Status JSON: encoded and decoded back in a round trip.
- **Simulation, seeded.** A deterministic simulation drives the decider over 1000 seeds, against a fake systemd that
  honours `Conflicts=` and ordered stop-before-start, with random delays. The events are random logins (real and
  forged), leaves, crashes, slow starts, slow stops, gate restarts and hand-started units. After every step it asserts:
  - at most one unit is active or activating;
  - no server is stopped while it holds a session from an unmarked or exempt source, or any session older than
    `loginGraceS`;
  - every login gets exactly one outcome;
  - switches per hour stay within `switchesPerHourMax`, and starts per source per hour within
    `startsPerSourcePerHourMax`.

  This follows `app_builder_sim_test.py` (RESEARCH 3).
- **Fuzz.** `go test -fuzz` on the frame reader, seeded with the table's inputs. The check runs it for a fixed time
  budget.
- **NixOS VM test, `tests/minecraft.nix`, rewritten.** The server units run a fake backend instead of the image. The
  fake is a small Go program built from the same module (`cmd/fake-server`). It speaks handshake, status and login,
  reports `players.online` from its live sessions, and with a flag ignores SIGTERM. A python client in the test
  driver checks:
  - the status of a sleeping server;
  - a login that starts it, the kick, and a rejoin that relays;
  - a login for a second server refused while the first has a session;
  - after the session ends and `minimumOnlineS` passes (shortened by the test's settings), a login that switches;
  - a login for the old server during the switch, kicked with `stopping`;
  - an unknown name, in status and in login;
  - a fake backend ignoring SIGTERM is killed, and the next server still binds;
  - `mc-layout` on a fake old data dir, interrupted once and run again;
  - the node exporter serving `homelab_mc_phase` through the textfile link;
  - polkit refusing the gate's user a unit not in `servers`.

  The modpack subtests move to the per-server form.
- **Other checks.** `nix flake check` runs `policy-eval` with new catalog cases (each refusal of section 4),
  `router-zones` with the wildcard expectations, `ddns-cloudflare`, `kopia` and `hermes-agent`.

## 9. Rollout and rollback outline

1. **Before the guest change.** Take a kopia snapshot on vm-104: `nas-restore now`
   (`src/core/104-internal-nas/lib/kopia.nix:270`).
2. **The guest change**, declaring `cobblemon` alone. `mc-layout` moves the data, and players use
   `cobblemon.mc.lsck0.dev`. The bare name disappears from DNS on the router's next DDNS run.
3. **Check on the real image.** `mc-rcon whitelist add <name>`, then check that `/var/lib/minecraft/whitelist.json`
   changed and that the container log shows no EBUSY. Only then declare a second server.
4. **Rollback of the guest change.** `git revert`. Before the revert's sync, move the data back to the top level,
   dotfiles included (`find /var/lib/minecraft/cobblemon -mindepth 1 -maxdepth 1 -exec mv -t /var/lib/minecraft {} +`,
   then `rmdir /var/lib/minecraft/cobblemon`), or restore the snapshot of step 1. Other servers' dirs stay and are
   ignored by the old layout.
5. **Adding a server later.** Declare it, then `./sync.sh`. The settings reload adds it without a restart, unless the
   same sync changes the gate's binary: then `systemctl restart mc-gate` when no one is on.
6. **Removing a server.** While it sleeps (`mc-state`), remove it, then `./sync.sh`. Its data dir stays on the nas.

## 10. Rejected

- **lazymc per server plus a coordinator.** lazymc kicks with a fixed text. It cannot refuse because another server is
  busy, and each server would need its own port behind something that splits by name, so a second front would remain.
- **itzg/mc-router with its webhook scaler.** Exact names only, it holds the client rather than kicking, and nothing
  coordinates exclusion across routes (RESEARCH 5).
- **Velocity with plugins.** A full proxy layer and a JVM in front of every connection, for what the gate does in a
  few hundred lines.
- **Exact DNS records per server.** Every new server would need a DNS change, which the wildcard avoids.
- **Holding the client while the server boots.** The owner chose the kick. Holding also risks the client's own 30 s
  timeout against a modded boot.
- **Counting players over rcon `list`.** It needs text parsing that mods and locales change, and rcon is unreachable
  until the server is up. The backend's status ping gives `players.online` as a number (RESEARCH 4).
- **Occupying only by sessions older than the login timeout.** A player who joined seconds ago, not yet counted by the
  status poll, could then be stopped. Every session occupies instead, and looping sources are marked.
- **`After=` both ways between server units.** Every pair would form an ordering cycle, which systemd breaks by
  deleting a job, possibly the stop job of the conflicting unit.
- **Generic polkit regex `^minecraft-.*`.** It would also match units that are not servers. The rule lists the exact
  generated unit names.
