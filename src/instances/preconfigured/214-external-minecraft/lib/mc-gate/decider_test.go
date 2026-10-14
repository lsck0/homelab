package main

import (
	"encoding/json"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"
)

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// fakeBackend is the one backend port every server shares: it answers while the server behind it is up, and a test
// that is about a start which never answers turns it off.
type fakeBackend struct {
	answering bool
	online    int
	fetches   int
}

func (b *fakeBackend) fetch(string) ([]byte, error) {
	b.fetches++
	if !b.answering {
		return nil, fmt.Errorf("connection refused")
	}
	return fakeStatus(b.online), nil
}

// deciderTestPair is two declared servers, a fake clock and a fake systemd, the ground most rules are read on.
func deciderTestPair(t *testing.T) (*Decider, *fakeSystemd, *fakeClock, Settings) {
	t.Helper()
	d, systemd, clock, settings, _ := deciderTestBackend(t)
	return d, systemd, clock, settings
}

// deciderTestBackend is the same ground, with the backend the test may silence.
func deciderTestBackend(t *testing.T) (*Decider, *fakeSystemd, *fakeClock, Settings, *fakeBackend) {
	t.Helper()
	clock := fakeClockCreate()
	settings := testSettings(t, "alpha", "beta")
	systemd := fakeSystemdCreate(clock, settings.Servers[0].Unit, settings.Servers[1].Unit)
	backend := &fakeBackend{answering: true}
	d, _ := testDecider(t, settings, clock, systemd, backend.fetch)
	return d, systemd, clock, settings, backend
}

// Test_spec001_r045a_phase covers the records being right before the reply leaves: the target is starting and the
// server it replaces is stopping, so the next login decides against the new picture (R-045a).
func Test_spec001_r045a_phase(t *testing.T) {
	d, _, clock, _ := deciderTestPair(t)
	testServerRunning(d, "beta", clock.Now())
	clock.advance(durationFromSeconds(d.settings.Limits.MinimumOnlineS) + time.Second)

	decision := testLogin(d, "alpha", testSource)
	if decision.Outcome != outcomeStarting {
		t.Fatalf("outcome %q, want %q", decision.Outcome, outcomeStarting)
	}
	if d.servers["alpha"].phase != phaseStarting {
		t.Fatalf("alpha is %q, want starting", d.servers["alpha"].phase)
	}
	if d.servers["beta"].phase != phaseStopping {
		t.Fatalf("beta is %q, want stopping", d.servers["beta"].phase)
	}
	// the next login already sees the new picture
	if second := testLogin(d, "beta", testSourceOther); second.Outcome != outcomeStopping {
		t.Fatalf("the second login got %q, want %q", second.Outcome, outcomeStopping)
	}
}

// Test_spec001_r045b_sync covers the commands being run inside the event, stop before start (R-045b).
func Test_spec001_r045b_sync(t *testing.T) {
	d, systemd, clock, settings := deciderTestPair(t)
	testServerRunning(d, "beta", clock.Now())
	clock.advance(durationFromSeconds(d.settings.Limits.MinimumOnlineS) + time.Second)

	testLogin(d, "alpha", testSource)
	want := []string{"stop " + settings.Servers[1].Unit, "start " + settings.Servers[0].Unit}
	if !slices.Equal(systemd.calls, want) {
		t.Fatalf("calls %v, want %v", systemd.calls, want)
	}
}

// Test_spec001_r045c_rollback covers a refused command leaving no trace but a failure: the records are what they
// were, and the login is told so (R-045c).
func Test_spec001_r045c_rollback(t *testing.T) {
	d, systemd, clock, settings := deciderTestPair(t)
	testServerRunning(d, "beta", clock.Now())
	clock.advance(durationFromSeconds(d.settings.Limits.MinimumOnlineS) + time.Second)
	systemd.startErr[settings.Servers[0].Unit] = fmt.Errorf("polkit says no")

	decision := testLogin(d, "alpha", testSource)
	if decision.Outcome != outcomeFailed {
		t.Fatalf("outcome %q, want %q", decision.Outcome, outcomeFailed)
	}
	if d.servers["alpha"].phase != phaseSleeping || d.servers["beta"].phase != phaseRunning {
		t.Fatalf("records are alpha=%q beta=%q, want sleeping and running", d.servers["alpha"].phase, d.servers["beta"].phase)
	}
	if d.servers["alpha"].failures != 1 || !d.servers["alpha"].lastStartFailed {
		t.Fatalf("alpha has %d failures, lastStartFailed %v", d.servers["alpha"].failures, d.servers["alpha"].lastStartFailed)
	}
}

