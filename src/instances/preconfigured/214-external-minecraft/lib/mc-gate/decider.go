package main

import (
	"fmt"
	"log/slog"
	"maps"
	"net/netip"
	"slices"
	"time"
)

/*
 * -----------------------------------------------------------------------------
 * CONSTANTS
 * -----------------------------------------------------------------------------
 */

// a server's phase, as the gate holds it; it is set from a decision first and corrected from systemd second
const (
	phaseSleeping Phase = "sleeping"
	phaseStarting Phase = "starting"
	phaseRunning  Phase = "running"
	phaseStopping Phase = "stopping"
)

const (
	eventLogin eventKind = iota
	eventSessionEnd
	eventStatus
	eventTick
	eventReload
	eventSnapshot
)

// the decider answers from its own records, so a connection never waits long enough for a deep queue to matter
const deciderEventsQueued = 64

/*
 * -----------------------------------------------------------------------------
 * TYPES
 * -----------------------------------------------------------------------------
 */

type Phase string

type eventKind int

// Session is one relayed login. It is live from the decision until the relay ends, whatever the player does with it.
type Session struct {
	id        uint64
	source    netip.Addr
	startedAt time.Time
}

// Server is one declared server's record. Every field is owned by the decider's goroutine and read nowhere else.
type Server struct {
	name       string
	unit       string
	version    *string
	protocol   *int
	modpackEnv string

	phase          Phase
	sessions       []Session
	playersOnline  int
	reservedUntil  time.Time
	idleSince      time.Time
	startedAt      time.Time
	runningSince   time.Time
	lastSessionEnd time.Time
	failures       int
	// what the metrics count: failures resets with a good start, these never go down (R-090)
	startsTotal        int
	startFailuresTotal int
	// set when a start was refused, never answered, or ended in a failed unit; cleared by the next start
	lastStartFailed bool
	// true while the decider has issued a stop, or has seen the unit deactivating; it is what makes a stopping
	// record provable rather than guessed
	stopIssued bool
	// the backend's last live status, from the cache file at startup and from a fetch afterwards
	status   []byte
	statusAt time.Time
	// dropped by a reload, kept until its sessions end (R-055c)
	removed bool
	// the unit's own ActiveState was `active` at the last reconcile. Every server shares the one backend port, so
	// while a switch waits on the old server's save, an answer there is the old server's (R-046g)
	unitUp bool
}

// Decision is one login's answer: a relay to the backend, a kick with a text, or a close with neither.
type Decision struct {
	Outcome string
	Text    string
	Backend string
	Session uint64
}

// Decider owns every record (R-044). Connections reach it over one channel, so two logins are never decided at once
// and the rules below need no lock.
type Decider struct {
	settings Settings
	servers  map[string]*Server
	// the declared names, sorted: the list an unknown kick shows and the order every loop runs in
	names   []string
	sources map[netip.Addr]*Source
	budget  Budget
	// the counters of R-090 the records do not hold themselves: one per kick reason, and every switch ever
	kicks         map[string]int
	switchesTotal int
	// the metrics last written, so a view that did not change is not written again
	metrics []byte

	systemd Systemd
	allow   *Allow
	fetch   StatusFetch
	log     *slog.Logger
	now     func() time.Time

	sessionSeq uint64
	events     chan deciderEvent
	stopped    chan struct{}
}

// deciderEvent is one thing that happened. Every one carries a reply channel, so the caller's order of events is the
// decider's order of decisions.
type deciderEvent struct {
	kind     eventKind
	name     string
	player   string
	source   netip.Addr
	session  uint64
	settings Settings
	reply    chan deciderReply
}

type deciderReply struct {
	decision Decision
	status   []byte
	state    State
}

/*
 * -----------------------------------------------------------------------------
 * LIFETIME
 * -----------------------------------------------------------------------------
 */

