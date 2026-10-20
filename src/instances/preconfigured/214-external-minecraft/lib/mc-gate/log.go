package main

import (
	"log/slog"
	"net/netip"
)

/*
 * -----------------------------------------------------------------------------
 * CONSTANTS
 * -----------------------------------------------------------------------------
 */

// one journal line per event; the message is the event, every fact is a field
const (
	logLogin       = "login"
	logStart       = "start"
	logStop        = "stop"
	logStartFailed = "start-failed"
	logReconcile   = "reconcile"
	logRestart     = "restart"
)

// why a server was started or stopped, the one field that tells a switch from a sleep apart
const (
	reasonLogin   = "login"
	reasonSwitch  = "switch"
	reasonIdle    = "idle"
	reasonTimeout = "timeout"
	// the unit changed since the server started: a deploy never restarts a server, the gate does once nobody is on
	reasonStale = "stale"
)

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// logLoginWrite records one decision. The player name is unauthenticated, so it reaches the journal and nothing else.
func logLoginWrite(log *slog.Logger, source netip.Addr, player, server, outcome string) {
	log.Info(logLogin, "source", source.String(), "name", player, "server", server, "outcome", outcome)
}

// logStartWrite and logStopWrite name the source only for a switch, which is the one case a person asks about.
func logStartWrite(log *slog.Logger, server, reason string, source netip.Addr) {
	log.Info(logStart, append([]any{"server", server, "reason", reason}, logSourceAttrs(source)...)...)
}

func logStopWrite(log *slog.Logger, server, reason string, source netip.Addr) {
	log.Info(logStop, append([]any{"server", server, "reason", reason}, logSourceAttrs(source)...)...)
}

// logStartFailedWrite records a start that never answered, or that systemd refused.
func logStartFailedWrite(log *slog.Logger, server string, seconds int, err error) {
	attrs := []any{"server", server, "seconds", seconds}
	if err != nil {
		attrs = append(attrs, "err", err)
	}
	log.Warn(logStartFailed, attrs...)
}

// logReconcileWrite records a correction systemd's view forced on a record: a crash, a hand-started unit, a stop that
// never got queued.
func logReconcileWrite(log *slog.Logger, server string, from, to Phase, observed string) {
	log.Info(logReconcile, "server", server, "from", string(from), "to", string(to), "observed", observed)
}

func logSourceAttrs(source netip.Addr) []any {
	if !source.IsValid() {
		return nil
	}
	return []any{"source", source.String()}
}