// Test_spec001_r047_occupied covers every way a server holds people, and the one way a young session does not
// (R-047, R-048b).
func Test_spec001_r047_occupied(t *testing.T) {
	cases := []struct {
		name  string
		setup func(d *Decider, now time.Time)
		want  bool
	}{
		{name: "empty", setup: func(*Decider, time.Time) {}, want: false},
		{
			name: "players online", want: true,
			setup: func(d *Decider, _ time.Time) { d.servers["alpha"].playersOnline = 1 },
		},
		{
			name: "old session", want: true,
			setup: func(d *Decider, now time.Time) {
				testSessionAdd(d, "alpha", testSource, now.Add(-2*durationFromSeconds(d.settings.Limits.LoginGraceS)))
				d.sources[testSource].markedLooping = true
			},
		},
		{
			name: "young session from an unmarked source", want: true,
			setup: func(d *Decider, now time.Time) { testSessionAdd(d, "alpha", testSource, now) },
		},
		{
			name: "young session from a marked source", want: false,
			setup: func(d *Decider, now time.Time) {
				testSessionAdd(d, "alpha", testSource, now)
				source := d.sources[testSource]
				source.markedLooping, source.shortSessionEnds = true, []time.Time{now}
			},
		},
		{
			name: "reserved", want: true,
			setup: func(d *Decider, now time.Time) { d.servers["alpha"].reservedUntil = now.Add(time.Minute) },
		},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			d, _, clock, _ := deciderTestPair(t)
			testServerRunning(d, "alpha", clock.Now())
			test.setup(d, clock.Now())
			if got := deciderOccupied(d, d.servers["alpha"], clock.Now()); got != test.want {
				t.Fatalf("occupied = %v, want %v", got, test.want)
			}
		})
	}
}

// Test_spec001_r048a_mark covers a source that reconnects in a loop being marked (R-048a).
func Test_spec001_r048a_mark(t *testing.T) {
	d, _, clock, _ := deciderTestPair(t)
	testServerRunning(d, "alpha", clock.Now())
	limits := d.settings.Limits
	for turn := range limits.LoopShortSessionsMax {
		decision := testLogin(d, "alpha", testSource)
		if decision.Outcome != outcomeRelay {
			t.Fatalf("turn %d: outcome %q, want a relay", turn, decision.Outcome)
		}
		clock.advance(durationFromSeconds(limits.LoginGraceS) / 2)
		testSessionEnd(d, "alpha", decision.Session)
		if turn < limits.LoopShortSessionsMax-1 && deciderSourceLooping(d, testSource, clock.Now()) {
			t.Fatalf("marked after %d short sessions", turn+1)
		}
	}
	if !deciderSourceLooping(d, testSource, clock.Now()) {
		t.Fatalf("not marked after %d short sessions", limits.LoopShortSessionsMax)
	}
}

// Test_spec001_r048b_young covers a marked source's young session not holding a server against everyone else
// (R-048b).
func Test_spec001_r048b_young(t *testing.T) {
	d, _, clock, _ := deciderTestPair(t)
	testServerRunning(d, "alpha", clock.Now())
	testSessionAdd(d, "alpha", testSource, clock.Now())
	source := d.sources[testSource]
	source.markedLooping, source.shortSessionEnds = true, []time.Time{clock.Now()}

	if deciderOccupied(d, d.servers["alpha"], clock.Now()) {
		t.Fatal("a marked source's young session occupies")
	}
	// the same session, once it outlives the grace window, does occupy
	clock.advance(durationFromSeconds(d.settings.Limits.LoginGraceS))
	if !deciderOccupied(d, d.servers["alpha"], clock.Now()) {
		t.Fatal("a session past the grace window does not occupy")
	}
}

// Test_spec001_r048c_clear covers both ways a mark lapses: a real session, and a quiet window (R-048c).
func Test_spec001_r048c_clear(t *testing.T) {
	limits := testSettings(t).Limits
	t.Run("a long session", func(t *testing.T) {
		d, _, clock, _ := deciderTestPair(t)
		testServerRunning(d, "alpha", clock.Now())
		source := deciderSourceGet(d, testSource)
		source.markedLooping, source.shortSessionEnds = true, []time.Time{clock.Now()}

		decision := testLogin(d, "alpha", testSource)
		clock.advance(durationFromSeconds(limits.LoginGraceS) + time.Second)
		testSessionEnd(d, "alpha", decision.Session)
		if deciderSourceLooping(d, testSource, clock.Now()) {
			t.Fatal("the mark survived a session past the grace window")
		}
	})

	t.Run("a quiet window", func(t *testing.T) {
		d, _, clock, _ := deciderTestPair(t)
		source := deciderSourceGet(d, testSource)
		source.markedLooping, source.shortSessionEnds = true, []time.Time{clock.Now()}
		clock.advance(durationFromSeconds(limits.LoopWindowS) + time.Second)
		if deciderSourceLooping(d, testSource, clock.Now()) {
			t.Fatal("the mark survived loopWindowS without a short session")
		}
	})
}

