package main

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"html"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"net/netip"
	"net/url"
	"path"
	"strings"
	"time"
)

// The deception is what a scanner crowdsec decided to deceive (lib/ladder.nix), a forged search crawler and a honeypot
// hit get instead of the lab. traefik's errors middlewares turn the gate's deception statuses into a fetch here with
// the request's url and headers, and the answer into a 200 (gate.nix); the honeypot router sends here itself. A common
// enumeration target gets a small plausible fake, any other path the labyrinth, both trickled within the tarpit's
// slots. Every fake carries canaries (an aws key, a database password, api and git tokens) drawn from its client and
// path under the gate's own key, so a later use of one names who fetched it where, and each issuance is logged. Nothing
// in a fake comes from the lab: fixed templates and a seeded generator, never the request's host or anything else of it.
const (
	pathDeceive       = "/deceive"
	pathForgedCrawler = "/forged-crawler"
	pathHoneypot      = "/honeypot"
	deceptionURLQuery = "url"
	// a fake is a few hundred bytes to a few KiB; a template past this is a bug
	deceptionBodyBytesMax = 4096
	// 1 KiB/s: a fake arrives within four seconds, inside a scanner's timeout, and still costs it seconds per probe
	deceptionChunkBytes    = 128
	deceptionChunkInterval = 125 * time.Millisecond
	// what of an attacker's path the journal keeps
	deceptionPathLogBytesMax = 512
	canaryIDBytes            = 6
)

// the formats' own lengths, so a fake reads like the real thing
const (
	awsKeyIDPrefix   = "AKIA"
	awsKeyIDChars    = 16
	awsSecretChars   = 40
	passwordChars    = 24
	apiTokenChars    = 40
	gitTokenPrefix   = "ghp_"
	gitTokenChars    = 36
	bcryptPrefix     = "$2y$10$"
	bcryptChars      = 53
	laravelKeyChars  = 43
	fakeUserCountMax = 4
)

const (
	alphabetUpper  = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	alphabetLower  = "abcdefghijklmnopqrstuvwxyz"
	alphabetDigits = "0123456789"
	alphabetAlnum  = alphabetUpper + alphabetLower + alphabetDigits
	alphabetBase32 = alphabetUpper + "234567"
	alphabetBase64 = alphabetAlnum + "+/"
	alphabetBcrypt = "./" + alphabetAlnum
	alphabetHex    = alphabetDigits + "abcdef"
)

var (
	fakeApps       = []string{"atlas", "harbor", "nimbus", "orchid", "quarry", "summit", "tundra", "vertex"}
	fakeOrgs       = []string{"acme-labs", "bluefin-dev", "northwind-it", "redline-web"}
	fakeUsers      = []string{"admin", "deploy", "webmaster", "ops", "jsmith", "mweber", "akoch", "lfischer"}
	fakeRoles      = []string{"admin", "editor", "viewer"}
	fakeRegions    = []string{"eu-central-1", "eu-west-1", "us-east-1"}
	fakePHP        = []string{"7.4.33", "8.1.27", "8.2.18"}
	fakeWordPress  = []string{"6.4.3", "6.5.2", "6.6.1"}
	fakeKernels    = []string{"5.15.0-105", "5.15.0-113", "6.8.0-40"}
	fakeAPIVersion = []string{"v1", "v2", "v3"}
	// documentation addresses (rfc 5737): a fake's clients are nobody's
	fakeClientPrefixes = []string{"192.0.2.", "198.51.100.", "203.0.113."}
	fakePages          = []string{"/", "/index.php", "/login", "/static/app.js", "/favicon.ico"}
)

// Deception is the deception listener's state beside the gate's: the statuses that send a request there, the canaries'
// key and its pace.
type Deception struct {
	statusDeceive       int
	statusForgedCrawler int
	canaryKey           []byte
	interval            time.Duration
}

// Canary is one fake's set of secrets, all drawn from its client and path; ID names it in the journal.
type Canary struct {
	ID         string
	AWSKeyID   string
	AWSSecret  string
	DBUser     string
	DBPassword string
	APIToken   string
	GitToken   string
}

type deceptionTarget struct {
	name        string
	contentType string
	// path is cleaned and lowercase
	matches func(path string) bool
	render  func(rng *rand.Rand, c Canary) []byte
}

