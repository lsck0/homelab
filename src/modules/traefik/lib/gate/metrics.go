package main

import (
	"fmt"
	"io"
	"slices"
	"sync"
)

const (
	metricVerdicts     = "homelab_gate_verdicts_total"
	metricAnswers      = "homelab_gate_answers_total"
	metricBans         = "homelab_gate_bans_total"
	metricTarpit       = "homelab_gate_tarpit_total"
	metricErrors       = "homelab_gate_errors_total"
	metricTarpitActive = "homelab_gate_tarpit_active"
	metricOnionDecoys  = "homelab_gate_onion_decoys_total"
)

type metricSpec struct {
	name  string
	help  string
	gauge bool
	// the one label's name; "" for none
	label string
}

var metricSpecs = []metricSpec{
	{metricVerdicts, "Requests the gate answered itself or passed, by verdict.", false, "verdict"},
	{metricAnswers, "Captcha answers, by outcome.", false, "outcome"},
	{metricBans, "Distinct crowdsec bans the gate enforced for the first time.", false, ""},
	{metricTarpit, "Labyrinth requests, trickled or refused at the tarpit's bounds.", false, "outcome"},
	{metricErrors, "Failed calls to crowdsec or authelia, by upstream.", false, "upstream"},
	{metricTarpitActive, "Labyrinth answers trickling now.", true, ""},
	{metricOnionDecoys, "Onion captcha answers naming a lookalike address's label: visitors of a phishing copy, by route.", false, "route"},
}

// Metrics are the gate's counters, served in prometheus' text format on its loopback listener, where a timer copies
// them into the node exporter's textfile directory (modules/traefik/gate.nix).
type Metrics struct {
	mu     sync.Mutex
	values map[string]map[string]int64
}

func metricsCreate() *Metrics {
	values := map[string]map[string]int64{}
	for _, spec := range metricSpecs {
		values[spec.name] = map[string]int64{}
	}
	return &Metrics{values: values}
}

func metricsDestroy(_ *Metrics) {}

// metricsAdd moves a series by delta; label is its one label's value, "" for a metric without one.
func metricsAdd(m *Metrics, name, label string, delta int64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	series, declared := m.values[name]
	if !declared {
		panic("metrics: undeclared " + name)
	}
	series[label] += delta
}

func metricsRender(m *Metrics, w io.Writer) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, spec := range metricSpecs {
		kind := "counter"
		if spec.gauge {
			kind = "gauge"
		}
		if _, err := fmt.Fprintf(w, "# HELP %s %s\n# TYPE %s %s\n", spec.name, spec.help, spec.name, kind); err != nil {
			return err
		}
		series := m.values[spec.name]
		if spec.label == "" {
			if _, err := fmt.Fprintf(w, "%s %d\n", spec.name, series[""]); err != nil {
				return err
			}
			continue
		}
		labels := make([]string, 0, len(series))
		for label := range series {
			labels = append(labels, label)
		}
		slices.Sort(labels)
		for _, label := range labels {
			if _, err := fmt.Fprintf(w, "%s{%s=%q} %d\n", spec.name, spec.label, label, series[label]); err != nil {
				return err
			}
		}
	}
	return nil
}
