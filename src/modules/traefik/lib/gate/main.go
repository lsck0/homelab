// Command lab-gate is the ingress's gate in front of every protected route (modules/traefik/gate.nix): it turns
// crowdsec's decisions into pages a person can read and act on, asks flagged clients a captcha, limits anonymous
// clients below the ingress's own limit, and trickles the bot labyrinth.
//
// One process, two loopback listeners. The gate's own: traefik's forwardauth calls /auth?captcha=&limit=&tarpit=&scale=
// for every request of a gated route (2xx passes it, any other answer is the client's), the captcha form posts to the
// answer path, a timer reads /metrics. The tarpit's: the labyrinth routers' service, proxying iocaine a few bytes at a
// time.
//
// A request is judged in this order, cheapest and most trusted first:
//   - the source is allowed (the house, the lab, wireguard, loopback, the house's public address): pass
//   - it carries an authelia session authelia confirms: pass, whatever crowdsec says
//   - crowdsec's decision for the client (ban beats captcha), cached for seconds: verdictDecide
//   - an anonymous client over its token bucket: 429
//
// The captcha: one scene of labelled shapes per client, drawn from a seed only the gate knows, one question needing
// the picture to answer, exactly six hex characters, one try. A wrong or late answer regenerates the puzzle and is
// marked in the response (X-Lab-Gate: wrong|expired); crowdsec reads the access log and bans the client after too
// many (modules/traefik/lib/ladder.nix). A right one sets a cookie, an hmac over the client's address and an expiry,
// that passes the client's captcha decisions until it expires.
//
// Rejected: the bouncer plugin's captcha. It serves hcaptcha, recaptcha or turnstile, or a "custom" provider whose
// page loads the provider's script and checks a token at its server; none is offline, script-free or self-hosted, and
// its ban page is a fixed file that cannot say how long a ban lasts.
//
//	lab-gate -settings /etc/lab-gate/settings.json
package main

import (
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"time"
)

/*
 * -----------------------------------------------------------------------------
 * CONSTANTS
 * -----------------------------------------------------------------------------
 */

const (
	// traefik is the only caller, on loopback: these bound a stuck connection, never a slow client
	serverReadHeaderTimeout = 5 * time.Second
	serverIdleTimeout       = 2 * time.Minute
	// at least 256 bits, as hmac-sha256 uses them
	captchaKeyBytesMin = 32
)

/*
 * -----------------------------------------------------------------------------
 * LIFETIME
 * -----------------------------------------------------------------------------
 */

func gateCreate(settings Settings) (*Gate, error) {
	lapiKey, err := keyFileLoad(settings.Lapi.KeyFile, 0)
	if err != nil {
		return nil, fmt.Errorf("crowdsec bouncer key: %w", err)
	}
	metrics := metricsCreate()
	g := &Gate{
		allow:     allowCreate(settings.Allow),
		decisions: decisionsCreate(settings.Lapi.URL, string(lapiKey)),
		limiter:   limiterCreate(settings.Anonymous),
		tarpit:    tarpitCreate(settings.Tarpit.Upstream, metrics),
		metrics:   metrics,
	}
	if settings.Session != nil {
		g.sessions = sessionsCreate(*settings.Session)
	}
	if c := settings.Captcha; c != nil {
		key, err := keyFileLoad(c.KeyFile, captchaKeyBytesMin)
		if err != nil {
			return nil, fmt.Errorf("captcha key: %w", err)
		}
		challenges, err := challengesCreate(c.RegenerationsMax, c.AnswerLog)
		if err != nil {
			return nil, fmt.Errorf("captcha answer log: %w", err)
		}
		g.captcha = &Captcha{key: key, cookieDomain: c.CookieDomain, answerPath: c.AnswerPath, challenges: challenges,
			renders: make(chan struct{}, renderSlots)}
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
	limiterDestroy(g.limiter)
	decisionsDestroy(g.decisions)
	sessionsDestroy(g.sessions)
	allowDestroy(g.allow)
	metricsDestroy(g.metrics)
}

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

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
	failed := make(chan error, 2)
	for _, server := range []*http.Server{gateServer, tarpitServer} {
		go func() { failed <- server.ListenAndServe() }()
	}
	slog.Info("listening", "gate", settings.Listen, "tarpit", settings.TarpitListen, "captcha", g.captcha != nil, "sessions", g.sessions != nil)
	err = <-failed
	if !errors.Is(err, http.ErrServerClosed) {
		slog.Error("listener", "err", err)
	}
	gateDestroy(g)
	os.Exit(1)
}