/*
 * -----------------------------------------------------------------------------
 * INTERNAL
 * -----------------------------------------------------------------------------
 */

func draw(rng *rand.Rand, alphabet string, count int) string {
	out := make([]byte, count)
	for i := range out {
		out[i] = alphabet[rng.IntN(len(alphabet))]
	}
	return string(out)
}

func pick[T any](rng *rand.Rand, list []T) T {
	return list[rng.IntN(len(list))]
}

func dbURL(c Canary) string {
	return fmt.Sprintf("mysql://%s:%s@mysql:3306/%s_prod", c.DBUser, c.DBPassword, c.DBUser)
}

// canarySeed is the one source of a fake's randomness: the same client and path get the same fake, so a canary
// found anywhere names its fetcher even past the journal's retention. Keyed, since without the key anyone could
// compute any client's canaries and plant them; a client address holds no zero byte, so the pair is unambiguous.
func canarySeed(key []byte, client, requestPath string) [sha256.Size]byte {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(client + "\x00" + requestPath))
	return [sha256.Size]byte(mac.Sum(nil))
}

func canaryDraw(rng *rand.Rand, seed [sha256.Size]byte) Canary {
	return Canary{
		ID:         hex.EncodeToString(seed[:canaryIDBytes]),
		AWSKeyID:   awsKeyIDPrefix + draw(rng, alphabetBase32, awsKeyIDChars),
		AWSSecret:  draw(rng, alphabetBase64, awsSecretChars),
		DBUser:     pick(rng, fakeApps),
		DBPassword: draw(rng, alphabetAlnum, passwordChars),
		APIToken:   draw(rng, alphabetAlnum, apiTokenChars),
		GitToken:   gitTokenPrefix + draw(rng, alphabetAlnum, gitTokenChars),
	}
}

// canaryComment is a debug leftover as careless sites ship them: the bait in an html fake
func canaryComment(c Canary) string {
	return fmt.Sprintf("<!-- staging: DATABASE_URL=%s AWS_ACCESS_KEY_ID=%s AWS_SECRET_ACCESS_KEY=%s API_TOKEN=%s -->\n",
		dbURL(c), c.AWSKeyID, c.AWSSecret, c.APIToken)
}

func fakeEnvRender(rng *rand.Rand, c Canary) []byte {
	return fmt.Appendf(nil, `APP_NAME=%s
APP_ENV=production
APP_KEY=base64:%s=
APP_DEBUG=false
APP_URL=http://localhost

DB_CONNECTION=mysql
DB_HOST=mysql
DB_PORT=3306
DB_DATABASE=%s_prod
DB_USERNAME=%s
DB_PASSWORD=%s

REDIS_HOST=redis
REDIS_PORT=6379

AWS_ACCESS_KEY_ID=%s
AWS_SECRET_ACCESS_KEY=%s
AWS_DEFAULT_REGION=%s
AWS_BUCKET=%s-uploads

API_TOKEN=%s
`, c.DBUser, draw(rng, alphabetBase64, laravelKeyChars), c.DBUser, c.DBUser, c.DBPassword, c.AWSKeyID, c.AWSSecret,
		pick(rng, fakeRegions), c.DBUser, c.APIToken)
}

func fakeGitConfigRender(rng *rand.Rand, c Canary) []byte {
	return fmt.Appendf(nil, `[core]
	repositoryformatversion = 0
	filemode = true
	bare = false
	logallrefupdates = true
[remote "origin"]
	url = https://%s:%s@github.com/%s/%s.git
	fetch = +refs/heads/*:refs/remotes/origin/*
[branch "main"]
	remote = origin
	merge = refs/heads/main
`, pick(rng, fakeUsers), c.GitToken, pick(rng, fakeOrgs), c.DBUser)
}

