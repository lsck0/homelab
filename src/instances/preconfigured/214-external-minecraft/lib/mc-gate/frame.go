package main

import (
	"errors"
	"fmt"
	"io"
	"strings"
	"unicode/utf16"
	"unicode/utf8"
)

/*
 * -----------------------------------------------------------------------------
 * CONSTANTS
 * -----------------------------------------------------------------------------
 */

const (
	// a VarInt holds an int32 in at most 5 groups of 7 bits; the fifth carries the top 4 and must have no others set
	varIntBytesMax     = 5
	varIntLastByteBits = 0x0F
	// the protocol's own bound on the handshake's address field, in characters
	addressCharsMax = 255

	// one id per packet the gate reads or writes; the value repeats because each one is read in its own state
	packetIDHandshake       = 0x00
	packetIDLoginStart      = 0x00
	packetIDStatusRequest   = 0x00
	packetIDStatusResponse  = 0x00
	packetIDLoginDisconnect = 0x00
	packetIDPing            = 0x01

	intentStatus   = 1
	intentLogin    = 2
	intentTransfer = 3

	// a legacy ping has no length prefix: it opens with 0xFE, and 1.4 onwards with 0xFE 0x01 0xFA
	legacyPingByte0 = 0xFE
	legacyPingByte1 = 0x01
	legacyPingByte2 = 0xFA
	// the only answer a legacy client understands, a 0xFF kick carrying a UTF-16BE string
	legacyKickID = 0xFF
	// the highest protocol a legacy client can be told about; anything above it reads as "outdated server"
	legacyKickProtocol = "127"
	// the ping a legacy client shows, which the format demands twice (version line and motd)
	legacyKickMarker = "\u00a71"
)

// the eight bytes of the status ping payload, a Long the gate echoes unchanged
const pingPayloadBytes = 8

var (
	errFrameTooLong = errors.New("frame: over the byte cap")
	errVarIntLong   = errors.New("varint: over five bytes")
)

/*
 * -----------------------------------------------------------------------------
 * TYPES
 * -----------------------------------------------------------------------------
 */

// Handshake is the client's first packet: everything the gate decides on.
type Handshake struct {
	Protocol int32
	Address  string
	Port     uint16
	Intent   int32
}

// connReader reads a connection's opening frames while keeping every byte, because a relayed login replays them to
// the backend; bytesMax bounds what a stranger may make the gate hold before it has decided anything.
type connReader struct {
	r        io.Reader
	buf      []byte
	pos      int
	bytesMax int
}

/*
 * -----------------------------------------------------------------------------
 * LIFETIME
 * -----------------------------------------------------------------------------
 */

func connReaderCreate(r io.Reader, bytesMax int) *connReader {
	return &connReader{r: r, bytesMax: bytesMax}
}

func connReaderDestroy(cr *connReader) {
	if cr == nil {
		return
	}
	cr.buf, cr.r = nil, nil
}

/*
 * -----------------------------------------------------------------------------
 * INTERNAL
 * -----------------------------------------------------------------------------
 */

// connReaderNeed reads until count unparsed bytes are buffered.
func connReaderNeed(cr *connReader, count int) error {
	want := cr.pos + count
	if want > cr.bytesMax {
		return errFrameTooLong
	}
	if len(cr.buf) >= want {
		return nil
	}
	grow := make([]byte, want-len(cr.buf))
	n, err := io.ReadFull(cr.r, grow)
	cr.buf = append(cr.buf, grow[:n]...)
	return err
}

// connReaderTake consumes count buffered bytes, which connReaderNeed has read.
func connReaderTake(cr *connReader, count int) []byte {
	taken := cr.buf[cr.pos : cr.pos+count]
	cr.pos += count
	return taken
}

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// varIntRead decodes a VarInt and returns the bytes it took. An encoding past five bytes, or a fifth byte carrying
// bits an int32 has no room for, is rejected: both are a client lying about a length.
func varIntRead(data []byte) (int32, int, error) {
	var value uint32
	for i := range varIntBytesMax {
		if i >= len(data) {
			return 0, 0, io.ErrUnexpectedEOF
		}
		b := data[i]
		if i == varIntBytesMax-1 && b&^byte(varIntLastByteBits) != 0 {
			return 0, 0, errVarIntLong
		}
		value |= uint32(b&0x7F) << (7 * i)
		if b&0x80 == 0 {
			return int32(value), i + 1, nil
		}
	}
	return 0, 0, errVarIntLong
}

// varIntAppend writes a VarInt, the inverse of varIntRead.
func varIntAppend(buf []byte, value int32) []byte {
	v := uint32(value)
	for {
		b := byte(v & 0x7F)
		v >>= 7
		if v == 0 {
			return append(buf, b)
		}
		buf = append(buf, b|0x80)
	}
}

// stringRead decodes a length-prefixed UTF-8 string and bounds it in characters, as the protocol does.
func stringRead(data []byte, charsMax int) (string, int, error) {
	length, n, err := varIntRead(data)
	if err != nil {
		return "", 0, err
	}
	if length < 0 || int(length) > len(data)-n {
		return "", 0, io.ErrUnexpectedEOF
	}
	text := string(data[n : n+int(length)])
	if !utf8.ValidString(text) {
		return "", 0, errors.New("string: not utf-8")
	}
	if utf8.RuneCountInString(text) > charsMax {
		return "", 0, fmt.Errorf("string: %d characters, at most %d", utf8.RuneCountInString(text), charsMax)
	}
	return text, n + int(length), nil
}

