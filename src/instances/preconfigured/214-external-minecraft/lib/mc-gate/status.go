package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net"
	"time"
)

/*
 * -----------------------------------------------------------------------------
 * CONSTANTS
 * -----------------------------------------------------------------------------
 */

const (
	// a status response carries a 64x64 png favicon as a data uri, which no real server pushes anywhere near this far
	statusBytesMax = 64 * 1024
	// what a client is told about a server that has never answered a status ping and declares no version in nix
	statusVersionUnknown  = "?"
	statusProtocolUnknown = -1
	// the gate's own handshake when it asks a backend: -1 is the protocol a ping, not a login, carries
	statusProbeProtocol = -1
	statusProbeAddress  = "127.0.0.1"
	statusProbePort     = 25565
)

/*
 * -----------------------------------------------------------------------------
 * TYPES
 * -----------------------------------------------------------------------------
 */

// StatusFetch asks a backend for its status; a test answers without a socket.
type StatusFetch func(address string) ([]byte, error)

// Status is the status response's JSON, with the fields the gate reads or rewrites. An unknown field of a backend's
// answer is dropped on the way through, which costs nothing: only a sleeping server's answer is ever rebuilt.
type Status struct {
	Version     StatusVersion `json:"version"`
	Players     StatusPlayers `json:"players"`
	Description any           `json:"description"`
	Favicon     string        `json:"favicon,omitempty"`
}

type StatusVersion struct {
	Name     string `json:"name"`
	Protocol int    `json:"protocol"`
}

type StatusPlayers struct {
	Max    int            `json:"max"`
	Online int            `json:"online"`
	Sample []StatusSample `json:"sample"`
}

type StatusSample struct {
	Name string `json:"name"`
	ID   string `json:"id"`
}

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// statusParse reads a backend's answer, which is the only status the gate ever takes from outside itself.
func statusParse(data []byte) (Status, error) {
	var status Status
	if err := json.Unmarshal(data, &status); err != nil {
		return Status{}, fmt.Errorf("status: %w", err)
	}
	return status, nil
}

// statusBuild renders the answer for a server that is not answering itself: the cached version, protocol, player
// maximum and favicon when there is a cache, the declared ones otherwise, with no one online and the phase's
// description.
func statusBuild(cached []byte, version *string, protocol *int, description string) ([]byte, error) {
	status := Status{Version: StatusVersion{Name: statusVersionUnknown, Protocol: statusProtocolUnknown}}
	if version != nil {
		status.Version.Name = *version
	}
	if protocol != nil {
		status.Version.Protocol = *protocol
	}
	if len(cached) > 0 {
		parsed, err := statusParse(cached)
		if err == nil {
			status.Version, status.Favicon = parsed.Version, parsed.Favicon
			status.Players.Max = parsed.Players.Max
		}
	}
	status.Players.Online, status.Players.Sample = 0, nil
	status.Description = map[string]string{"text": description}
	return json.Marshal(status)
}

// statusFetchTCP asks a backend on loopback, speaking the handshake and status request a client would.
func statusFetchTCP(address string, timeout time.Duration) ([]byte, error) {
	conn, err := net.DialTimeout("tcp", address, timeout)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(timeout)); err != nil {
		return nil, err
	}
	var handshake []byte
	handshake = varIntAppend(handshake, statusProbeProtocol)
	handshake = stringAppend(handshake, statusProbeAddress)
	handshake = binary.BigEndian.AppendUint16(handshake, statusProbePort)
	handshake = varIntAppend(handshake, intentStatus)
	request := append(packetBuild(packetIDHandshake, handshake), packetBuild(packetIDStatusRequest, nil)...)
	if _, err := conn.Write(request); err != nil {
		return nil, err
	}
	reader := connReaderCreate(conn, statusBytesMax)
	defer connReaderDestroy(reader)
	id, body, err := frameRead(reader)
	if err != nil {
		return nil, err
	}
	if id != packetIDStatusResponse {
		return nil, fmt.Errorf("status: packet id %d", id)
	}
	// the response is one String, which may be the whole 64 KiB the reader allows
	payload, _, err := stringRead(body, statusBytesMax)
	if err != nil {
		return nil, err
	}
	return []byte(payload), nil
}