func fakeWordPressRender(rng *rand.Rand, c Canary) []byte {
	return fmt.Appendf(nil, `<!DOCTYPE html>
<html lang="en-US">
<head>
<meta charset="UTF-8">
<title>Log In &lsaquo; %s &#8212; WordPress</title>
<meta name="robots" content="noindex, nofollow">
<link rel="stylesheet" href="/wp-admin/load-styles.php?c=0&amp;dir=ltr&amp;load%%5Bchunk_0%%5D=dashicons,buttons,forms,l10n,login&amp;ver=%s">
</head>
<body class="login no-js login-action-login wp-core-ui locale-en-us">
<div id="login">
<h1><a href="https://wordpress.org/">Powered by WordPress</a></h1>
<form name="loginform" id="loginform" action="/wp-login.php" method="post">
<p><label for="user_login">Username or Email Address</label>
<input type="text" name="log" id="user_login" class="input" value="" size="20" autocapitalize="off" autocomplete="username" required="required"></p>
<div class="user-pass-wrap"><label for="user_pass">Password</label>
<input type="password" name="pwd" id="user_pass" class="input password-input" value="" size="20" autocomplete="current-password" spellcheck="false" required="required"></div>
<p class="submit"><input type="submit" name="wp-submit" id="wp-submit" class="button button-primary button-large" value="Log In">
<input type="hidden" name="redirect_to" value="/wp-admin/">
<input type="hidden" name="testcookie" value="1"></p>
</form>
</div>
%s</body>
</html>
`, c.DBUser, pick(rng, fakeWordPress), canaryComment(c))
}

func htmlRows(pairs [][2]string) string {
	var rows strings.Builder
	for _, pair := range pairs {
		fmt.Fprintf(&rows, "<tr><td class=\"e\">%s </td><td class=\"v\">%s </td></tr>\n", html.EscapeString(pair[0]), html.EscapeString(pair[1]))
	}
	return rows.String()
}

func fakePHPInfoRender(rng *rand.Rand, c Canary) []byte {
	php := pick(rng, fakePHP)
	minor := php[:strings.LastIndexByte(php, '.')]
	system := fmt.Sprintf("Linux web-%s %s-generic #%d-Ubuntu SMP x86_64", draw(rng, alphabetHex, 4), pick(rng, fakeKernels), 100+rng.IntN(50))
	return fmt.Appendf(nil, `<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>PHP %s - phpinfo()</title></head>
<body><div class="center">
<h1 class="p">PHP Version %s</h1>
<table>
%s</table>
<h2>Environment</h2>
<table>
%s</table>
</div>
%s</body></html>
`, php, php, htmlRows([][2]string{
		{"System", system},
		{"Server API", "Apache 2.0 Handler"},
		{"Loaded Configuration File", "/etc/php/" + minor + "/apache2/php.ini"},
		{"memory_limit", "256M"},
	}), htmlRows([][2]string{
		{"APP_ENV", "production"},
		{"DB_HOST", "mysql"},
		{"DB_USERNAME", c.DBUser},
		{"DB_PASSWORD", c.DBPassword},
		{"AWS_ACCESS_KEY_ID", c.AWSKeyID},
		{"AWS_SECRET_ACCESS_KEY", c.AWSSecret},
		{"API_TOKEN", c.APIToken},
	}), canaryComment(c))
}

func fakeServerStatusRender(rng *rand.Rand, c Canary) []byte {
	var rows strings.Builder
	requests := []string{
		"GET /api/v1/export?token=" + c.APIToken + " HTTP/1.1",
		"GET /media/upload?X-Amz-Credential=" + c.AWSKeyID + "%2F" + pick(rng, fakeRegions) + "%2Fs3%2Faws4_request HTTP/1.1",
	}
	for range fakeUserCountMax {
		requests = append(requests, "GET "+pick(rng, fakePages)+" HTTP/1.1")
	}
	for i, request := range requests {
		fmt.Fprintf(&rows, "<tr><td><b>%d-0</b></td><td>%d</td><td>%s%d</td><td nowrap>localhost:80</td><td nowrap>%s</td></tr>\n",
			i, 1000+rng.IntN(30000), pick(rng, fakeClientPrefixes), 1+rng.IntN(254), html.EscapeString(request))
	}
	return fmt.Appendf(nil, `<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
<html><head>
<title>Apache Status</title>
</head><body>
<h1>Apache Server Status for localhost (via 127.0.0.1)</h1>
<dl><dt>Server Version: Apache/2.4.58 (Ubuntu) OpenSSL/3.0.13</dt>
<dt>Server MPM: prefork</dt>
</dl><hr /><dl>
<dt>Server uptime: %d days %d hours %d minutes</dt>
<dt>Total accesses: %d - Total Traffic: %d.%d MB</dt>
<dt>%d requests currently being processed, %d idle workers</dt>
</dl>
<table border="0"><tr><th>Srv</th><th>PID</th><th>Client</th><th>VHost</th><th>Request</th></tr>
%s</table>
</body></html>
`, 1+rng.IntN(90), rng.IntN(24), rng.IntN(60), 10000+rng.IntN(900000), 10+rng.IntN(9000), rng.IntN(10),
		len(requests), 1+rng.IntN(8), rows.String())
}

