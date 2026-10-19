package main

import (
	"context"
	"encoding/base64"
	"html/template"
	"log/slog"
	"net/http"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

const (
	// client-ip (modules/traefik/lib/traefik-clientip) writes the real client here on every websecure router
	headerClient = "X-Real-Ip"
	// forwardauth's copy of the request's path and query
	headerForwardedURI = "X-Forwarded-Uri"
	// forwardauth's copy of the request's host, which the router's rule matched (traefik trusts no client's here)
	headerForwardedHost = "X-Forwarded-Host"

	pathAuth    = "/auth"
	pathStrip   = "/strip"
	pathMetrics = "/metrics"

	answerField        = "answer"
	answerBodyBytesMax = 512
	returnQuery        = "return"
	returnBytesMax     = 2048

	// pages drawn at once: a burst of flagged clients waits for a slot instead of spending every core on pngs
	renderSlots = 4
	// a banned client on a route with the tarpit waits this long for its ban page, in one of the tarpit's slots
	banDelay = 10 * time.Second
	// a limited client may retry after this long
	limitedRetryAfterSeconds = 1
	// not 403: crowdsec's probing scenarios count 403s, and a flagged person's page loads are no probe
	captchaStatus = http.StatusTooManyRequests
)

// Verdict is what the gate does with one request.
type Verdict int

const (
	VerdictPass Verdict = iota
	VerdictCaptcha
	VerdictBan
	VerdictLimited
	VerdictUnavailable
	VerdictCount
)

var verdictNames = [VerdictCount]string{"pass", "captcha", "ban", "limited", "unavailable"}

// RouteFlags are a route's gate features, from the query of its forwardauth address (modules/traefik/gate.nix).
type RouteFlags struct {
	Captcha bool
	Limit   bool
	Tarpit  bool
	Scale   int
}

// Captcha is the captcha's state when the ingress asks one.
type Captcha struct {
	key          []byte
	cookieDomain string
	answerPath   string
	// onion address -> its route
	onions     map[string]string
	challenges *Challenges
	renders    chan struct{}
}

// Gate is everything a request is judged by.
type Gate struct {
	allow     *Allow
	sessions  *Sessions
	decisions *Decisions
	limiter   *Limiter
	captcha   *Captcha
	tarpit    *Tarpit
	metrics   *Metrics
	// cookie name -> stripped by /strip
	stripCookies map[string]bool
	// crowdsec's state as last seen, so an outage logs once, not per request
	lapiFailing atomic.Bool
}

// routeFlagsParse reads the forwardauth address's query; anything malformed is the module's bug and stops the route.
func routeFlagsParse(query url.Values) (RouteFlags, bool) {
	scale, err := strconv.Atoi(query.Get("scale"))
	if err != nil || scale < 1 {
		return RouteFlags{}, false
	}
	flag := func(name string) bool { return query.Get(name) == "1" }
	return RouteFlags{Captcha: flag("captcha"), Limit: flag("limit"), Tarpit: flag("tarpit"), Scale: scale}, true
}

// returnPathParse keeps a return target on this host: a path, never a scheme, a host or a protocol-relative url.
func returnPathParse(target string) string {
	if len(target) > returnBytesMax || !strings.HasPrefix(target, "/") || strings.HasPrefix(target, "//") ||
		strings.HasPrefix(target, "/\\") || strings.ContainsAny(target, "\r\n") {
		return "/"
	}
	return target
}

// verdictDecide is the gate's whole policy for a client neither allowed by source nor logged in: crowdsec's
// decision, the route's captcha feature, whether this ingress asks captchas, whether the request is the answer
// itself, and whether the client holds a solved captcha. An ingress without the captcha sits behind one that asks
// it (the internal ingress behind the edge, which sees the same requests), so it leaves captcha decisions to that one.
func verdictDecide(kind DecisionKind, routeCaptcha, captchaEnabled, answering, cookieValid bool) Verdict {
	switch kind {
	case DecisionNone:
		return VerdictPass
	case DecisionBan:
		return VerdictBan
	case DecisionCaptcha:
		if answering || !routeCaptcha || !captchaEnabled || cookieValid {
			return VerdictPass
		}
		return VerdictCaptcha
	case DecisionUnknown:
		// crowdsec is down: a person still gets through by the captcha, a machine waits
		switch {
		case answering, routeCaptcha && captchaEnabled && cookieValid:
			return VerdictPass
		case routeCaptcha && captchaEnabled:
			return VerdictCaptcha
		}
		return VerdictUnavailable
	}
	panic("verdict: no such decision kind")
}

// verdictDecideOnion is the policy for an onion session, which no source, login or crowdsec decision tells apart
// from the others: every session without a solved captcha is asked one, a session failing too many is banned.
func verdictDecideOnion(answering, cookieValid, banned bool) Verdict {
	switch {
	case answering, cookieValid:
		return VerdictPass
	case banned:
		return VerdictBan
	}
	return VerdictCaptcha
}

// onionOf is the onion address a request names, if any: the onion captcha is the owner's rule for every onion
// route, whatever its captcha feature says, for nothing else tells a tor visitor from a bot.
func onionOf(g *Gate, host string) (string, bool) {
	if g.captcha == nil {
		return "", false
	}
	address := hostNormalize(host)
	_, onion := g.captcha.onions[address]
	return address, onion
}

// onionCookieSet sets a cookie for the onion address alone: no domain, and not Secure, the page being plain http
// inside tor's encryption, where a browser that counts no onion as secure would drop a Secure cookie.
func onionCookieSet(w http.ResponseWriter, name, value string, maxAge time.Duration) {
	http.SetCookie(w, &http.Cookie{
		Name:     name,
		Value:    value,
		Path:     "/",
		MaxAge:   int(maxAge / time.Second),
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	})
}

func cookieValid(g *Gate, r *http.Request, client string, now time.Time) bool {
	if g.captcha == nil {
		return false
	}
	cookie, err := r.Cookie(cookieName)
	return err == nil && cookieDecode(g.captcha.key, client, cookie.Value, now)
}

func lapiStateLog(g *Gate, err error) {
	failing := err != nil
	if g.lapiFailing.Swap(failing) == failing {
		return
	}
	if failing {
		slog.Error("crowdsec unreachable: flagged and unknown clients get the captcha or wait", "err", err)
	} else {
		slog.Info("crowdsec reachable again")
	}
}

// captchaPageWrite asks the client its puzzle: a scene, or for an onion session (address set) its route's address
// among lookalikes.
func captchaPageWrite(ctx context.Context, g *Gate, w http.ResponseWriter, client, address, uri string, now time.Time) {
	puzzle, notice, triesLeft, err := challengesShow(g.captcha.challenges, client, address, now)
	if err != nil {
		slog.Error("captcha: answer log", "err", err)
	}
	select {
	case g.captcha.renders <- struct{}{}:
	case <-ctx.Done():
		return
	}
	image, err := puzzleRender(puzzle)
	<-g.captcha.renders
	if err != nil {
		slog.Error("captcha: render", "err", err)
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	wording := sceneWording
	if address != "" {
		wording = onionWording
	}
	size := puzzleSize(puzzle)
	action := g.captcha.answerPath + "?" + url.Values{returnQuery: {returnPathParse(uri)}}.Encode()
	pageWrite(w, captchaStatus, verdictNames[VerdictCaptcha], pageData{
		Title:     wording.title,
		Lead:      wording.lead,
		Captcha:   true,
		Notice:    wording.notices[notice],
		Image:     template.URL("data:image/png;base64," + base64.StdEncoding.EncodeToString(image)),
		Width:     size.X,
		Height:    size.Y,
		Alt:       wording.alt,
		Question:  puzzle.Question,
		Action:    action,
		TriesLeft: triesLeft,
		TriesMax:  g.captcha.challenges.regenerationsMax,
		Subject:   wording.subject,
		Aside:     wording.aside,
	})
}

// banPageRender says how long the ban lasts and why: lead names what is banned, an address or an onion session.
func banPageRender(w http.ResponseWriter, until time.Time, lead string, now time.Time) {
	remaining := until.Sub(now)
	w.Header().Set("Retry-After", strconv.FormatInt(int64(max(remaining, 0)/time.Second), 10))
	pageWrite(w, http.StatusForbidden, verdictNames[VerdictBan], pageData{
		Title: "You have been banned for " + durationHuman(remaining),
		Lead:  lead,
		Until: until.UTC().Format("15:04 UTC on 2 January"),
	})
}

func banPageWrite(ctx context.Context, g *Gate, w http.ResponseWriter, client string, flags RouteFlags, decision Decision, now time.Time) {
	if flags.Tarpit && tarpitAcquire(g.tarpit, client) {
		timer := time.NewTimer(banDelay)
		select {
		case <-timer.C:
		case <-ctx.Done():
		}
		timer.Stop()
		tarpitRelease(g.tarpit, client)
	}
	banPageRender(w, decision.Until, "Requests from this address looked automated to the lab, so it refuses them for now.", now)
}

// gateAuthOnion judges a request to an onion route asking the captcha by its browser's session, never its address:
// every tor visitor arrives from the router, which the allow list, crowdsec and the limits all see as one client.
func gateAuthOnion(ctx context.Context, g *Gate, w http.ResponseWriter, r *http.Request, address, uri string, answering bool, now time.Time) Verdict {
	session, hasSession := onionSessionOf(r)
	client := onionClient(address, session)
	var bannedUntil time.Time
	banned := false
	if hasSession {
		bannedUntil, banned = challengesBanned(g.captcha.challenges, client, now)
	}
	verdict := verdictDecideOnion(answering, hasSession && cookieValid(g, r, client, now), banned)
	switch verdict {
	case VerdictCaptcha:
		if !hasSession {
			session = onionSessionNew()
			client = onionClient(address, session)
			// a browser session's cookie: its puzzles and its ban live as long as the gate remembers them
			onionCookieSet(w, onionSessionCookie, session, 0)
		}
		captchaPageWrite(ctx, g, w, client, address, uri, now)
	case VerdictBan:
		banPageRender(w, bannedUntil, "This browser answered too many puzzles wrong, so the lab refuses it for now.", now)
	}
	return verdict
}

// gateAuth is traefik's forwardauth call for every request of a gated route: 2xx lets it through, anything else is
// the answer its client gets.
func gateAuth(g *Gate, w http.ResponseWriter, r *http.Request) {
	now := time.Now()
	flags, valid := routeFlagsParse(r.URL.Query())
	clientText := r.Header.Get(headerClient)
	client, err := netip.ParseAddr(clientText)
	if !valid || err != nil {
		http.Error(w, "gate: no route flags or client address", http.StatusBadRequest)
		return
	}
	verdict := VerdictPass
	defer func() { metricsAdd(g.metrics, metricVerdicts, verdictNames[verdict], 1) }()
	uri := r.Header.Get(headerForwardedURI)
	path, _, _ := strings.Cut(uri, "?")
	answering := g.captcha != nil && path == g.captcha.answerPath
	if address, onion := onionOf(g, r.Header.Get(headerForwardedHost)); onion {
		verdict = gateAuthOnion(r.Context(), g, w, r, address, uri, answering, now)
		return
	}
	if allowContains(g.allow, client, now) {
		return
	}
	authenticated, err := sessionsAuthenticated(r.Context(), g.sessions, r, now)
	if err != nil {
		metricsAdd(g.metrics, metricErrors, "authelia", 1)
	}
	if authenticated {
		return
	}
	decision, newBan, err := decisionsGet(r.Context(), g.decisions, clientText, now)
	lapiStateLog(g, err)
	if err != nil {
		metricsAdd(g.metrics, metricErrors, "crowdsec", 1)
	}
	if newBan {
		metricsAdd(g.metrics, metricBans, "", 1)
		slog.Info("ban enforced", "client", clientText, "until", decision.Until.UTC())
	}
	needsCookie := decision.Kind == DecisionCaptcha || decision.Kind == DecisionUnknown
	verdict = verdictDecide(decision.Kind, flags.Captcha, g.captcha != nil, answering, needsCookie && cookieValid(g, r, clientText, now))
	if verdict == VerdictPass && flags.Limit && !answering && !limiterTake(g.limiter, clientText, flags.Scale, now) {
		verdict = VerdictLimited
	}
	switch verdict {
	case VerdictPass:
	case VerdictCaptcha:
		captchaPageWrite(r.Context(), g, w, clientText, "", uri, now)
	case VerdictBan:
		banPageWrite(r.Context(), g, w, clientText, flags, decision, now)
	case VerdictLimited:
		w.Header().Set("Retry-After", strconv.Itoa(limitedRetryAfterSeconds))
		pageWrite(w, http.StatusTooManyRequests, verdictNames[verdict], pageData{
			Title: "Too many requests",
			Lead:  "Slow down a little; the lab answers again in a moment.",
		})
	case VerdictUnavailable:
		w.Header().Set("Retry-After", strconv.Itoa(int(decisionCacheTTL/time.Second)))
		pageWrite(w, http.StatusServiceUnavailable, verdictNames[verdict], pageData{
			Title: "The lab cannot check this address right now",
			Lead:  "Try again in a few seconds.",
		})
	case VerdictCount:
		panic("gate: no such verdict")
	}
}

// gateAnswer takes the captcha form: one try, then back to where the client was going, with a cookie if it was right.
func gateAnswer(g *Gate, w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	now := time.Now()
	client := r.Header.Get(headerClient)
	if _, err := netip.ParseAddr(client); err != nil {
		http.Error(w, "gate: no client address", http.StatusBadRequest)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, answerBodyBytesMax)
	// an oversized or malformed body is an empty answer: wrong, like any other
	_ = r.ParseForm()
	address, onion := onionOf(g, r.Host)
	session, hasSession := onionSessionOf(r)
	if onion {
		client = onionClient(address, session)
	}
	// an onion answer without a session has no puzzle: expired, and no state for the empty session to share
	outcome := OutcomeExpired
	if !onion || hasSession {
		outcome = challengesAnswer(g.captcha.challenges, client, r.PostForm.Get(answerField), now)
	}
	metricsAdd(g.metrics, metricAnswers, outcomeNames[outcome], 1)
	if outcome == OutcomeDecoy {
		metricsAdd(g.metrics, metricOnionDecoys, g.captcha.onions[address], 1)
	}
	slog.Info("captcha answer", "client", client, "outcome", outcomeNames[outcome])
	switch {
	case outcome != OutcomeSolved:
	case onion:
		onionCookieSet(w, cookieName, cookieEncode(g.captcha.key, client, now.Add(cookieLifetime)), cookieLifetime)
	default:
		http.SetCookie(w, &http.Cookie{
			Name:     cookieName,
			Value:    cookieEncode(g.captcha.key, client, now.Add(cookieLifetime)),
			Domain:   g.captcha.cookieDomain,
			Path:     "/",
			MaxAge:   int(cookieLifetime / time.Second),
			Secure:   true,
			HttpOnly: true,
			SameSite: http.SameSiteLaxMode,
		})
	}
	w.Header().Set("Cache-Control", pageCacheControl)
	w.Header().Set(headerOutcome, outcomeNames[outcome])
	http.Redirect(w, r, returnPathParse(r.URL.Query().Get(returnQuery)), http.StatusSeeOther)
}

func gateMetrics(g *Gate, w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	if err := metricsRender(g.metrics, w); err != nil {
		slog.Warn("metrics: render", "err", err)
	}
}

// gateMux routes the gate's own listener; traefik reaches it for forwardauth and the answer, the metrics timer locally.
func gateMux(g *Gate) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc(pathAuth, func(w http.ResponseWriter, r *http.Request) { gateAuth(g, w, r) })
	mux.HandleFunc(pathStrip, func(w http.ResponseWriter, r *http.Request) { gateStrip(g, w, r) })
	mux.HandleFunc(pathMetrics, func(w http.ResponseWriter, r *http.Request) { gateMetrics(g, w, r) })
	if g.captcha != nil {
		mux.HandleFunc(g.captcha.answerPath, func(w http.ResponseWriter, r *http.Request) { gateAnswer(g, w, r) })
	}
	return mux
}
