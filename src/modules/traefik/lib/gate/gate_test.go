package main

import (
	"bytes"
	"fmt"
	"image/png"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
)

/*
 * -----------------------------------------------------------------------------
 * PUZZLE
 * -----------------------------------------------------------------------------
 */

// the generator's bound holds: every seed yields a well-posed puzzle, its answer six hex characters taken from a
// plate (or a plate backwards), its wording naming no label
func TestPuzzleEverySeedPosed(t *testing.T) {
	const seeds = 20000
	hex := regexp.MustCompile(`^[0-9a-f]{6}$`)
	for seed := range uint64(seeds) {
		puzzle := puzzleFromSeed(seed, len(shapeColors))
		if !hex.MatchString(puzzle.Answer) {
			t.Fatalf("seed %d: answer %q", seed, puzzle.Answer)
		}
		fromPlate := false
		for _, o := range puzzle.Objects {
			if strings.Contains(puzzle.Question, o.Label) {
				t.Fatalf("seed %d: question %q names label %s", seed, puzzle.Question, o.Label)
			}
			if o.Label == puzzle.Answer || labelReverse(o.Label) == puzzle.Answer {
				fromPlate = true
			}
		}
		if !fromPlate {
			t.Fatalf("seed %d: answer %s is on no plate", seed, puzzle.Answer)
		}
	}
}

func TestPuzzleSeedDeterministic(t *testing.T) {
	for _, seed := range []uint64{0, 1, 42, 1 << 63} {
		a, b := puzzleFromSeed(seed, len(shapeColors)), puzzleFromSeed(seed, len(shapeColors))
		if a.Question != b.Question || a.Answer != b.Answer || len(a.Objects) != len(b.Objects) {
			t.Fatalf("seed %d: two puzzles", seed)
		}
	}
	if puzzleFromSeed(1, len(shapeColors)).Answer == puzzleFromSeed(2, len(shapeColors)).Answer {
		t.Fatal("seeds 1 and 2 share an answer")
	}
}

func TestAnswerNormalize(t *testing.T) {
	cases := []struct {
		typed  string
		answer string
		valid  bool
	}{
		{"3fa9c1", "3fa9c1", true},
		{"3FA9C1", "3fa9c1", true},
		{"0x3fa9c1", "3fa9c1", true},
		{"0X3Fa9c1", "3fa9c1", true},
		{"  3fa9c1 ", "3fa9c1", true},
		{"3fa9c", "", false},
		{"3fa9c12", "", false},
		{"3fa9cg", "", false},
		{"0x", "", false},
		{"", "", false},
		{"x3fa9c1", "", false},
	}
	for _, c := range cases {
		answer, valid := answerNormalize(c.typed)
		if answer != c.answer || valid != c.valid {
			t.Errorf("%q: got %q %v, want %q %v", c.typed, answer, valid, c.answer, c.valid)
		}
	}
}

func TestPuzzleRenderPng(t *testing.T) {
	image, err := puzzleRender(puzzleFromSeed(7, len(shapeColors)))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(image), "\x89PNG") {
		t.Fatal("not a png")
	}
}

/*
 * -----------------------------------------------------------------------------
 * COOKIE
 * -----------------------------------------------------------------------------
 */

func TestCookie(t *testing.T) {
	key := []byte(strings.Repeat("k", captchaKeyBytesMin))
	now := time.Unix(1_700_000_000, 0)
	value := cookieEncode(key, "203.0.113.9", now.Add(cookieLifetime))
	cases := []struct {
		name   string
		key    []byte
		client string
		value  string
		at     time.Time
		valid  bool
	}{
		{"its client, in time", key, "203.0.113.9", value, now, true},
		{"another client", key, "203.0.113.10", value, now, false},
		{"expired", key, "203.0.113.9", value, now.Add(cookieLifetime), false},
		{"another key", []byte(strings.Repeat("x", captchaKeyBytesMin)), "203.0.113.9", value, now, false},
		{"expiry moved", key, "203.0.113.9", "9" + value, now, false},
		{"mac flipped", key, "203.0.113.9", value[:len(value)-1] + "A", now, false},
		{"no separator", key, "203.0.113.9", "garbage", now, false},
		{"empty", key, "203.0.113.9", "", now, false},
	}
	for _, c := range cases {
		if got := cookieDecode(c.key, c.client, c.value, c.at); got != c.valid {
			t.Errorf("%s: got %v", c.name, got)
		}
	}
}

/*
 * -----------------------------------------------------------------------------
 * VERDICT
 * -----------------------------------------------------------------------------
 */

