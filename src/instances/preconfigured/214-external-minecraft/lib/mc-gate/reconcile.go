package main

import (
	"time"
)

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// deciderReconcile runs every reconcileS, always, because a unit started by hand must be seen (R-046a). One
// `systemctl show` covers every server unit; the records are corrected only in the cases R-046b to R-046f name, so
// a start job that systemd has queued behind a slow save is never read as a server that is down.
func deciderReconcile(d *Decider, now time.Time) {
	servers := deciderServers(d)
	units := make([]string, 0, len(servers))
	for _, server := range servers {
		units = append(units, server.unit)
	}
	states, err := d.systemd.Show(units)
	if err != nil {
		d.log.Warn(logReconcile, "err", err)
		return
	}
	// a unit started by hand takes the lab over, so at most one sleeping record is promoted per pass
	promoted := false
	for _, server := range servers {
		state, known := states[server.unit]
		if !known {
			continue
		}
		deciderReconcileServer(d, server, state, &promoted)
	}
	deciderReconcileStatus(d, now)
	deciderReconcileTimeouts(d, now)
	deciderReconcileSleep(d, now)
	for address, source := range d.sources {
		sourcePrune(source, now, d.settings.Limits)
		if sourceIdle(source) {
			delete(d.sources, address)
		}
	}
	d.budget.switches = timesPrune(d.budget.switches, now, budgetWindow)
}

// deciderReconcileServer applies R-046b to R-046f to one record.
//
// A second unit started by hand in the same pass is stopped rather than promoted: two servers at once is what
// R-072's Conflicts= exists to prevent, and crashing on an invariant an operator can break by hand would take the
// gate down with it.
func deciderReconcileServer(d *Decider, server *Server, state UnitState, promoted *bool) {
	activity := activityFromUnit(state)
	before := server.phase
	switch server.phase {
	case phaseStarting, phaseRunning:
		if activity != activityIdle || state.Job {
			return
		}
		// R-046b
		if state.Active == "failed" {
			server.failures, server.lastStartFailed = server.failures+1, true
		}
		serverSleepSet(server)
	case phaseSleeping:
		switch {
		case activity == activityStarted && !*promoted:
			// R-046c
			*promoted = true
			server.phase, server.startedAt = phaseStarting, time.Time{}
			deciderReconcileExclude(d, server)
		case activity == activityStarted:
			deciderStop(d, server, reasonSwitch)
		case activity == activityStopping:
			// R-046d
			server.phase, server.stopIssued = phaseStopping, true
		default:
			return
		}
	case phaseStopping:
		switch {
		case activity == activityIdle && !state.Job:
			// R-046e
			serverSleepSet(server)
		case activity == activityStarted && !state.Job && deciderActive(d, server.name) == nil:
			// R-046f
			serverRunningSet(d, server, d.now())
		default:
			return
		}
	}
	logReconcileWrite(d.log, server.name, before, server.phase, state.Active)
}

// deciderReconcileExclude stops whatever else is up once a unit was started behind the gate's back (R-046c).
func deciderReconcileExclude(d *Decider, target *Server) {
	for _, server := range deciderServers(d) {
		if server == target || server.phase == phaseSleeping || server.phase == phaseStopping {
			continue
		}
		deciderStop(d, server, reasonSwitch)
	}
}

// deciderReconcileStatus asks the backend of the one server that could be answering: a starting server is up once it
// answers (R-046g), and a running one's player count is what occupancy reads.
func deciderReconcileStatus(d *Decider, now time.Time) {
	for _, server := range deciderServers(d) {
		if server.phase != phaseStarting && server.phase != phaseRunning {
			continue
		}
		if now.Sub(server.statusAt) < durationFromSeconds(d.settings.Limits.StatusCacheS) {
			continue
		}
		if !deciderStatusRefresh(d, server, now) {
			continue
		}
		if server.phase == phaseStarting {
			serverRunningSet(d, server, now)
			logReconcileWrite(d.log, server.name, phaseStarting, phaseRunning, "backend")
		}
	}
}

// deciderReconcileTimeouts stops a start that never answered (R-053a). The first start after a pack change downloads
// the pack, which takes minutes, so it gets the longer window (R-053b).
func deciderReconcileTimeouts(d *Decider, now time.Time) {
	for _, server := range deciderServers(d) {
		if server.phase != phaseStarting || server.startedAt.IsZero() {
			continue
		}
		waited := now.Sub(server.startedAt)
		if waited < deciderStartTimeout(d, server) {
			continue
		}
		server.failures, server.lastStartFailed = server.failures+1, true
		logStartFailedWrite(d.log, server.name, int(waited.Seconds()), nil)
		deciderStop(d, server, reasonTimeout)
	}
}

// deciderStartTimeout is the window a start has to answer in.
func deciderStartTimeout(d *Decider, server *Server) time.Duration {
	if startedMarkerNewer(d.settings.StateDir, server.name, server.modpackEnv) {
		return durationFromSeconds(d.settings.Limits.StartTimeoutS)
	}
	return durationFromSeconds(d.settings.Limits.FirstStartTimeoutS)
}

// deciderReconcileSleep stops a server nobody has used for sleepAfterS (R-050b).
func deciderReconcileSleep(d *Decider, now time.Time) {
	for _, server := range deciderServers(d) {
		if server.phase != phaseRunning || deciderOccupied(d, server, now) {
			continue
		}
		if now.Sub(server.idleSince) < durationFromSeconds(d.settings.Limits.SleepAfterS) {
			continue
		}
		deciderStop(d, server, reasonIdle)
	}
}