// Test_spec001_r048d_cap covers one address holding at most sessionsPerSourceMax live sessions, the row that comes
// before the table (R-048d).
func Test_spec001_r048d_cap(t *testing.T) {
	d, _, clock, _ := deciderTestPair(t)
	testServerRunning(d, "alpha", clock.Now())
	limits := d.settings.Limits
	sessions := []uint64{}
	for turn := range limits.SessionsPerSourceMax {
		decision := testLogin(d, "alpha", testSource)
		if decision.Outcome != outcomeRelay {
			t.Fatalf("session %d: outcome %q, want a relay", turn, decision.Outcome)
		}
		sessions = append(sessions, decision.Session)
	}
	capped := testLogin(d, "alpha", testSource)
	if capped.Outcome != outcomeCapped || capped.Text != "" {
		t.Fatalf("outcome %q with text %q, want capped and no text", capped.Outcome, capped.Text)
	}
	// another address is not touched by the cap
	if other := testLogin(d, "alpha", testSourceOther); other.Outcome != outcomeRelay {
		t.Fatalf("another source got %q", other.Outcome)
	}
	// and a seat freed is a seat given back
	testSessionEnd(d, "alpha", sessions[0])
	if again := testLogin(d, "alpha", testSource); again.Outcome != outcomeRelay {
		t.Fatalf("after a session ended the source got %q", again.Outcome)
	}
}

// Test_spec001_r048e_exempt covers the house never being capped and never being marked (R-048e).
func Test_spec001_r048e_exempt(t *testing.T) {
	clock := fakeClockCreate()
	settings := testSettings(t, "alpha")
	settings.Allow = SettingsAllow{Cidrs: []string{"203.0.113.0/24"}}
	systemd := fakeSystemdCreate(clock, settings.Servers[0].Unit)
	d, _ := testDecider(t, settings, clock, systemd, nil)
	testServerRunning(d, "alpha", clock.Now())

	for turn := range settings.Limits.SessionsPerSourceMax + 2 {
		decision := testLogin(d, "alpha", testSource)
		if decision.Outcome != outcomeRelay {
			t.Fatalf("session %d: outcome %q, want a relay", turn, decision.Outcome)
		}
		clock.advance(time.Second)
		testSessionEnd(d, "alpha", decision.Session)
	}
	if deciderSourceLooping(d, testSource, clock.Now()) {
		t.Fatal("an exempt source was marked as looping")
	}
}

// Test_spec001_r049_reservation covers the player who was kicked getting the seat back: a start the gate issued
// reserves the server for rejoinS, a unit that came up by itself does not (R-049).
func Test_spec001_r049_reservation(t *testing.T) {
	d, systemd, clock, settings := deciderTestPair(t)
	testLogin(d, "alpha", testSource)
	at := clock.Now()
	testTick(d)
	want := at.Add(durationFromSeconds(settings.Limits.RejoinS))
	if got := d.servers["alpha"].reservedUntil; !got.Equal(want) {
		t.Fatalf("reservedUntil %v, want %v", got, want)
	}
	if !deciderOccupied(d, d.servers["alpha"], clock.Now()) {
		t.Fatal("a reserved server is not occupied")
	}

	// a unit somebody started by hand belongs to nobody, so it reserves nothing
	fakeSystemdSet(systemd, settings.Servers[0].Unit, unitInactive, false)
	testTick(d)
	fakeSystemdSet(systemd, settings.Servers[1].Unit, unitActive, false)
	testTick(d)
	if got := d.servers["beta"].reservedUntil; !got.IsZero() {
		t.Fatalf("a hand-started server reserved until %v", got)
	}
}

// Test_spec001_r050a_idle_since covers idleSince being the latest of the three moments (R-050a).
func Test_spec001_r050a_idle_since(t *testing.T) {
	d, _, clock, _ := deciderTestPair(t)
	server := d.servers["alpha"]
	running := clock.Now()
	testServerRunning(d, "alpha", running)
	if !server.idleSince.Equal(running) {
		t.Fatalf("idleSince %v, want the moment it became running", server.idleSince)
	}

	reserved := running.Add(time.Minute)
	server.reservedUntil = reserved
	serverIdleRefresh(server)
	if !server.idleSince.Equal(reserved) {
		t.Fatalf("idleSince %v, want the reservation %v", server.idleSince, reserved)
	}

	clock.advance(2 * time.Minute)
	session := testSessionAdd(d, "alpha", testSource, clock.Now())
	clock.advance(time.Minute)
	testSessionEnd(d, "alpha", session)
	if !server.idleSince.Equal(clock.Now()) {
		t.Fatalf("idleSince %v, want the session's end %v", server.idleSince, clock.Now())
	}
}