func deciderCreate(settings Settings, systemd Systemd, allow *Allow, fetch StatusFetch, log *slog.Logger, now func() time.Time) *Decider {
	d := &Decider{
		servers: make(map[string]*Server), sources: make(map[netip.Addr]*Source),
		systemd: systemd, allow: allow, fetch: fetch, log: log, now: now,
		kicks:  map[string]int{},
		events: make(chan deciderEvent, deciderEventsQueued), stopped: make(chan struct{}),
	}
	deciderSettingsApply(d, settings)
	// the file exists before the first event, so a scrape right after a restart reads the records (R-090)
	deciderMetricsSave(d)
	return d
}

// deciderRun is the one goroutine that owns the records; it ends when deciderDestroy closes the channel.
func deciderRun(d *Decider) {
	for event := range d.events {
		deciderHandle(d, event)
	}
	close(d.stopped)
}

func deciderDestroy(d *Decider) {
	if d == nil {
		return
	}
	close(d.events)
	<-d.stopped
}

func serverCreate(d *Decider, declared SettingsServer) *Server {
	return &Server{
		name: declared.Name, unit: declared.Unit, version: declared.Version, protocol: declared.Protocol,
		modpackEnv: declared.ModpackEnv, phase: phaseSleeping,
		status: statusCacheLoad(d.settings.StateDir, declared.Name),
	}
}

/*
 * -----------------------------------------------------------------------------
 * INTERNAL
 * -----------------------------------------------------------------------------
 */

// deciderServers lists every record, dropped ones included, in one order, so a decision never depends on map order.
func deciderServers(d *Decider) []*Server {
	servers := make([]*Server, 0, len(d.servers))
	for _, name := range slices.Sorted(maps.Keys(d.servers)) {
		servers = append(servers, d.servers[name])
	}
	return servers
}

// deciderActive is the one record that is starting or running, which the invariant allows at most one of.
func deciderActive(d *Decider, exclude string) *Server {
	for _, server := range deciderServers(d) {
		if server.name != exclude && (server.phase == phaseStarting || server.phase == phaseRunning) {
			return server
		}
	}
	return nil
}

// deciderOther is the active server a login for another one has to reckon with: the started one before a stopping
// one, since only a started one can be occupied.
func deciderOther(d *Decider, exclude string) *Server {
	if active := deciderActive(d, exclude); active != nil {
		return active
	}
	for _, server := range deciderServers(d) {
		if server.name != exclude && server.phase == phaseStopping {
			return server
		}
	}
	return nil
}

// serverPlayers is how many people a server holds: the backend's own count, or the gate's live sessions while the
// backend has not counted a player who joined seconds ago.
func serverPlayers(server *Server) int {
	return max(server.playersOnline, len(server.sessions))
}

// serverIdleRefresh keeps idleSince the latest of the last session end, the reservation and the start (R-050a).
func serverIdleRefresh(server *Server) {
	server.idleSince = server.lastSessionEnd
	for _, moment := range []time.Time{server.reservedUntil, server.runningSince} {
		if moment.After(server.idleSince) {
			server.idleSince = moment
		}
	}
}

// serverRunningSet marks a server up. A start the gate issued earns the player who was kicked a reservation (R-049);
// a unit that came up by itself earns none.
func serverRunningSet(d *Decider, server *Server, now time.Time) {
	server.phase, server.runningSince, server.stopIssued = phaseRunning, now, false
	if !server.startedAt.IsZero() {
		server.reservedUntil = now.Add(durationFromSeconds(d.settings.Limits.RejoinS))
	}
	server.startedAt, server.lastStartFailed = time.Time{}, false
	serverIdleRefresh(server)
	if err := startedMarkerTouch(d.settings.StateDir, server.name, now); err != nil {
		d.log.Warn("start marker", "server", server.name, "err", err)
	}
}