// the policy, every combination: a ban always stops, a captcha decision asks unless the route opts out, the request
// is the answer, a cookie proves a solve or the ingress asks none; crowdsec down asks too
func TestVerdictDecide(t *testing.T) {
	for kind := DecisionNone; kind <= DecisionUnknown; kind++ {
		for bits := range 16 {
			routeCaptcha, captchaEnabled, answering, cookie := bits&1 != 0, bits&2 != 0, bits&4 != 0, bits&8 != 0
			got := verdictDecide(kind, routeCaptcha, captchaEnabled, answering, cookie)
			var want Verdict
			switch kind {
			case DecisionNone:
				want = VerdictPass
			case DecisionBan:
				want = VerdictBan
			case DecisionCaptcha:
				want = VerdictCaptcha
				if answering || !routeCaptcha || !captchaEnabled || cookie {
					want = VerdictPass
				}
			case DecisionUnknown:
				switch {
				case answering || (routeCaptcha && captchaEnabled && cookie):
					want = VerdictPass
				case routeCaptcha && captchaEnabled:
					want = VerdictCaptcha
				default:
					want = VerdictUnavailable
				}
			}
			if got != want {
				t.Errorf("kind %d route %v enabled %v answering %v cookie %v: got %s, want %s",
					kind, routeCaptcha, captchaEnabled, answering, cookie, verdictNames[got], verdictNames[want])
			}
		}
	}
}

func TestDecisionFromLapi(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	cases := []struct {
		body  string
		kind  DecisionKind
		until time.Duration
		banID int64
		err   bool
	}{
		{`null`, DecisionNone, 0, 0, false},
		{`[]`, DecisionNone, 0, 0, false},
		{`[{"id":3,"type":"captcha","duration":"3h59m1.5s"}]`, DecisionCaptcha, 3*time.Hour + 59*time.Minute + 1500*time.Millisecond, 0, false},
		{`[{"id":3,"type":"captcha","duration":"4h"},{"id":4,"type":"ban","duration":"10m"}]`, DecisionBan, 10 * time.Minute, 4, false},
		{`[{"id":5,"type":"ban","duration":"10m"},{"id":4,"type":"ban","duration":"1h"}]`, DecisionBan, time.Hour, 4, false},
		{`[{"id":6,"type":"throttle","duration":"1m"}]`, DecisionBan, time.Minute, 6, false},
		{`[{"id":7,"type":"ban","duration":"soon"}]`, DecisionNone, 0, 0, true},
		{`{`, DecisionNone, 0, 0, true},
	}
	for _, c := range cases {
		decision, err := decisionFromLapi([]byte(c.body), now)
		if (err != nil) != c.err {
			t.Errorf("%s: err %v", c.body, err)
			continue
		}
		if c.err {
			continue
		}
		if decision.Kind != c.kind || decision.BanID != c.banID || (c.kind != DecisionNone && !decision.Until.Equal(now.Add(c.until))) {
			t.Errorf("%s: got %+v", c.body, decision)
		}
	}
}

func TestDurationHuman(t *testing.T) {
	cases := map[time.Duration]string{
		59 * time.Second:                           "less than a minute",
		time.Minute:                                "1 minute",
		59*time.Minute + 59*time.Second:            "59 minutes",
		time.Hour:                                  "1 hour",
		3*time.Hour + 59*time.Minute:               "3 hours 59 minutes",
		3*time.Hour + 30*time.Second:               "3 hours",
		26 * time.Hour:                             "1 day 2 hours",
		7*24*time.Hour + 5*time.Minute:             "7 days",
		2*24*time.Hour + time.Hour + 9*time.Minute: "2 days 1 hour",
	}
	for d, want := range cases {
		if got := durationHuman(d); got != want {
			t.Errorf("%v: got %q, want %q", d, got, want)
		}
	}
}

func TestReturnPathParse(t *testing.T) {
	cases := map[string]string{
		"/":                     "/",
		"/a/b?c=d":              "/a/b?c=d",
		"":                      "/",
		"https://evil.example/": "/",
		"//evil.example/":       "/",
		"/\\evil.example":       "/",
		"evil":                  "/",
		"/a\r\nSet-Cookie: x":   "/",
		"/" + strings.Repeat("a", returnBytesMax): "/",
	}
	for target, want := range cases {
		if got := returnPathParse(target); got != want {
			t.Errorf("%q: got %q", target, got)
		}
	}
}

/*
 * -----------------------------------------------------------------------------
 * STATE
 * -----------------------------------------------------------------------------
 */

