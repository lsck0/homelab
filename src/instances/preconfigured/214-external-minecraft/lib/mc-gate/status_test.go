package main

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"
)

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// statusTestDescription is what a client shows for an answer, which is the one field every case here is about.
func statusTestDescription(t *testing.T, answer []byte) string {
	t.Helper()
	var decoded struct {
		Description struct {
			Text string `json:"text"`
		} `json:"description"`
	}
	if err := json.Unmarshal(answer, &decoded); err != nil {
		t.Fatalf("status %s: %v", answer, err)
	}
	return decoded.Description.Text
}

// Test_spec001_r042_status covers every answer a ping gets: the gate answers from its own records, a running
// server's live status is cached for statusCacheS, and a name it does not know names no server (R-042, R-053c).
func Test_spec001_r042_status(t *testing.T) {
	t.Run("round trip", func(t *testing.T) {
		version, protocol := "1.21.1", 767
		answer, err := statusBuild(fakeStatus(7), &version, &protocol, descriptionSleeping)
		if err != nil {
			t.Fatalf("statusBuild: %v", err)
		}
		status, err := statusParse(answer)
		if err != nil {
			t.Fatalf("statusParse: %v", err)
		}
		// the cache gives the version and the maximum; nobody is online on a server that is not running
		if status.Version.Name != "1.21.1" || status.Version.Protocol != 767 {
			t.Fatalf("version %+v", status.Version)
		}
		if status.Players.Online != 0 || status.Players.Max != 20 || len(status.Players.Sample) != 0 {
			t.Fatalf("players %+v", status.Players)
		}
		if got := statusTestDescription(t, answer); got != descriptionSleeping {
			t.Fatalf("description %q", got)
		}
	})

	t.Run("no cache", func(t *testing.T) {
		answer, err := statusBuild(nil, nil, nil, descriptionSleeping)
		if err != nil {
			t.Fatalf("statusBuild: %v", err)
		}
		status, _ := statusParse(answer)
		if status.Version.Name != statusVersionUnknown || status.Version.Protocol != statusProtocolUnknown {
			t.Fatalf("version %+v, want the unknown one", status.Version)
		}
	})

	clock := fakeClockCreate()
	settings := testSettings(t, "alpha", "beta")
	systemd := fakeSystemdCreate(clock, settings.Servers[0].Unit, settings.Servers[1].Unit)
	fetches := 0
	fetch := func(string) ([]byte, error) {
		fetches++
		return fakeStatus(3), nil
	}
	d, _ := testDecider(t, settings, clock, systemd, fetch)

	cases := []struct {
		name   string
		ask    string
		setup  func()
		expect string
	}{
		{
			name: "unknown name", ask: "gamma", setup: func() {}, expect: descriptionUnknown,
		},
		{
			name: "sleeping", ask: "alpha", setup: func() {}, expect: descriptionSleeping,
		},
		{
			name: "starting", ask: "alpha", expect: descriptionStarting,
			setup: func() { d.servers["alpha"].phase = phaseStarting },
		},
		{
			name: "stopping", ask: "alpha", expect: descriptionStopping,
			setup: func() { d.servers["alpha"].phase, d.servers["alpha"].stopIssued = phaseStopping, true },
		},
		{
			name: "failed", ask: "alpha", expect: descriptionFailed,
			setup: func() {
				d.servers["alpha"].phase, d.servers["alpha"].stopIssued = phaseSleeping, false
				d.servers["alpha"].lastStartFailed = true
			},
		},
		{
			name: "another one runs", ask: "alpha", expect: fmt.Sprintf(descriptionRunning, "beta", 3),
			setup: func() {
				d.servers["alpha"].phase, d.servers["alpha"].lastStartFailed = phaseSleeping, false
				d.servers["beta"].phase, d.servers["beta"].playersOnline = phaseRunning, 3
			},
		},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			test.setup()
			answer := testEvent(d, deciderEvent{kind: eventStatus, name: test.ask}).status
			if got := statusTestDescription(t, answer); got != test.expect {
				t.Fatalf("description %q, want %q", got, test.expect)
			}
		})
	}

	t.Run("running is fetched and cached", func(t *testing.T) {
		d.servers["beta"].statusAt, fetches = time.Time{}, 0
		first := testEvent(d, deciderEvent{kind: eventStatus, name: "beta"}).status
		clock.advance(durationFromSeconds(settings.Limits.StatusCacheS) - time.Second)
		second := testEvent(d, deciderEvent{kind: eventStatus, name: "beta"}).status
		if fetches != 1 {
			t.Fatalf("%d fetches for two pings, want 1", fetches)
		}
		if string(first) != string(second) {
			t.Fatalf("the cached answer changed: %s then %s", first, second)
		}
		clock.advance(2 * time.Second)
		testEvent(d, deciderEvent{kind: eventStatus, name: "beta"})
		if fetches != 2 {
			t.Fatalf("%d fetches past statusCacheS, want 2", fetches)
		}
	})
}