// serverSleepSet marks a server down; its player count belongs to a backend that is gone.
func serverSleepSet(server *Server) {
	server.phase, server.stopIssued = phaseSleeping, false
	server.playersOnline, server.statusAt = 0, time.Time{}
	server.startedAt, server.runningSince = time.Time{}, time.Time{}
	serverIdleRefresh(server)
}

// deciderSourceGet is one address's history, created on first sight and forgotten once it holds nothing.
func deciderSourceGet(d *Decider, address netip.Addr) *Source {
	source, known := d.sources[address]
	if !known {
		source = &Source{}
		d.sources[address] = source
	}
	return source
}

// deciderSourceLooping is true for a marked source. An exempt one is never marked, so the house is never a loop.
func deciderSourceLooping(d *Decider, address netip.Addr, now time.Time) bool {
	if allowContains(d.allow, address, now) {
		return false
	}
	source, known := d.sources[address]
	if !known {
		return false
	}
	sourcePrune(source, now, d.settings.Limits)
	return source.markedLooping
}

// deciderOccupied is what a switch or a sleep may not stop (R-047). A young session occupies because a player who
// joined seconds ago is not in the backend's count yet, unless its source is a known reconnect loop (R-048b).
func deciderOccupied(d *Decider, server *Server, now time.Time) bool {
	if server.playersOnline > 0 {
		return true
	}
	grace := durationFromSeconds(d.settings.Limits.LoginGraceS)
	for _, session := range server.sessions {
		if now.Sub(session.startedAt) >= grace || !deciderSourceLooping(d, session.source, now) {
			return true
		}
	}
	return now.Before(server.reservedUntil)
}

// deciderKick builds one refusal; the texts are R-054's and live in one file.
func deciderKick(d *Decider, outcome, server string, players int) Decision {
	d.kicks[outcome]++
	return Decision{Outcome: outcome, Text: kickText(outcome, server, players, d.names)}
}

// deciderStart issues a start. Every phase is set before any reply and before systemd is asked (R-045a), the asking
// is synchronous and stops the others first (R-045b), and a command systemd refuses leaves no trace but a failure
// (R-045c).
func deciderStart(d *Decider, now time.Time, target *Server, source netip.Addr) Decision {
	type savedServer struct {
		server     *Server
		phase      Phase
		startedAt  time.Time
		failed     bool
		stopIssued bool
	}
	saved := []savedServer{}
	stops := []*Server{}
	for _, server := range deciderServers(d) {
		saved = append(saved, savedServer{server, server.phase, server.startedAt, server.lastStartFailed, server.stopIssued})
		if server == target || server.phase == phaseSleeping {
			continue
		}
		switching := server.phase == phaseRunning
		server.phase, server.stopIssued = phaseStopping, true
		if switching {
			stops = append(stops, server)
		}
	}
	target.phase, target.startedAt, target.lastStartFailed = phaseStarting, now, false

	var err error
	for _, server := range stops {
		if err = d.systemd.Stop(server.unit); err != nil {
			break
		}
	}
	if err == nil {
		err = d.systemd.Start(target.unit)
	}
	if err != nil {
		for _, state := range saved {
			state.server.phase, state.server.startedAt = state.phase, state.startedAt
			state.server.lastStartFailed, state.server.stopIssued = state.failed, state.stopIssued
		}
		target.failures, target.lastStartFailed = target.failures+1, true
		target.startFailuresTotal++
		logStartFailedWrite(d.log, target.name, 0, err)
		return deciderKick(d, outcomeFailed, target.name, 0)
	}

	causing := deciderSourceGet(d, source)
	causing.starts = append(causing.starts, now)
	target.startsTotal++
	reason := reasonLogin
	if len(stops) > 0 {
		// only a start that stops a running server spends the global budget (R-051b)
		d.budget.switches = append(d.budget.switches, now)
		d.switchesTotal++
		reason = reasonSwitch
	}
	for _, server := range stops {
		logStopWrite(d.log, server.name, reasonSwitch, source)
	}
	logStartWrite(d.log, target.name, reason, source)
	return deciderKick(d, outcomeStarting, target.name, 0)
}