func TestChallengesOneTry(t *testing.T) {
	const regenerationsMax = 5
	c, err := challengesCreate(regenerationsMax, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer challengesDestroy(c)
	now := time.Unix(1_700_000_000, 0)
	const client = "203.0.113.9"

	if got := challengesAnswer(c, client, "000000", now); got != OutcomeExpired {
		t.Fatalf("an answer without a puzzle: %s", outcomeNames[got])
	}
	first, notice, tries, _ := challengesShow(c, client, "", now)
	if notice != NoticeExpired || tries != regenerationsMax-1 {
		t.Fatalf("after one failure: notice %d tries %d", notice, tries)
	}
	again, notice, _, _ := challengesShow(c, client, "", now.Add(time.Second))
	if again.Answer != first.Answer || notice != NoticeNone {
		t.Fatal("a reload changed the puzzle or repeated the notice")
	}
	wrong := labelReverse(first.Answer)
	if wrong == first.Answer {
		t.Fatal("a palindrome answer")
	}
	if got := challengesAnswer(c, client, wrong, now); got != OutcomeWrong {
		t.Fatalf("a wrong answer: %s", outcomeNames[got])
	}
	// the right answer to a spent puzzle is worth nothing
	if got := challengesAnswer(c, client, first.Answer, now); got != OutcomeExpired {
		t.Fatalf("a second try: %s", outcomeNames[got])
	}
	second, _, tries, _ := challengesShow(c, client, "", now)
	if tries != regenerationsMax-3 {
		t.Fatalf("after three failures: tries %d", tries)
	}
	if got := challengesAnswer(c, client, "0x"+strings.ToUpper(second.Answer), now.Add(puzzleLifetime)); got != OutcomeExpired {
		t.Fatalf("a late answer: %s", outcomeNames[got])
	}
	third, _, _, _ := challengesShow(c, client, "", now)
	if got := challengesAnswer(c, client, "0x"+strings.ToUpper(third.Answer), now); got != OutcomeSolved {
		t.Fatalf("the right answer: %s", outcomeNames[got])
	}
	// failures leave the window after an hour
	_, _, tries, _ = challengesShow(c, client, "", now.Add(failureWindow))
	if tries != regenerationsMax {
		t.Fatalf("an hour later: tries %d", tries)
	}
}

func TestLimiter(t *testing.T) {
	l := limiterCreate(SettingsAnonymous{AveragePerSecond: 2, Burst: 4})
	defer limiterDestroy(l)
	now := time.Unix(1_700_000_000, 0)
	for scale, burst := range map[int]int{1: 4, 3: 12} {
		for i := range burst {
			if !limiterTake(l, "203.0.113.9", scale, now) {
				t.Fatalf("scale %d: request %d of the burst refused", scale, i)
			}
		}
		if limiterTake(l, "203.0.113.9", scale, now) {
			t.Fatalf("scale %d: past the burst", scale)
		}
		if !limiterTake(l, "203.0.113.9", scale, now.Add(time.Second/time.Duration(scale))) {
			t.Fatalf("scale %d: no refill", scale)
		}
	}
	if !limiterTake(l, "203.0.113.10", 1, now) {
		t.Fatal("another client shares the bucket")
	}
}

func TestTableBound(t *testing.T) {
	const countMax = 8
	tbl := tableCreate[int](countMax)
	defer tableDestroy(tbl)
	for i := range 10 * countMax {
		tbl.mu.Lock()
		tableRoomMake(tbl, func(v int) bool { return v%2 == 0 })
		tbl.entries[fmt.Sprint(i)] = i
		if len(tbl.entries) > countMax {
			t.Fatalf("%d entries", len(tbl.entries))
		}
		tbl.mu.Unlock()
	}
}

func TestTarpitBounds(t *testing.T) {
	tp := tarpitCreate("http://127.0.0.1:1", metricsCreate())
	defer tarpitDestroy(tp)
	tp.totalMax = 3
	for range tarpitPerClientMax {
		if !tarpitAcquire(tp, "a") {
			t.Fatal("a client's first trickles refused")
		}
	}
	if tarpitAcquire(tp, "a") {
		t.Fatal("past the per-client bound")
	}
	if !tarpitAcquire(tp, "b") || tarpitAcquire(tp, "c") {
		t.Fatal("the total bound is not 3")
	}
	tarpitRelease(tp, "a")
	if !tarpitAcquire(tp, "c") {
		t.Fatal("a released slot stays taken")
	}
}

/*
 * -----------------------------------------------------------------------------
 * END TO END
 * -----------------------------------------------------------------------------
 */

type gateFixture struct {
	gate      *Gate
	decisions map[string]string
	server    *httptest.Server
}

func gateFixtureCreate(t *testing.T) *gateFixture {
	t.Helper()
	f := &gateFixture{decisions: map[string]string{}}
	lapi := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get(lapiKeyHeader) != "bouncer-key" {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		body, found := f.decisions[r.URL.Query().Get("ip")]
		if !found {
			body = "null"
		}
		io.WriteString(w, body)
	}))
	t.Cleanup(lapi.Close)
	labyrinth := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		io.WriteString(w, strings.Repeat("nonsense ", 8))
	}))
	t.Cleanup(labyrinth.Close)
	metrics := metricsCreate()
	challenges, err := challengesCreate(5, nil)
	if err != nil {
		t.Fatal(err)
	}
	f.gate = &Gate{
		allow:     allowCreate(SettingsAllow{Cidrs: []string{"10.0.0.0/8"}}),
		decisions: decisionsCreate(lapi.URL, "bouncer-key"),
		limiter:   limiterCreate(SettingsAnonymous{AveragePerSecond: 1, Burst: 3}),
		tarpit:    tarpitCreate(labyrinth.URL, metrics),
		metrics:   metrics,
		captcha: &Captcha{key: []byte(strings.Repeat("k", captchaKeyBytesMin)), cookieDomain: "lsck0.dev",
			answerPath: "/.lab-gate/answer", onions: map[string]string{testOnion: testOnionRoute}, challenges: challenges,
			renders: make(chan struct{}, renderSlots)},
	}
	f.gate.tarpit.interval = time.Millisecond
	f.server = httptest.NewServer(gateMux(f.gate))
	t.Cleanup(f.server.Close)
	return f
}

