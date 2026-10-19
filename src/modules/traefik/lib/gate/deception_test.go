package main

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const (
	testStatusDeceive       = 452
	testStatusForgedCrawler = 453
	testGooglebotUserAgent  = "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
	testYandexUserAgent     = "Mozilla/5.0 (compatible; YandexBot/3.0; +http://yandex.com/bots)"
	testBrowserUserAgent    = "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"
	// inside the fixture's googlebot ranges
	testGooglebotAddress = "66.249.64.5"
	// googlebot's, outside the fixture's ranges: its reverse name alone verifies it
	testGooglebotNewAddress = "192.178.4.1"
	// rfc 2544's benchmark range: no fake's own documentation addresses
	testScanner = "198.18.0.7"
)

var (
	testCanaryKey      = []byte(strings.Repeat("c", hmacKeyBytesMin))
	testCanaryOtherKey = []byte(strings.Repeat("d", hmacKeyBytesMin))
)

// testResolver is dns as a table: an address's reverse names, a name's addresses; failing times every lookup out.
type testResolver struct {
	names     map[string][]string
	addresses map[string][]netip.Addr
	failing   bool
}

func (r testResolver) LookupAddr(_ context.Context, address string) ([]string, error) {
	if r.failing {
		return nil, &net.DNSError{Err: "i/o timeout", Name: address, IsTimeout: true}
	}
	names, found := r.names[address]
	if !found {
		return nil, &net.DNSError{Err: "no such host", Name: address, IsNotFound: true}
	}
	return names, nil
}

func (r testResolver) LookupNetIP(_ context.Context, _, host string) ([]netip.Addr, error) {
	addresses, found := r.addresses[host]
	if !found {
		return nil, &net.DNSError{Err: "no such host", Name: host, IsNotFound: true}
	}
	return addresses, nil
}

func testCrawlersCreate(t *testing.T, resolver CrawlerResolver) *Crawlers {
	t.Helper()
	ranges := filepath.Join(t.TempDir(), "googlebot.json")
	if err := os.WriteFile(ranges, []byte(`["66.249.64.0/27", "2001:4860:4801:10::/64"]`), 0o600); err != nil {
		t.Fatal(err)
	}
	c, err := crawlersCreate([]SettingsCrawler{
		{Name: "googlebot", UserAgent: "Googlebot", RangesFile: &ranges, ReverseDomains: []string{"googlebot.com", "google.com"}},
		{Name: "yandexbot", UserAgent: "YandexBot", ReverseDomains: []string{"yandex.ru", "yandex.com."}},
	}, resolver)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { crawlersDestroy(c) })
	return c
}

// crawlerJudgeSettled judges once, waits for the lookup it started, and judges again
func crawlerJudgeSettled(t *testing.T, c *Crawlers, userAgent, client string) CrawlerVerdict {
	t.Helper()
	address := netip.MustParseAddr(client)
	crawlerJudge(c, userAgent, address, time.Now())
	for deadline := time.Now().Add(5 * time.Second); len(c.lookups) > 0; {
		if time.Now().After(deadline) {
			t.Fatal("a lookup never ended")
		}
		time.Sleep(time.Millisecond)
	}
	return crawlerJudge(c, userAgent, address, time.Now())
}