// deciderStop takes a server down on the gate's own account: it idled out, or its start never answered.
func deciderStop(d *Decider, server *Server, reason string) {
	previous, previousIssued := server.phase, server.stopIssued
	server.phase, server.stopIssued = phaseStopping, true
	if err := d.systemd.Stop(server.unit); err != nil {
		server.phase, server.stopIssued = previous, previousIssued
		d.log.Warn(logStop, "server", server.name, "reason", reason, "err", err)
		return
	}
	logStopWrite(d.log, server.name, reason, netip.Addr{})
}

// deciderDecide is the table of R-052, its rows in order.
func deciderDecide(d *Decider, now time.Time, name string, address netip.Addr) Decision {
	limits := d.settings.Limits
	exempt := allowContains(d.allow, address, now)
	source := deciderSourceGet(d, address)
	sourcePrune(source, now, limits)
	// row 0: a flood from one address is closed before any rule can spend a server on it (R-048d)
	if !exempt && source.live >= limits.SessionsPerSourceMax {
		return Decision{Outcome: outcomeCapped}
	}

	target, declared := d.servers[name]
	if !declared || target.removed {
		return deciderKick(d, outcomeUnknown, name, 0)
	}
	switch target.phase {
	case phaseRunning:
		d.sessionSeq++
		target.sessions = append(target.sessions, Session{id: d.sessionSeq, source: address, startedAt: now})
		source.live++
		return Decision{Outcome: outcomeRelay, Backend: d.settings.Backend, Session: d.sessionSeq}
	case phaseStarting:
		return deciderKick(d, outcomeStarting, target.name, 0)
	case phaseStopping:
		return deciderKick(d, outcomeStopping, target.name, 0)
	}

	other := deciderOther(d, target.name)
	switch {
	case other == nil:
	case other.phase == phaseStarting:
		return deciderKick(d, outcomeBusyStarting, other.name, 0)
	case other.phase == phaseStopping:
		return deciderKick(d, outcomeStopping, other.name, 0)
	case deciderOccupied(d, other, now):
		return deciderKick(d, outcomeBusy, other.name, serverPlayers(other))
	case now.Sub(other.runningSince) < durationFromSeconds(limits.MinimumOnlineS):
		return deciderKick(d, outcomeJustStarted, other.name, 0)
	}
	switching := other != nil
	if !sourceStartsLeft(source, now, limits) || (switching && !budgetSwitchesLeft(&d.budget, now, limits)) {
		return deciderKick(d, outcomeBudget, target.name, 0)
	}
	return deciderStart(d, now, target, address)
}

// deciderSessionEndRecord closes one relay: the server idles from now, and the source learns whether that was a
// player or another turn of a reconnect loop.
func deciderSessionEndRecord(d *Decider, now time.Time, name string, id uint64) {
	server, known := d.servers[name]
	if !known {
		return
	}
	index := slices.IndexFunc(server.sessions, func(session Session) bool { return session.id == id })
	if index < 0 {
		return
	}
	session := server.sessions[index]
	server.sessions = slices.Delete(server.sessions, index, index+1)
	server.lastSessionEnd = now
	serverIdleRefresh(server)
	if source, known := d.sources[session.source]; known {
		source.live = max(source.live-1, 0)
		// an exempt source is never marked, so one friend's failed joins cannot mark the whole house (R-048e)
		if !allowContains(d.allow, session.source, now) {
			sourceSessionEnd(source, now, now.Sub(session.startedAt), d.settings.Limits)
		}
		if sourceIdle(source) {
			delete(d.sources, session.source)
		}
	}
}