func gateFixtureAuth(t *testing.T, f *gateFixture, client, query string, cookies ...*http.Cookie) (int, string, http.Header) {
	t.Helper()
	return gateFixtureAuthHost(t, f, testHost, client, query, cookies...)
}

func gateFixtureAuthHost(t *testing.T, f *gateFixture, host, client, query string, cookies ...*http.Cookie) (int, string, http.Header) {
	t.Helper()
	request, _ := http.NewRequest(http.MethodGet, f.server.URL+pathAuth+"?"+query, nil)
	request.Header.Set(headerClient, client)
	request.Header.Set(headerForwardedURI, "/page?x=1")
	request.Header.Set(headerForwardedHost, host)
	for _, cookie := range cookies {
		request.AddCookie(cookie)
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(response.Body)
	return response.StatusCode, string(body), response.Header
}

func gateFixtureAnswer(t *testing.T, f *gateFixture, client, answer string) *http.Response {
	t.Helper()
	return gateFixtureAnswerHost(t, f, testHost, client, answer)
}

func gateFixtureAnswerHost(t *testing.T, f *gateFixture, host, client, answer string, cookies ...*http.Cookie) *http.Response {
	t.Helper()
	form := url.Values{answerField: {answer}}
	request, _ := http.NewRequest(http.MethodPost, f.server.URL+"/.lab-gate/answer?return=%2Fpage%3Fx%3D1", strings.NewReader(form.Encode()))
	request.Host = host
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	request.Header.Set(headerClient, client)
	for _, cookie := range cookies {
		request.AddCookie(cookie)
	}
	noRedirect := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	response, err := noRedirect.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	return response
}

const routeAll = "captcha=1&limit=1&tarpit=0&scale=1"

func TestGateCaptchaFlow(t *testing.T) {
	f := gateFixtureCreate(t)
	const client = "203.0.113.9"
	f.decisions[client] = `[{"id":1,"type":"captcha","duration":"4h"}]`

	status, page, header := gateFixtureAuth(t, f, client, routeAll)
	if status != captchaStatus || header.Get(headerOutcome) != "captcha" {
		t.Fatalf("a flagged client: %d %s", status, header.Get(headerOutcome))
	}
	answer := puzzleFromSeed(f.gate.captcha.challenges.clients.entries[client].seed, len(shapeColors)).Answer
	for _, forbidden := range []string{"<script", answer, "javascript:"} {
		if strings.Contains(strings.ToLower(page), forbidden) {
			t.Fatalf("the page contains %q", forbidden)
		}
	}
	if strings.Count(page, "<input") != 1 || !strings.Contains(page, `src="data:image/png;base64,`) {
		t.Fatal("the page is not one text box and one image")
	}
	if !strings.Contains(header.Get("Content-Security-Policy"), "'sha256-"+cssDigest()+"'") {
		t.Fatal("the csp does not admit the page's own style")
	}

	response := gateFixtureAnswer(t, f, client, labelReverse(answer))
	if response.Header.Get(headerOutcome) != "wrong" || response.Header.Get("Location") != "/page?x=1" || len(response.Cookies()) != 0 {
		t.Fatalf("a wrong answer: %s %s", response.Header.Get(headerOutcome), response.Header.Get("Location"))
	}
	_, page, _ = gateFixtureAuth(t, f, client, routeAll)
	if !strings.Contains(page, "not right") {
		t.Fatal("the new puzzle does not say the answer was wrong")
	}
	answer = puzzleFromSeed(f.gate.captcha.challenges.clients.entries[client].seed, len(shapeColors)).Answer
	response = gateFixtureAnswer(t, f, client, strings.ToUpper(answer))
	cookies := response.Cookies()
	if response.Header.Get(headerOutcome) != "solved" || len(cookies) != 1 || cookies[0].Domain != "lsck0.dev" || !cookies[0].Secure || !cookies[0].HttpOnly {
		t.Fatalf("the right answer: %s %v", response.Header.Get(headerOutcome), cookies)
	}
	if status, _, _ := gateFixtureAuth(t, f, client, routeAll, cookies[0]); status != http.StatusOK {
		t.Fatalf("with the cookie: %d", status)
	}
	if status, _, _ := gateFixtureAuth(t, f, "203.0.113.10", routeAll, cookies[0]); status != http.StatusOK {
		t.Fatalf("an unflagged client: %d", status)
	}
	f.decisions["203.0.113.11"] = f.decisions[client]
	if status, _, _ := gateFixtureAuth(t, f, "203.0.113.11", routeAll, cookies[0]); status != captchaStatus {
		t.Fatalf("a flagged client with another's cookie: %d", status)
	}
	// a route that opts out lets a captcha decision through
	if status, _, _ := gateFixtureAuth(t, f, "203.0.113.11", "captcha=0&limit=1&tarpit=0&scale=1"); status != http.StatusOK {
		t.Fatalf("captcha off: %d", status)
	}
}

func TestGateBanAndAllow(t *testing.T) {
	f := gateFixtureCreate(t)
	f.decisions["203.0.113.66"] = `[{"id":9,"type":"ban","duration":"3h59m30s"}]`
	f.decisions["10.1.2.3"] = f.decisions["203.0.113.66"]
	status, page, header := gateFixtureAuth(t, f, "203.0.113.66", routeAll)
	if status != http.StatusForbidden || !strings.Contains(page, "You have been banned for 3 hours 59 minutes") {
		t.Fatalf("a banned client: %d", status)
	}
	if retry := header.Get("Retry-After"); retry != "14370" {
		t.Fatalf("retry-after %s", retry)
	}
	if status, _, _ := gateFixtureAuth(t, f, "10.1.2.3", routeAll); status != http.StatusOK {
		t.Fatalf("an allowed source with a ban: %d", status)
	}
	var metrics strings.Builder
	if err := metricsRender(f.gate.metrics, &metrics); err != nil || !strings.Contains(metrics.String(), "homelab_gate_bans_total 1\n") {
		t.Fatalf("metrics:\n%s", metrics.String())
	}
}

func TestGateAnonymousLimit(t *testing.T) {
	f := gateFixtureCreate(t)
	codes := map[int]int{}
	for range 6 {
		status, _, _ := gateFixtureAuth(t, f, "203.0.113.20", routeAll)
		codes[status]++
	}
	if codes[http.StatusOK] != 3 || codes[http.StatusTooManyRequests] != 3 {
		t.Fatalf("anonymous burst 3: %v", codes)
	}
	if status, _, _ := gateFixtureAuth(t, f, "203.0.113.20", "captcha=1&limit=0&tarpit=0&scale=1"); status != http.StatusOK {
		t.Fatalf("limit off: %d", status)
	}
}

func TestTarpitServe(t *testing.T) {
	f := gateFixtureCreate(t)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { tarpitServe(f.gate.tarpit, w, r) }))
	defer server.Close()
	request, _ := http.NewRequest(http.MethodGet, server.URL+"/.env", nil)
	request.Header.Set(headerClient, "203.0.113.30")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if string(body) != strings.Repeat("nonsense ", 8) {
		t.Fatalf("trickled %q", body)
	}
}

