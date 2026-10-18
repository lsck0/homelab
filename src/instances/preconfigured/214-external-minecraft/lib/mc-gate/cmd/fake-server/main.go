package main

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
)

/*
 * -----------------------------------------------------------------------------
 * CONSTANTS
 * -----------------------------------------------------------------------------
 */

// the fake answers a status and a login, which both start at packet 0x00 of their state
const (
	packetIDHandshake = 0x00
	packetIDPing      = 0x01
	intentStatus      = 1
	framePayloadMax   = 64 * 1024
)

/*
 * -----------------------------------------------------------------------------
 * INTERNAL
 * -----------------------------------------------------------------------------
 */

// varIntRead and varIntAppend are repeated here rather than imported: the gate's copy lives in `package main` of the
// module root, which no other package can import.
func varIntRead(r io.Reader) (int32, error) {
	var value, shift int32
	for i := 0; i < 5; i++ {
		var b [1]byte
		if _, err := io.ReadFull(r, b[:]); err != nil {
			return 0, err
		}
		value |= int32(b[0]&0x7f) << shift
		if b[0]&0x80 == 0 {
			return value, nil
		}
		shift += 7
	}
	return 0, errors.New("varint too long")
}

func varIntAppend(buf []byte, value int32) []byte {
	for {
		part := byte(value & 0x7f)
		value = int32(uint32(value) >> 7)
		if value != 0 {
			part |= 0x80
		}
		buf = append(buf, part)
		if value == 0 {
			return buf
		}
	}
}

func stringAppend(buf []byte, text string) []byte {
	return append(varIntAppend(buf, int32(len(text))), text...)
}

func packetWrite(w io.Writer, id int32, body []byte) error {
	packet := varIntAppend(nil, id)
	packet = append(packet, body...)
	_, err := w.Write(append(varIntAppend(nil, int32(len(packet))), packet...))
	return err
}

// frameRead returns one packet's id and body, bounded so a wrong length cannot allocate the host's memory.
func frameRead(r io.Reader) (int32, []byte, error) {
	length, err := varIntRead(r)
	if err != nil {
		return 0, nil, err
	}
	if length <= 0 || length > framePayloadMax {
		return 0, nil, fmt.Errorf("frame length %d", length)
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(r, payload); err != nil {
		return 0, nil, err
	}
	id, err := varIntRead(&sliceReader{data: payload})
	if err != nil {
		return 0, nil, err
	}
	used := len(varIntAppend(nil, id))
	return id, payload[used:], nil
}

// sliceReader lets frameRead parse the packet id out of a payload it has already read.
type sliceReader struct {
	data []byte
	pos  int
}

func (sr *sliceReader) Read(p []byte) (int, error) {
	if sr.pos >= len(sr.data) {
		return 0, io.EOF
	}
	n := copy(p, sr.data[sr.pos:])
	sr.pos += n
	return n, nil
}

// statusBuild reports the live sessions, which is what the gate's occupancy reads back.
func statusBuild(version string, protocol int, online int32) []byte {
	answer := map[string]any{
		"version": map[string]any{"name": version, "protocol": protocol},
		"players": map[string]any{"max": 20, "online": online, "sample": []any{}},
		"description": map[string]any{
			"text": fmt.Sprintf("fake-server, %d online", online),
		},
	}
	data, err := json.Marshal(answer)
	if err != nil {
		panic("status: " + err.Error())
	}
	return data
}

// connServe keeps a login open until the client leaves, so the session count the status reports is real.
func connServe(conn net.Conn, sessions *atomic.Int32, version string, protocol int) {
	defer conn.Close()
	id, body, err := frameRead(conn)
	if err != nil || id != packetIDHandshake || len(body) == 0 {
		return
	}
	intent := int32(body[len(body)-1])
	if intent == intentStatus {
		if _, _, err := frameRead(conn); err != nil {
			return
		}
		if err := packetWrite(conn, 0x00, stringAppend(nil, string(statusBuild(version, protocol, sessions.Load())))); err != nil {
			return
		}
		id, ping, err := frameRead(conn)
		if err != nil || id != packetIDPing || len(ping) < 8 {
			return
		}
		packetWrite(conn, packetIDPing, ping[:8])
		return
	}

	if _, _, err := frameRead(conn); err != nil {
		return
	}
	sessions.Add(1)
	defer sessions.Add(-1)
	// login success with a fixed uuid: the fake plays no game, it only holds the session open
	var uuid [16]byte
	binary.BigEndian.PutUint64(uuid[8:], 1)
	body = append(uuid[:], stringAppend(nil, "player")...)
	if err := packetWrite(conn, 0x02, append(body, 0x00)); err != nil {
		return
	}
	io.Copy(io.Discard, conn)
}

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

func main() {
	listen := flag.String("listen", "127.0.0.1:25566", "address to listen on")
	version := flag.String("version", "1.21.1", "version name to report")
	protocol := flag.Int("protocol", 767, "protocol number to report")
	ignoreTerm := flag.Bool("ignore-sigterm", false, "ignore SIGTERM, to test a stop that has to be killed")
	flag.Parse()
	if *ignoreTerm {
		signal.Notify(make(chan os.Signal, 1), syscall.SIGTERM)
	}

	listener, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatalf("listen %s: %v", *listen, err)
	}
	defer listener.Close()
	log.Printf("fake-server on %s", *listen)

	var sessions atomic.Int32
	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Fatalf("accept: %v", err)
		}
		go connServe(conn, &sessions, *version, *protocol)
	}
}