// deciderStatusAnswer builds what a ping is told (R-042).
func deciderStatusAnswer(d *Decider, now time.Time, name string) []byte {
	server, declared := d.servers[name]
	if !declared || server.removed {
		// a scanner reads this, so it names no server (Security)
		answer, _ := statusBuild(nil, nil, nil, descriptionUnknown)
		return answer
	}
	if server.phase == phaseRunning {
		if now.Sub(server.statusAt) >= durationFromSeconds(d.settings.Limits.StatusCacheS) {
			deciderStatusRefresh(d, server, now)
		}
		if !server.statusAt.IsZero() {
			return server.status
		}
	}
	running, players := "", 0
	if other := deciderOther(d, name); other != nil && other.phase == phaseRunning {
		running, players = other.name, serverPlayers(other)
	}
	failed := server.lastStartFailed && server.phase == phaseSleeping
	description := statusTagged(name, statusDescription(server.phase, failed, running, players))
	answer, err := statusBuild(server.status, server.version, server.protocol, description)
	if err != nil {
		d.log.Warn("status", "server", name, "err", err)
	}
	return answer
}

// deciderStatusRefresh asks the backend, which is also how a starting server is seen to be up (R-046g).
func deciderStatusRefresh(d *Decider, server *Server, now time.Time) bool {
	answer, err := d.fetch(d.settings.Backend)
	if err != nil {
		return false
	}
	server.status, server.statusAt = answer, now
	if parsed, err := statusParse(answer); err == nil {
		server.playersOnline = parsed.Players.Online
	}
	if err := statusCacheSave(d.settings.StateDir, server.name, answer); err != nil {
		d.log.Warn("status cache", "server", server.name, "err", err)
	}
	return true
}

// deciderSettingsApply takes a new settings file. A server it no longer declares is kept while it has sessions, and
// the records of the others survive untouched, so a reload closes no connection (R-055b, R-055c).
func deciderSettingsApply(d *Decider, settings Settings) {
	d.settings = settings
	kept := make(map[string]*Server, len(settings.Servers))
	names := make([]string, 0, len(settings.Servers))
	for _, declared := range settings.Servers {
		names = append(names, declared.Name)
		server, known := d.servers[declared.Name]
		if !known {
			kept[declared.Name] = serverCreate(d, declared)
			continue
		}
		server.unit, server.version, server.protocol = declared.Unit, declared.Version, declared.Protocol
		server.modpackEnv, server.removed = declared.ModpackEnv, false
		kept[declared.Name] = server
	}
	for name, server := range d.servers {
		if _, declared := kept[name]; declared || len(server.sessions) == 0 {
			continue
		}
		server.removed = true
		kept[name] = server
	}
	slices.Sort(names)
	d.servers, d.names = kept, names
}

// deciderPrune drops a server a reload removed once its last session has ended (R-055c).
func deciderPrune(d *Decider) {
	for name, server := range d.servers {
		if server.removed && len(server.sessions) == 0 {
			delete(d.servers, name)
		}
	}
}

// deciderAssert holds the decider's invariants after every event. A broken one is a programmer error: it crashes the
// gate, which Restart=always brings back, rather than letting two servers share the guest's memory.
func deciderAssert(d *Decider) {
	active := 0
	for _, server := range deciderServers(d) {
		if server.phase == phaseStarting || server.phase == phaseRunning {
			active++
		}
		if server.phase == phaseStopping && !server.stopIssued {
			panic("decider: stopping without a stop: " + deciderRecords(d))
		}
	}
	if active > 1 {
		panic(fmt.Sprintf("decider: %d servers active: %s", active, deciderRecords(d)))
	}
	if len(d.budget.switches) > d.settings.Limits.SwitchesPerHourMax {
		panic(fmt.Sprintf("decider: %d switches an hour: %s", len(d.budget.switches), deciderRecords(d)))
	}
	for address, source := range d.sources {
		if len(source.starts) > d.settings.Limits.StartsPerSourcePerHourMax {
			panic(fmt.Sprintf("decider: %d starts an hour from %s", len(source.starts), address))
		}
	}
}

