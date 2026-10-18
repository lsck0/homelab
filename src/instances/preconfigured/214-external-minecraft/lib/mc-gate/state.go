package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

/*
 * -----------------------------------------------------------------------------
 * CONSTANTS
 * -----------------------------------------------------------------------------
 */

const (
	// the state file is read by mc-state and by a person over ssh
	stateFileName = "state.json"
	stateFileMode = 0o644
	// the status cache and the start marker of one server
	statusFileSuffix  = ".json"
	startedFileSuffix = ".started"
)

/*
 * -----------------------------------------------------------------------------
 * TYPES
 * -----------------------------------------------------------------------------
 */

// State is /run/mc-gate/state.json, the gate's whole view in the shape a person reads.
type State struct {
	UpdatedAt string        `json:"updatedAt"`
	Servers   []StateServer `json:"servers"`
	// how many switches the last hour holds, the global budget seen from outside
	SwitchesLastHour int `json:"switchesLastHour"`
}

// StateServer is one server's line. A moment that has not happened is null rather than a zero time.
type StateServer struct {
	Name          string  `json:"name"`
	Phase         string  `json:"phase"`
	Sessions      int     `json:"sessions"`
	Players       int     `json:"players"`
	ReservedUntil *string `json:"reservedUntil"`
	IdleSince     *string `json:"idleSince"`
	Failures      int     `json:"failures"`
}

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// stateMoment renders a moment for the state file, or nothing when it never happened.
func stateMoment(at time.Time) *string {
	if at.IsZero() {
		return nil
	}
	text := at.Format(time.RFC3339)
	return &text
}

// fileWriteAtomic replaces a file through a temp file beside it, so a reader never sees half a write and a crash
// leaves the old content.
func fileWriteAtomic(path string, data []byte, mode os.FileMode) error {
	temp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	name := temp.Name()
	_, writeErr := temp.Write(data)
	closeErr := temp.Close()
	if err := errors.Join(writeErr, closeErr); err != nil {
		os.Remove(name)
		return err
	}
	if err := os.Chmod(name, mode); err != nil {
		os.Remove(name)
		return err
	}
	if err := os.Rename(name, path); err != nil {
		os.Remove(name)
		return err
	}
	return nil
}

// stateSave writes the state file into the unit's RuntimeDirectory.
func stateSave(runtimeDir string, state State) error {
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return fmt.Errorf("state: %w", err)
	}
	data = append(data, '\n')
	return fileWriteAtomic(filepath.Join(runtimeDir, stateFileName), data, stateFileMode)
}

// statusCacheLoad is a sleeping server's last live status, or nothing when it has never answered one.
func statusCacheLoad(stateDir, name string) []byte {
	data, err := os.ReadFile(filepath.Join(stateDir, name+statusFileSuffix))
	if err != nil {
		return nil
	}
	return data
}

func statusCacheSave(stateDir, name string, data []byte) error {
	return fileWriteAtomic(filepath.Join(stateDir, name+statusFileSuffix), data, stateFileMode)
}

// startedMarkerTouch records a good start, whose mtime tells a first start after a pack change from a later one.
func startedMarkerTouch(stateDir, name string, now time.Time) error {
	path := filepath.Join(stateDir, name+startedFileSuffix)
	if err := fileWriteAtomic(path, nil, stateFileMode); err != nil {
		return err
	}
	return os.Chtimes(path, now, now)
}

// startedMarkerNewer is true when the server has started well since its pack last changed. A missing marker
// or a missing modpack.env is a server that has never started with this pack, which gets the longer timeout.
func startedMarkerNewer(stateDir, name, modpackEnv string) bool {
	started, err := os.Stat(filepath.Join(stateDir, name+startedFileSuffix))
	if err != nil {
		return false
	}
	pack, err := os.Stat(modpackEnv)
	if err != nil {
		return false
	}
	return started.ModTime().After(pack.ModTime())
}