// Test_spec001_r050b_sleep covers a server nobody uses being stopped after sleepAfterS (R-050b).
func Test_spec001_r050b_sleep(t *testing.T) {
	d, systemd, clock, settings := deciderTestPair(t)
	testServerRunning(d, "alpha", clock.Now())
	fakeSystemdSet(systemd, settings.Servers[0].Unit, unitActive, false)

	clock.advance(durationFromSeconds(settings.Limits.SleepAfterS) - time.Second)
	testTick(d)
	if d.servers["alpha"].phase != phaseRunning {
		t.Fatalf("alpha is %q before sleepAfterS", d.servers["alpha"].phase)
	}
	clock.advance(2 * time.Second)
	testTick(d)
	if d.servers["alpha"].phase != phaseStopping {
		t.Fatalf("alpha is %q past sleepAfterS, want stopping", d.servers["alpha"].phase)
	}

	// a server somebody is on is never slept
	d2, systemd2, clock2, settings2 := deciderTestPair(t)
	testServerRunning(d2, "alpha", clock2.Now())
	fakeSystemdSet(systemd2, settings2.Servers[0].Unit, unitActive, false)
	testSessionAdd(d2, "alpha", testSource, clock2.Now())
	clock2.advance(durationFromSeconds(settings2.Limits.SleepAfterS) + time.Second)
	testTick(d2)
	if d2.servers["alpha"].phase != phaseRunning {
		t.Fatalf("an occupied alpha is %q, want running", d2.servers["alpha"].phase)
	}
}

// Test_spec001_r050c_restart covers a gate that was restarted taking over a unit that is up, with the idle clock
// starting now (R-050c).
func Test_spec001_r050c_restart(t *testing.T) {
	clock := fakeClockCreate()
	settings := testSettings(t, "alpha", "beta")
	systemd := fakeSystemdCreate(clock, settings.Servers[0].Unit, settings.Servers[1].Unit)
	fakeSystemdSet(systemd, settings.Servers[0].Unit, unitActive, false)

	d, _ := testDecider(t, settings, clock, systemd, func(string) ([]byte, error) { return fakeStatus(0), nil })
	clock.advance(time.Minute)
	testTick(d)
	server := d.servers["alpha"]
	if server.phase != phaseRunning {
		t.Fatalf("alpha is %q after a restart, want running", server.phase)
	}
	if !server.idleSince.Equal(clock.Now()) {
		t.Fatalf("idleSince %v, want now %v", server.idleSince, clock.Now())
	}
	if !server.reservedUntil.IsZero() {
		t.Fatalf("a server found running reserved until %v", server.reservedUntil)
	}
}

// Test_spec001_r051a_source covers one address causing at most startsPerSourcePerHourMax starts an hour (R-051a).
func Test_spec001_r051a_source(t *testing.T) {
	d, systemd, clock, settings := deciderTestPair(t)
	limits := settings.Limits
	for turn := range limits.StartsPerSourcePerHourMax {
		if decision := testLogin(d, "alpha", testSource); decision.Outcome != outcomeStarting {
			t.Fatalf("start %d: outcome %q", turn, decision.Outcome)
		}
		// the start goes nowhere; the gate gives up on it and the source keeps the cost
		fakeSystemdSet(systemd, settings.Servers[0].Unit, unitInactive, false)
		clock.advance(time.Minute)
		testTick(d)
	}
	if decision := testLogin(d, "alpha", testSource); decision.Outcome != outcomeBudget {
		t.Fatalf("outcome %q past the source's starts, want %q", decision.Outcome, outcomeBudget)
	}
	// another address still has its own budget
	if decision := testLogin(d, "alpha", testSourceOther); decision.Outcome != outcomeStarting {
		t.Fatalf("another source got %q", decision.Outcome)
	}
	// and an hour later the first one does again
	fakeSystemdSet(systemd, settings.Servers[0].Unit, unitInactive, false)
	clock.advance(budgetWindow + time.Minute)
	testTick(d)
	if decision := testLogin(d, "alpha", testSource); decision.Outcome != outcomeStarting {
		t.Fatalf("an hour later the source got %q", decision.Outcome)
	}
}

