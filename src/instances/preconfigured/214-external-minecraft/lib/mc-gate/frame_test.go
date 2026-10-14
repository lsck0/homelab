package main

import (
	"bytes"
	"encoding/binary"
	"strings"
	"testing"
)

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// the protocol a current client sends, which the gate only logs
const handshakeTestProtocol = 767

// frameTestInputs are the openings the spec names, reused by the test and as the fuzz seeds.
func frameTestInputs() [][]byte {
	address := strings.Repeat("a", 255)
	return [][]byte{
		// the varint edges, as frame lengths
		{0x00},
		{0x01, 0x00},
		{0x7f},
		{0x80, 0x01},
		{0xff, 0x01},
		// an overlong encoding of 1, a fifth byte whose bits run past int32, and two varints past five bytes
		{0x81, 0x00},
		{0xff, 0xff, 0xff, 0xff, 0x7f},
		{0x81, 0x80, 0x80, 0x80, 0x80, 0x00},
		{0xff, 0xff, 0xff, 0xff, 0xff, 0x01},
		// the legacy pings
		{legacyPingByte0},
		{legacyPingByte0, legacyPingByte1, legacyPingByte2},
		// a modern frame of length 126, whose first byte is 0xFE as a varint continuation
		append([]byte{0xfe, 0x00}, bytes.Repeat([]byte{0x00}, 126)...),
		handshakeTestPacket(handshakeTestProtocol, address, intentLogin),
		handshakeTestPacket(handshakeTestProtocol, "cobblemon.mc.lsck0.dev\x00FML2\x00", intentStatus),
		handshakeTestPacket(handshakeTestProtocol, "", intentTransfer),
	}
}

// handshakeTestPacket builds a client's first packet the way a client does.
func handshakeTestPacket(protocol int32, address string, intent int32) []byte {
	body := varIntAppend(nil, protocol)
	body = stringAppend(body, address)
	body = binary.BigEndian.AppendUint16(body, 25565)
	body = varIntAppend(body, intent)
	return packetBuild(packetIDHandshake, body)
}

// Test_spec001_r040_frame covers the untrusted boundary: every frame is read from a bounded reader, and a VarInt
// that is overlong or too long is rejected rather than read as the value it encodes (R-040).
func Test_spec001_r040_frame(t *testing.T) {
	cases := []struct {
		name  string
		data  []byte
		value int32
		used  int
		fails bool
	}{
		{name: "zero", data: []byte{0x00}, value: 0, used: 1},
		{name: "one", data: []byte{0x01}, value: 1, used: 1},
		{name: "last one byte", data: []byte{0x7f}, value: 127, used: 1},
		{name: "first two bytes", data: []byte{0x80, 0x01}, value: 128, used: 2},
		{name: "two bytes", data: []byte{0xff, 0x01}, value: 255, used: 2},
		{name: "three bytes", data: []byte{0xff, 0xff, 0x7f}, value: 2097151, used: 3},
		{name: "max int32", data: []byte{0xff, 0xff, 0xff, 0xff, 0x07}, value: 2147483647, used: 5},
		{name: "minus one", data: []byte{0xff, 0xff, 0xff, 0xff, 0x0f}, value: -1, used: 5},
		{name: "fifth byte over four bits", data: []byte{0xff, 0xff, 0xff, 0xff, 0x7f}, fails: true},
		{name: "six bytes", data: []byte{0x81, 0x80, 0x80, 0x80, 0x80, 0x00}, fails: true},
		{name: "truncated", data: []byte{0x80}, fails: true},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			value, used, err := varIntRead(test.data)
			if test.fails {
				if err == nil {
					t.Fatalf("varIntRead(%x) = %d, want an error", test.data, value)
				}
				return
			}
			if err != nil {
				t.Fatalf("varIntRead(%x): %v", test.data, err)
			}
			if value != test.value || used != test.used {
				t.Fatalf("varIntRead(%x) = %d in %d bytes, want %d in %d", test.data, value, used, test.value, test.used)
			}
			if round := varIntAppend(nil, test.value); !bytes.Equal(round, test.data) {
				t.Fatalf("varIntAppend(%d) = %x, want %x", test.value, round, test.data)
			}
		})
	}

	t.Run("handshake", func(t *testing.T) {
		address := strings.Repeat("a", addressCharsMax)
		reader := connReaderCreate(bytes.NewReader(handshakeTestPacket(handshakeTestProtocol, address, intentLogin)), 1024)
		id, body, err := frameRead(reader)
		if err != nil {
			t.Fatalf("frameRead: %v", err)
		}
		handshake, err := handshakeParse(id, body)
		if err != nil {
			t.Fatalf("handshakeParse: %v", err)
		}
		if handshake.Address != address || handshake.Intent != intentLogin || handshake.Protocol != handshakeTestProtocol {
			t.Fatalf("handshakeParse = %+v", handshake)
		}
	})

	t.Run("address over the cap", func(t *testing.T) {
		packet := handshakeTestPacket(handshakeTestProtocol, strings.Repeat("a", addressCharsMax+1), intentLogin)
		reader := connReaderCreate(bytes.NewReader(packet), 1024)
		id, body, _ := frameRead(reader)
		if _, err := handshakeParse(id, body); err == nil {
			t.Fatal("handshakeParse took an address over 255 characters")
		}
	})

	t.Run("bad intent", func(t *testing.T) {
		packet := handshakeTestPacket(handshakeTestProtocol, "a", 9)
		reader := connReaderCreate(bytes.NewReader(packet), 1024)
		id, body, _ := frameRead(reader)
		if _, err := handshakeParse(id, body); err == nil {
			t.Fatal("handshakeParse took intent 9")
		}
	})

	t.Run("byte cap", func(t *testing.T) {
		reader := connReaderCreate(bytes.NewReader(bytes.Repeat([]byte{0xff}, 4096)), 16)
		if _, _, err := frameRead(reader); err == nil {
			t.Fatal("frameRead read past the byte cap")
		}
	})

	t.Run("legacy ping", func(t *testing.T) {
		legacy := connReaderCreate(bytes.NewReader([]byte{legacyPingByte0, legacyPingByte1, legacyPingByte2}), 1024)
		if !frameIsLegacyPing(legacy) {
			t.Fatal("FE 01 FA is not seen as a legacy ping")
		}
		lone := connReaderCreate(bytes.NewReader([]byte{legacyPingByte0}), 1024)
		if !frameIsLegacyPing(lone) {
			t.Fatal("a lone FE is not seen as a legacy ping")
		}
		// a modern frame of length 126 opens with 0xFE as the first byte of a two-byte VarInt
		modern := connReaderCreate(bytes.NewReader(append([]byte{0xfe, 0x00}, bytes.Repeat([]byte{0x11}, 126)...)), 1024)
		if frameIsLegacyPing(modern) {
			t.Fatal("a modern frame of length 126 is seen as a legacy ping")
		}
		if id, _, err := frameRead(modern); err != nil || id != 0x11 {
			t.Fatalf("frameRead after the legacy check: id %d, err %v", id, err)
		}
	})

	t.Run("legacy kick", func(t *testing.T) {
		kick := legacyKickBuild(textLegacy)
		if kick[0] != legacyKickID {
			t.Fatalf("legacy kick opens with %#x, want %#x", kick[0], legacyKickID)
		}
		units := int(binary.BigEndian.Uint16(kick[1:3]))
		if len(kick) != 3+units*2 {
			t.Fatalf("legacy kick is %d bytes for %d utf-16 units", len(kick), units)
		}
	})

	t.Run("login start", func(t *testing.T) {
		packet := packetBuild(packetIDLoginStart, stringAppend(nil, "Notch"))
		reader := connReaderCreate(bytes.NewReader(packet), 1024)
		id, body, err := frameRead(reader)
		if err != nil {
			t.Fatalf("frameRead: %v", err)
		}
		player, err := loginStartParse(id, body)
		if err != nil || player != "Notch" {
			t.Fatalf("loginStartParse = %q, %v", player, err)
		}
	})
}

