package main

import (
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"net/netip"
	"sync"
	"sync/atomic"
	"time"
)

/*
 * -----------------------------------------------------------------------------
 * TYPES
 * -----------------------------------------------------------------------------
 */

// Gate is the listener's side: the settings a connection reads, the decider it asks, and the dial a relay makes.
// The settings pointer is swapped whole by a reload, so a connection reads one consistent file (R-055b).
type Gate struct {
	settings atomic.Pointer[Settings]
	decider  *Decider
	dial     func(address string) (net.Conn, error)
	log      *slog.Logger
	now      func() time.Time
}

/*
 * -----------------------------------------------------------------------------
 * LIFETIME
 * -----------------------------------------------------------------------------
 */

func gateCreate(settings Settings, decider *Decider, dial func(address string) (net.Conn, error), log *slog.Logger, now func() time.Time) *Gate {
	g := &Gate{decider: decider, dial: dial, log: log, now: now}
	g.settings.Store(&settings)
	return g
}

func gateDestroy(g *Gate) {
	if g == nil {
		return
	}
	deciderDestroy(g.decider)
}

/*
 * -----------------------------------------------------------------------------
 * INTERNAL
 * -----------------------------------------------------------------------------
 */

// connKickBuild is a login-state Disconnect, whose text is JSON; the configuration and play states take NBT instead,
// which is why the gate never relays a connection it means to refuse.
func connKickBuild(text string) []byte {
	message, err := json.Marshal(map[string]string{"text": text})
	if err != nil {
		// the input is one string, so a failure here would be a broken runtime
		panic("kick: " + err.Error())
	}
	return packetBuild(packetIDLoginDisconnect, stringAppend(nil, string(message)))
}

// connStatusServe answers a ping itself, so a sleeping server needs no backend and a running one is asked at most
// once per statusCacheS however fast the pings come (R-042).
func connStatusServe(g *Gate, conn net.Conn, reader *connReader, name string) {
	id, _, err := frameRead(reader)
	if err != nil || id != packetIDStatusRequest {
		return
	}
	answer := deciderStatus(g.decider, name)
	if _, err := conn.Write(packetBuild(packetIDStatusResponse, stringAppend(nil, string(answer)))); err != nil {
		return
	}
	// the ping is a Long the client measures its latency with, echoed unchanged
	id, body, err := frameRead(reader)
	if err != nil || id != packetIDPing || len(body) < pingPayloadBytes {
		return
	}
	conn.Write(packetBuild(packetIDPing, body[:pingPayloadBytes]))
}

// connRelay writes the bytes the gate has already read to the backend and copies both ways until either side ends.
func connRelay(g *Gate, conn net.Conn, opening []byte, decision Decision, name string) {
	backend, err := g.dial(decision.Backend)
	if err != nil {
		g.log.Warn("relay", "server", name, "err", err)
		deciderSessionEnd(g.decider, name, decision.Session)
		return
	}
	defer deciderSessionEnd(g.decider, name, decision.Session)
	defer backend.Close()
	// the handshake and the login start the decision was made on, replayed unchanged
	if _, err := backend.Write(opening); err != nil {
		return
	}
	// a relayed connection is a player's whole session: no deadline past the handshake
	conn.SetDeadline(time.Time{})
	var copies sync.WaitGroup
	copies.Add(2)
	for _, pair := range [][2]net.Conn{{backend, conn}, {conn, backend}} {
		go func(to, from net.Conn) {
			defer copies.Done()
			io.Copy(to, from)
			// one side ending ends the other copy too
			to.SetDeadline(time.Now())
		}(pair[0], pair[1])
	}
	copies.Wait()
}

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// connServe takes one connection from its first byte to its end. Everything before the decision is bounded in time
// and in bytes (R-040), because a stranger opened it.
func connServe(g *Gate, conn net.Conn, source netip.Addr) {
	defer conn.Close()
	settings := g.settings.Load()
	if err := conn.SetDeadline(g.now().Add(durationFromSeconds(settings.Limits.HandshakeTimeoutS))); err != nil {
		return
	}
	reader := connReaderCreate(conn, settings.Limits.HandshakeBytesMax)
	defer connReaderDestroy(reader)

	if frameIsLegacyPing(reader) {
		conn.Write(legacyKickBuild(textLegacy))
		return
	}
	id, body, err := frameRead(reader)
	if err != nil {
		return
	}
	handshake, err := handshakeParse(id, body)
	if err != nil {
		return
	}
	name := addressNormalize(handshake.Address, settings.Suffix)
	if handshake.Intent == intentStatus {
		connStatusServe(g, conn, reader, name)
		return
	}

	id, body, err = frameRead(reader)
	if err != nil {
		return
	}
	player, err := loginStartParse(id, body)
	if err != nil {
		return
	}
	decision := deciderLogin(g.decider, name, player, source)
	switch decision.Outcome {
	case outcomeRelay:
		connRelay(g, conn, reader.buf[:reader.pos], decision, name)
	case outcomeCapped:
		// a source over its session cap is closed without a word (R-048d)
	default:
		conn.Write(connKickBuild(decision.Text))
	}
}
