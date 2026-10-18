package main

import (
	"slices"
	"time"
)

/*
 * -----------------------------------------------------------------------------
 * CONSTANTS
 * -----------------------------------------------------------------------------
 */

// both budgets, per source and global, are counted per hour
const budgetWindow = time.Hour

/*
 * -----------------------------------------------------------------------------
 * TYPES
 * -----------------------------------------------------------------------------
 */

// Source is one client address's history. A forged login costs its source a start of its budget, and a reconnect loop
// marks it, so its young sessions stop holding a server against everyone else.
type Source struct {
	shortSessionEnds []time.Time
	markedLooping    bool
	starts           []time.Time
	live             int
}

// Budget is the one global switch counter, so forged traffic can never lock real players out of a lab
// where every server sleeps.
type Budget struct {
	switches []time.Time
}

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// timesPrune drops every moment older than window, which is how both budgets and the loop window are kept.
func timesPrune(times []time.Time, now time.Time, window time.Duration) []time.Time {
	cut := now.Add(-window)
	return slices.DeleteFunc(times, func(at time.Time) bool { return !at.After(cut) })
}

// sourcePrune ages a source out. A mark lapses with the last short session that earned it.
func sourcePrune(source *Source, now time.Time, limits SettingsLimits) {
	source.starts = timesPrune(source.starts, now, budgetWindow)
	source.shortSessionEnds = timesPrune(source.shortSessionEnds, now, durationFromSeconds(limits.LoopWindowS))
	if len(source.shortSessionEnds) == 0 {
		source.markedLooping = false
	}
}

// sourceIdle is true for a source worth forgetting: it holds nothing the rules would read again.
func sourceIdle(source *Source) bool {
	return source.live == 0 && len(source.starts) == 0 && len(source.shortSessionEnds) == 0
}

// sourceSessionEnd records how one relayed session ended. A session that outlived the grace window was a real player,
// which clears the mark and the short ends behind it.
func sourceSessionEnd(source *Source, now time.Time, lifetime time.Duration, limits SettingsLimits) {
	if lifetime >= durationFromSeconds(limits.LoginGraceS) {
		source.shortSessionEnds, source.markedLooping = nil, false
		return
	}
	source.shortSessionEnds = append(source.shortSessionEnds, now)
	sourcePrune(source, now, limits)
	if len(source.shortSessionEnds) >= limits.LoopShortSessionsMax {
		source.markedLooping = true
	}
}

// sourceStartsLeft is true while the source may cause another start.
func sourceStartsLeft(source *Source, now time.Time, limits SettingsLimits) bool {
	source.starts = timesPrune(source.starts, now, budgetWindow)
	return len(source.starts) < limits.StartsPerSourcePerHourMax
}

// budgetSwitchesLeft is true while another start may stop a running server.
func budgetSwitchesLeft(budget *Budget, now time.Time, limits SettingsLimits) bool {
	budget.switches = timesPrune(budget.switches, now, budgetWindow)
	return len(budget.switches) < limits.SwitchesPerHourMax
}
