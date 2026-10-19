// Command lab-gate is the ingress's gate in front of every protected route (modules/traefik/lib/gate.nix): it turns
// crowdsec's decisions into pages a person can read, asks flagged clients a captcha, limits anonymous clients below
// the ingress's own limit, trickles the bot labyrinth, and serves the deception: fakes with canaries and the labyrinth
// for a scanner crowdsec decided to deceive and a forged search crawler.
//
// A request is judged cheapest and most trusted first: an allowed source passes, then a session authelia confirms,
// then crowdsec's cached decision (deceive beats ban beats captcha), where nothing of ban strength holds a forged
// search crawler on a route with the bot defence, then an anonymous client's token bucket (429).
//
// Security: an onion visitor always arrives from the router, so nothing tells two apart. Every browser session there
// picks its route's own address among lookalikes sharing its ends; a phishing proxy relays the page from the real
// address, which then matches no row its visitor's address bar shows.
//
// Rejected: the bouncer plugin's captcha. Every provider it offers loads a third-party script and checks a token at
// its server, and its ban page is a fixed file that cannot say how long a ban lasts.
//
//	lab-gate -settings /etc/lab-gate/settings.json
package main

import (
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"time"
)

const (
	// traefik is the only caller, on loopback: these bound a stuck connection, never a slow client
	serverReadHeaderTimeout = 5 * time.Second
	serverIdleTimeout       = 2 * time.Minute
	// at least 256 bits, as hmac-sha256 uses them
	hmacKeyBytesMin = 32
)

func gateCreate(settings Settings) (*Gate, error) {
	lapiKey, err := keyFileLoad(settings.Lapi.KeyFile, 0)
	if err != nil {
		return nil, fmt.Errorf("crowdsec bouncer key: %w", err)
	}
	metrics := metricsCreate()
	crawlers, err := crawlersCreate(settings.Crawlers, net.DefaultResolver)
	if err != nil {
		return nil, fmt.Errorf("crawlers: %w", err)
	}
	canaryKey, err := keyFileLoad(settings.Deception.CanaryKeyFile, hmacKeyBytesMin)
	if err != nil {
		return nil, fmt.Errorf("canary key: %w", err)
	}
	g := &Gate{
		allow:     allowCreate(settings.Allow),
		decisions: decisionsCreate(settings.Lapi.URL, string(lapiKey)),
		limiter:   limiterCreate(settings.Anonymous),
		tarpit:    tarpitCreate(settings.Tarpit.Upstream, metrics),
		crawlers:  crawlers,
		deception: &Deception{statusDeceive: settings.Deception.StatusDeceive, statusForgedCrawler: settings.Deception.StatusForgedCrawler,
			canaryKey: canaryKey, interval: deceptionChunkInterval},
		metrics:      metrics,
		stripCookies: make(map[string]bool, len(settings.StripCookies)),
	}
	for _, name := range settings.StripCookies {
		g.stripCookies[name] = true
	}
	if settings.Session != nil {
		g.sessions = sessionsCreate(*settings.Session)
	}
	if c := settings.Captcha; c != nil {
		key, err := keyFileLoad(c.KeyFile, hmacKeyBytesMin)
		if err != nil {
			return nil, fmt.Errorf("captcha key: %w", err)
		}
		onions, err := onionRoutes(c.Onions)
		if err != nil {
			return nil, fmt.Errorf("captcha onions: %w", err)
		}
		challenges, err := challengesCreate(c.RegenerationsMax, c.AnswerLog)
		if err != nil {
			return nil, fmt.Errorf("captcha answer log: %w", err)
		}
		g.captcha = &Captcha{key: key, cookieDomain: c.CookieDomain, answerPath: c.AnswerPath, onions: onions,
			challenges: challenges, renders: make(chan struct{}, renderSlots)}
	}
	return g, nil
}

func gateDestroy(g *Gate) {
	if g == nil {
		return
	}
	if g.captcha != nil {
		challengesDestroy(g.captcha.challenges)
	}
	tarpitDestroy(g.tarpit)
	crawlersDestroy(g.crawlers)
	limiterDestroy(g.limiter)
	decisionsDestroy(g.decisions)
	sessionsDestroy(g.sessions)
	allowDestroy(g.allow)
	metricsDestroy(g.metrics)
}

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stderr, nil)))
	settingsPath := flag.String("settings", "", "the gate's settings file (json)")
	flag.Parse()
	data, err := os.ReadFile(*settingsPath)
	if err != nil {
		slog.Error("settings", "err", err)
		os.Exit(1)
	}
	settings, err := settingsParse(data)
	if err != nil {
		slog.Error("settings", "err", err)
		os.Exit(1)
	}
	g, err := gateCreate(settings)
	if err != nil {
		slog.Error("startup", "err", err)
		os.Exit(1)
	}

	gateServer := &http.Server{Addr: settings.Listen, Handler: gateMux(g), ReadHeaderTimeout: serverReadHeaderTimeout, IdleTimeout: serverIdleTimeout}
	tarpitHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { tarpitServe(g.tarpit, w, r) })
	// no write timeout: a trickle is slow on purpose, tarpitDurationMax ends it
	tarpitServer := &http.Server{Addr: settings.TarpitListen, Handler: tarpitHandler, ReadHeaderTimeout: serverReadHeaderTimeout, IdleTimeout: serverIdleTimeout}
	// trickles as well
	deceptionServer := &http.Server{Addr: settings.Deception.Listen, Handler: deceptionMux(g), ReadHeaderTimeout: serverReadHeaderTimeout, IdleTimeout: serverIdleTimeout}
	servers := []*http.Server{gateServer, tarpitServer, deceptionServer}
	failed := make(chan error, len(servers))
	for _, server := range servers {
		go func() { failed <- server.ListenAndServe() }()
	}
	slog.Info("listening", "gate", settings.Listen, "tarpit", settings.TarpitListen, "deception", settings.Deception.Listen,
		"captcha", g.captcha != nil, "sessions", g.sessions != nil, "crawlers", len(g.crawlers.list))
	err = <-failed
	if !errors.Is(err, http.ErrServerClosed) {
		slog.Error("listener", "err", err)
	}
	gateDestroy(g)
	os.Exit(1)
}