/*
 * -----------------------------------------------------------------------------
 * ONION
 * -----------------------------------------------------------------------------
 */

const (
	// hello's address (src/generated/onions.json)
	testOnion      = "tqxs4mr42gshsz5u6x472i3adx3bltm7hyn4tn664w3q72p7a6pguzad.onion"
	testOnionRoute = "hello"
	testHost       = "wat.lsck0.dev"
	// every tor visitor's address at the gate: the router, a private address the allow list passes
	testRouter = "10.30.0.1"
)

func TestOnionAddressValid(t *testing.T) {
	cases := map[string]bool{
		testOnion:                  true,
		strings.ToUpper(testOnion): false,
		strings.TrimSuffix(testOnion, onionSuffix): false,
		testOnion[1:]:       false,
		"0" + testOnion[1:]: false,
		testHost:            false,
		"":                  false,
	}
	for address, valid := range cases {
		if got := onionAddressValid(address); got != valid {
			t.Errorf("%q: got %v", address, got)
		}
	}
	if _, err := onionRoutes(map[string]string{"a": testOnion, "b": testOnion}); err == nil {
		t.Fatal("two routes share an address")
	}
	if _, err := onionRoutes(map[string]string{"a": testHost}); err == nil {
		t.Fatal("a name that is no onion address")
	}
}

