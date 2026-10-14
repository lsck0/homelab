package main

import (
	"bytes"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"net/netip"
	"strings"
	"testing"
	"time"
)

/*
 * -----------------------------------------------------------------------------
 * CONSTANTS
 * -----------------------------------------------------------------------------
 */

// the simulation's size: enough seeds for a rare order to show up, few enough steps for the whole suite to stay fast
const (
	simSeeds = 1000
	simSteps = 30
)

// what one step does, drawn by weight
const (
	simLogin = iota
	simForged
	simLeave
	simTick
	simCrash
	simHandStart
	simRefuse
	simRestart
	simKinds
)

/*
 * -----------------------------------------------------------------------------
 * TYPES
 * -----------------------------------------------------------------------------
 */

// simWorld is one seed's lab: the records, the units, the clock and the trace that explains a failure.
type simWorld struct {
	t        *testing.T
	seed     uint64
	rng      *rand.Rand
	clock    *fakeClock
	systemd  *fakeSystemd
	settings Settings
	journal  *bytes.Buffer
	decider  *Decider
	trace    []string
	// the addresses a login comes from; the first is inside the allow cidr, so it is exempt
	sources []netip.Addr
}

/*
 * -----------------------------------------------------------------------------
 * INTERNAL
 * -----------------------------------------------------------------------------
 */

// simCreate builds one seed's world. Every delay is drawn from the seed, so a failing order replays exactly.
func simCreate(t *testing.T, seed uint64) *simWorld {
	t.Helper()
	rng := rand.New(rand.NewPCG(seed, 0x9e3779b97f4a7c15))
	settings := testSettings(t, "alpha", "beta", "gamma")
	settings.Allow = SettingsAllow{Cidrs: []string{"10.9.0.0/16"}}
	clock := fakeClockCreate()
	units := []string{}
	for _, server := range settings.Servers {
		units = append(units, server.Unit)
	}
	world := &simWorld{
		t: t, seed: seed, rng: rng, clock: clock, settings: settings,
		systemd: fakeSystemdCreate(clock, units...), journal: &bytes.Buffer{},
		sources: []netip.Addr{
			netip.MustParseAddr("10.9.0.4"),
			netip.MustParseAddr("203.0.113.1"),
			netip.MustParseAddr("203.0.113.2"),
			netip.MustParseAddr("198.51.100.1"),
		},
	}
	world.systemd.startDelay = time.Duration(rng.IntN(60)) * time.Second
	world.systemd.stopDelay = time.Duration(rng.IntN(30)) * time.Second
	simGateCreate(world)
	return world
}

// simGateCreate is the gate starting, which is also what a restart does: new records, the same units underneath.
func simGateCreate(world *simWorld) {
	log := slog.New(slog.NewJSONHandler(world.journal, nil))
	allow := allowCreateWith(world.settings.Allow, testLookupNone)
	fetch := func(string) ([]byte, error) {
		name := simBackendServer(world)
		if name == "" {
			return nil, fmt.Errorf("connection refused")
		}
		return fakeStatus(simRealPlayers(world, name)), nil
	}
	world.decider = deciderCreate(world.settings, world.systemd, allow, fetch, log, world.clock.Now)
}

// simBackendServer is the server whose backend is answering: the one unit that is fully up.
func simBackendServer(world *simWorld) string {
	for _, declared := range world.settings.Servers {
		if world.systemd.units[declared.Unit].active == unitActive {
			return declared.Name
		}
	}
	return ""
}

// simRealPlayers is what a backend would count: the sessions that outlived the grace window. A reconnect loop is
// never counted, so it can never hold a server up on its own.
func simRealPlayers(world *simWorld, name string) int {
	server, known := world.decider.servers[name]
	if !known {
		return 0
	}
	grace := durationFromSeconds(world.settings.Limits.LoginGraceS)
	players := 0
	for _, session := range server.sessions {
		if world.clock.Now().Sub(session.startedAt) >= grace {
			players++
		}
	}
	return players
}

// simServerName is one declared server, drawn by the seed; one name in ten is not declared at all.
func simServerName(world *simWorld) string {
	if world.rng.IntN(10) == 0 {
		return "delta"
	}
	return world.settings.Servers[world.rng.IntN(len(world.settings.Servers))].Name
}

