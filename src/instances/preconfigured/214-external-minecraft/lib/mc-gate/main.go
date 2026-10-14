package main

import (
	"flag"
	"log/slog"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"syscall"
	"time"
)

/*
 * -----------------------------------------------------------------------------
 * CONSTANTS
 * -----------------------------------------------------------------------------
 */

// a relay dials loopback, where a refusal is immediate and a slow connect only means the backend is gone
const backendDialTimeout = 5 * time.Second

/*
 * -----------------------------------------------------------------------------
 * INTERNAL
 * -----------------------------------------------------------------------------
 */

// settingsLoad reads the file the unit points at; it is also the reload path, so a bad edit keeps the old settings.
func settingsLoad(path string) (Settings, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Settings{}, err
	}
	return settingsParse(data)
}

// mainReload re-reads the settings on SIGHUP, because the unit is reloaded, not restarted, when a server is added
// while people are playing (R-055b).
func mainReload(path string, decider *Decider, gate *Gate, log *slog.Logger) {
	hangups := make(chan os.Signal, 1)
	signal.Notify(hangups, syscall.SIGHUP)
	for range hangups {
		settings, err := settingsLoad(path)
		if err != nil {
			log.Warn("reload", "err", err)
			continue
		}
		deciderReload(decider, settings)
		gate.settings.Store(&settings)
		log.Info("reload", "servers", len(settings.Servers))
	}
}

// mainReconcile drives the decider's clock: systemd is asked on a tick, never on a connection, so a flood of pings
// costs nothing.
func mainReconcile(decider *Decider, every time.Duration) {
	ticker := time.NewTicker(every)
	defer ticker.Stop()
	for range ticker.C {
		deciderTick(decider)
	}
}

// mainServe takes connections until the listener is closed; one connection is one goroutine, and its panic takes the
// gate down on purpose, because a decider that kept a session nobody holds would hold a server up forever.
func mainServe(gate *Gate, listener net.Listener) error {
	for {
		conn, err := listener.Accept()
		if err != nil {
			return err
		}
		source := netipFromAddr(conn.RemoteAddr())
		if !source.IsValid() {
			conn.Close()
			continue
		}
		go connServe(gate, conn, source)
	}
}

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stderr, nil))
	path := flag.String("settings", "", "path of the settings file")
	flag.Parse()
	if *path == "" {
		log.Error("settings", "err", "missing -settings")
		os.Exit(1)
	}
	settings, err := settingsLoad(*path)
	if err != nil {
		log.Error("settings", "err", err)
		os.Exit(1)
	}

	allow := allowCreate(settings.Allow)
	defer allowDestroy(allow)
	fetch := func(address string) ([]byte, error) {
		return statusFetchTCP(address, durationFromSeconds(settings.Limits.HandshakeTimeoutS))
	}
	decider := deciderCreate(settings, systemdExec{}, allow, fetch, log, time.Now)
	go deciderRun(decider)
	dial := func(address string) (net.Conn, error) {
		return net.DialTimeout("tcp", address, backendDialTimeout)
	}
	gate := gateCreate(settings, decider, dial, log, time.Now)
	defer gateDestroy(gate)

	listener, err := net.Listen("tcp", settings.Listen)
	if err != nil {
		log.Error("listen", "address", settings.Listen, "err", err)
		os.Exit(1)
	}
	defer listener.Close()

	// a gate that was restarted learns from systemd what is up before it answers anything (R-050c)
	deciderTick(decider)
	go mainReconcile(decider, durationFromSeconds(settings.Limits.ReconcileS))
	go mainReload(*path, decider, gate, log)
	log.Info("listen", "address", settings.Listen, "servers", len(settings.Servers))
	if err := mainServe(gate, listener); err != nil {
		log.Error("accept", "err", err)
		os.Exit(1)
	}
}

// netipFromAddr is the source a decision is attributed to; a listener that is not TCP has none.
func netipFromAddr(addr net.Addr) netip.Addr {
	tcp, ok := addr.(*net.TCPAddr)
	if !ok {
		return netip.Addr{}
	}
	return tcp.AddrPort().Addr().Unmap()
}
