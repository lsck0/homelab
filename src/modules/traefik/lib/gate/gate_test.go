package main

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"regexp"
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
	first, notice, tries, _ := challengesShow(c, client, now)
	if notice != NoticeExpired || tries != regenerationsMax-1 {
		t.Fatalf("after one failure: notice %d tries %d", notice, tries)
	}
	again, notice, _, _ := challengesShow(c, client, now.Add(time.Second))
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
	second, _, tries, _ := challengesShow(c, client, now)
	if tries != regenerationsMax-3 {
		t.Fatalf("after three failures: tries %d", tries)
	}
	if got := challengesAnswer(c, client, "0x"+strings.ToUpper(second.Answer), now.Add(puzzleLifetime)); got != OutcomeExpired {
		t.Fatalf("a late answer: %s", outcomeNames[got])
	}
	third, _, _, _ := challengesShow(c, client, now)
	if got := challengesAnswer(c, client, "0x"+strings.ToUpper(third.Answer), now); got != OutcomeSolved {
		t.Fatalf("the right answer: %s", outcomeNames[got])
	}
	// failures leave the window after an hour
	_, _, tries, _ = challengesShow(c, client, now.Add(failureWindow))
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
			answerPath: "/.lab-gate/answer", challenges: challenges, renders: make(chan struct{}, renderSlots)},
	}
	f.gate.tarpit.interval = time.Millisecond
	f.server = httptest.NewServer(gateMux(f.gate))
	t.Cleanup(f.server.Close)
	return f
}

func gateFixtureAuth(t *testing.T, f *gateFixture, client, query string, cookies ...*http.Cookie) (int, string, http.Header) {
	t.Helper()
	request, _ := http.NewRequest(http.MethodGet, f.server.URL+pathAuth+"?"+query, nil)
	request.Header.Set(headerClient, client)
	request.Header.Set(headerForwardedURI, "/page?x=1")
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
	form := url.Values{answerField: {answer}}
	request, _ := http.NewRequest(http.MethodPost, f.server.URL+"/.lab-gate/answer?return=%2Fpage%3Fx%3D1", strings.NewReader(form.Encode()))
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	request.Header.Set(headerClient, client)
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
	if status != http.StatusForbidden || header.Get(headerOutcome) != "captcha" {
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
	if status, _, _ := gateFixtureAuth(t, f, "203.0.113.11", routeAll, cookies[0]); status != http.StatusForbidden {
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