func fakeAdminRender(rng *rand.Rand, c Canary) []byte {
	return fmt.Appendf(nil, `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>%s admin - Sign in</title></head>
<body><main>
<h1>%s administration</h1>
<form method="post" action="/admin/login">
<input type="hidden" name="csrf_token" value="%s">
<label>Username <input name="username" autocomplete="username"></label>
<label>Password <input name="password" type="password" autocomplete="current-password"></label>
<button type="submit">Sign in</button>
</form>
</main>
%s</body></html>
`, c.DBUser, c.DBUser, draw(rng, alphabetHex, apiTokenChars), canaryComment(c))
}

func fakeUsersDraw(rng *rand.Rand) []string {
	users := []string{fakeUsers[0]}
	for range 1 + rng.IntN(fakeUserCountMax-1) {
		users = append(users, pick(rng, fakeUsers[1:]))
	}
	return users
}

func fakeSQLDumpRender(rng *rand.Rand, c Canary) []byte {
	var users strings.Builder
	for i, user := range fakeUsersDraw(rng) {
		token := "NULL"
		if i == 0 {
			token = "'" + c.APIToken + "'"
		}
		if i > 0 {
			users.WriteString(",")
		}
		fmt.Fprintf(&users, "(%d,'%s@example.com','%s%s',%s)", i+1, user, bcryptPrefix, draw(rng, alphabetBcrypt, bcryptChars), token)
	}
	return fmt.Appendf(nil, "-- MySQL dump 10.13  Distrib 8.0.36, for Linux (x86_64)\n--\n-- Host: mysql    Database: %s_prod\n"+
		"-- ------------------------------------------------------\n"+
		"CREATE TABLE `users` (`id` int NOT NULL AUTO_INCREMENT, `email` varchar(255) NOT NULL, `password` varchar(255) NOT NULL, "+
		"`api_token` varchar(80) DEFAULT NULL, PRIMARY KEY (`id`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;\n"+
		"INSERT INTO `users` VALUES %s;\n"+
		"CREATE TABLE `settings` (`name` varchar(64) NOT NULL, `value` text, PRIMARY KEY (`name`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;\n"+
		"INSERT INTO `settings` VALUES ('aws_access_key_id','%s'),('aws_secret_access_key','%s'),('database_url','%s');\n",
		c.DBUser, users.String(), c.AWSKeyID, c.AWSSecret, dbURL(c))
}

// fakeBackupRender is a zip of one sql dump; its timestamp is drawn too, so the same client and path get the same bytes
func fakeBackupRender(rng *rand.Rand, c Canary) []byte {
	var archive bytes.Buffer
	writer := zip.NewWriter(&archive)
	modified := time.Date(2024, time.Month(1+rng.IntN(12)), 1+rng.IntN(28), rng.IntN(24), rng.IntN(60), 0, 0, time.UTC)
	file, err := writer.CreateHeader(&zip.FileHeader{Name: c.DBUser + "_prod.sql", Method: zip.Deflate, Modified: modified})
	if err != nil {
		panic("deception: zip into memory: " + err.Error())
	}
	if _, err := file.Write(fakeSQLDumpRender(rng, c)); err != nil {
		panic("deception: zip into memory: " + err.Error())
	}
	if err := writer.Close(); err != nil {
		panic("deception: zip into memory: " + err.Error())
	}
	return archive.Bytes()
}

type fakeAPIUser struct {
	ID       int    `json:"id"`
	Username string `json:"username"`
	Email    string `json:"email"`
	Role     string `json:"role"`
	APIKey   string `json:"api_key,omitempty"`
}

type fakeAPIStorage struct {
	Provider        string `json:"provider"`
	Bucket          string `json:"bucket"`
	Region          string `json:"region"`
	AccessKeyID     string `json:"access_key_id"`
	SecretAccessKey string `json:"secret_access_key"`
}