func TestHostNormalize(t *testing.T) {
	for host, want := range map[string]string{
		testOnion:                          testOnion,
		strings.ToUpper(testOnion) + ":80": testOnion,
		"Wat.Lsck0.Dev":                    testHost,
	} {
		if got := hostNormalize(host); got != want {
			t.Errorf("%q: got %q", host, got)
		}
	}
}

// every glyph the rows and plates set is in the font, five columns by seven rows
func TestGlyphsCover(t *testing.T) {
	for _, char := range onionAlphabet + onionSuffix + hexDigits {
		glyph, found := glyphs[char]
		if !found {
			t.Fatalf("no glyph for %q", char)
		}
		for _, row := range glyph {
			if len(row) != glyphColumns {
				t.Fatalf("glyph %q: row %q", char, row)
			}
		}
	}
}

// the rows over seeds: the real address once, decoys alike at both ends yet distinct, the real row's label the
// answer, every other row's label a decoy answer, none naming another
func TestOnionPuzzleEverySeed(t *testing.T) {
	const seeds = 5000
	prefix, suffix := testOnion[:onionKeptPrefix], testOnion[onionKeyChars-onionKeptSuffix:]
	backwards := 0
	for seed := range uint64(seeds) {
		puzzle := onionPuzzleFromSeed(seed, testOnion)
		if len(puzzle.Rows) != onionRows || len(puzzle.Decoys) != onionRows-1 || len(puzzle.Objects) != 0 {
			t.Fatalf("seed %d: %d rows, %d decoys", seed, len(puzzle.Rows), len(puzzle.Decoys))
		}
		reversed := strings.HasSuffix(puzzle.Question, backwardsSentence)
		if reversed {
			backwards++
		}
		addresses, answers := map[string]bool{}, map[string]bool{}
		realRows := 0
		for _, row := range puzzle.Rows {
			if !onionAddressValid(row.Address) || !strings.HasPrefix(row.Address, prefix) || !strings.HasSuffix(row.Address, suffix) {
				t.Fatalf("seed %d: row %s is no lookalike", seed, row.Address)
			}
			answer := row.Code
			if reversed {
				answer = labelReverse(answer)
			}
			addresses[row.Address], answers[answer] = true, true
			if row.Address == testOnion {
				realRows++
				if answer != puzzle.Answer {
					t.Fatalf("seed %d: the real row says %s, the answer is %s", seed, answer, puzzle.Answer)
				}
			} else if !slices.Contains(puzzle.Decoys, answer) {
				t.Fatalf("seed %d: decoy row %s's label is no decoy answer", seed, row.Address)
			}
		}
		if realRows != 1 || len(addresses) != onionRows || len(answers) != onionRows || slices.Contains(puzzle.Decoys, puzzle.Answer) {
			t.Fatalf("seed %d: %d real rows, %d addresses, %d answers", seed, realRows, len(addresses), len(answers))
		}
	}
	if backwards == 0 || backwards == seeds {
		t.Fatalf("%d of %d puzzles backwards", backwards, seeds)
	}
	positions := map[int]bool{}
	for seed := range uint64(64) {
		positions[slices.IndexFunc(onionPuzzleFromSeed(seed, testOnion).Rows, func(r Row) bool { return r.Address == testOnion })] = true
	}
	if len(positions) != onionRows {
		t.Fatalf("the real row stands in %d of %d places", len(positions), onionRows)
	}
}

