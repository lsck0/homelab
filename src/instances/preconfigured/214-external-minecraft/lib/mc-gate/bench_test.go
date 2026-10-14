package main

import (
	"bytes"
	"testing"
)

/*
 * -----------------------------------------------------------------------------
 * BENCHMARKS
 * -----------------------------------------------------------------------------
 */

// Benchmark_spec001_r040_frame measures what the gate spends on a connection before it decides: the frame reader,
// the handshake parse and the address normalization. The Performance section claims under 1 ms of cpu per
// connection and no allocation beyond the frame buffer, so allocations are reported.
func Benchmark_spec001_r040_frame(b *testing.B) {
	packet := handshakeTestPacket(handshakeTestProtocol, "cobblemon.mc.lsck0.dev\x00FML2\x00", intentLogin)
	reader := bytes.NewReader(nil)

	b.ReportAllocs()
	for b.Loop() {
		reader.Reset(packet)
		cr := connReaderCreate(reader, 1024)
		id, body, err := frameRead(cr)
		if err != nil {
			b.Fatalf("frameRead: %v", err)
		}
		handshake, err := handshakeParse(id, body)
		if err != nil {
			b.Fatalf("handshakeParse: %v", err)
		}
		if addressNormalize(handshake.Address, ".mc.lsck0.dev") != "cobblemon" {
			b.Fatalf("addressNormalize(%q) = %q", handshake.Address, handshake.Address)
		}
	}
}

// Benchmark_spec001_r044_decide measures one login decision, handed to the owning goroutine and waited for as a
// real connection does it (R-044). The target is starting, which is the one row of R-052 that decides without
// changing a record, so every iteration measures the same work.
func Benchmark_spec001_r044_decide(b *testing.B) {
	clock := fakeClockCreate()
	settings := testSettings(b, "alpha")
	systemd := fakeSystemdCreate(clock, settings.Servers[0].Unit)
	d, _ := testDecider(b, settings, clock, systemd, nil)
	go deciderRun(d)
	defer deciderDestroy(d)
	if decision := deciderLogin(d, "alpha", "player", testSource); decision.Outcome != outcomeStarting {
		b.Fatalf("the first login is %q, want %q", decision.Outcome, outcomeStarting)
	}

	b.ReportAllocs()
	for b.Loop() {
		if decision := deciderLogin(d, "alpha", "player", testSource); decision.Outcome != outcomeStarting {
			b.Fatalf("login is %q, want %q", decision.Outcome, outcomeStarting)
		}
	}
}
