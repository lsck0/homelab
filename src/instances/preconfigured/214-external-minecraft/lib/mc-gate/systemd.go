package main

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

/*
 * -----------------------------------------------------------------------------
 * CONSTANTS
 * -----------------------------------------------------------------------------
 */

// --no-block returns once the job is queued, so none of these waits on a server's own boot or save
const systemctlTimeout = 10 * time.Second

// the absolute path nixos gives systemctl; a binary found on PATH mid-run is a supply chain problem
const systemctlPath = "/run/current-system/sw/bin/systemctl"

// how a unit's ActiveState reads to the decider (R-046a)
const (
	activityStarted  Activity = "started"
	activityStopping Activity = "stopping"
	activityIdle     Activity = "idle"
)

/*
 * -----------------------------------------------------------------------------
 * TYPES
 * -----------------------------------------------------------------------------
 */

// Activity is a unit's state reduced to what the reconcile rules read.
type Activity string

// UnitState is one unit as `systemctl show` reports it. Job is set while a start or stop job is queued, which is how
// a unit waiting for its conflicting predecessor to save looks: inactive, but with work pending.
type UnitState struct {
	Active string
	Job    bool
}

// Systemd is every call the gate makes to the init system. The real one runs systemctl; a test's fake answers from
// its own units, so the decider's rules are proven without a system bus.
type Systemd interface {
	Show(units []string) (map[string]UnitState, error)
	Start(unit string) error
	Stop(unit string) error
}

// systemdExec is the real implementation: the polkit rule of R-075 lets the gate's user run exactly these verbs.
type systemdExec struct{}

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// activityFromUnit maps an ActiveState to what the decider acts on. An unrecognized state reads as idle, the
// direction that costs a login a restart rather than a relay into nothing.
func activityFromUnit(state UnitState) Activity {
	switch state.Active {
	case "active", "activating", "reloading":
		return activityStarted
	case "deactivating":
		return activityStopping
	}
	return activityIdle
}

func (systemdExec) Show(units []string) (map[string]UnitState, error) {
	if len(units) == 0 {
		return map[string]UnitState{}, nil
	}
	arguments := append([]string{"show", "--property=Id", "--property=ActiveState", "--property=Job"}, units...)
	output, err := systemctlRun(arguments)
	if err != nil {
		return nil, err
	}
	states := make(map[string]UnitState, len(units))
	id, state := "", UnitState{}
	for line := range strings.SplitSeq(output, "\n") {
		key, value, found := strings.Cut(strings.TrimSpace(line), "=")
		if !found {
			if id != "" {
				states[id] = state
			}
			id, state = "", UnitState{}
			continue
		}
		switch key {
		case "Id":
			id = value
		case "ActiveState":
			state.Active = value
		case "Job":
			state.Job = value != ""
		}
	}
	if id != "" {
		states[id] = state
	}
	return states, nil
}

func (systemdExec) Start(unit string) error {
	_, err := systemctlRun([]string{"start", "--no-block", unit})
	return err
}

func (systemdExec) Stop(unit string) error {
	_, err := systemctlRun([]string{"stop", "--no-block", unit})
	return err
}

func systemctlRun(arguments []string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), systemctlTimeout)
	defer cancel()
	command := exec.CommandContext(ctx, systemctlPath, arguments...)
	output, err := command.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("systemctl %s: %w: %s", strings.Join(arguments, " "), err, strings.TrimSpace(string(output)))
	}
	return string(output), nil
}