// stringAppend writes a length-prefixed UTF-8 string, the inverse of stringRead.
func stringAppend(buf []byte, text string) []byte {
	buf = varIntAppend(buf, int32(len(text)))
	return append(buf, text...)
}

// packetBuild frames one packet: VarInt length over id and body.
func packetBuild(id int32, body []byte) []byte {
	var inner []byte
	inner = varIntAppend(inner, id)
	inner = append(inner, body...)
	return append(varIntAppend(nil, int32(len(inner))), inner...)
}

// frameRead takes the next frame, returning its id and body. The bytes stay in the reader for a relay to replay.
func frameRead(cr *connReader) (int32, []byte, error) {
	length := int32(0)
	for taken := 1; ; taken++ {
		if taken > varIntBytesMax {
			return 0, nil, errVarIntLong
		}
		if err := connReaderNeed(cr, taken); err != nil {
			return 0, nil, err
		}
		value, _, err := varIntRead(cr.buf[cr.pos : cr.pos+taken])
		if errors.Is(err, io.ErrUnexpectedEOF) {
			continue
		}
		if err != nil {
			return 0, nil, err
		}
		length = value
		connReaderTake(cr, taken)
		break
	}
	if length <= 0 {
		return 0, nil, errors.New("frame: empty")
	}
	if err := connReaderNeed(cr, int(length)); err != nil {
		return 0, nil, err
	}
	frame := connReaderTake(cr, int(length))
	id, n, err := varIntRead(frame)
	if err != nil {
		return 0, nil, err
	}
	return id, frame[n:], nil
}

// frameIsLegacyPing is true when the connection opens with a legacy ping. Three bytes are checked, not one, so a
// modern frame of length 126 (0x7E is not 0xFE, but a 0xFE length byte is a continuation) is never mistaken for one.
func frameIsLegacyPing(cr *connReader) bool {
	if connReaderNeed(cr, 3) != nil {
		// a lone 0xFE is the oldest ping, and a 0xFE that no frame follows is nothing else either
		return len(cr.buf) > cr.pos && cr.buf[cr.pos] == legacyPingByte0
	}
	head := cr.buf[cr.pos : cr.pos+3]
	return head[0] == legacyPingByte0 && head[1] == legacyPingByte1 && head[2] == legacyPingByte2
}

// legacyKickBuild is the one answer a legacy client renders: 0xFF, a UTF-16BE length in characters, then the fields
// separated by NUL, which the format demands in full even though only the motd is read by a person.
func legacyKickBuild(text string) []byte {
	fields := strings.Join([]string{legacyKickMarker, legacyKickProtocol, text, text, "0", "0"}, "\x00")
	units := utf16.Encode([]rune(fields))
	out := []byte{legacyKickID, byte(len(units) >> 8), byte(len(units))}
	for _, unit := range units {
		out = append(out, byte(unit>>8), byte(unit))
	}
	return out
}

// handshakeParse reads the client's first packet; anything but id 0x00 with four well-formed fields is not a client.
func handshakeParse(id int32, body []byte) (Handshake, error) {
	if id != packetIDHandshake {
		return Handshake{}, fmt.Errorf("handshake: packet id %d", id)
	}
	protocol, n, err := varIntRead(body)
	if err != nil {
		return Handshake{}, fmt.Errorf("handshake: protocol: %w", err)
	}
	body = body[n:]
	address, n, err := stringRead(body, addressCharsMax)
	if err != nil {
		return Handshake{}, fmt.Errorf("handshake: address: %w", err)
	}
	body = body[n:]
	if len(body) < 2 {
		return Handshake{}, io.ErrUnexpectedEOF
	}
	port := uint16(body[0])<<8 | uint16(body[1])
	intent, _, err := varIntRead(body[2:])
	if err != nil {
		return Handshake{}, fmt.Errorf("handshake: intent: %w", err)
	}
	if intent != intentStatus && intent != intentLogin && intent != intentTransfer {
		return Handshake{}, fmt.Errorf("handshake: intent %d", intent)
	}
	return Handshake{Protocol: protocol, Address: address, Port: port, Intent: intent}, nil
}

// loginStartParse reads the player's name. It is unauthenticated, so it reaches the log and nothing else.
func loginStartParse(id int32, body []byte) (string, error) {
	if id != packetIDLoginStart {
		return "", fmt.Errorf("login start: packet id %d", id)
	}
	// the name is at most 16 characters, but a lenient bound keeps a future field from closing a real client
	name, _, err := stringRead(body, addressCharsMax)
	if err != nil {
		return "", fmt.Errorf("login start: name: %w", err)
	}
	return name, nil
}

// addressNormalize turns the address a client dialed into a server name: forge appends \0FML\0, proxies
// append \-separated parts, resolvers may leave the root dot, and the suffix is the lab's own.
func addressNormalize(address, suffix string) string {
	if cut := strings.IndexByte(address, 0); cut >= 0 {
		address = address[:cut]
	}
	if cut := strings.IndexByte(address, '\\'); cut >= 0 {
		address = address[:cut]
	}
	address = strings.TrimSuffix(address, ".")
	address = strings.ToLower(address)
	return strings.TrimSuffix(address, strings.ToLower(suffix))
}
