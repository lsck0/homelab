# Research: several Minecraft servers, one running at a time

Ask (2026-10-14): several Minecraft servers on vm-214, each at `<name>.mc.lsck0.dev` on the one public port 25565.
All sleep until a player joins. Only one runs at a time: a login for a sleeping server while the running one has
players is refused with a message; while the running one is empty, it is stopped and the requested one started. The
joining player is kicked with "starting, rejoin in about 60 s", not held. The bare `mc.lsck0.dev` is dropped.

Paths are relative to the repo root; external facts carry their URL.

## 1. The guest today

vm-214, `src/instances/preconfigured/214-external-minecraft/`.

- **Front.** lazymc owns 0.0.0.0:25565 (`main.nix:113-142`, the sops template `lazymc.toml`). It answers status
  pings itself and starts the server on a real login (`main.nix:1-3`). It stops the server with rcon `stop` after
  `sleepAfterS = 1800` without players (`main.nix:31`), and keeps it up at least `minimumOnlineS = 60` (`main.nix:32`).
- **Server.** One podman container `minecraft`, started by lazymc as its child through `mcStart` (`main.nix:43-68`),
  image `itzg/minecraft-server:2026.9.1-java21` (`main.nix:15`). Game port published on 127.0.0.1:25566, rcon on
  127.0.0.1:25575 (`main.nix:22-23, 48`). Heap 7G (`main.nix:29`).
- **State.** One data dir `/var/lib/minecraft` and one modpack cache `/var/lib/minecraft-modpacks`, both nas mounts
  (`main.nix:8-9, 101`; shares `instance.nix:27-30`). The pack is `modpack.env` in the data dir, written by
  `mc-modpack` (`main.nix:75-94`), which ends in `systemctl restart lazymc` (`main.nix:92`). Worlds are kept per pack
  as `LEVEL=<slug>`. whitelist.json and ops.json live in the data dir, not in the repo (`main.nix:4-5`). So separate
  data dirs mean separate whitelists and ops, unless the dirs share those files. The gate cannot check names in their
  place, because Login Start names are unauthenticated (section 4). `skill.md:43-45` tells hermes to run
  `whitelist add`, which works only while the server is awake.
- **Tools.** `mc-modpack` (`main.nix:75-94`) and `mc-rcon` = `podman exec minecraft rcon-cli` (`main.nix:97-99`).
- **Secrets.** `minecraft-rcon-password` (hex:24) and `minecraft-cf-api-key` (manual) (`instance.nix:32-35`), rendered
  into `minecraft-server.env` under /run (`main.nix:103-111`).
- **Shape.** 10 GiB unballooned, 10 cores, always on: no `idle`, no `power` (`instance.nix:3-14`,
  `src/generated/lab.json:244-250`). An l4 route on an idle guest is refused (`src/modules/catalog.nix:325-327`). So the
  guest stays up and sleep happens inside it. With 10 GiB and a 7G heap, only one modded server fits anyway.
- **Route.** `services.minecraft = { host = "mc"; protocol = "tcp"; port = 25565; publicPort = 25565;
  srv = "_minecraft._tcp"; on = [ "inflightLimit" "accessLog" "probe" ] ++ profiles.observed; }` (`instance.nix:16-25`).
- **Tests.**
  - `tests/minecraft.nix`: a `runNixOSTest` of `lab.guest "214"` with lazymc replaced by a fake. It covers the modpack
    switching and that secrets stay under /run (`tests/minecraft.nix:8-69`).
  - The nas kopia test assumes the layout. It uses `/srv/nas/data/minecraft/world/level.dat` and runs
    `nas-restore service minecraft` (`src/core/104-internal-nas/tests/kopia.nix:16-17, 41, 54, 61-63, 88-93`). The help
    text is at `src/core/104-internal-nas/lib/kopia.nix:266`.
- **Docs.**
  - `skill.md:14, 18, 23-24` name `mc.lsck0.dev` and lazymc.
  - `src/core/300-router/skill.md:31-32` says `25565 -> vm-214`.
  - `src/scripts/init.sh:114` says "forward 443 and 25565".
