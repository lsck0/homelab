package main

import (
	"time"
)

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// deciderReconcile runs every reconcileS, always, because a unit started by hand must be seen. One
// `systemctl show` covers every server unit; the records are corrected only in the cases below, so
// a start job that systemd has queued behind a slow save is never read as a server that is down. It returns the
// server whose backend the caller asks before deciderReconcileFinish runs, or nil when it already ran.
func deciderReconcile(d *Decider, now time.Time) *Server {
	servers := deciderServers(d)
	units := make([]string, 0, len(servers))
	for _, server := range servers {
		units = append(units, server.unit)
	}
	states, err := d.systemd.Show(units)
	if err != nil {
		d.log.Warn(logReconcile, "err", err)
		return nil
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
	server := deciderReconcileStatus(d, now)
	if server != nil {
		server.statusFetching = true
	}
	return server
}

// deciderReconcileFinish is the rest of a pass, after the backend's answer is in.
func deciderReconcileFinish(d *Decider, now time.Time) {
	deciderReconcileTimeouts(d, now)
	deciderReconcileSleep(d, now)
	deciderReconcileStale(d, now)
	for address, source := range d.sources {
		sourcePrune(source, now, d.settings.Limits)
		if sourceIdle(source) {
			delete(d.sources, address)
		}
	}
	d.budget.switches = timesPrune(d.budget.switches, now, budgetWindow)
}

// deciderReconcileServer corrects one record from its unit.
//
// A second unit started by hand in the same pass is stopped rather than promoted: two servers at once is what
// the units' Conflicts= exists to prevent, and crashing on an invariant an operator can break by hand would take the
// gate down with it.
func deciderReconcileServer(d *Decider, server *Server, state UnitState, promoted *bool) {
	activity := activityFromUnit(state)
	before := server.phase
	// a queued restart leaves the old server active and answering until its stop begins
	server.unitUp = state.Active == "active" && !state.Job
	server.stale = server.unitUp && state.File != "" && startedUnitLoad(server.startedUnit) != state.File
	switch server.phase {
	case phaseStarting, phaseRunning:
		if activity != activityIdle || state.Job {
			return
		}
		// the unit went down under a started record
		if state.Active == "failed" {
			server.failures, server.lastStartFailed = server.failures+1, true
			// only a start counts as a failed start: a server that dies after hours of play is a crash, and the
			// start-failure alert names the pack and the world
			if before == phaseStarting {
				server.startFailuresTotal++
			}
		}
		serverSleepSet(server)
	case phaseSleeping:
		switch {
		case activity == activityStarted && !*promoted:
			// started by hand
			*promoted = true
			server.phase, server.startedAt = phaseStarting, time.Time{}
			deciderReconcileExclude(d, server)
		case activity == activityStarted:
			deciderStop(d, server, reasonSwitch)
		case activity == activityStopping:
			server.phase, server.stopIssued = phaseStopping, true
		default:
			return
		}
	case phaseStopping:
		switch {
		case activity == activityIdle && !state.Job:
			serverSleepSet(server)
		case activity == activityStarted && !state.Job && deciderActive(d, server.name) == nil:
			// a stop that never happened: the unit is still up and nothing else is
			serverRunningSet(d, server, d.now())
		default:
			return
		}
	}
	logReconcileWrite(d.log, server.name, before, server.phase, state.Active)
}

// deciderReconcileExclude stops whatever else is up once a unit was started behind the gate's back.
func deciderReconcileExclude(d *Decider, target *Server) {
	for _, server := range deciderServers(d) {
		if server == target || server.phase == phaseSleeping || server.phase == phaseStopping {
			continue
		}
		deciderStop(d, server, reasonSwitch)
	}
}

// deciderReconcileStatus is the one server that could be answering: a starting server is up once it answers, and a
// running one's player count is what occupancy reads. A starting server whose unit is not yet active is not asked:
// its start job waits on the old server's stop, and the old server still answers on the port.
func deciderReconcileStatus(d *Decider, now time.Time) *Server {
	for _, server := range deciderServers(d) {
		if server.phase != phaseStarting && server.phase != phaseRunning {
			continue
		}
		if server.phase == phaseStarting && !server.unitUp {
			continue
		}
		if deciderStatusDue(d, server, now) {
			return server
		}
	}
	return nil
}

// deciderReconcileTimeouts stops a start that never answered. The first start after a pack change downloads
// the pack, which takes minutes, so it gets the longer window.
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
		server.startFailuresTotal++
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

// deciderReconcileSleep stops a server nobody has used for sleepAfterS.
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

// deciderReconcileStale restarts a server running an older unit than the installed one the moment nobody is on it.
func deciderReconcileStale(d *Decider, now time.Time) {
	for _, server := range deciderServers(d) {
		if server.phase != phaseRunning || !server.stale || deciderOccupied(d, server, now) {
			continue
		}
		deciderRestart(d, server, now)
	}
}