// published ranges verify at once; outside them reverse dns verifies only a name in the crawler's domains that resolves
// back, and leaves a failing resolver's address unknown, never forged: ranges alone never forge
func TestCrawlerJudge(t *testing.T) {
	resolver := testResolver{
		names: map[string][]string{
			"5.255.253.1":           {"spider-5-255-253-1.yandex.com."},
			"203.0.113.50":          {"spider.yandex.com.evil.example."},
			"203.0.113.51":          {"spider-1.yandex.ru."},
			testGooglebotNewAddress: {"crawl-192-178-4-1.googlebot.com."},
		},
		addresses: map[string][]netip.Addr{
			"spider-5-255-253-1.yandex.com":   {netip.MustParseAddr("5.255.253.1")},
			"spider-1.yandex.ru":              {netip.MustParseAddr("5.255.253.2")},
			"crawl-192-178-4-1.googlebot.com": {netip.MustParseAddr(testGooglebotNewAddress)},
		},
	}
	c := testCrawlersCreate(t, resolver)
	now := time.Now()
	cases := []struct {
		userAgent string
		client    string
		want      CrawlerVerdict
	}{
		{testBrowserUserAgent, "203.0.113.9", CrawlerNone},
		{testGooglebotUserAgent, testGooglebotAddress, CrawlerVerified},
		{testGooglebotUserAgent, "::ffff:" + testGooglebotAddress, CrawlerVerified},
		{testGooglebotUserAgent, "2001:4860:4801:10::1", CrawlerVerified},
		{"googlebot/2.1", "203.0.113.9", CrawlerUnknown},
	}
	for _, k := range cases {
		if got := crawlerJudge(c, k.userAgent, netip.MustParseAddr(k.client), now); got != k.want {
			t.Errorf("%q from %s: got %d, want %d", k.userAgent, k.client, got, k.want)
		}
	}
	if got := crawlerJudge(c, testYandexUserAgent, netip.MustParseAddr("5.255.253.1"), now); got != CrawlerUnknown {
		t.Fatalf("an unsettled address: %d", got)
	}
	for _, k := range []struct {
		userAgent string
		client    string
		want      CrawlerVerdict
	}{
		{testYandexUserAgent, "5.255.253.1", CrawlerVerified},
		{testYandexUserAgent, "203.0.113.50", CrawlerForged},
		{testYandexUserAgent, "203.0.113.51", CrawlerForged},
		{testYandexUserAgent, "203.0.113.52", CrawlerForged},
		{testGooglebotUserAgent, testGooglebotNewAddress, CrawlerVerified},
		{"googlebot/2.1", "203.0.113.9", CrawlerForged},
		{testGooglebotUserAgent, "66.249.64.32", CrawlerForged},
	} {
		if got := crawlerJudgeSettled(t, c, k.userAgent, k.client); got != k.want {
			t.Errorf("%q from %s: got %d, want %d", k.userAgent, k.client, got, k.want)
		}
	}

	failing := testCrawlersCreate(t, testResolver{failing: true})
	if got := crawlerJudgeSettled(t, failing, testYandexUserAgent, "203.0.113.53"); got != CrawlerUnknown {
		t.Fatalf("a failing resolver: %d", got)
	}
	// the lookups' bound: past it an address stays unknown and unremembered
	for range crawlerLookupsMax {
		failing.lookups <- struct{}{}
	}
	if got := crawlerJudge(failing, testYandexUserAgent, netip.MustParseAddr("203.0.113.54"), now); got != CrawlerUnknown {
		t.Fatalf("lookups full: %d", got)
	}
	if _, found := failing.settled.entries["yandexbot 203.0.113.54"]; found {
		t.Fatal("lookups full, yet the address is remembered")
	}
}

func gateFixtureAuthAgent(t *testing.T, f *gateFixture, client, userAgent, query string) (int, string) {
	t.Helper()
	request, _ := http.NewRequest(http.MethodGet, f.server.URL+pathAuth+"?"+query, nil)
	request.Header.Set(headerClient, client)
	request.Header.Set(headerForwardedURI, "/")
	request.Header.Set(headerForwardedHost, testHost)
	request.Header.Set(headerUserAgent, userAgent)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(response.Body)
	return response.StatusCode, string(body)
}

const routeCrawlers = "captcha=0&limit=0&tarpit=1&crawlers=1&scale=1"

