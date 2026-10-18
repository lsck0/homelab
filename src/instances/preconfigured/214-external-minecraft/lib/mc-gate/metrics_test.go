package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// metricsTestValue is one sample of the rendered file, or "" when the file holds no such series. It parses the
// exposition format the way the node exporter does, so a sample this test finds is one prometheus finds.
func metricsTestValue(t *testing.T, rendered []byte, series string) string {
	t.Helper()
	for _, line := range strings.Split(string(rendered), "\n") {
		if strings.HasPrefix(line, "#") {
			continue
		}
		name, value, found := strings.Cut(line, " ")
		if found && name == series {
			return value
		}
	}
	return ""
}

// Test_metrics_render covers the file prometheus scrapes: every metric the gate exports is rendered, a phase that is
// not the current one is written as 0 rather than left out, the file is written atomically at 0644, and a view that
// did not change is not written again.
func Test_metrics_render(t *testing.T) {
	servers := []*Server{
		{
			name: "cobblemon", phase: phaseRunning, playersOnline: 3,
			sessions:    []Session{{id: 1}, {id: 2}},
			startsTotal: 4, startFailuresTotal: 1,
		},
		{name: "atm10", phase: phaseSleeping},
	}
	kicks := map[string]int{outcomeStarting: 5, outcomeBusy: 2}

	t.Run("every metric", func(t *testing.T) {
		rendered := metricsRender(servers, kicks, 7)
		for series, want := range map[string]string{
			`homelab_mc_phase{server="cobblemon",phase="running"}`:  "1",
			`homelab_mc_phase{server="cobblemon",phase="sleeping"}`: "0",
			`homelab_mc_phase{server="atm10",phase="sleeping"}`:     "1",
			`homelab_mc_sessions{server="cobblemon"}`:               "2",
			// the backend counted three, which is more than the gate relays right now
			`homelab_mc_players{server="cobblemon"}`:              "3",
			`homelab_mc_players{server="atm10"}`:                  "0",
			`homelab_mc_starts_total{server="cobblemon"}`:         "4",
			`homelab_mc_start_failures_total{server="cobblemon"}`: "1",
			`homelab_mc_start_failures_total{server="atm10"}`:     "0",
			`homelab_mc_kicks_total{reason="starting"}`:           "5",
			`homelab_mc_kicks_total{reason="busy"}`:               "2",
			"homelab_mc_switches_total":                           "7",
		} {
			if got := metricsTestValue(t, rendered, series); got != want {
				t.Fatalf("%s is %q, want %q", series, got, want)
			}
		}
	})

	t.Run("types", func(t *testing.T) {
		rendered := string(metricsRender(servers, kicks, 7))
		for _, want := range []string{
			"# TYPE homelab_mc_phase gauge", "# TYPE homelab_mc_sessions gauge", "# TYPE homelab_mc_players gauge",
			"# TYPE homelab_mc_starts_total counter", "# TYPE homelab_mc_start_failures_total counter",
			"# TYPE homelab_mc_kicks_total counter", "# TYPE homelab_mc_switches_total counter",
		} {
			if !strings.Contains(rendered, want) {
				t.Fatalf("%q is missing from\n%s", want, rendered)
			}
		}
	})

	t.Run("atomic", func(t *testing.T) {
		dir := t.TempDir()
		last, err := metricsSave(dir, nil, metricsRender(servers, kicks, 7))
		if err != nil {
			t.Fatalf("metricsSave: %v", err)
		}
		path := filepath.Join(dir, metricsFileName)
		info, err := os.Stat(path)
		if err != nil {
			t.Fatalf("stat: %v", err)
		}
		// the node exporter runs as its own user and reads the file through a link
		if info.Mode().Perm() != metricsFileMode {
			t.Fatalf("mode %v", info.Mode().Perm())
		}
		// a second write leaves one file, not the temp one beside it
		if last, err = metricsSave(dir, last, metricsRender(servers, kicks, 8)); err != nil {
			t.Fatalf("metricsSave: %v", err)
		}
		entries, err := os.ReadDir(dir)
		if err != nil {
			t.Fatalf("readdir: %v", err)
		}
		if len(entries) != 1 || entries[0].Name() != metricsFileName {
			t.Fatalf("the dir holds %v", entries)
		}
		// an unchanged view writes nothing: a status ping of the public port must not touch the disk
		before, err := os.Stat(path)
		if err != nil {
			t.Fatalf("stat: %v", err)
		}
		if err := os.Chtimes(path, before.ModTime().Add(-time.Hour), before.ModTime().Add(-time.Hour)); err != nil {
			t.Fatalf("chtimes: %v", err)
		}
		if _, err := metricsSave(dir, last, metricsRender(servers, kicks, 8)); err != nil {
			t.Fatalf("metricsSave: %v", err)
		}
		after, err := os.Stat(path)
		if err != nil {
			t.Fatalf("stat: %v", err)
		}
		if !after.ModTime().Equal(before.ModTime().Add(-time.Hour)) {
			t.Fatalf("an unchanged view was written again at %v", after.ModTime())
		}
	})
}