- **Hermes.**
  - Hermes has an `mc` tool bound to the route key: it reaches the guest by `lab.routes.minecraft.vmid`
    (`src/instances/preconfigured/113-internal-hermes/main.nix:76-78`). Renaming or splitting that route breaks it.
    `src/instances/preconfigured/113-internal-hermes/tests/hermes-skills.nix:28` lists `mc` as a tool.
  - `src/instances/preconfigured/113-internal-hermes/tests/hermes-agent.sh` checks the tool (lines 13, 81, 98-102, 113,
    250-252, 329). Line 252 expects `ssh 10\.200\.0\.208 .*mc-modpack`, but the stub (98-102) and the guest are .214,
    so that assertion is stale today.

## 2. How a tcp route's name reaches DNS and the router

- **`host`.** One DNS label: `dnsLabel = types.strMatching "[a-z0-9]([a-z0-9-]*[a-z0-9])?"` (`src/modules/service.nix:74`,
  used at `:124`). Neither `a.mc` nor `*.mc` passes it.
- **fqdn.** Everywhere `net.fqdn = host: "${host}.${domain}"` (`src/modules/net.nix:128`).
- **Port forward.** `flows.portForwards` gets one entry per `catalog.forwarded` route (`src/modules/flows.nix:288-293`).
  The router renders an L4 dnat per entry: `inflightLimit` gives `ct count over 256`, `accessLog` a rate-limited log
  `forward <port>: ` (`src/core/300-router/main.nix:517-533`). No hostname is involved.
- **Lab DNS.** The router's CoreDNS `hosts` block holds `forwardHostLines`, one exact name per forward host mapped to
  the backend's address (`300-router/main.nix:125, 145-147, 595`). The SRV `template` answers
  `_minecraft._tcp.mc.lsck0.dev` with the route's own fqdn (`300-router/main.nix:598-602`). That `template` is the only
  one in the repo; nothing matches names by pattern. Any other name, `a.mc.lsck0.dev` included, goes to blocky
  upstream (`300-router/main.nix:603-604`). It then gets the public A record, which port forwards answer hairpinned for
  the trusted zones only, never a dmz (`300-router/main.nix:187, 201`).