type fakeAPIData struct {
	Users       []fakeAPIUser  `json:"users"`
	Storage     fakeAPIStorage `json:"storage"`
	DatabaseURL string         `json:"database_url"`
}

type fakeAPIBody struct {
	Status  string      `json:"status"`
	Version string      `json:"version"`
	Data    fakeAPIData `json:"data"`
}

func fakeAPIRender(rng *rand.Rand, c Canary) []byte {
	body := fakeAPIBody{Status: "ok", Version: pick(rng, fakeAPIVersion), Data: fakeAPIData{
		Storage: fakeAPIStorage{Provider: "s3", Bucket: c.DBUser + "-uploads", Region: pick(rng, fakeRegions),
			AccessKeyID: c.AWSKeyID, SecretAccessKey: c.AWSSecret},
		DatabaseURL: dbURL(c),
	}}
	for i, user := range fakeUsersDraw(rng) {
		apiUser := fakeAPIUser{ID: i + 1, Username: user, Email: user + "@example.com", Role: pick(rng, fakeRoles)}
		if i == 0 {
			apiUser.Role, apiUser.APIKey = fakeRoles[0], c.APIToken
		}
		body.Data.Users = append(body.Data.Users, apiUser)
	}
	out, err := json.MarshalIndent(body, "", "  ")
	if err != nil {
		panic("deception: json of fixed types: " + err.Error())
	}
	return append(out, '\n')
}

func pathIsUnder(p, prefix string) bool {
	return p == prefix || strings.HasPrefix(p, prefix+"/")
}

// the common enumeration targets, first match wins; any other path gets the labyrinth
var deceptionTargets = []deceptionTarget{
	{"env", "text/plain; charset=utf-8", func(p string) bool {
		base := path.Base(p)
		return base == ".env" || strings.HasPrefix(base, ".env.")
	}, fakeEnvRender},
	{"git-config", "text/plain; charset=utf-8", func(p string) bool { return strings.HasSuffix(p, "/.git/config") }, fakeGitConfigRender},
	{"wordpress", "text/html; charset=UTF-8", func(p string) bool {
		return path.Base(p) == "wp-login.php" || pathIsUnder(p, "/wp-admin")
	}, fakeWordPressRender},
	{"phpinfo", "text/html; charset=UTF-8", func(p string) bool {
		base := path.Base(p)
		return base == "phpinfo.php" || base == "info.php"
	}, fakePHPInfoRender},
	{"server-status", "text/html; charset=ISO-8859-1", func(p string) bool { return p == "/server-status" }, fakeServerStatusRender},
	{"backup", "application/zip", func(p string) bool { return strings.HasSuffix(p, ".zip") }, fakeBackupRender},
	{"admin", "text/html; charset=utf-8", func(p string) bool { return pathIsUnder(p, "/admin") }, fakeAdminRender},
	{"api", "application/json", func(p string) bool { return pathIsUnder(p, "/api") }, fakeAPIRender},
}

func deceptionTargetOf(requestPath string) (*deceptionTarget, bool) {
	cleaned := strings.ToLower(path.Clean("/" + requestPath))
	for i := range deceptionTargets {
		if deceptionTargets[i].matches(cleaned) {
			return &deceptionTargets[i], true
		}
	}
	return nil, false
}

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// deceptionFakeRender is a target's fake for one client and path: the same key and pair always get the same bytes.
func deceptionFakeRender(target *deceptionTarget, key []byte, client, requestPath string) (Canary, []byte) {
	seed := canarySeed(key, client, requestPath)
	rng := rand.New(rand.NewChaCha8(seed))
	canary := canaryDraw(rng, seed)
	body := target.render(rng, canary)
	if len(body) == 0 || len(body) > deceptionBodyBytesMax {
		panic(fmt.Sprintf("deception: %s fake of %d bytes", target.name, len(body)))
	}
	return canary, body
}

