package main

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"
	"time"
)

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// settingsTestJSON renders a settings file, so a case changes one field of a file that is otherwise whole.
func settingsTestJSON(t *testing.T, change func(file map[string]any)) []byte {
	t.Helper()
	file := map[string]any{
		"listen": "0.0.0.0:25565", "suffix": ".mc.lsck0.dev", "backend": "127.0.0.1:25566",
		"stateDir": "/var/lib/mc-gate", "runtimeDir": "/run/mc-gate",
		"servers": []any{map[string]any{
			"name": "cobblemon", "unit": "minecraft-cobblemon.service",
			"version": "1.21.1", "protocol": 767, "modpackEnv": "/var/lib/minecraft/cobblemon/modpack.env",
		}},
		"limits": map[string]any{
			"handshakeTimeoutS": 10, "handshakeBytesMax": 1024, "statusCacheS": 5, "reconcileS": 5,
			"loginGraceS": 60, "loopWindowS": 600, "loopShortSessionsMax": 3, "sessionsPerSourceMax": 4,
			"rejoinS": 180, "sleepAfterS": 1800, "minimumOnlineS": 300,
			"startsPerSourcePerHourMax": 3, "switchesPerHourMax": 6,
			"startTimeoutS": 300, "firstStartTimeoutS": 1200,
		},
		"allow": map[string]any{
			"cidrs": []any{"10.0.0.0/8", "192.168.0.0/16"},
			"hosts": []any{map[string]any{"name": "lsck0.dev", "network": "ip4", "bits": 32}},
		},
	}
	change(file)
	data, err := json.Marshal(file)
	if err != nil {
		t.Fatalf("render the settings: %v", err)
	}
	return data
}

// Test_spec001_r055a_settings covers the settings file of the data model being read whole, and every way a
// generated file could be wrong being refused rather than guessed at (R-055a).
func Test_spec001_r055a_settings(t *testing.T) {
	good := settingsTestJSON(t, func(map[string]any) {})
	settings, err := settingsParse(good)
	if err != nil {
		t.Fatalf("settingsParse: %v", err)
	}
	if settings.Listen != "0.0.0.0:25565" || settings.Suffix != ".mc.lsck0.dev" || settings.Backend != "127.0.0.1:25566" {
		t.Fatalf("settings %+v", settings)
	}
	if len(settings.Servers) != 1 || settings.Servers[0].Name != "cobblemon" {
		t.Fatalf("servers %+v", settings.Servers)
	}
	if *settings.Servers[0].Version != "1.21.1" || *settings.Servers[0].Protocol != 767 {
		t.Fatalf("declared version %+v", settings.Servers[0])
	}
	if settings.Limits.SleepAfterS != 1800 || durationFromSeconds(settings.Limits.RejoinS) != 3*time.Minute {
		t.Fatalf("limits %+v", settings.Limits)
	}
	if len(settings.Allow.Cidrs) != 2 || settings.Allow.Hosts[0].Bits != 32 {
		t.Fatalf("allow %+v", settings.Allow)
	}

	t.Run("a server with no version", func(t *testing.T) {
		data := settingsTestJSON(t, func(file map[string]any) {
			server := file["servers"].([]any)[0].(map[string]any)
			server["version"], server["protocol"] = nil, nil
		})
		parsed, err := settingsParse(data)
		if err != nil {
			t.Fatalf("settingsParse: %v", err)
		}
		if parsed.Servers[0].Version != nil || parsed.Servers[0].Protocol != nil {
			t.Fatalf("server %+v", parsed.Servers[0])
		}
	})

	refusals := []struct {
		name   string
		change func(file map[string]any)
	}{
		{name: "an unknown field", change: func(file map[string]any) { file["lazymc"] = true }},
		{name: "no listen", change: func(file map[string]any) { file["listen"] = "" }},
		{name: "no backend", change: func(file map[string]any) { file["backend"] = "" }},
		{name: "a relative stateDir", change: func(file map[string]any) { file["stateDir"] = "state" }},
		{name: "a suffix with no dot", change: func(file map[string]any) { file["suffix"] = "mc.lsck0.dev" }},
		{name: "no servers", change: func(file map[string]any) { file["servers"] = []any{} }},
		{
			name: "a name that is no label",
			change: func(file map[string]any) {
				file["servers"].([]any)[0].(map[string]any)["name"] = "Cobble.mon"
			},
		},
		{
			name: "two servers of one name",
			change: func(file map[string]any) {
				first := file["servers"].([]any)[0]
				file["servers"] = []any{first, first}
			},
		},
		{
			name: "a unit that is no service",
			change: func(file map[string]any) {
				file["servers"].([]any)[0].(map[string]any)["unit"] = "minecraft-cobblemon"
			},
		},
		{
			name:   "a limit of zero",
			change: func(file map[string]any) { file["limits"].(map[string]any)["sleepAfterS"] = 0 },
		},
		{
			name:   "a cidr that is no prefix",
			change: func(file map[string]any) { file["allow"].(map[string]any)["cidrs"] = []any{"10.0.0.0"} },
		},
		{
			name: "a host of no network",
			change: func(file map[string]any) {
				file["allow"].(map[string]any)["hosts"].([]any)[0].(map[string]any)["network"] = "ip9"
			},
		},
		{
			name: "a host of too many bits",
			change: func(file map[string]any) {
				file["allow"].(map[string]any)["hosts"].([]any)[0].(map[string]any)["bits"] = 64
			},
		},
	}
	for _, test := range refusals {
		t.Run(test.name, func(t *testing.T) {
			if _, err := settingsParse(settingsTestJSON(t, test.change)); err == nil {
				t.Fatal("the settings were taken")
			}
		})
	}

	t.Run("not json", func(t *testing.T) {
		if _, err := settingsParse([]byte("listen = 25565")); err == nil {
			t.Fatal("a file that is not json was taken")
		}
	})
}