// Test_spec001_r051b_switches covers the global switch budget: a start from all-asleep is free, one that stops a
// running server is not (R-051b).
func Test_spec001_r051b_switches(t *testing.T) {
	d, _, clock, settings := deciderTestPair(t)
	limits := settings.Limits

	testLogin(d, "alpha", testSource)
	testTick(d)
	if len(d.budget.switches) != 0 {
		t.Fatalf("a start from all-asleep spent %d switches", len(d.budget.switches))
	}

	// every switch comes from its own address, so the source budget never runs out first
	for turn := range limits.SwitchesPerHourMax {
		clock.advance(durationFromSeconds(limits.MinimumOnlineS) + time.Second)
		name := []string{"beta", "alpha"}[turn%2]
		source := netip.AddrFrom4([4]byte{203, 0, 113, byte(20 + turn)})
		if decision := testLogin(d, name, source); decision.Outcome != outcomeStarting {
			t.Fatalf("switch %d: outcome %q", turn, decision.Outcome)
		}
		testTick(d)
	}
	if len(d.budget.switches) != limits.SwitchesPerHourMax {
		t.Fatalf("%d switches spent, want %d", len(d.budget.switches), limits.SwitchesPerHourMax)
	}

	clock.advance(durationFromSeconds(limits.MinimumOnlineS) + time.Second)
	last := netip.AddrFrom4([4]byte{203, 0, 113, 99})
	// the server the loop left asleep, so this login is another switch rather than a relay
	asleep := []string{"beta", "alpha"}[limits.SwitchesPerHourMax%2]
	if decision := testLogin(d, asleep, last); decision.Outcome != outcomeBudget {
		t.Fatalf("outcome %q past the switch budget, want %q", decision.Outcome, outcomeBudget)
	}
}

// Test_spec001_r051c_minimum_online covers a server that just came up being left alone for minimumOnlineS (R-051c).
func Test_spec001_r051c_minimum_online(t *testing.T) {
	d, _, clock, settings := deciderTestPair(t)
	testServerRunning(d, "beta", clock.Now())
	d.servers["beta"].reservedUntil = time.Time{}
	serverIdleRefresh(d.servers["beta"])

	clock.advance(durationFromSeconds(settings.Limits.MinimumOnlineS) - time.Second)
	if decision := testLogin(d, "alpha", testSource); decision.Outcome != outcomeJustStarted {
		t.Fatalf("outcome %q under minimumOnlineS, want %q", decision.Outcome, outcomeJustStarted)
	}
	clock.advance(2 * time.Second)
	if decision := testLogin(d, "alpha", testSource); decision.Outcome != outcomeStarting {
		t.Fatalf("outcome %q past minimumOnlineS, want %q", decision.Outcome, outcomeStarting)
	}
}

// Test_spec001_r052_table covers every row of the decision table, in its order (R-052).
func Test_spec001_r052_table(t *testing.T) {
	cases := []struct {
		name    string
		ask     string
		source  netip.Addr
		setup   func(d *Decider, clock *fakeClock)
		outcome string
		// the phases the records must hold afterwards, for the rows that act
		after map[string]Phase
	}{
		{
			name: "unknown", ask: "gamma", source: testSource, outcome: outcomeUnknown,
			setup: func(*Decider, *fakeClock) {},
		},
		{
			name: "target running, no other", ask: "alpha", source: testSource, outcome: outcomeRelay,
			setup: func(d *Decider, clock *fakeClock) { testServerRunning(d, "alpha", clock.Now()) },
		},
		{
			name: "target starting", ask: "alpha", source: testSource, outcome: outcomeStarting,
			setup: func(d *Decider, clock *fakeClock) {
				d.servers["alpha"].phase, d.servers["alpha"].startedAt = phaseStarting, clock.Now()
			},
		},
		{
			name: "target stopping", ask: "alpha", source: testSource, outcome: outcomeStopping,
			setup: func(d *Decider, _ *fakeClock) {
				d.servers["alpha"].phase, d.servers["alpha"].stopIssued = phaseStopping, true
			},
		},
		{
			name: "other starting", ask: "alpha", source: testSource, outcome: outcomeBusyStarting,
			setup: func(d *Decider, clock *fakeClock) {
				d.servers["beta"].phase, d.servers["beta"].startedAt = phaseStarting, clock.Now()
			},
		},
		{
			name: "other stopping", ask: "alpha", source: testSource, outcome: outcomeStopping,
			setup: func(d *Decider, _ *fakeClock) {
				d.servers["beta"].phase, d.servers["beta"].stopIssued = phaseStopping, true
			},
		},
		{
			name: "other running and occupied", ask: "alpha", source: testSource, outcome: outcomeBusy,
			setup: func(d *Decider, clock *fakeClock) {
				testServerRunning(d, "beta", clock.Now())
				d.servers["beta"].playersOnline = 2
				clock.advance(durationFromSeconds(d.settings.Limits.MinimumOnlineS) + time.Second)
			},
		},
		{
			name: "other just started", ask: "alpha", source: testSource, outcome: outcomeJustStarted,
			setup: func(d *Decider, clock *fakeClock) { testServerRunning(d, "beta", clock.Now()) },
		},
		{
			name: "over a budget", ask: "alpha", source: testSource, outcome: outcomeBudget,
			setup: func(d *Decider, clock *fakeClock) {
				testServerRunning(d, "beta", clock.Now())
				clock.advance(durationFromSeconds(d.settings.Limits.MinimumOnlineS) + time.Second)
				source := deciderSourceGet(d, testSource)
				for range d.settings.Limits.StartsPerSourcePerHourMax {
					source.starts = append(source.starts, clock.Now())
				}
			},
		},
		{
			name: "other running, not occupied", ask: "alpha", source: testSource, outcome: outcomeStarting,
			after: map[string]Phase{"alpha": phaseStarting, "beta": phaseStopping},
			setup: func(d *Decider, clock *fakeClock) {
				testServerRunning(d, "beta", clock.Now())
				clock.advance(durationFromSeconds(d.settings.Limits.MinimumOnlineS) + time.Second)
			},
		},
		{
			name: "all asleep", ask: "alpha", source: testSource, outcome: outcomeStarting,
			after: map[string]Phase{"alpha": phaseStarting, "beta": phaseSleeping},
			setup: func(*Decider, *fakeClock) {},
		},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			d, _, clock, _ := deciderTestPair(t)
			test.setup(d, clock)
			decision := testLogin(d, test.ask, test.source)
			if decision.Outcome != test.outcome {
				t.Fatalf("outcome %q, want %q", decision.Outcome, test.outcome)
			}
			if decision.Outcome != outcomeRelay && decision.Outcome != outcomeCapped && decision.Text == "" {
				t.Fatal("a kick with no text")
			}
			for name, phase := range test.after {
				if got := d.servers[name].phase; got != phase {
					t.Fatalf("%s is %q, want %q", name, got, phase)
				}
			}
		})
	}

	t.Run("capped comes first", func(t *testing.T) {
		d, _, clock, _ := deciderTestPair(t)
		testServerRunning(d, "alpha", clock.Now())
		for range d.settings.Limits.SessionsPerSourceMax {
			testLogin(d, "alpha", testSource)
		}
		// even an unknown name is only closed, because the row before the table comes first
		if decision := testLogin(d, "gamma", testSource); decision.Outcome != outcomeCapped {
			t.Fatalf("outcome %q, want %q", decision.Outcome, outcomeCapped)
		}
	})
}