- **Public DNS.** `ddns-records.json` takes the forward hosts as `proxied = false` (`300-router/main.nix:130-141`).
  `ddns-cloudflare.sh` writes A records only (`lib/ddns-cloudflare.sh:85`). It deletes A records holding the house's
  address that the list does not name (`:110-131`). So a hand-made `*.mc` record would be deleted: either ddns emits
  the names (or the wildcard itself), or that filter changes. Cloudflare accepts wildcards below the apex, such as
  `*.www.example.com` (https://developers.cloudflare.com/dns/manage-dns-records/reference/wildcard-dns-records/). No
  SRV record exists in Cloudflare, so outside players reach 25565 by A record and the default port.
  `tests/ddns_cloudflare_test.py:34` expects `mc.<zone>`.
- **Edge, homepage.** The edge and the homepage see http routes only (`200-external-traefik/main.nix:42`,
  `102-internal-homepage/main.nix:5`). The minecraft route has no `homepage` and no card.
- **Prober.** The `probe` feature on a tcp route is a blackbox `tcp_up` connect to `10.200.0.214:25565`. It does no
  protocol check, and it is skipped while the guest is not `awake` (`103-internal-grafana/main.nix:195-200, 751-755`).
  Whatever listens on 25565 answers it (lazymc today, the gate later), so it never shows whether a server is up.
- **Wildcards elsewhere.** The ingress certificates cover `*.lsck0.dev`, one level deep
  (`src/modules/traefik/default.nix:727-728`). That is irrelevant to a tcp route, but it means a two-level name for an
  http route would get no certificate.
- **Catalog checks.**
  - `hostProblems` groups routes by exact host and errors when two owners claim one (`catalog.nix:207-214`).
  - The srv check needs a publicPort (`catalog.nix:317-318`).
  - Duplicate public ports are counted per owner (`catalog.nix:192-195, 329-333`). Two routes of vm-214 on tcp/25565
    pass that check, but each would render its own dnat.
- **Tests that encode the name.**
  - `src/tests/router-zones.nix:44-53`: the dns expectations by `net.fqdn r.host`.
  - `:60`: port 25565 in `tcpPorts`.
  - `:205-206`: 25565 closed there.
  - `:239-240`: the srv format, via teamspeak. `src/core/103-internal-grafana/tests/dashboards.nix:12` (a fake tcp
  route on 25565).

## 3. Repo conventions that constrain the build

- **Discovery.** A guest's `tests/*.nix` becomes `checks.x86_64-linux.<file name>` (`src/flake.nix:49-80`). Script tests
  are `runCommand` around a python test file (`300-router/tests/ddns-cloudflare.nix`). Deterministic simulations over
  seeds exist (`107-internal-swarm/tests/app_builder_sim_test.py`).
- **Placement.** What one instance uses lives in its folder's `lib/` (`src/tests/policy/placement.nix:14-22`).
- **Long-running daemons.**
  - Python via `pkgs.writers.writePython3Bin`: `fronius-exporter` (`103-internal-grafana/main.nix:313-319, 1015-1030`).
  - The swarm controller api is socket-activated python (`src/modules/swarm/default.nix:759-770`).
  - Go via `buildGoModule`: `lab-gate`, the ingresses' forwardAuth gate
    (`src/modules/traefik/lib/gate.nix:40-48`, `traefik/default.nix:1218-1227`).
  - There is no nushell, rust or js in `src/`.
  - The name `lab-gate` is taken.
- **Laws a change touches.**
  - `src/tests/policy/network.nix:333-335`: every port-forward line names one numeric port.
  - `guests.nix`: `needs` and the memory budget.
  - `mounts.nix`: shares equal mounts.
  - `secrets.nix`: sops wiring.
- **Corpus.** The repo has no `specs/`, no AGENTS.md and no merge-policy line. This spec starts the corpus; merge policy
  defaults to human.

## 4. The protocol facts the gate needs

- **Framing.** `VarInt length | VarInt id | data`. A VarInt has at most 5 bytes. A String is a VarInt byte length plus
  UTF-8, its limit counted in UTF-16 units. https://minecraft.wiki/w/Java_Edition_protocol/Data_types
- **Handshake.** id 0x00: protocol VarInt, server address String (max 255), port u16, intent VarInt. Intent 1 is
  status, 2 is login, 3 is transfer (since 1.20.5; it continues to the login state). Pinging clients may send
  protocol -1. https://minecraft.wiki/w/Java_Edition_protocol/Packets,
  https://minecraft.wiki/w/Java_Edition_protocol/Server_List_Ping
- **The address is the SRV target, not the typed name.** With no SRV and a wildcard A record, it is the typed name.
  (Same pages.) Inside the lab the router's SRV template points a name at itself, so this holds there too.
- **Normalizing the address.** mc-router does it in this order
  (https://github.com/itzg/mc-router/blob/master/server/routes.go, lines 278-290):
  1. cut at the first `\0` (Forge's `\0FML\0`/`\0FML2\0`, BungeeCord forwarding);
  2. cut at the first `\`;
  3. strip one trailing `.`;
  4. lowercase.

  NeoForge 1.21.1 sends no suffix; mod negotiation is in the configuration phase (grep of
  https://github.com/neoforged/NeoForge/tree/1.21.1). Cutting at `\0` still costs nothing.
- **Legacy ping.** The first byte is 0xFE (no length prefix); 1.6+ sends `FE 01 FA`. The reply is a 0xFF kick with a
  UTF-16BE string. Modern clients fall back to it after a malformed status response
  (https://minecraft.wiki/w/Java_Edition_protocol/Server_List_Ping). mc-router peeks the byte and answers
  (https://github.com/itzg/mc-router/blob/master/mcproto/read.go, lines 37-45). lazymc ignores it. Peeking the three
  bytes `FE 01 FA` avoids mistaking a 126-byte modern frame length for the legacy id.
- **Status.**
  - Request 0x00 is empty. Response 0x00 is JSON: `version.name`, `version.protocol`, `players.max`/`online`/`sample`,
    `description` (a text component), `favicon` (64x64 png data uri).
  - Ping 0x01 carries a Long, which the pong echoes; then the server closes.
  - NeoForge 1.21.1 adds only `isModded` (optional, default false) to the status JSON; there is no `forgeData` on that
    branch
    (https://github.com/neoforged/NeoForge/blob/1.21.1/patches/net/minecraft/network/protocol/status/ServerStatus.java.patch).
  - lazymc's sleeping status: version and protocol from config, 0 online, its sleeping MOTD
    (https://github.com/timvisee/lazymc/blob/master/src/status.rs).
- **Login.**
  - Login Start (id 0x00) carries name (max 16) and uuid. It is unauthenticated at that point: good for logs, spoofable
    for any decision.
  - Login Disconnect (login state, clientbound 0x00) is a JSON text component. In the configuration and play states the
    reason is NBT, so the gate kicks during login.
  - mc-router and lazymc both read Login Start before kicking
    (https://github.com/itzg/mc-router/blob/master/server/connector.go, lines 529-545;
    https://github.com/timvisee/lazymc/blob/master/src/status.rs).
  - lazymc declares support from 1.20.3 (protocol 765). 1.21.1 is protocol 767
    (https://raw.githubusercontent.com/misode/mcmeta/1.21.1-summary/version.json).
- **Counting players.**
  - rcon `list` prints `There are %s of a max of %s players online: %s`
    (https://raw.githubusercontent.com/misode/mcmeta/1.21.1-assets/assets/minecraft/lang/en_us.json). Mods or locales
    may change the text.
  - lazymc polls the backend's status for `players.online`
    (https://github.com/timvisee/lazymc/blob/master/src/monitor.rs).
  - itzg's autopause treats a failed ping as one player, which fails closed
    (https://github.com/itzg/docker-minecraft-server/blob/master/scripts/auto/autopause-fcns.sh).
  - A gate that relays every session after the handshake can count live login sessions itself, with no polling and no
    parsing.
- **Stopping the server.** `mc-server-runner` turns SIGTERM into `stop` (over rcon when enabled) and waits
  `STOP_DURATION` (default 60 s) before killing (https://github.com/itzg/mc-server-runner/blob/master/main.go,
  https://docs.itzg.me/minecraft-server/configuration/misc-options/). podman's `--stop-timeout` defaults to 10 s
  (https://docs.podman.io/en/latest/markdown/podman-run.1.html), and `mcStart` sets none (`main.nix:46`). So a
  `podman stop` kills the server before it saves, unless the timeout exceeds `STOP_DURATION`.

## 5. Prior art

| Tool | Host routing | Wake on join | Sleep | Status while asleep | Kick | One of N |
|---|---|---|---|---|---|---|
| lazymc | no, one server | yes | yes | yes | yes | no |
| itzg/mc-router | exact names, default route | yes (docker, k8s, webhook) | yes | yes | no, holds | no |
| infrared | wildcards | none found | no | placeholder | n/a | no |
| minekube gate (lite) | yes | not documented | not documented | not documented | n/a | no |
| Velocity + plugins | proxy | yes | yes | n/a | n/a | not documented |

lazymc's own timeouts: `server.start_timeout = 300`, `server.stop_timeout = 150`, `time.minimum_online_time = 60`
(https://github.com/timvisee/lazymc/blob/master/res/lazymc.toml). The guest's skill says a pack's first start downloads
it and takes several minutes (`src/instances/preconfigured/214-external-minecraft/skill.md:24`).

Sources: https://github.com/timvisee/lazymc, https://github.com/itzg/mc-router, https://github.com/haveachin/infrared,
https://github.com/minekube/gate. No tool found does one-of-N exclusion. mc-router's `-auto-scale-webhook-url`
delegates up and down to an external service per route, but nothing coordinates across routes. mc-router holds the
client while waking rather than kicking it. Velocity adds a full proxy layer.

## 6. Not verified

- How a NeoForge 1.21.1 client renders a login-state JSON disconnect, and whether it marks a status without
  `isModded`. Needs a real client.
- The Login Start layout for protocol 767 from a 1.21.1-specific source.
- Whether rcon `list` and `players.online` count a player still in the configuration phase.
- Real stop time of the modded pack.
- What Geyser puts in the address field.
