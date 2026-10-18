package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"
)

/*
 * -----------------------------------------------------------------------------
 * CONSTANTS
 * -----------------------------------------------------------------------------
 */

// the unit states systemd reports, which the reconciler maps onto the three activities
const (
	unitInactive     = "inactive"
	unitActivating   = "activating"
	unitActive       = "active"
	unitDeactivating = "deactivating"
	unitFailed       = "failed"
)

// what a fake unit is waiting to become
const (
	pendingNone  = ""
	pendingStart = "start"
	pendingStop  = "stop"
)

/*
 * -----------------------------------------------------------------------------
 * TYPES
 * -----------------------------------------------------------------------------
 */

// fakeClock drives every budget, grace window and timeout, so no test ever sleeps.
type fakeClock struct {
	at time.Time
}

func fakeClockCreate() *fakeClock {
	return &fakeClock{at: time.Date(2025, 1, 1, 12, 0, 0, 0, time.UTC)}
}

func (c *fakeClock) Now() time.Time { return c.at }

func (c *fakeClock) advance(by time.Duration) { c.at = c.at.Add(by) }

// fakeUnit is one systemd unit: what it is, what it is waiting to become, and when that completes.
type fakeUnit struct {
	active  string
	job     bool
	pending string
	begun   bool
	dueAt   time.Time
	// the unit ends a start in `failed`, which is how a crashing backend is simulated
	failStart bool
}

// fakeSystemd answers `systemctl show` from its own units and honours what the real units declare: `Conflicts=`
// means a start waits until every other unit is gone, and a transition takes as long as the test says.
type fakeSystemd struct {
	clock      *fakeClock
	units      map[string]*fakeUnit
	startErr   map[string]error
	stopErr    map[string]error
	showErr    error
	calls      []string
	startDelay time.Duration
	stopDelay  time.Duration
}

/*
 * -----------------------------------------------------------------------------
 * LIFETIME
 * -----------------------------------------------------------------------------
 */

func fakeSystemdCreate(clock *fakeClock, units ...string) *fakeSystemd {
	f := &fakeSystemd{
		clock: clock, units: make(map[string]*fakeUnit, len(units)),
		startErr: map[string]error{}, stopErr: map[string]error{},
	}
	for _, unit := range units {
		f.units[unit] = &fakeUnit{active: unitInactive}
	}
	return f
}

/*
 * -----------------------------------------------------------------------------
 * INTERNAL
 * -----------------------------------------------------------------------------
 */

func fakeSystemdNames(f *fakeSystemd) []string {
	names := make([]string, 0, len(f.units))
	for name := range f.units {
		names = append(names, name)
	}
	slices.Sort(names)
	return names
}

// fakeSystemdBusy is the `Conflicts=` rule: a start begins only once nothing else is up or going down.
func fakeSystemdBusy(f *fakeSystemd, exclude string) bool {
	for name, unit := range f.units {
		if name == exclude {
			continue
		}
		if unit.active != unitInactive && unit.active != unitFailed {
			return true
		}
	}
	return false
}

// fakeSystemdAdvance completes whatever the clock has reached and begins whatever may now begin.
func fakeSystemdAdvance(f *fakeSystemd) {
	now := f.clock.Now()
	for _, name := range fakeSystemdNames(f) {
		unit := f.units[name]
		switch unit.pending {
		case pendingStop:
			if !unit.begun {
				if unit.active == unitInactive || unit.active == unitFailed {
					unit.pending, unit.job, unit.begun = pendingNone, false, false
					continue
				}
				unit.active, unit.job, unit.begun, unit.dueAt = unitDeactivating, true, true, now.Add(f.stopDelay)
			}
			if !now.Before(unit.dueAt) {
				unit.active, unit.job, unit.pending, unit.begun = unitInactive, false, pendingNone, false
			}
		case pendingStart:
			if !unit.begun {
				if fakeSystemdBusy(f, name) {
					continue
				}
				unit.active, unit.job, unit.begun, unit.dueAt = unitActivating, true, true, now.Add(f.startDelay)
			}
			if !now.Before(unit.dueAt) {
				result := unitActive
				if unit.failStart {
					result = unitFailed
				}
				unit.active, unit.job, unit.pending, unit.begun = result, false, pendingNone, false
			}
		}
	}
}

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

