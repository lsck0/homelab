package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
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

// Test_status_answer covers every answer a ping gets: the gate answers from its own records, a running
// server's live status is cached for statusCacheS, and a name it does not know names no server.
func Test_status_answer(t *testing.T) {
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
			name: "sleeping", ask: "alpha", setup: func() {}, expect: statusTagged("alpha", descriptionSleeping),
		},
		{
			name: "starting", ask: "alpha", expect: statusTagged("alpha", descriptionStarting),
			setup: func() { d.servers["alpha"].phase = phaseStarting },
		},
		{
			name: "stopping", ask: "alpha", expect: statusTagged("alpha", descriptionStopping),
			setup: func() { d.servers["alpha"].phase, d.servers["alpha"].stopIssued = phaseStopping, true },
		},
		{
			name: "failed", ask: "alpha", expect: statusTagged("alpha", descriptionFailed),
			setup: func() {
				d.servers["alpha"].phase, d.servers["alpha"].stopIssued = phaseSleeping, false
				d.servers["alpha"].lastStartFailed = true
			},
		},
		{
			name: "another one runs", ask: "alpha", expect: statusTagged("alpha", fmt.Sprintf(descriptionRunning, "beta", 3)),
			setup: func() {
				d.servers["alpha"].phase, d.servers["alpha"].lastStartFailed = phaseSleeping, false
				d.servers["beta"].phase, d.servers["beta"].playersOnline = phaseRunning, 3
			},
		},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			test.setup()
			answer := testStatus(d, test.ask)
			if got := statusTestDescription(t, answer); got != test.expect {
				t.Fatalf("description %q, want %q", got, test.expect)
			}
		})
	}

	t.Run("running is fetched and cached", func(t *testing.T) {
		d.servers["beta"].statusAt, fetches = time.Time{}, 0
		first := testStatus(d, "beta")
		clock.advance(durationFromSeconds(settings.Limits.StatusCacheS) - time.Second)
		second := testStatus(d, "beta")
		if fetches != 1 {
			t.Fatalf("%d fetches for two pings, want 1", fetches)
		}
		if string(first) != string(second) {
			t.Fatalf("the cached answer changed: %s then %s", first, second)
		}
		clock.advance(2 * time.Second)
		testStatus(d, "beta")
		if fetches != 2 {
			t.Fatalf("%d fetches past statusCacheS, want 2", fetches)
		}
	})
}

// Test_status_fetch_outside covers the decider never asking the backend itself: a stale ping hands the fetch to
// its caller, a second ping meanwhile is answered from the records, and an unchanged answer leaves the cache file alone.
func Test_status_fetch_outside(t *testing.T) {
	d, _, clock, settings, backend := deciderTestBackend(t)
	testServerRunning(d, "beta", clock.Now())
	backend.online = 2

	reply := testEvent(d, deciderEvent{kind: eventStatus, name: "beta"})
	if reply.fetch != "beta" || backend.fetches != 0 {
		t.Fatalf("fetch %q after %d fetches, want beta handed out and none made", reply.fetch, backend.fetches)
	}
	if second := testEvent(d, deciderEvent{kind: eventStatus, name: "beta"}); second.fetch != "" {
		t.Fatal("a second ping asked again while the first fetch was out")
	}
	testEvent(d, deciderFetchEvent(d, reply, eventStatusFetched))
	if d.servers["beta"].playersOnline != 2 {
		t.Fatalf("%d players online, want 2", d.servers["beta"].playersOnline)
	}

	cache := filepath.Join(settings.StateDir, "beta"+statusFileSuffix)
	before, err := os.Stat(cache)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(cache, time.Unix(0, 0), time.Unix(0, 0)); err != nil {
		t.Fatal(err)
	}
	clock.advance(durationFromSeconds(settings.Limits.StatusCacheS) + time.Second)
	testStatus(d, "beta")
	after, err := os.Stat(cache)
	if err != nil {
		t.Fatal(err)
	}
	if !after.ModTime().Equal(time.Unix(0, 0)) || after.Size() != before.Size() {
		t.Fatal("an unchanged answer rewrote the status cache")
	}
}
