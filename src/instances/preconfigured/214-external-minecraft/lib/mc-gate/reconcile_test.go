package main

import (
	"testing"
	"time"
)

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// Test_spec001_r046a_mapping covers the three activities every unit state falls into (R-046a).
func Test_spec001_r046a_mapping(t *testing.T) {
	cases := []struct {
		state UnitState
		want  Activity
	}{
		{state: UnitState{Active: unitActive}, want: activityStarted},
		{state: UnitState{Active: unitActivating}, want: activityStarted},
		{state: UnitState{Active: "reloading"}, want: activityStarted},
		{state: UnitState{Active: unitDeactivating}, want: activityStopping},
		{state: UnitState{Active: unitInactive}, want: activityIdle},
		{state: UnitState{Active: unitFailed}, want: activityIdle},
		{state: UnitState{Active: "", Job: true}, want: activityIdle},
	}
	for _, test := range cases {
		t.Run(test.state.Active, func(t *testing.T) {
			if got := activityFromUnit(test.state); got != test.want {
				t.Fatalf("activityFromUnit(%q) = %q, want %q", test.state.Active, got, test.want)
			}
		})
	}

	t.Run("one call per tick", func(t *testing.T) {
		d, systemd, _, settings := deciderTestPair(t)
		shows := &countingSystemd{Systemd: systemd}
		d.systemd = shows
		testTick(d)
		if shows.shows != 1 {
			t.Fatalf("%d systemctl show calls in one tick, want 1", shows.shows)
		}
		if len(shows.units) != len(settings.Servers) {
			t.Fatalf("%d units asked about, want %d", len(shows.units), len(settings.Servers))
		}
	})
}

// countingSystemd counts what a tick asks systemd, which is the cost of R-046a.
type countingSystemd struct {
	Systemd
	shows int
	units []string
}

func (c *countingSystemd) Show(units []string) (map[string]UnitState, error) {
	c.shows, c.units = c.shows+1, units
	return c.Systemd.Show(units)
}

// Test_spec001_r046b_idle covers a server the gate thinks is up whose unit is gone, which is what a crash looks
// like (R-046b).
func Test_spec001_r046b_idle(t *testing.T) {
	cases := []struct {
		name     string
		active   string
		failures int
		failed   bool
	}{
		{name: "inactive", active: unitInactive, failures: 0, failed: false},
		{name: "failed", active: unitFailed, failures: 1, failed: true},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			d, systemd, clock, settings := deciderTestPair(t)
			testServerRunning(d, "alpha", clock.Now())
			fakeSystemdSet(systemd, settings.Servers[0].Unit, test.active, false)
			testTick(d)
			server := d.servers["alpha"]
			if server.phase != phaseSleeping {
				t.Fatalf("alpha is %q, want sleeping", server.phase)
			}
			if server.failures != test.failures || server.lastStartFailed != test.failed {
				t.Fatalf("%d failures, lastStartFailed %v", server.failures, server.lastStartFailed)
			}
		})
	}

	t.Run("a queued job is left alone", func(t *testing.T) {
		d, systemd, clock, settings := deciderTestPair(t)
		testServerRunning(d, "alpha", clock.Now())
		fakeSystemdSet(systemd, settings.Servers[0].Unit, unitInactive, true)
		testTick(d)
		if d.servers["alpha"].phase != phaseRunning {
			t.Fatalf("alpha is %q while a job is queued, want running", d.servers["alpha"].phase)
		}
	})
}

// Test_spec001_r046c_hand_start covers a unit somebody started by hand being taken over, and everything else being
// stopped the way Conflicts= would (R-046c).
func Test_spec001_r046c_hand_start(t *testing.T) {
	d, systemd, clock, settings, backend := deciderTestBackend(t)
	// the hand-started unit is still booting, so the record stops at starting (R-046g)
	backend.answering = false
	testServerRunning(d, "alpha", clock.Now())
	fakeSystemdSet(systemd, settings.Servers[0].Unit, unitActive, false)
	fakeSystemdSet(systemd, settings.Servers[1].Unit, unitActive, false)

	testTick(d)
	if d.servers["beta"].phase != phaseStarting {
		t.Fatalf("beta is %q after a hand start, want starting", d.servers["beta"].phase)
	}
	if d.servers["alpha"].phase != phaseStopping {
		t.Fatalf("alpha is %q, want stopping", d.servers["alpha"].phase)
	}
}

