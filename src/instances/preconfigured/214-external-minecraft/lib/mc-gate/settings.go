package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"regexp"
	"strings"
	"time"
)

/*
 * -----------------------------------------------------------------------------
 * CONSTANTS
 * -----------------------------------------------------------------------------
 */

// a server's name is one DNS label, because it is one label below the wildcard host *.mc
var settingsNamePattern = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?$`)

// a host's network and the bits an address of it carries
var allowNetworkBits = map[string]int{"ip4": 32, "ip6": 128}

/*
 * -----------------------------------------------------------------------------
 * TYPES
 * -----------------------------------------------------------------------------
 */

// Settings is the gate's one configuration file, rendered from the instance's `servers`; an unknown field is an error.
type Settings struct {
	Listen     string           `json:"listen"`
	Suffix     string           `json:"suffix"`
	Backend    string           `json:"backend"`
	StateDir   string           `json:"stateDir"`
	RuntimeDir string           `json:"runtimeDir"`
	Servers    []SettingsServer `json:"servers"`
	Limits     SettingsLimits   `json:"limits"`
	Allow      SettingsAllow    `json:"allow"`
}

// SettingsServer is one declared server. Version and Protocol answer a status ping for a server that has never
// answered one itself; ModpackEnv is the file whose mtime tells a first start from a later one.
type SettingsServer struct {
	Name       string  `json:"name"`
	Unit       string  `json:"unit"`
	Version    *string `json:"version"`
	Protocol   *int    `json:"protocol"`
	ModpackEnv string  `json:"modpackEnv"`
}

// SettingsLimits are every bound the gate holds, in seconds or in counts, so a test can shorten them without a rebuild.
type SettingsLimits struct {
	HandshakeTimeoutS         int `json:"handshakeTimeoutS"`
	HandshakeBytesMax         int `json:"handshakeBytesMax"`
	StatusCacheS              int `json:"statusCacheS"`
	ReconcileS                int `json:"reconcileS"`
	LoginGraceS               int `json:"loginGraceS"`
	LoopWindowS               int `json:"loopWindowS"`
	LoopShortSessionsMax      int `json:"loopShortSessionsMax"`
	SessionsPerSourceMax      int `json:"sessionsPerSourceMax"`
	RejoinS                   int `json:"rejoinS"`
	SleepAfterS               int `json:"sleepAfterS"`
	MinimumOnlineS            int `json:"minimumOnlineS"`
	StartsPerSourcePerHourMax int `json:"startsPerSourcePerHourMax"`
	SwitchesPerHourMax        int `json:"switchesPerHourMax"`
	StartTimeoutS             int `json:"startTimeoutS"`
	FirstStartTimeoutS        int `json:"firstStartTimeoutS"`
}

// SettingsAllow is who the gate never marks as looping and never caps: networks, and names resolved to the house's
// changing address and prefix. nix feeds it the same values it feeds lab-gate.
type SettingsAllow struct {
	Cidrs []string            `json:"cidrs"`
	Hosts []SettingsAllowHost `json:"hosts"`
}

// SettingsAllowHost is a name whose addresses of one family ("ip4", "ip6") each stand for the prefix of Bits around it.
type SettingsAllowHost struct {
	Name    string `json:"name"`
	Network string `json:"network"`
	Bits    int    `json:"bits"`
}

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// durationFromSeconds turns one of the settings' bounds into a duration.
func durationFromSeconds(value int) time.Duration {
	return time.Duration(value) * time.Second
}

// settingsParse reads the file strictly: every rule a later stage relies on is checked here, once.
func settingsParse(data []byte) (Settings, error) {
	var settings Settings
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&settings); err != nil {
		return Settings{}, fmt.Errorf("settings: %w", err)
	}
	for _, field := range []struct{ name, value string }{{"listen", settings.Listen}, {"backend", settings.Backend}} {
		if _, err := netip.ParseAddrPort(field.value); err != nil {
			return Settings{}, fmt.Errorf("settings: %s: %w", field.name, err)
		}
	}
	if !strings.HasPrefix(settings.Suffix, ".") {
		return Settings{}, fmt.Errorf("settings: suffix %q must start with a dot", settings.Suffix)
	}
	for _, field := range []struct{ name, value string }{{"stateDir", settings.StateDir}, {"runtimeDir", settings.RuntimeDir}} {
		if !strings.HasPrefix(field.value, "/") {
			return Settings{}, fmt.Errorf("settings: %s %q must be an absolute path", field.name, field.value)
		}
	}
	// a gate with no server would listen and refuse everything, which is a misgenerated file, not a lab
	if len(settings.Servers) == 0 {
		return Settings{}, fmt.Errorf("settings: no servers")
	}
	seen := make(map[string]bool, len(settings.Servers))
	for _, server := range settings.Servers {
		if !settingsNamePattern.MatchString(server.Name) {
			return Settings{}, fmt.Errorf("settings: servers: %q is not a dns label", server.Name)
		}
		if seen[server.Name] {
			return Settings{}, fmt.Errorf("settings: servers: %q twice", server.Name)
		}
		seen[server.Name] = true
		if !strings.HasSuffix(server.Unit, ".service") || server.ModpackEnv == "" {
			return Settings{}, fmt.Errorf("settings: servers: %q needs a .service unit and a modpackEnv", server.Name)
		}
	}
	if err := settingsLimitsCheck(settings.Limits); err != nil {
		return Settings{}, err
	}
	for _, cidr := range settings.Allow.Cidrs {
		if _, err := netip.ParsePrefix(cidr); err != nil {
			return Settings{}, fmt.Errorf("settings: allow.cidrs: %w", err)
		}
	}
	for _, host := range settings.Allow.Hosts {
		bitsMax, known := allowNetworkBits[host.Network]
		if host.Name == "" || !known || host.Bits < 1 || host.Bits > bitsMax {
			return Settings{}, fmt.Errorf("settings: allow.hosts: %q needs a name, network ip4 or ip6 and bits within it", host.Name)
		}
	}
	return settings, nil
}

// settingsLimitsCheck rejects a limit no code below could act on, so no decision ever divides by zero or loops forever.
func settingsLimitsCheck(limits SettingsLimits) error {
	for _, field := range []struct {
		name  string
		value int
	}{
		{"handshakeTimeoutS", limits.HandshakeTimeoutS},
		{"handshakeBytesMax", limits.HandshakeBytesMax},
		{"statusCacheS", limits.StatusCacheS},
		{"reconcileS", limits.ReconcileS},
		{"loginGraceS", limits.LoginGraceS},
		{"loopWindowS", limits.LoopWindowS},
		{"loopShortSessionsMax", limits.LoopShortSessionsMax},
		{"sessionsPerSourceMax", limits.SessionsPerSourceMax},
		{"rejoinS", limits.RejoinS},
		{"sleepAfterS", limits.SleepAfterS},
		{"minimumOnlineS", limits.MinimumOnlineS},
		{"startsPerSourcePerHourMax", limits.StartsPerSourcePerHourMax},
		{"switchesPerHourMax", limits.SwitchesPerHourMax},
		{"startTimeoutS", limits.StartTimeoutS},
		{"firstStartTimeoutS", limits.FirstStartTimeoutS},
	} {
		if field.value < 1 {
			return fmt.Errorf("settings: limits: %s must be positive", field.name)
		}
	}
	// the handshake and the login start fit a frame each; below two frames no client could ever be read
	if limits.HandshakeBytesMax < 2*(addressCharsMax+varIntBytesMax) {
		return errors.New("settings: limits: handshakeBytesMax is below one handshake")
	}
	return nil
}