// Test_spec001_r055b_reload covers a reload adding a server and changing a limit while the records of the others
// are untouched, which is what keeps a reload from cutting a session (R-055b).
func Test_spec001_r055b_reload(t *testing.T) {
	d, _, clock, settings := deciderTestPair(t)
	testServerRunning(d, "alpha", clock.Now())
	decision := testLogin(d, "alpha", testSource)
	if decision.Outcome != outcomeRelay {
		t.Fatalf("outcome %q, want a relay", decision.Outcome)
	}

	next := settings
	next.Servers = append(slices.Clone(settings.Servers), SettingsServer{
		Name: "gamma", Unit: "minecraft-gamma.service", ModpackEnv: "/var/lib/minecraft/gamma/modpack.env",
	})
	next.Limits.SleepAfterS = 60
	testEvent(d, deciderEvent{kind: eventReload, settings: next})

	if len(d.servers) != 3 || d.servers["gamma"] == nil {
		t.Fatalf("servers after the reload: %v", d.names)
	}
	alpha := d.servers["alpha"]
	if alpha.phase != phaseRunning || len(alpha.sessions) != 1 {
		t.Fatalf("alpha is %q with %d sessions", alpha.phase, len(alpha.sessions))
	}
	if d.settings.Limits.SleepAfterS != 60 {
		t.Fatalf("sleepAfterS is %d after the reload", d.settings.Limits.SleepAfterS)
	}
	// the new server is known to the next login, and the unknown text names it
	if decision := testLogin(d, "gamma", testSourceOther); decision.Outcome == outcomeUnknown {
		t.Fatal("the added server is unknown")
	}
	if !strings.Contains(kickText(outcomeUnknown, "delta", 0, d.names), "gamma") {
		t.Fatalf("the unknown text does not name gamma: %q", kickText(outcomeUnknown, "delta", 0, d.names))
	}
}

// Test_spec001_r055c_keep covers a server a reload dropped being kept until its last session ends (R-055c).
func Test_spec001_r055c_keep(t *testing.T) {
	d, _, clock, settings := deciderTestPair(t)
	testServerRunning(d, "beta", clock.Now())
	decision := testLogin(d, "beta", testSource)

	next := settings
	next.Servers = slices.Clone(settings.Servers[:1])
	testEvent(d, deciderEvent{kind: eventReload, settings: next})

	kept := d.servers["beta"]
	if kept == nil || len(kept.sessions) != 1 {
		t.Fatalf("the dropped server was forgotten with a session on it: %v", d.names)
	}
	if slices.Contains(d.names, "beta") {
		t.Fatalf("a dropped server is still declared: %v", d.names)
	}
	// it is gone from the table, so a login for it is unknown
	if again := testLogin(d, "beta", testSourceOther); again.Outcome != outcomeUnknown {
		t.Fatalf("a login for the dropped server got %q", again.Outcome)
	}

	testSessionEnd(d, "beta", decision.Session)
	if d.servers["beta"] != nil {
		t.Fatal("the dropped server outlived its last session")
	}
}