// a forged crawler on a bot-defended route and a client crowdsec deceives get the deception statuses, and nobody else;
// a forger crowdsec bans gets the ban page
func TestGateDeceptionVerdicts(t *testing.T) {
	f := gateFixtureCreate(t)
	for _, forger := range []string{"203.0.113.70", "203.0.113.73"} {
		crawlerJudgeSettled(t, f.gate.crawlers, testGooglebotUserAgent, forger)
	}
	cases := []struct {
		name      string
		client    string
		userAgent string
		query     string
		want      int
	}{
		{"a forged crawler", "203.0.113.70", testGooglebotUserAgent, routeCrawlers, testStatusForgedCrawler},
		{"a forged crawler on a route without the bot defence", "203.0.113.70", testGooglebotUserAgent, "captcha=0&limit=0&tarpit=1&crawlers=0&scale=1", http.StatusOK},
		{"a verified crawler", testGooglebotAddress, testGooglebotUserAgent, routeCrawlers, http.StatusOK},
		{"a forged crawler from an allowed source", "10.1.2.3", testGooglebotUserAgent, routeCrawlers, http.StatusOK},
		{"a browser", "203.0.113.72", testBrowserUserAgent, routeCrawlers, http.StatusOK},
	}
	for _, c := range cases {
		if status, body := gateFixtureAuthAgent(t, f, c.client, c.userAgent, c.query); status != c.want || (status != http.StatusOK && body != "") {
			t.Errorf("%s: %d %q", c.name, status, body)
		}
	}

	f.decisions["203.0.113.71"] = `[{"id":11,"type":"ban","duration":"24h"},{"id":10,"type":"deceive","duration":"5m"}]`
	f.decisions["10.1.2.3"] = f.decisions["203.0.113.71"]
	for range 2 {
		if status, _ := gateFixtureAuthAgent(t, f, "203.0.113.71", testBrowserUserAgent, routeAll); status != testStatusDeceive {
			t.Fatalf("a deceived client: %d", status)
		}
	}
	if status, _ := gateFixtureAuthAgent(t, f, "10.1.2.3", testBrowserUserAgent, routeAll); status != http.StatusOK {
		t.Fatalf("an allowed source crowdsec deceives: %d", status)
	}
	f.decisions["203.0.113.73"] = `[{"id":12,"type":"ban","duration":"24h"}]`
	status, body := gateFixtureAuthAgent(t, f, "203.0.113.73", testGooglebotUserAgent, "captcha=0&limit=0&tarpit=0&crawlers=1&scale=1")
	if status != http.StatusForbidden || !strings.Contains(body, "You have been banned for") {
		t.Fatalf("a forger crowdsec bans: %d %q", status, body)
	}
	var metrics strings.Builder
	if err := metricsRender(f.gate.metrics, &metrics); err != nil {
		t.Fatal(err)
	}
	for _, series := range []string{
		"homelab_gate_deceives_total 1\n",
		`homelab_gate_verdicts_total{verdict="deceive"} 2`,
		`homelab_gate_verdicts_total{verdict="forged-crawler"} 1`,
		`homelab_gate_verdicts_total{verdict="ban"} 1`,
	} {
		if !strings.Contains(metrics.String(), series) {
			t.Errorf("no %q in\n%s", series, metrics.String())
		}
	}
}

func deceptionFetch(t *testing.T, server *httptest.Server, target, client, userAgent string) (int, http.Header, []byte) {
	t.Helper()
	request, _ := http.NewRequest(http.MethodGet, server.URL+target, nil)
	request.Host = testHost
	request.Header.Set(headerClient, client)
	request.Header.Set(headerUserAgent, userAgent)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(response.Body)
	return response.StatusCode, response.Header, body
}

// the errors middleware's fetch: its query, the request's whole url escaped
func deceptionQuery(reason, requestPath string) string {
	return reason + "?" + url.Values{deceptionURLQuery: {"https://" + testHost + requestPath}}.Encode()
}