func (f *fakeSystemd) Show(units []string) (map[string]UnitState, error) {
	if f.showErr != nil {
		return nil, f.showErr
	}
	fakeSystemdAdvance(f)
	states := make(map[string]UnitState, len(units))
	for _, name := range units {
		unit, known := f.units[name]
		if !known {
			continue
		}
		states[name] = UnitState{Active: unit.active, Job: unit.job}
	}
	return states, nil
}

func (f *fakeSystemd) Start(unit string) error {
	f.calls = append(f.calls, "start "+unit)
	if err := f.startErr[unit]; err != nil {
		return err
	}
	for name, other := range f.units {
		// Conflicts= stops whatever is up before the new unit may run
		if name != unit && (other.active == unitActive || other.active == unitActivating) {
			other.pending, other.begun = pendingStop, false
		}
	}
	f.units[unit].pending, f.units[unit].begun = pendingStart, false
	fakeSystemdAdvance(f)
	return nil
}

func (f *fakeSystemd) Stop(unit string) error {
	f.calls = append(f.calls, "stop "+unit)
	if err := f.stopErr[unit]; err != nil {
		return err
	}
	f.units[unit].pending, f.units[unit].begun = pendingStop, false
	fakeSystemdAdvance(f)
	return nil
}

// fakeSystemdSet forces a unit's state, which is how a crash, a hand start and a hand stop enter a test.
func fakeSystemdSet(f *fakeSystemd, unit, active string, job bool) {
	f.units[unit].active, f.units[unit].job = active, job
	f.units[unit].pending, f.units[unit].begun = pendingNone, false
}

// fakeStatus is the backend's answer, with the player count the occupancy rules read.
func fakeStatus(online int) []byte {
	answer, err := json.Marshal(Status{
		Version: StatusVersion{Name: "1.21.1", Protocol: 767},
		Players: StatusPlayers{Max: 20, Online: online},
	})
	if err != nil {
		panic(err)
	}
	return answer
}

// testSettings is the spec's own limits over throwaway directories, so a test changes only what it is about.
func testSettings(t testing.TB, names ...string) Settings {
	t.Helper()
	dir := t.TempDir()
	settings := Settings{
		Listen: "127.0.0.1:0", Suffix: ".mc.lsck0.dev", Backend: "127.0.0.1:25566",
		StateDir: filepath.Join(dir, "state"), RuntimeDir: filepath.Join(dir, "run"),
		Limits: SettingsLimits{
			HandshakeTimeoutS: 10, HandshakeBytesMax: 1024, StatusCacheS: 5, ReconcileS: 5,
			LoginGraceS: 60, LoopWindowS: 600, LoopShortSessionsMax: 3, SessionsPerSourceMax: 4,
			RejoinS: 180, SleepAfterS: 1800, MinimumOnlineS: 300,
			StartsPerSourcePerHourMax: 3, SwitchesPerHourMax: 6,
			StartTimeoutS: 300, FirstStartTimeoutS: 1200,
		},
	}
	for _, directory := range []string{settings.StateDir, settings.RuntimeDir} {
		if err := os.MkdirAll(directory, 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", directory, err)
		}
	}
	for _, name := range names {
		settings.Servers = append(settings.Servers, SettingsServer{
			Name: name, Unit: "minecraft-" + name + ".service",
			ModpackEnv: filepath.Join(dir, name+".env"),
		})
	}
	return settings
}

// testDecider is a decider driven by hand: deciderHandle is called straight, so a test's event order is the
// decider's event order with no goroutine in between. It is never destroyed, because deciderDestroy waits for a
// goroutine a test does not run.
func testDecider(t testing.TB, settings Settings, clock *fakeClock, systemd Systemd, fetch StatusFetch) (*Decider, *bytes.Buffer) {
	t.Helper()
	if fetch == nil {
		fetch = func(string) ([]byte, error) { return nil, fmt.Errorf("no backend") }
	}
	journal := &bytes.Buffer{}
	log := slog.New(slog.NewJSONHandler(journal, nil))
	allow := allowCreateWith(settings.Allow, testLookupNone)
	t.Cleanup(func() { allowDestroy(allow) })
	return deciderCreate(settings, systemd, allow, fetch, log, clock.Now), journal
}

