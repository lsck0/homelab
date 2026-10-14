package main

import (
	"fmt"
	"strings"
)

/*
 * -----------------------------------------------------------------------------
 * CONSTANTS
 * -----------------------------------------------------------------------------
 */

// the outcome of a login, which is also the key of its text and the value the journal and the metrics carry
const (
	outcomeRelay        = "relay"
	outcomeCapped       = "capped"
	outcomeUnknown      = "unknown"
	outcomeStarting     = "starting"
	outcomeStopping     = "stopping"
	outcomeBusyStarting = "busyStarting"
	outcomeBusy         = "busy"
	outcomeJustStarted  = "justStarted"
	outcomeBudget       = "budget"
	outcomeFailed       = "failed"
)

// the kick texts of R-054, rendered by kickText; the client shows them on its disconnect screen
const (
	textStarting     = "%s is starting, rejoin in about a minute"
	textStopping     = "%s is stopping, try again in a minute"
	textBusyStarting = "%s is starting for someone, try again later"
	textBusy         = "%s is running with %d players, try again later"
	textJustStarted  = "%s just started, try again in a few minutes"
	textBudget       = "too many server switches, try again later"
	textFailed       = "%s failed to start, try again later"
	textUnknown      = "no server %s here; servers: %s"
)

// the status descriptions of R-042 and R-053c, rendered by statusDescription; the client shows them in its server list
const (
	descriptionSleeping = "sleeping, join to start it"
	descriptionStarting = "starting, rejoin in about a minute"
	descriptionStopping = "stopping"
	descriptionRunning  = "%s is running with %d players"
	descriptionFailed   = "failed to start, join to try again"
	descriptionUnknown  = "no such server"
)

// what a legacy client is told, which its format shows as both the version and the motd
const textLegacy = "lsck0.dev minecraft"

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// kickText renders the text of one outcome. server is the server the text speaks of, which is the requested one for
// starting, stopping, failed and unknown, and the other one for busyStarting, busy and justStarted.
func kickText(outcome, server string, players int, servers []string) string {
	switch outcome {
	case outcomeStarting:
		return fmt.Sprintf(textStarting, server)
	case outcomeStopping:
		return fmt.Sprintf(textStopping, server)
	case outcomeBusyStarting:
		return fmt.Sprintf(textBusyStarting, server)
	case outcomeBusy:
		return fmt.Sprintf(textBusy, server, players)
	case outcomeJustStarted:
		return fmt.Sprintf(textJustStarted, server)
	case outcomeBudget:
		return textBudget
	case outcomeFailed:
		return fmt.Sprintf(textFailed, server)
	case outcomeUnknown:
		return fmt.Sprintf(textUnknown, server, strings.Join(servers, ", "))
	}
	panic("kickText: outcome " + outcome + " has no text")
}

// statusDescription renders what a pinged server says about itself. running names the server that is running instead,
// which is the pinged one only when it answers no live status of its own.
func statusDescription(phase Phase, failed bool, running string, players int) string {
	if failed {
		return descriptionFailed
	}
	switch phase {
	case phaseStarting:
		return descriptionStarting
	case phaseStopping:
		return descriptionStopping
	case phaseRunning:
		return fmt.Sprintf(descriptionRunning, running, players)
	case phaseSleeping:
		if running != "" {
			return fmt.Sprintf(descriptionRunning, running, players)
		}
		return descriptionSleeping
	}
	panic("statusDescription: phase " + string(phase) + " has no description")
}