func TestDeceptionServe(t *testing.T) {
	f := gateFixtureCreate(t)
	server := httptest.NewServer(deceptionMux(f.gate))
	t.Cleanup(server.Close)
	f.decisions[testScanner] = `[{"id":10,"type":"deceive","duration":"5m"},{"id":11,"type":"ban","duration":"24h"}]`

	status, header, first := deceptionFetch(t, server, deceptionQuery(pathDeceive, "/.env?debug=1"), testScanner, testBrowserUserAgent)
	if status != http.StatusOK || header.Get("Content-Type") != "text/plain; charset=utf-8" || header.Get(headerOutcome) != "" ||
		!bytes.Contains(first, []byte("AWS_ACCESS_KEY_ID=AKIA")) {
		t.Fatalf("a deceived scanner's .env: %d %q %q", status, header.Get(headerOutcome), first)
	}
	if _, _, again := deceptionFetch(t, server, deceptionQuery(pathDeceive, "/.env"), testScanner, testBrowserUserAgent); !bytes.Equal(first, again) {
		t.Fatal("the same client and path got another fake")
	}
	if _, _, body := deceptionFetch(t, server, deceptionQuery(pathDeceive, "/some/page"), testScanner, testBrowserUserAgent); string(body) != strings.Repeat("nonsense ", 8) {
		t.Fatalf("a path no fake answers: %q", body)
	}
	if status, _, body := deceptionFetch(t, server, deceptionQuery(pathDeceive, "/.env"), "203.0.113.81", testBrowserUserAgent); status != http.StatusBadGateway || string(body) != http.StatusText(http.StatusBadGateway)+"\n" {
		t.Fatalf("a client crowdsec does not deceive: %d %q", status, body)
	}

	crawlerJudgeSettled(t, f.gate.crawlers, testGooglebotUserAgent, "203.0.113.82")
	status, header, body := deceptionFetch(t, server, deceptionQuery(pathForgedCrawler, "/api/v1/users"), "203.0.113.82", testGooglebotUserAgent)
	var api fakeAPIBody
	if status != http.StatusOK || header.Get(headerOutcome) != "forged-crawler" || json.Unmarshal(body, &api) != nil ||
		!strings.HasPrefix(api.Data.Storage.AccessKeyID, awsKeyIDPrefix) {
		t.Fatalf("a forged crawler's api: %d %q %q", status, header.Get(headerOutcome), body)
	}
	if status, header, _ := deceptionFetch(t, server, deceptionQuery(pathForgedCrawler, "/api/v1/users"), testGooglebotAddress, testGooglebotUserAgent); status != http.StatusBadGateway || header.Get(headerOutcome) != "" {
		t.Fatalf("a verified crawler: %d %q", status, header.Get(headerOutcome))
	}
	if status, _, body := deceptionFetch(t, server, pathHoneypot+"/.git/config", "203.0.113.83", testBrowserUserAgent); status != http.StatusOK || !bytes.Contains(body, []byte(gitTokenPrefix)) {
		t.Fatalf("a honeypot hit: %d %q", status, body)
	}

	var metrics strings.Builder
	if err := metricsRender(f.gate.metrics, &metrics); err != nil {
		t.Fatal(err)
	}
	for _, series := range []string{
		`homelab_gate_canaries_total{target="env"} 2`,
		`homelab_gate_canaries_total{target="api"} 1`,
		`homelab_gate_canaries_total{target="git-config"} 1`,
		`homelab_gate_deceptions_total{served="labyrinth"} 1`,
		`homelab_gate_deceptions_total{served="refused"} 2`,
		"homelab_gate_tarpit_active 0\n",
	} {
		if !strings.Contains(metrics.String(), series) {
			t.Errorf("no %q in\n%s", series, metrics.String())
		}
	}
}