// deciderRecords renders every record for a panic line, which is the whole bug report of a broken invariant.
func deciderRecords(d *Decider) string {
	parts := make([]string, 0, len(d.servers))
	for _, server := range deciderServers(d) {
		parts = append(parts, fmt.Sprintf("%s=%s(sessions %d, players %d, failures %d)",
			server.name, server.phase, len(server.sessions), server.playersOnline, server.failures))
	}
	return "[" + fmt.Sprint(parts) + "]"
}

// deciderStateSave writes what a person reads and what prometheus scrapes, on every change (R-056, R-090).
func deciderStateSave(d *Decider) {
	if err := stateSave(d.settings.RuntimeDir, deciderState(d)); err != nil {
		d.log.Warn("state", "err", err)
	}
	deciderMetricsSave(d)
}

// deciderMetricsSave writes what prometheus scrapes, when it differs from what is already there (R-090).
func deciderMetricsSave(d *Decider) {
	rendered := metricsRender(deciderServers(d), d.kicks, d.switchesTotal)
	last, err := metricsSave(d.settings.StateDir, d.metrics, rendered)
	d.metrics = last
	if err != nil {
		d.log.Warn("metrics", "err", err)
	}
}

func deciderState(d *Decider) State {
	state := State{UpdatedAt: d.now().Format(time.RFC3339), SwitchesLastHour: len(d.budget.switches)}
	for _, server := range deciderServers(d) {
		state.Servers = append(state.Servers, StateServer{
			Name: server.name, Phase: string(server.phase), Sessions: len(server.sessions),
			Players: server.playersOnline, ReservedUntil: stateMoment(server.reservedUntil),
			IdleSince: stateMoment(server.idleSince), Failures: server.failures,
		})
	}
	return state
}

// deciderHandle applies one event. It is the only writer of every record, and every event ends with the invariants
// held and the state file written.
func deciderHandle(d *Decider, event deciderEvent) {
	now := d.now()
	reply := deciderReply{}
	switch event.kind {
	case eventLogin:
		reply.decision = deciderDecide(d, now, event.name, event.source)
		logLoginWrite(d.log, event.source, event.player, event.name, reply.decision.Outcome)
	case eventSessionEnd:
		deciderSessionEndRecord(d, now, event.name, event.session)
	case eventStatus:
		reply.status = deciderStatusAnswer(d, now, event.name)
	case eventTick:
		deciderReconcile(d, now)
	case eventReload:
		deciderSettingsApply(d, event.settings)
	case eventSnapshot:
		reply.state = deciderState(d)
	}
	deciderPrune(d)
	deciderAssert(d)
	if event.kind != eventSnapshot {
		deciderStateSave(d)
	}
	if event.reply != nil {
		event.reply <- reply
	}
}

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// deciderSend hands one event to the owner and waits for it, which is what serializes two logins (R-044).
func deciderSend(d *Decider, event deciderEvent) deciderReply {
	event.reply = make(chan deciderReply, 1)
	d.events <- event
	return <-event.reply
}

func deciderLogin(d *Decider, name, player string, source netip.Addr) Decision {
	return deciderSend(d, deciderEvent{kind: eventLogin, name: name, player: player, source: source}).decision
}

func deciderSessionEnd(d *Decider, name string, session uint64) {
	deciderSend(d, deciderEvent{kind: eventSessionEnd, name: name, session: session})
}

func deciderStatus(d *Decider, name string) []byte {
	return deciderSend(d, deciderEvent{kind: eventStatus, name: name}).status
}

func deciderTick(d *Decider) {
	deciderSend(d, deciderEvent{kind: eventTick})
}

func deciderReload(d *Decider, settings Settings) {
	deciderSend(d, deciderEvent{kind: eventReload, settings: settings})
}

func deciderSnapshot(d *Decider) State {
	return deciderSend(d, deciderEvent{kind: eventSnapshot}).state
}