// simLiveSession is one live session, or nothing.
func simLiveSession(world *simWorld) (string, uint64) {
	for _, server := range deciderServers(world.decider) {
		if len(server.sessions) > 0 {
			return server.name, server.sessions[world.rng.IntN(len(server.sessions))].id
		}
	}
	return "", 0
}

// simSessions is true while anybody is on any server, which is when an operator's hand start is not simulated: a
// hand start makes the gate exclude every other unit, and that stop is not one R-047 covers.
func simSessions(world *simWorld) bool {
	for _, server := range world.decider.servers {
		if len(server.sessions) > 0 {
			return true
		}
	}
	return false
}

// simOccupiedBySession is the invariant's own reading of R-047: a session past the grace window, or one from a
// source that is not marked as looping.
func simOccupiedBySession(world *simWorld, server *Server) bool {
	now := world.clock.Now()
	grace := durationFromSeconds(world.settings.Limits.LoginGraceS)
	for _, session := range server.sessions {
		if now.Sub(session.startedAt) >= grace || !deciderSourceLooping(world.decider, session.source, now) {
			return true
		}
	}
	return false
}

// simStep applies one event and returns what it was, for the trace.
func simStep(world *simWorld) string {
	rng := world.rng
	switch simDraw(rng) {
	case simLogin:
		name, source := simServerName(world), world.sources[rng.IntN(len(world.sources))]
		decision := testLogin(world.decider, name, source)
		simAssertLogin(world, name, decision)
		return fmt.Sprintf("login %s from %s: %s", name, source, decision.Outcome)
	case simForged:
		// a forged login comes from a fresh address and leaves at once, which is what a reconnect loop looks like
		source := netip.AddrFrom4([4]byte{198, 51, 100, byte(rng.IntN(255))})
		name := simServerName(world)
		decision := testLogin(world.decider, name, source)
		simAssertLogin(world, name, decision)
		if decision.Outcome == outcomeRelay {
			testSessionEnd(world.decider, name, decision.Session)
		}
		return fmt.Sprintf("forged login %s from %s: %s", name, source, decision.Outcome)
	case simLeave:
		name, session := simLiveSession(world)
		if name == "" {
			return "nobody to leave"
		}
		testSessionEnd(world.decider, name, session)
		return fmt.Sprintf("leave %s session %d", name, session)
	case simCrash:
		for _, declared := range world.settings.Servers {
			if world.systemd.units[declared.Unit].active == unitActive {
				fakeSystemdSet(world.systemd, declared.Unit, unitFailed, false)
				return "crash " + declared.Name
			}
		}
		return "nothing to crash"
	case simHandStart:
		if simSessions(world) {
			return "no hand start while anybody plays"
		}
		declared := world.settings.Servers[rng.IntN(len(world.settings.Servers))]
		world.systemd.Start(declared.Unit)
		// the gate sees the hand start at its next reconcile; the sim runs that one here, while nobody plays, so
		// the exclusion R-046c and R-046f ask for can never be mistaken for a stop of an occupied server
		testTick(world.decider)
		return "hand start " + declared.Name
	case simRefuse:
		declared := world.settings.Servers[rng.IntN(len(world.settings.Servers))]
		if world.systemd.startErr[declared.Unit] != nil {
			delete(world.systemd.startErr, declared.Unit)
			delete(world.systemd.stopErr, declared.Unit)
			return "allow " + declared.Name
		}
		world.systemd.startErr[declared.Unit] = fmt.Errorf("refused by polkit")
		return "refuse " + declared.Name
	case simRestart:
		simGateCreate(world)
		testTick(world.decider)
		return "gate restart"
	default:
		testTick(world.decider)
		return "tick"
	}
}

// simDraw picks what happens, weighted so that most steps are the traffic the gate exists for.
func simDraw(rng *rand.Rand) int {
	weights := [simKinds]int{simLogin: 30, simForged: 15, simLeave: 20, simTick: 22, simCrash: 5, simHandStart: 3, simRefuse: 3, simRestart: 2}
	total := 0
	for _, weight := range weights {
		total += weight
	}
	draw := rng.IntN(total)
	for kind, weight := range weights {
		if draw < weight {
			return kind
		}
		draw -= weight
	}
	return simTick
}