func TestOnionPuzzleRenderPng(t *testing.T) {
	puzzle := onionPuzzleFromSeed(7, testOnion)
	data, err := puzzleRender(puzzle)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	if size := decoded.Bounds().Size(); size != puzzleSize(puzzle) || size.Y >= canvasHeightPx {
		t.Fatalf("size %v", size)
	}
}

func TestVerdictDecideOnion(t *testing.T) {
	for bits := range 8 {
		answering, cookie, banned := bits&1 != 0, bits&2 != 0, bits&4 != 0
		want := VerdictCaptcha
		switch {
		case answering || cookie:
			want = VerdictPass
		case banned:
			want = VerdictBan
		}
		if got := verdictDecideOnion(answering, cookie, banned); got != want {
			t.Errorf("answering %v cookie %v banned %v: got %s", answering, cookie, banned, verdictNames[got])
		}
	}
}

// an onion session's state: a decoy's label counts as a failure of its own kind, past the limit the session alone is
// banned for an hour, and the count starts over after
func TestChallengesOnion(t *testing.T) {
	const regenerationsMax = 5
	c, err := challengesCreate(regenerationsMax, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer challengesDestroy(c)
	now := time.Unix(1_700_000_000, 0)
	a, b := onionClient(testOnion, onionSessionNew()), onionClient(testOnion, onionSessionNew())

	puzzle, _, _, _ := challengesShow(c, a, testOnion, now)
	if len(puzzle.Rows) != onionRows {
		t.Fatal("an onion session got no rows")
	}
	if got := challengesAnswer(c, a, puzzle.Decoys[0], now); got != OutcomeDecoy {
		t.Fatalf("a decoy's label: %s", outcomeNames[got])
	}
	_, notice, tries, _ := challengesShow(c, a, testOnion, now)
	if notice != NoticeDecoy || tries != regenerationsMax-1 {
		t.Fatalf("after a decoy: notice %d tries %d", notice, tries)
	}
	for range regenerationsMax {
		if _, banned := challengesBanned(c, a, now); banned {
			t.Fatal("banned within the limit")
		}
		challengesShow(c, a, testOnion, now)
		challengesAnswer(c, a, "000000", now)
	}
	until, banned := challengesBanned(c, a, now)
	if !banned || !until.Equal(now.Add(onionBanDuration)) {
		t.Fatalf("past the limit: banned %v until %v", banned, until)
	}
	if _, banned := challengesBanned(c, b, now); banned {
		t.Fatal("another session of the same router is banned")
	}
	shown, _, _, _ := challengesShow(c, b, testOnion, now)
	if got := challengesAnswer(c, b, shown.Answer, now); got != OutcomeSolved {
		t.Fatalf("another session's right answer: %s", outcomeNames[got])
	}
	if _, banned := challengesBanned(c, a, now.Add(onionBanDuration)); banned {
		t.Fatal("the ban outlasts its hour")
	}
	if _, _, tries, _ := challengesShow(c, a, testOnion, now.Add(onionBanDuration)); tries != regenerationsMax {
		t.Fatalf("after the ban: tries %d", tries)
	}
}

func onionPuzzleOf(f *gateFixture, session string) Puzzle {
	f.gate.captcha.challenges.clients.mu.Lock()
	defer f.gate.captcha.challenges.clients.mu.Unlock()
	return onionPuzzleFromSeed(f.gate.captcha.challenges.clients.entries[onionClient(testOnion, session)].seed, testOnion)
}

func cookieNamed(cookies []*http.Cookie, name string) *http.Cookie {
	for _, cookie := range cookies {
		if cookie.Name == name {
			return cookie
		}
	}
	return nil
}

// the onion captcha end to end: every session is asked, whatever the allow list or the route's feature say; a
// decoy's label fails and is counted per route; the right one passes this session alone
func TestGateOnionFlow(t *testing.T) {
	f := gateFixtureCreate(t)
	routeOff := strings.Replace(routeAll, "captcha=1", "captcha=0", 1)

	// clearnet unchanged: the router's address is allowed at a name
	if status, _, _ := gateFixtureAuth(t, f, testRouter, routeAll); status != http.StatusOK {
		t.Fatalf("the router at a name: %d", status)
	}
	status, page, header := gateFixtureAuthHost(t, f, testOnion, testRouter, routeOff)
	session := cookieNamed((&http.Response{Header: header}).Cookies(), onionSessionCookie)
	if status != captchaStatus || header.Get(headerOutcome) != "captcha" || session == nil || session.Secure || session.Domain != "" || !session.HttpOnly {
		t.Fatalf("a new onion session: %d %v", status, session)
	}
	puzzle := onionPuzzleOf(f, session.Value)
	for _, forbidden := range append([]string{"<script", testOnion, puzzle.Answer}, puzzle.Decoys...) {
		if strings.Contains(strings.ToLower(page), forbidden) {
			t.Fatalf("the page contains %q", forbidden)
		}
	}
	if strings.Count(page, "<input") != 1 || !strings.Contains(page, `src="data:image/png;base64,`) || !strings.Contains(page, "address bar") {
		t.Fatal("the page is not one text box, one image and the address bar's question")
	}
	// a reload keeps the session's puzzle; an answer without the session finds none
	gateFixtureAuthHost(t, f, testOnion, testRouter, routeAll, session)
	if onionPuzzleOf(f, session.Value).Answer != puzzle.Answer {
		t.Fatal("a reload changed the puzzle")
	}
	if got := gateFixtureAnswerHost(t, f, testOnion, testRouter, puzzle.Answer).Header.Get(headerOutcome); got != "expired" {
		t.Fatalf("an answer without a session: %s", got)
	}

	response := gateFixtureAnswerHost(t, f, testOnion, testRouter, puzzle.Decoys[0], session)
	if response.Header.Get(headerOutcome) != "decoy" || cookieNamed(response.Cookies(), cookieName) != nil {
		t.Fatalf("a decoy's label: %s", response.Header.Get(headerOutcome))
	}
	var metrics strings.Builder
	if err := metricsRender(f.gate.metrics, &metrics); err != nil || !strings.Contains(metrics.String(), `homelab_gate_onion_decoys_total{route="hello"} 1`) {
		t.Fatalf("metrics:\n%s", metrics.String())
	}
	_, page, _ = gateFixtureAuthHost(t, f, testOnion, testRouter, routeAll, session)
	if !strings.Contains(page, "another address") {
		t.Fatal("the new puzzle does not say the label was a decoy's")
	}
	response = gateFixtureAnswerHost(t, f, testOnion, testRouter, onionPuzzleOf(f, session.Value).Answer, session)
	pass := cookieNamed(response.Cookies(), cookieName)
	if response.Header.Get(headerOutcome) != "solved" || pass == nil || pass.Domain != "" || pass.Secure || !pass.HttpOnly {
		t.Fatalf("the right answer: %s %v", response.Header.Get(headerOutcome), pass)
	}
	if status, _, _ := gateFixtureAuthHost(t, f, testOnion, testRouter, routeAll, session, pass); status != http.StatusOK {
		t.Fatalf("with the pass: %d", status)
	}
	// the pass is its session's: with another session, or none, it is worth nothing
	other := &http.Cookie{Name: onionSessionCookie, Value: onionSessionNew()}
	if status, _, _ := gateFixtureAuthHost(t, f, testOnion, testRouter, routeAll, other, pass); status != captchaStatus {
		t.Fatalf("another session with the pass: %d", status)
	}
	if status, _, _ := gateFixtureAuthHost(t, f, testOnion, testRouter, routeAll, pass); status != captchaStatus {
		t.Fatalf("the pass without its session: %d", status)
	}
}

// the regeneration ban on an onion host lands on the session that failed, never on the router every visitor shares
func TestGateOnionBanPerSession(t *testing.T) {
	f := gateFixtureCreate(t)
	failing := &http.Cookie{Name: onionSessionCookie, Value: onionSessionNew()}
	for range f.gate.captcha.challenges.regenerationsMax + 1 {
		gateFixtureAuthHost(t, f, testOnion, testRouter, routeAll, failing)
		if got := gateFixtureAnswerHost(t, f, testOnion, testRouter, "000000", failing).Header.Get(headerOutcome); got != "wrong" {
			t.Fatalf("a wrong answer: %s", got)
		}
	}
	status, page, header := gateFixtureAuthHost(t, f, testOnion, testRouter, routeAll, failing)
	if status != http.StatusForbidden || !strings.Contains(page, "You have been banned for 59 minutes") || header.Get(headerOutcome) != "ban" {
		t.Fatalf("the failing session: %d", status)
	}
	if retry, _ := strconv.Atoi(header.Get("Retry-After")); retry <= 3500 || retry > 3600 {
		t.Fatalf("retry-after %s", header.Get("Retry-After"))
	}
	if status, _, _ := gateFixtureAuthHost(t, f, testOnion, testRouter, routeAll); status != captchaStatus {
		t.Fatalf("a new session from the same router: %d", status)
	}
	if status, _, _ := gateFixtureAuth(t, f, testRouter, routeAll); status != http.StatusOK {
		t.Fatalf("the router at a name: %d", status)
	}
}