// Test_spec001_r053a_timeout covers a start that never answers being given up on (R-053a).
func Test_spec001_r053a_timeout(t *testing.T) {
	d, systemd, clock, settings, backend := deciderTestBackend(t)
	// the start goes nowhere, so nothing ever answers on the backend port
	backend.answering = false
	// the server has started well since its pack last changed, so it gets the short timeout
	deciderTestMarkStarted(t, settings, "alpha", clock.Now())

	testLogin(d, "alpha", testSource)
	fakeSystemdSet(systemd, settings.Servers[0].Unit, unitActivating, true)
	clock.advance(durationFromSeconds(settings.Limits.StartTimeoutS) - time.Second)
	testTick(d)
	if d.servers["alpha"].phase != phaseStarting {
		t.Fatalf("alpha is %q before startTimeoutS", d.servers["alpha"].phase)
	}

	clock.advance(2 * time.Second)
	testTick(d)
	server := d.servers["alpha"]
	if server.phase != phaseStopping || server.failures != 1 || !server.lastStartFailed {
		t.Fatalf("alpha is %q with %d failures, lastStartFailed %v", server.phase, server.failures, server.lastStartFailed)
	}

	// the next start clears the flag
	fakeSystemdSet(systemd, settings.Servers[0].Unit, unitInactive, false)
	testTick(d)
	testLogin(d, "alpha", testSourceOther)
	if server.lastStartFailed {
		t.Fatal("a new start kept lastStartFailed")
	}
}

// deciderTestMarkStarted writes the marker of a good start, newer than the server's modpack.env (R-053b).
func deciderTestMarkStarted(t *testing.T, settings Settings, name string, at time.Time) {
	t.Helper()
	declared := settings.Servers[slices.IndexFunc(settings.Servers, func(s SettingsServer) bool { return s.Name == name })]
	if err := os.WriteFile(declared.ModpackEnv, nil, 0o644); err != nil {
		t.Fatalf("write %s: %v", declared.ModpackEnv, err)
	}
	if err := os.Chtimes(declared.ModpackEnv, at.Add(-time.Hour), at.Add(-time.Hour)); err != nil {
		t.Fatalf("chtimes %s: %v", declared.ModpackEnv, err)
	}
	if err := startedMarkerTouch(settings.StateDir, name, at); err != nil {
		t.Fatalf("marker for %s: %v", name, err)
	}
}