// simAssertLogin holds the fourth and the fifth invariant: one outcome per login, and the records set before the
// reply that announces them (R-044, R-045a).
func simAssertLogin(world *simWorld, name string, decision Decision) {
	outcomes := []string{outcomeRelay, outcomeCapped, outcomeUnknown, outcomeStarting, outcomeStopping,
		outcomeBusyStarting, outcomeBusy, outcomeJustStarted, outcomeBudget, outcomeFailed}
	found := 0
	for _, outcome := range outcomes {
		if decision.Outcome == outcome {
			found++
		}
	}
	if found != 1 {
		simFail(world, fmt.Sprintf("login for %s got outcome %q", name, decision.Outcome))
	}
	server, declared := world.decider.servers[name]
	switch decision.Outcome {
	case outcomeRelay:
		if !declared || server.phase != phaseRunning || decision.Backend == "" {
			simFail(world, fmt.Sprintf("relay for %s, which is not running", name))
		}
	case outcomeStarting:
		// the reply only ever announces a phase the records already hold
		if declared && server.phase != phaseStarting {
			simFail(world, fmt.Sprintf("%s was told starting while the record is %q", name, server.phase))
		}
	case outcomeCapped:
		if decision.Text != "" {
			simFail(world, "a capped login carries a text")
		}
	default:
		if decision.Text == "" {
			simFail(world, "a kick with no text: "+decision.Outcome)
		}
	}
}

// simAssert holds the invariants that must be true between any two events.
func simAssert(world *simWorld, occupied map[string]bool) {
	active := 0
	for _, declared := range world.settings.Servers {
		unit := world.systemd.units[declared.Unit]
		if unit.active == unitActive || unit.active == unitActivating {
			active++
		}
	}
	if active > 1 {
		simFail(world, fmt.Sprintf("%d units are up at once", active))
	}

	limits := world.settings.Limits
	if len(world.decider.budget.switches) > limits.SwitchesPerHourMax {
		simFail(world, fmt.Sprintf("%d switches in an hour", len(world.decider.budget.switches)))
	}
	for address, source := range world.decider.sources {
		if len(source.starts) > limits.StartsPerSourcePerHourMax {
			simFail(world, fmt.Sprintf("%d starts in an hour from %s", len(source.starts), address))
		}
	}

	// every stop the gate decided on, against who was on that server when it decided
	for _, line := range testJournal(world.t, world.journal) {
		if line["msg"] != logStop {
			continue
		}
		reason, _ := line["reason"].(string)
		if reason != reasonSwitch && reason != reasonIdle {
			continue
		}
		name, _ := line["server"].(string)
		if occupied[name] {
			simFail(world, fmt.Sprintf("%s was stopped (%s) while it was occupied", name, reason))
		}
	}
}

// simFail prints the seed, the whole event trace and the records, which is the entire bug report.
func simFail(world *simWorld, message string) {
	world.t.Fatalf("seed %d: %s\ntrace:\n  %s\nrecords: %s\njournal:\n%s",
		world.seed, message, strings.Join(world.trace, "\n  "), deciderRecords(world.decider), world.journal.String())
}

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// Test_spec001_r044_sim drives the whole decider over a thousand seeded histories of real and forged logins,
// leaves, crashes, slow starts and stops, gate restarts, hand-started units and refused commands, and holds the
// five invariants after every single step. Time is the fake clock, so a day of lab traffic costs no wall time
// (R-044, R-045a, R-047, R-051a, R-051b, R-072).
func Test_spec001_r044_sim(t *testing.T) {
	for seed := range uint64(simSeeds) {
		world := simCreate(t, seed)
		for step := range simSteps {
			// time moves between events, which is what makes a grace window, a budget and a timeout pass
			world.clock.advance(time.Duration(world.rng.IntN(400)) * time.Second)
			occupied := map[string]bool{}
			for _, server := range deciderServers(world.decider) {
				occupied[server.name] = simOccupiedBySession(world, server)
			}
			world.journal.Reset()
			what := simStep(world)
			world.trace = append(world.trace, fmt.Sprintf("%2d %s: %s", step, world.clock.Now().Format(time.TimeOnly), what))
			simAssert(world, occupied)
		}
	}
}
