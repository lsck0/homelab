package main

import (
	"bytes"
	"fmt"
	"maps"
	"path/filepath"
	"slices"
	"strings"
)

/*
 * -----------------------------------------------------------------------------
 * CONSTANTS
 * -----------------------------------------------------------------------------
 */

const (
	// the node exporter reads this file through a link in its textfile dir, so it is world readable
	metricsFileName = "metrics.prom"
	metricsFileMode = 0o644
	// every metric of this gate, in one place: the prefix is the lab's, the subsystem is this guest's
	metricPhase         = "homelab_mc_phase"
	metricSessions      = "homelab_mc_sessions"
	metricPlayers       = "homelab_mc_players"
	metricStarts        = "homelab_mc_starts_total"
	metricStartFailures = "homelab_mc_start_failures_total"
	metricKicks         = "homelab_mc_kicks_total"
	metricSwitches      = "homelab_mc_switches_total"
)

// every phase, so a series that stopped being true is written as 0 rather than left at its last value
var metricPhases = []Phase{phaseSleeping, phaseStarting, phaseRunning, phaseStopping}

/*
 * -----------------------------------------------------------------------------
 * INTERNAL
 * -----------------------------------------------------------------------------
 */

// metricsLabel escapes a label value the way the text exposition format wants it. A server name is a dns label and
// a kick reason is one of texts.go's words, so nothing here can really need it; a counter that lies about its own
// format when something else does would be worse than the two lines it costs.
func metricsLabel(value string) string {
	replacer := strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`)
	return replacer.Replace(value)
}

func metricsLine(out *strings.Builder, name, labels string, value int) {
	if labels == "" {
		fmt.Fprintf(out, "%s %d\n", name, value)
		return
	}
	fmt.Fprintf(out, "%s{%s} %d\n", name, labels, value)
}

func metricsHeader(out *strings.Builder, name, kind, help string) {
	fmt.Fprintf(out, "# HELP %s %s\n# TYPE %s %s\n", name, help, name, kind)
}

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// metricsRender is the gate's whole view in the prometheus text format. It takes the records rather than the
// decider, so a test renders a view it built itself. It carries no timestamp of its own: the node exporter publishes
// node_textfile_mtime_seconds for this file, which is the same answer from the side that scrapes it.
func metricsRender(servers []*Server, kicks map[string]int, switches int) []byte {
	out := &strings.Builder{}

	metricsHeader(out, metricPhase, "gauge", "1 for the phase a Minecraft server is in, 0 for the others")
	for _, server := range servers {
		for _, phase := range metricPhases {
			value := 0
			if server.phase == phase {
				value = 1
			}
			metricsLine(out, metricPhase, fmt.Sprintf("server=%q,phase=%q",
				metricsLabel(server.name), metricsLabel(string(phase))), value)
		}
	}

	metricsHeader(out, metricSessions, "gauge", "logins the gate relays to a Minecraft server right now")
	for _, server := range servers {
		metricsLine(out, metricSessions, fmt.Sprintf("server=%q", metricsLabel(server.name)), len(server.sessions))
	}

	metricsHeader(out, metricPlayers, "gauge", "players a Minecraft server last reported")
	for _, server := range servers {
		metricsLine(out, metricPlayers, fmt.Sprintf("server=%q", metricsLabel(server.name)), serverPlayers(server))
	}

	metricsHeader(out, metricStarts, "counter", "starts the gate issued for a Minecraft server")
	for _, server := range servers {
		metricsLine(out, metricStarts, fmt.Sprintf("server=%q", metricsLabel(server.name)), server.startsTotal)
	}

	metricsHeader(out, metricStartFailures, "counter", "starts of a Minecraft server that never came up")
	for _, server := range servers {
		metricsLine(out, metricStartFailures, fmt.Sprintf("server=%q", metricsLabel(server.name)),
			server.startFailuresTotal)
	}

	metricsHeader(out, metricKicks, "counter", "logins the gate refused, by the reason it gave")
	for _, reason := range slices.Sorted(maps.Keys(kicks)) {
		metricsLine(out, metricKicks, fmt.Sprintf("reason=%q", metricsLabel(reason)), kicks[reason])
	}

	metricsHeader(out, metricSwitches, "counter", "starts that stopped another Minecraft server first")
	metricsLine(out, metricSwitches, "", switches)

	return []byte(out.String())
}

// metricsSave replaces the file the node exporter reads, atomically, so it never scrapes half a write. A
// render equal to the one on disk writes nothing: every status ping of an unauthenticated internet port passes
// through here, and the file, unlike the state in /run, lives on the guest's disk.
func metricsSave(stateDir string, last, data []byte) ([]byte, error) {
	if last != nil && bytes.Equal(last, data) {
		return last, nil
	}
	// a write that failed leaves the old file on disk, so the next identical render must try again
	if err := fileWriteAtomic(filepath.Join(stateDir, metricsFileName), data, metricsFileMode); err != nil {
		return last, err
	}
	return data, nil
}
