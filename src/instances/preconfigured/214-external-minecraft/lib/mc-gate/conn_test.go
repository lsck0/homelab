package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"testing"
	"time"
)

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// connTestGate is a gate over pipes: no listener, no sockets, and a dial that hands back one end of a second pipe.
func connTestGate(t *testing.T, settings Settings, d *Decider, backend net.Conn) *Gate {
	t.Helper()
	log := slog.New(slog.NewJSONHandler(io.Discard, nil))
	dial := func(string) (net.Conn, error) {
		if backend == nil {
			return nil, io.ErrClosedPipe
		}
		return backend, nil
	}
	return gateCreate(settings, d, dial, log, time.Now)
}

// connTestKickText reads a login-state Disconnect and returns the text the client shows.
func connTestKickText(t *testing.T, data []byte) string {
	t.Helper()
	reader := connReaderCreate(bytes.NewReader(data), 64*1024)
	id, body, err := frameRead(reader)
	if err != nil {
		t.Fatalf("frameRead of the kick: %v", err)
	}
	if id != packetIDLoginDisconnect {
		t.Fatalf("kick packet id %d", id)
	}
	payload, _, err := stringRead(body, 64*1024)
	if err != nil {
		t.Fatalf("kick text: %v", err)
	}
	// the login state's Disconnect carries the text as JSON, which is what a client renders
	var message struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal([]byte(payload), &message); err != nil {
		t.Fatalf("kick json %q: %v", payload, err)
	}
	return message.Text
}

// Test_conn_login covers one connection end to end over a pipe pair: a login for a sleeping server is
// kicked, and a login for a running one relays every byte the gate has already read.
func Test_conn_login(t *testing.T) {
	clock := fakeClockCreate()
	settings := testSettings(t, "alpha")
	systemd := fakeSystemdCreate(clock, settings.Servers[0].Unit)
	d, _ := testDecider(t, settings, clock, systemd, func(string) ([]byte, error) { return fakeStatus(0), nil })
	go deciderRun(d)
	defer deciderDestroy(d)

	t.Run("kick", func(t *testing.T) {
		client, server := net.Pipe()
		gate := connTestGate(t, settings, d, nil)
		go connServe(gate, server, testSource)
		client.Write(handshakeTestPacket(handshakeTestProtocol, "alpha.mc.lsck0.dev", intentLogin))
		client.Write(packetBuild(packetIDLoginStart, stringAppend(nil, "player")))
		answer, err := io.ReadAll(client)
		if err != nil {
			t.Fatalf("read the kick: %v", err)
		}
		if text := connTestKickText(t, answer); text != kickText(outcomeStarting, "alpha", 0, d.names) {
			t.Fatalf("kick text %q", text)
		}
	})

	t.Run("unknown name", func(t *testing.T) {
		client, server := net.Pipe()
		gate := connTestGate(t, settings, d, nil)
		go connServe(gate, server, testSourceOther)
		client.Write(handshakeTestPacket(handshakeTestProtocol, "gamma.mc.lsck0.dev", intentLogin))
		client.Write(packetBuild(packetIDLoginStart, stringAppend(nil, "player")))
		answer, _ := io.ReadAll(client)
		if text := connTestKickText(t, answer); text != kickText(outcomeUnknown, "gamma", 0, d.names) {
			t.Fatalf("kick text %q", text)
		}
	})

	t.Run("status", func(t *testing.T) {
		client, server := net.Pipe()
		gate := connTestGate(t, settings, d, nil)
		go connServe(gate, server, testSource)
		// a pipe carries no buffer, so the client writes while the gate answers
		go func() {
			client.Write(handshakeTestPacket(handshakeTestProtocol, "alpha.mc.lsck0.dev", intentStatus))
			client.Write(packetBuild(packetIDStatusRequest, nil))
			client.Write(packetBuild(packetIDPing, binary.BigEndian.AppendUint64(nil, 42)))
		}()
		answer, _ := io.ReadAll(client)
		reader := connReaderCreate(bytes.NewReader(answer), 64*1024)
		id, body, err := frameRead(reader)
		if err != nil || id != packetIDStatusResponse {
			t.Fatalf("status response: id %d, err %v", id, err)
		}
		if _, _, err := stringRead(body, statusBytesMax); err != nil {
			t.Fatalf("status payload: %v", err)
		}
		id, body, err = frameRead(reader)
		if err != nil || id != packetIDPing || binary.BigEndian.Uint64(body) != 42 {
			t.Fatalf("pong: id %d, body %x, err %v", id, body, err)
		}
	})

	t.Run("legacy ping", func(t *testing.T) {
		client, server := net.Pipe()
		gate := connTestGate(t, settings, d, nil)
		go connServe(gate, server, testSource)
		client.Write([]byte{legacyPingByte0, legacyPingByte1, legacyPingByte2})
		answer, _ := io.ReadAll(client)
		if len(answer) == 0 || answer[0] != legacyKickID {
			t.Fatalf("legacy answer %x", answer)
		}
	})

	t.Run("relay", func(t *testing.T) {
		// the server is up, so the next login is relayed rather than kicked
		fakeSystemdSet(systemd, settings.Servers[0].Unit, unitActive, false)
		deciderTick(d)
		if phase := deciderSnapshot(d).Servers[0].Phase; phase != string(phaseRunning) {
			t.Fatalf("alpha is %q, want running", phase)
		}

		client, server := net.Pipe()
		backend, backendPeer := net.Pipe()
		gate := connTestGate(t, settings, d, backend)
		go connServe(gate, server, testSource)
		opening := append(handshakeTestPacket(handshakeTestProtocol, "alpha.mc.lsck0.dev", intentLogin),
			packetBuild(packetIDLoginStart, stringAppend(nil, "player"))...)
		go func() {
			client.Write(opening)
			client.Write([]byte("play"))
		}()

		got := make([]byte, len(opening)+4)
		if _, err := io.ReadFull(backendPeer, got); err != nil {
			t.Fatalf("backend read: %v", err)
		}
		if !bytes.Equal(got[:len(opening)], opening) {
			t.Fatalf("the backend got %x, want the opening replayed", got)
		}

		// the backend's bytes reach the client, and its end ends the session
		backendPeer.Write([]byte("hello"))
		back := make([]byte, 5)
		if _, err := io.ReadFull(client, back); err != nil || string(back) != "hello" {
			t.Fatalf("client read %q: %v", back, err)
		}
		backendPeer.Close()
		client.Close()
		deadline := time.Now().Add(5 * time.Second)
		for deciderSnapshot(d).Servers[0].Sessions != 0 {
			if time.Now().After(deadline) {
				t.Fatal("the session never ended")
			}
			time.Sleep(time.Millisecond)
		}
	})
}