// testEvent applies one event without the decider's goroutine, and returns its reply.
func testEvent(d *Decider, event deciderEvent) deciderReply {
	event.reply = make(chan deciderReply, 1)
	deciderHandle(d, event)
	return <-event.reply
}

func testLogin(d *Decider, name string, source netip.Addr) Decision {
	return testEvent(d, deciderEvent{kind: eventLogin, name: name, player: "player", source: source}).decision
}

func testSessionEnd(d *Decider, name string, session uint64) {
	testEvent(d, deciderEvent{kind: eventSessionEnd, name: name, session: session})
}

// testTick is one reconcile pass, the backend asked between its halves the way deciderTick does.
func testTick(d *Decider) {
	reply := testEvent(d, deciderEvent{kind: eventTick})
	if reply.fetch != "" {
		testEvent(d, deciderFetchEvent(d, reply, eventTickFetched))
	}
}

// testStatus is one ping's answer, the backend asked the way deciderStatus does.
func testStatus(d *Decider, name string) []byte {
	reply := testEvent(d, deciderEvent{kind: eventStatus, name: name})
	if reply.fetch == "" {
		return reply.status
	}
	return testEvent(d, deciderFetchEvent(d, reply, eventStatusFetched)).status
}

// testRun brings a server up the way the gate does: a login starts it, the unit comes up, a tick sees it.
func testRun(t *testing.T, d *Decider, f *fakeSystemd, name string, source netip.Addr) {
	t.Helper()
	if decision := testLogin(d, name, source); decision.Outcome != outcomeStarting {
		t.Fatalf("login for %s: outcome %q, want %q", name, decision.Outcome, outcomeStarting)
	}
	fakeSystemdSet(f, d.servers[name].unit, unitActive, false)
	testTick(d)
	if d.servers[name].phase != phaseRunning {
		t.Fatalf("server %s: phase %q, want %q", name, d.servers[name].phase, phaseRunning)
	}
}

// testServerRunning puts a server up without a start, which is how a table row sets the state it is about.
func testServerRunning(d *Decider, name string, since time.Time) {
	server := d.servers[name]
	server.phase, server.runningSince, server.stopIssued = phaseRunning, since, false
	server.startedAt = time.Time{}
	serverIdleRefresh(server)
}

// testSessionAdd puts one live session on a server, as a relayed login would.
func testSessionAdd(d *Decider, name string, source netip.Addr, since time.Time) uint64 {
	server := d.servers[name]
	d.sessionSeq++
	server.sessions = append(server.sessions, Session{id: d.sessionSeq, source: source, startedAt: since})
	deciderSourceGet(d, source).live++
	return d.sessionSeq
}

// testJournal is every line the decider logged, as decoded objects.
func testJournal(t *testing.T, journal *bytes.Buffer) []map[string]any {
	t.Helper()
	lines := []map[string]any{}
	for _, raw := range bytes.Split(bytes.TrimSpace(journal.Bytes()), []byte("\n")) {
		if len(raw) == 0 {
			continue
		}
		var line map[string]any
		if err := json.Unmarshal(raw, &line); err != nil {
			t.Fatalf("journal line %q: %v", raw, err)
		}
		lines = append(lines, line)
	}
	return lines
}

// testJournalFind is the first line of one event, or nothing.
func testJournalFind(t *testing.T, journal *bytes.Buffer, message string) map[string]any {
	t.Helper()
	for _, line := range testJournal(t, journal) {
		if line["msg"] == message {
			return line
		}
	}
	return nil
}

// testLookupNone is the resolver a test uses when it declares no allow hosts.
func testLookupNone(context.Context, string, string) ([]netip.Addr, error) { return nil, nil }

var testSource = netip.MustParseAddr("203.0.113.7")
var testSourceOther = netip.MustParseAddr("198.51.100.9")