// Test_spec001_r053b_first_start covers the longer timeout of a server whose pack changed, which downloads it
// before it answers anything (R-053b).
func Test_spec001_r053b_first_start(t *testing.T) {
	d, systemd, clock, settings, backend := deciderTestBackend(t)
	backend.answering = false
	testLogin(d, "alpha", testSource)
	fakeSystemdSet(systemd, settings.Servers[0].Unit, unitActivating, true)

	// no marker at all: the pack has never started here
	clock.advance(durationFromSeconds(settings.Limits.StartTimeoutS) + time.Minute)
	testTick(d)
	if d.servers["alpha"].phase != phaseStarting {
		t.Fatalf("alpha is %q past startTimeoutS on its first start", d.servers["alpha"].phase)
	}
	clock.advance(durationFromSeconds(settings.Limits.FirstStartTimeoutS))
	testTick(d)
	if d.servers["alpha"].phase != phaseStopping {
		t.Fatalf("alpha is %q past firstStartTimeoutS, want stopping", d.servers["alpha"].phase)
	}

	// with a marker newer than the pack, the short timeout applies again
	deciderTestMarkStarted(t, settings, "beta", clock.Now())
	if deciderStartTimeout(d, d.servers["beta"]) != durationFromSeconds(settings.Limits.StartTimeoutS) {
		t.Fatalf("beta's timeout is %v, want startTimeoutS", deciderStartTimeout(d, d.servers["beta"]))
	}
	if deciderStartTimeout(d, d.servers["alpha"]) != durationFromSeconds(settings.Limits.FirstStartTimeoutS) {
		t.Fatalf("alpha's timeout is %v, want firstStartTimeoutS", deciderStartTimeout(d, d.servers["alpha"]))
	}
}

// Test_spec001_r053c_failed covers what a ping is told about a server whose start failed (R-053c).
func Test_spec001_r053c_failed(t *testing.T) {
	d, _, clock, _ := deciderTestPair(t)
	d.servers["alpha"].lastStartFailed = true
	answer := testEvent(d, deciderEvent{kind: eventStatus, name: "alpha"}).status
	if got := statusTestDescription(t, answer); got != descriptionFailed {
		t.Fatalf("description %q, want %q", got, descriptionFailed)
	}
	// a server that is up again says what it is, not what it was
	testServerRunning(d, "alpha", clock.Now())
	d.servers["alpha"].lastStartFailed = false
	answer = testEvent(d, deciderEvent{kind: eventStatus, name: "beta"}).status
	if got := statusTestDescription(t, answer); got == descriptionFailed {
		t.Fatal("beta is described as failed")
	}
}

// Test_spec001_r054_texts covers every text of the table, rendered from its key (R-054).
func Test_spec001_r054_texts(t *testing.T) {
	servers := []string{"alpha", "beta"}
	cases := []struct {
		outcome string
		server  string
		players int
		want    string
	}{
		{outcome: outcomeStarting, server: "alpha", want: "alpha is starting, rejoin in about a minute"},
		{outcome: outcomeStopping, server: "alpha", want: "alpha is stopping, try again in a minute"},
		{outcome: outcomeBusyStarting, server: "beta", want: "beta is starting for someone, try again later"},
		{outcome: outcomeBusy, server: "beta", players: 3, want: "beta is running with 3 players, try again later"},
		{outcome: outcomeJustStarted, server: "beta", want: "beta just started, try again in a few minutes"},
		{outcome: outcomeBudget, server: "alpha", want: "too many server switches, try again later"},
		{outcome: outcomeFailed, server: "alpha", want: "alpha failed to start, try again later"},
		{outcome: outcomeUnknown, server: "gamma", want: "no server gamma here; servers: alpha, beta"},
	}
	for _, test := range cases {
		t.Run(test.outcome, func(t *testing.T) {
			if got := kickText(test.outcome, test.server, test.players, servers); got != test.want {
				t.Fatalf("kickText = %q, want %q", got, test.want)
			}
		})
	}

	descriptions := []struct {
		name    string
		phase   Phase
		failed  bool
		running string
		players int
		want    string
	}{
		{name: "sleeping", phase: phaseSleeping, want: "sleeping, join to start it"},
		{name: "starting", phase: phaseStarting, want: "starting, rejoin in about a minute"},
		{name: "stopping", phase: phaseStopping, want: "stopping"},
		{name: "another runs", phase: phaseSleeping, running: "beta", players: 2, want: "beta is running with 2 players"},
		{name: "failed", phase: phaseSleeping, failed: true, want: "failed to start, join to try again"},
	}
	for _, test := range descriptions {
		t.Run("description "+test.name, func(t *testing.T) {
			got := statusDescription(test.phase, test.failed, test.running, test.players)
			if got != test.want {
				t.Fatalf("statusDescription = %q, want %q", got, test.want)
			}
		})
	}
	if descriptionUnknown != "no such server" {
		t.Fatalf("the unknown description is %q", descriptionUnknown)
	}
}