func TestDeceptionTargetOf(t *testing.T) {
	cases := map[string]string{
		"/.env":                       "env",
		"/app/.env.production":        "env",
		"/a/../.env":                  "env",
		"/.git/config":                "git-config",
		"/WP-LOGIN.PHP":               "wordpress",
		"/blog/wp-login.php":          "wordpress",
		"/wp-admin":                   "wordpress",
		"/wp-admin/setup-config.php":  "wordpress",
		"/phpinfo.php":                "phpinfo",
		"/info.php":                   "phpinfo",
		"/server-status":              "server-status",
		"/backup.zip":                 "backup",
		"/admin":                      "admin",
		"/admin/login":                "admin",
		"/api":                        "api",
		"/api/v1/users":               "api",
		"/administrator":              "",
		"/apiary":                     "",
		"/":                           "",
		"/internal/export":            "",
		"/vendor/phpunit/eval.php":    "",
		"/.environment/notes":         "",
		"/server-status-but-not-this": "",
	}
	for requestPath, want := range cases {
		target, found := deceptionTargetOf(requestPath)
		got := ""
		if found {
			got = target.name
		}
		if got != want {
			t.Errorf("%s: got %q, want %q", requestPath, got, want)
		}
	}
}

// the canary values a fake must carry for it to name its fetcher; a git config holds a remote's token alone
func canaryBaits(target string, c Canary) []string {
	if target == "git-config" {
		return []string{c.GitToken}
	}
	return []string{c.AWSKeyID, c.APIToken}
}

// every target's fake over many paths: within the size cap, the same bytes for the same key, client and path, other
// canaries for another client or another key, its canaries inside, and nothing of the request or the lab
func TestDeceptionFakes(t *testing.T) {
	const pathsPerTarget = 300
	samples := map[string]string{
		"env": "/x%d/.env", "git-config": "/x%d/.git/config", "wordpress": "/wp-admin/x%d", "phpinfo": "/x%d/phpinfo.php",
		"server-status": "/server-status", "backup": "/backup%d.zip", "admin": "/admin/x%d", "api": "/api/x%d",
	}
	if len(samples) != len(deceptionTargets) {
		t.Fatalf("%d samples for %d targets", len(samples), len(deceptionTargets))
	}
	forbidden := []string{testHost, "lsck0", testScanner, "127.0.0.1:"}
	for i := range deceptionTargets {
		target := &deceptionTargets[i]
		for n := range pathsPerTarget {
			requestPath := samples[target.name]
			if strings.Contains(requestPath, "%d") {
				requestPath = fmt.Sprintf(requestPath, n)
			}
			canary, body := deceptionFakeRender(target, testCanaryKey, testScanner, requestPath)
			if _, again := deceptionFakeRender(target, testCanaryKey, testScanner, requestPath); !bytes.Equal(body, again) {
				t.Fatalf("%s %s: two fakes", target.name, requestPath)
			}
			other, _ := deceptionFakeRender(target, testCanaryKey, "198.18.0.8", requestPath)
			if other.ID == canary.ID || other.AWSKeyID == canary.AWSKeyID {
				t.Fatalf("%s %s: another client got the same canary", target.name, requestPath)
			}
			if unkeyed, _ := deceptionFakeRender(target, testCanaryOtherKey, testScanner, requestPath); unkeyed.ID == canary.ID || unkeyed.AWSKeyID == canary.AWSKeyID {
				t.Fatalf("%s %s: another key drew the same canary", target.name, requestPath)
			}
			text := body
			if target.name == "backup" {
				text = testZipOnlyFile(t, body)
			}
			for _, bait := range canaryBaits(target.name, canary) {
				if !bytes.Contains(text, []byte(bait)) {
					t.Fatalf("%s %s: no canary %s in\n%s", target.name, requestPath, bait, text)
				}
			}
			for _, word := range forbidden {
				if bytes.Contains(text, []byte(word)) {
					t.Fatalf("%s %s: the fake contains %q", target.name, requestPath, word)
				}
			}
			if target.name == "api" && !json.Valid(body) {
				t.Fatalf("api %s: no json", requestPath)
			}
		}
	}
}

func testZipOnlyFile(t *testing.T, archive []byte) []byte {
	t.Helper()
	reader, err := zip.NewReader(bytes.NewReader(archive), int64(len(archive)))
	if err != nil || len(reader.File) != 1 {
		t.Fatalf("no zip of one file: %v", err)
	}
	file, err := reader.File[0].Open()
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	text, err := io.ReadAll(file)
	if err != nil {
		t.Fatal(err)
	}
	return text
}