// deceptionRequestOf is what a deception fetch stands for: the client's request (its uri, unescaped path) and whether
// the gate deceives the client for the reason the fetch names. A visitor the gate does not deceive gets no fake,
// whichever way it got here (a backend answering a deception status itself).
func deceptionRequestOf(ctx context.Context, g *Gate, r *http.Request, client netip.Addr, now time.Time) (requestURI, requestPath string, deceived bool) {
	if strings.HasPrefix(r.URL.Path, pathHoneypot+"/") {
		// only the honeypot router sends here: its rule is the reason
		original := strings.TrimPrefix(r.URL.RequestURI(), pathHoneypot)
		return original, strings.TrimPrefix(r.URL.Path, pathHoneypot), true
	}
	original, err := url.Parse(r.URL.Query().Get(deceptionURLQuery))
	if err != nil {
		return "", "", false
	}
	switch r.URL.Path {
	case pathDeceive:
		decision, _, _ := decisionsGet(ctx, g.decisions, client.String(), now)
		deceived = decision.Kind == DecisionDeceive
	case pathForgedCrawler:
		deceived = crawlerJudge(g.crawlers, r.Header.Get("User-Agent"), client, now) == CrawlerForged
	}
	return original.RequestURI(), original.Path, deceived
}

// deceptionServe is the deception listener: a fake or the labyrinth for a deceived client, within the tarpit's slots.
// Any other visitor gets a logged bad gateway, which statusRewrites turns into a 200 that still shows it.
func deceptionServe(g *Gate, w http.ResponseWriter, r *http.Request) {
	now := time.Now()
	clientText := r.Header.Get(headerClient)
	client, err := netip.ParseAddr(clientText)
	if err != nil {
		http.Error(w, "deception: no client address", http.StatusBadRequest)
		return
	}
	requestURI, requestPath, deceived := deceptionRequestOf(r.Context(), g, r, client, now)
	if !deceived {
		metricsAdd(g.metrics, metricDeceptions, "refused", 1)
		slog.Warn("deception refused", "client", clientText, "reason", r.URL.Path, "path", requestPath[:min(len(requestPath), deceptionPathLogBytesMax)])
		http.Error(w, http.StatusText(http.StatusBadGateway), http.StatusBadGateway)
		return
	}
	if r.URL.Path == pathForgedCrawler {
		// the forged-crawler signal requires it: a backend answering the status itself is logged by the same service
		w.Header().Set(headerOutcome, verdictNames[VerdictForgedCrawler])
	}
	if !tarpitAcquire(g.tarpit, clientText) {
		metricsAdd(g.metrics, metricDeceptions, "busy", 1)
		tarpitRefuse(g.tarpit, w)
		return
	}
	defer tarpitRelease(g.tarpit, clientText)
	metricsAdd(g.metrics, metricTarpitActive, "", 1)
	defer metricsAdd(g.metrics, metricTarpitActive, "", -1)
	ctx, cancel := context.WithTimeout(r.Context(), tarpitDurationMax)
	defer cancel()

	target, found := deceptionTargetOf(requestPath)
	if !found {
		metricsAdd(g.metrics, metricDeceptions, "labyrinth", 1)
		tarpitLabyrinthWrite(ctx, g.tarpit, w, requestURI, r.Host, r.Header.Get("User-Agent"))
		return
	}
	canary, body := deceptionFakeRender(target, g.deception.canaryKey, clientText, requestPath)
	metricsAdd(g.metrics, metricDeceptions, target.name, 1)
	metricsAdd(g.metrics, metricCanaries, target.name, 1)
	slog.Info("deception canary", "canary", canary.ID, "client", clientText, "path", requestPath[:min(len(requestPath), deceptionPathLogBytesMax)],
		"target", target.name, "aws_key_id", canary.AWSKeyID, "aws_secret", canary.AWSSecret, "db_password", canary.DBPassword,
		"api_token", canary.APIToken, "git_token", canary.GitToken)
	w.Header().Set("Content-Type", target.contentType)
	w.WriteHeader(http.StatusOK)
	trickleWrite(ctx, w, body, deceptionChunkBytes, g.deception.interval)
}

// deceptionMux routes the deception listener, which traefik alone reaches on loopback.
func deceptionMux(g *Gate) *http.ServeMux {
	mux := http.NewServeMux()
	serve := func(w http.ResponseWriter, r *http.Request) { deceptionServe(g, w, r) }
	mux.HandleFunc(pathDeceive, serve)
	mux.HandleFunc(pathForgedCrawler, serve)
	mux.HandleFunc(pathHoneypot+"/", serve)
	return mux
}