// Test_spec001_r056_state covers the state file being written on every change, in the shape a person reads (R-056).
func Test_spec001_r056_state(t *testing.T) {
	d, _, clock, settings := deciderTestPair(t)
	testServerRunning(d, "alpha", clock.Now())
	decision := testLogin(d, "alpha", testSource)

	raw, err := os.ReadFile(filepath.Join(settings.RuntimeDir, stateFileName))
	if err != nil {
		t.Fatalf("read the state file: %v", err)
	}
	var state State
	if err := json.Unmarshal(raw, &state); err != nil {
		t.Fatalf("state %s: %v", raw, err)
	}
	if state.UpdatedAt != clock.Now().Format(time.RFC3339) {
		t.Fatalf("updatedAt %q", state.UpdatedAt)
	}
	if len(state.Servers) != 2 {
		t.Fatalf("%d servers in the state file", len(state.Servers))
	}
	alpha := state.Servers[0]
	if alpha.Name != "alpha" || alpha.Phase != string(phaseRunning) || alpha.Sessions != 1 {
		t.Fatalf("alpha %+v", alpha)
	}
	if alpha.IdleSince == nil || state.Servers[1].ReservedUntil != nil {
		t.Fatalf("moments %+v and %+v", alpha, state.Servers[1])
	}

	// every change is written, so the file never lags behind the records
	clock.advance(time.Minute)
	testSessionEnd(d, "alpha", decision.Session)
	raw, _ = os.ReadFile(filepath.Join(settings.RuntimeDir, stateFileName))
	if err := json.Unmarshal(raw, &state); err != nil {
		t.Fatalf("state %s: %v", raw, err)
	}
	if state.Servers[0].Sessions != 0 || state.UpdatedAt != clock.Now().Format(time.RFC3339) {
		t.Fatalf("after the session ended: %+v at %q", state.Servers[0], state.UpdatedAt)
	}
}

// Test_spec001_r057_log covers one journal line per event, with the fields a person greps for (R-057).
func Test_spec001_r057_log(t *testing.T) {
	clock := fakeClockCreate()
	settings := testSettings(t, "alpha", "beta")
	systemd := fakeSystemdCreate(clock, settings.Servers[0].Unit, settings.Servers[1].Unit)
	backend := &fakeBackend{answering: true}
	d, journal := testDecider(t, settings, clock, systemd, backend.fetch)

	t.Run("login and start", func(t *testing.T) {
		testLogin(d, "alpha", testSource)
		login := testJournalFind(t, journal, logLogin)
		if login == nil || login["source"] != testSource.String() || login["server"] != "alpha" ||
			login["name"] != "player" || login["outcome"] != outcomeStarting {
			t.Fatalf("login line %v", login)
		}
		start := testJournalFind(t, journal, logStart)
		if start == nil || start["server"] != "alpha" || start["reason"] != reasonLogin {
			t.Fatalf("start line %v", start)
		}
	})

	t.Run("reconcile", func(t *testing.T) {
		journal.Reset()
		fakeSystemdSet(systemd, settings.Servers[0].Unit, unitFailed, false)
		testTick(d)
		line := testJournalFind(t, journal, logReconcile)
		if line == nil || line["server"] != "alpha" || line["from"] != string(phaseStarting) ||
			line["to"] != string(phaseSleeping) || line["observed"] != unitFailed {
			t.Fatalf("reconcile line %v", line)
		}
	})

	t.Run("switch names the source", func(t *testing.T) {
		journal.Reset()
		fakeSystemdSet(systemd, settings.Servers[0].Unit, unitInactive, false)
		testServerRunning(d, "beta", clock.Now())
		clock.advance(durationFromSeconds(settings.Limits.MinimumOnlineS) + time.Second)
		testLogin(d, "alpha", testSourceOther)
		stop := testJournalFind(t, journal, logStop)
		if stop == nil || stop["server"] != "beta" || stop["reason"] != reasonSwitch ||
			stop["source"] != testSourceOther.String() {
			t.Fatalf("stop line %v", stop)
		}
	})

	t.Run("start failed", func(t *testing.T) {
		journal.Reset()
		backend.answering = false
		fakeSystemdSet(systemd, settings.Servers[0].Unit, unitActivating, true)
		clock.advance(durationFromSeconds(settings.Limits.FirstStartTimeoutS) + time.Second)
		testTick(d)
		line := testJournalFind(t, journal, logStartFailed)
		if line == nil || line["server"] != "alpha" || line["seconds"] == nil {
			t.Fatalf("start-failed line %v", line)
		}
		stop := testJournalFind(t, journal, logStop)
		if stop == nil || stop["reason"] != reasonTimeout {
			t.Fatalf("stop line %v", stop)
		}
	})
}