// Test_spec001_r046d_stopping covers a unit somebody stopped by hand (R-046d).
func Test_spec001_r046d_stopping(t *testing.T) {
	d, systemd, _, settings := deciderTestPair(t)
	fakeSystemdSet(systemd, settings.Servers[0].Unit, unitDeactivating, true)
	testTick(d)
	if d.servers["alpha"].phase != phaseStopping {
		t.Fatalf("alpha is %q, want stopping", d.servers["alpha"].phase)
	}
}

// Test_spec001_r046e_stopped covers a stop that has completed (R-046e).
func Test_spec001_r046e_stopped(t *testing.T) {
	d, systemd, _, settings := deciderTestPair(t)
	d.servers["alpha"].phase, d.servers["alpha"].stopIssued = phaseStopping, true
	fakeSystemdSet(systemd, settings.Servers[0].Unit, unitInactive, false)
	testTick(d)
	if d.servers["alpha"].phase != phaseSleeping {
		t.Fatalf("alpha is %q, want sleeping", d.servers["alpha"].phase)
	}
}

// Test_spec001_r046f_unqueued_stop covers a stop that never took: the unit is up, so the record says so again
// (R-046f).
func Test_spec001_r046f_unqueued_stop(t *testing.T) {
	d, systemd, _, settings := deciderTestPair(t)
	d.servers["alpha"].phase, d.servers["alpha"].stopIssued = phaseStopping, true
	fakeSystemdSet(systemd, settings.Servers[0].Unit, unitActive, false)
	testTick(d)
	if d.servers["alpha"].phase != phaseRunning {
		t.Fatalf("alpha is %q, want running", d.servers["alpha"].phase)
	}
}

// Test_spec001_r046g_running covers a start becoming running the moment its backend answers, and not before
// (R-046g).
func Test_spec001_r046g_running(t *testing.T) {
	d, systemd, clock, settings, backend := deciderTestBackend(t)
	backend.answering = false

	testLogin(d, "alpha", testSource)
	fakeSystemdSet(systemd, settings.Servers[0].Unit, unitActive, false)
	clock.advance(durationFromSeconds(settings.Limits.ReconcileS))
	testTick(d)
	if d.servers["alpha"].phase != phaseStarting {
		t.Fatalf("alpha is %q while its backend is silent, want starting", d.servers["alpha"].phase)
	}

	backend.answering, backend.online = true, 2
	clock.advance(durationFromSeconds(settings.Limits.StatusCacheS) + time.Second)
	testTick(d)
	server := d.servers["alpha"]
	if server.phase != phaseRunning {
		t.Fatalf("alpha is %q once its backend answers, want running", server.phase)
	}
	if server.playersOnline != 2 {
		t.Fatalf("playersOnline %d, want the backend's 2", server.playersOnline)
	}
}

// Test_spec001_r046g_switch_port covers a switch: the new server's start job waits while the old server saves, and
// the old server still answers on the shared backend port. That answer must not make the new server running (R-046g).
func Test_spec001_r046g_switch_port(t *testing.T) {
	d, systemd, clock, settings, backend := deciderTestBackend(t)
	backend.answering = true

	testLogin(d, "alpha", testSource)
	fakeSystemdSet(systemd, settings.Servers[0].Unit, unitInactive, true)
	for range 3 {
		clock.advance(durationFromSeconds(settings.Limits.StatusCacheS) + time.Second)
		testTick(d)
		if d.servers["alpha"].phase != phaseStarting {
			t.Fatalf("alpha is %q while its start job waits and another server answers, want starting",
				d.servers["alpha"].phase)
		}
	}

	fakeSystemdSet(systemd, settings.Servers[0].Unit, unitActive, false)
	clock.advance(durationFromSeconds(settings.Limits.StatusCacheS) + time.Second)
	testTick(d)
	if d.servers["alpha"].phase != phaseRunning {
		t.Fatalf("alpha is %q once its unit is active and the port answers, want running", d.servers["alpha"].phase)
	}
}