// Test_spec001_r041_normalize covers the address a client dialed becoming a server name: forge's suffix, a proxy's
// parts, the root dot, upper case and the lab's own suffix (R-041).
func Test_spec001_r041_normalize(t *testing.T) {
	const suffix = ".mc.lsck0.dev"
	cases := []struct {
		name    string
		address string
		want    string
	}{
		{name: "plain", address: "cobblemon.mc.lsck0.dev", want: "cobblemon"},
		{name: "trailing dot", address: "cobblemon.mc.lsck0.dev.", want: "cobblemon"},
		{name: "upper case", address: "Cobblemon.MC.LSCK0.dev", want: "cobblemon"},
		{name: "forge", address: "cobblemon.mc.lsck0.dev\x00FML2\x00", want: "cobblemon"},
		{name: "forge and dot", address: "cobblemon.mc.lsck0.dev.\x00FML3\x00", want: "cobblemon"},
		{name: "proxy parts", address: "cobblemon.mc.lsck0.dev\\127.0.0.1\\id", want: "cobblemon"},
		{name: "other suffix", address: "cobblemon.example.org", want: "cobblemon.example.org"},
		{name: "suffix only", address: "mc.lsck0.dev", want: "mc.lsck0.dev"},
		{name: "empty", address: "", want: ""},
		{name: "long", address: strings.Repeat("a", 255), want: strings.Repeat("a", 255)},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			if got := addressNormalize(test.address, suffix); got != test.want {
				t.Fatalf("addressNormalize(%q) = %q, want %q", test.address, got, test.want)
			}
		})
	}
}

// Fuzz_spec001_r040_frame throws the openings of R-040 at the reader: it may reject anything, but it may not panic,
// read past its cap, or hand on a frame whose body it never had.
func Fuzz_spec001_r040_frame(f *testing.F) {
	for _, seed := range frameTestInputs() {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, data []byte) {
		const bytesMax = 1024
		reader := connReaderCreate(bytes.NewReader(data), bytesMax)
		defer connReaderDestroy(reader)
		if frameIsLegacyPing(reader) {
			legacyKickBuild(textLegacy)
			return
		}
		id, body, err := frameRead(reader)
		if err != nil {
			return
		}
		if len(reader.buf) > bytesMax {
			t.Fatalf("read %d bytes past the cap of %d", len(reader.buf), bytesMax)
		}
		if len(body) > len(data) {
			t.Fatalf("frame body of %d bytes out of %d read", len(body), len(data))
		}
		if handshake, err := handshakeParse(id, body); err == nil {
			if len(handshake.Address) > addressCharsMax {
				t.Fatalf("address of %d characters accepted", len(handshake.Address))
			}
			addressNormalize(handshake.Address, ".mc.lsck0.dev")
		}
		if player, err := loginStartParse(id, body); err == nil && len(player) > addressCharsMax {
			t.Fatalf("player name of %d characters accepted", len(player))
		}
	})
}