type writeSizes struct {
	*httptest.ResponseRecorder
	sizes []int
}

func (w *writeSizes) Write(chunk []byte) (int, error) {
	w.sizes = append(w.sizes, len(chunk))
	return w.ResponseRecorder.Write(chunk)
}

// the rate cap: no write past the chunk, one chunk per interval, all of the body
func TestTrickleWrite(t *testing.T) {
	const interval = 5 * time.Millisecond
	body := bytes.Repeat([]byte("x"), 3*deceptionChunkBytes+1)
	w := &writeSizes{ResponseRecorder: httptest.NewRecorder()}
	started := time.Now()
	trickleWrite(context.Background(), w, body, deceptionChunkBytes, interval)
	if elapsed := time.Since(started); elapsed < 3*interval {
		t.Fatalf("four chunks in %v", elapsed)
	}
	if len(w.sizes) != 4 || w.Body.Len() != len(body) {
		t.Fatalf("writes %v, %d bytes", w.sizes, w.Body.Len())
	}
	for _, size := range w.sizes {
		if size > deceptionChunkBytes {
			t.Fatalf("a write of %d bytes", size)
		}
	}
}

func TestSettingsDeception(t *testing.T) {
	settingsWith := func(deception, crawlers string) string {
		return `{"listen":"127.0.0.1:1","tarpitListen":"127.0.0.1:2","lapi":{"url":"http://127.0.0.1:3","keyFile":"/k"},` +
			`"allow":{"cidrs":[],"hosts":[]},"captcha":null,"session":null,"anonymous":{"averagePerSecond":1,"burst":1},` +
			`"tarpit":{"upstream":"http://127.0.0.1:4"},"deception":` + deception + `,"crawlers":` + crawlers + `,"stripCookies":[]}`
	}
	const deceptionValid = `{"listen":"127.0.0.1:5","statusDeceive":452,"statusForgedCrawler":453,"canaryKeyFile":"/c"}`
	const crawlerValid = `[{"name":"yandexbot","userAgent":"YandexBot","rangesFile":null,"reverseDomains":["yandex.ru"]}]`
	cases := []struct {
		name      string
		deception string
		crawlers  string
		valid     bool
	}{
		{"valid", deceptionValid, crawlerValid, true},
		{"the captcha's status", `{"listen":"127.0.0.1:5","statusDeceive":429,"statusForgedCrawler":453,"canaryKeyFile":"/c"}`, crawlerValid, false},
		{"one status twice", `{"listen":"127.0.0.1:5","statusDeceive":452,"statusForgedCrawler":452,"canaryKeyFile":"/c"}`, crawlerValid, false},
		{"a success", `{"listen":"127.0.0.1:5","statusDeceive":200,"statusForgedCrawler":453,"canaryKeyFile":"/c"}`, crawlerValid, false},
		{"no listener", `{"listen":"","statusDeceive":452,"statusForgedCrawler":453,"canaryKeyFile":"/c"}`, crawlerValid, false},
		{"no canary key", `{"listen":"127.0.0.1:5","statusDeceive":452,"statusForgedCrawler":453,"canaryKeyFile":""}`, crawlerValid, false},
		{"a crawler without ranges or domains", deceptionValid, `[{"name":"x","userAgent":"X","rangesFile":null,"reverseDomains":[]}]`, false},
		{"a crawler with ranges alone", deceptionValid, `[{"name":"x","userAgent":"X","rangesFile":"/r","reverseDomains":[]}]`, false},
		{"two crawlers of one name", deceptionValid, `[` + crawlerValid[1:len(crawlerValid)-1] + `,` + crawlerValid[1:], false},
	}
	for _, c := range cases {
		if _, err := settingsParse([]byte(settingsWith(c.deception, c.crawlers))); (err == nil) != c.valid {
			t.Errorf("%s: err %v", c.name, err)
		}
	}
}
