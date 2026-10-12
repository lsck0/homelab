package main

import (
	"crypto/sha256"
	"encoding/base64"
	"html/template"
	"net/http"
	"strconv"
	"strings"
	"time"
)

/*
 * -----------------------------------------------------------------------------
 * CONSTANTS
 * -----------------------------------------------------------------------------
 */

// The lab's look: the homepage's slate theme, light or dark as the system asks, system fonts only, no script at all.
const pageStyle = `
:root{color-scheme:light dark;--bg:#f8fafc;--card:#fff;--ink:#0f172a;--muted:#475569;--line:#e2e8f0;--accent:#0369a1;
--accent-ink:#fff;--warn-bg:#fef3c7;--warn-ink:#78350f;--stop:#b91c1c}
@media (prefers-color-scheme:dark){:root{--bg:#0f172a;--card:#1e293b;--ink:#e2e8f0;--muted:#94a3b8;--line:#334155;
--accent:#38bdf8;--accent-ink:#0f172a;--warn-bg:#422006;--warn-ink:#fde68a;--stop:#f87171}}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:grid;grid-template-columns:minmax(0,1fr);place-items:center;padding:16px;
background:var(--bg);color:var(--ink);
font:16px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{width:100%;min-width:0;max-width:760px;background:var(--card);border:1px solid var(--line);border-radius:16px;padding:28px;
box-shadow:0 10px 30px rgb(15 23 42/.08)}
h1{margin:0 0 4px;font-size:1.4rem;line-height:1.3}
.lead{margin:0 0 20px;color:var(--muted)}
.notice{margin:0 0 16px;padding:10px 14px;border-radius:10px;background:var(--warn-bg);color:var(--warn-ink)}
figure{margin:0 0 16px;border:1px solid var(--line);border-radius:12px;padding:8px}
figure img{display:block;max-width:100%;height:auto;margin:0 auto}
.question{margin:0 0 16px;font-size:1.1rem;font-weight:600}
form{display:flex;gap:10px;flex-wrap:wrap;align-items:flex-end}
label{display:flex;flex-direction:column;gap:6px;flex:1 1 220px;font-size:.9rem;color:var(--muted)}
input{font:600 1.3rem/1 ui-monospace,"SF Mono",Menlo,Consolas,monospace;letter-spacing:.2em;padding:12px 14px;
border:1px solid var(--line);border-radius:10px;background:var(--bg);color:var(--ink);text-transform:lowercase}
input:focus-visible,button:focus-visible{outline:3px solid var(--accent);outline-offset:2px}
button{font:600 1rem/1 system-ui,sans-serif;padding:15px 22px;border:0;border-radius:10px;background:var(--accent);
color:var(--accent-ink);cursor:pointer}
.small{margin:18px 0 0;font-size:.85rem;color:var(--muted)}
.stop{color:var(--stop)}
@media (max-width:480px){main{padding:18px;border-radius:12px}h1{font-size:1.2rem}}
`

const (
	headerOutcome = "X-Lab-Gate"
	// a gate page is per client and per moment: never stored
	pageCacheControl = "no-store"
)

var pageCSP = "default-src 'none'; img-src data:; form-action 'self'; frame-ancestors 'none'; base-uri 'none'; style-src 'sha256-" +
	cssDigest() + "'"

var pageTemplate = template.Must(template.New("page").Parse(`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>{{.Title}}</title>
<style>{{.Style}}</style>
</head>
<body>
<main>
{{if .Captcha}}<h1>{{.Title}}</h1>
<p class="lead">{{.Lead}}</p>
{{if .Notice}}<p class="notice" role="status">{{.Notice}}</p>{{end}}
<figure><img src="{{.Image}}" width="{{.Width}}" height="{{.Height}}" alt="{{.Alt}}"></figure>
<p class="question" id="question">{{.Question}}</p>
<form method="post" action="{{.Action}}">
<label for="answer">Answer: six characters, 0-9 and a-f
<input id="answer" name="answer" type="text" required minlength="6" maxlength="8" pattern="(0[xX])?[0-9A-Fa-f]{6}"
 autocomplete="off" autocapitalize="off" spellcheck="false" autofocus aria-describedby="question"></label>
<button type="submit">Continue</button>
</form>
<p class="small">A wrong answer brings a new picture. {{.TriesLeft}} of {{.TriesMax}} wrong answers left this hour; past them {{.Subject}} is banned.
No script, no tracking, nothing from anyone else. {{.Aside}}</p>
{{else}}<h1 class="stop">{{.Title}}</h1>
<p class="lead">{{.Lead}}</p>
{{if .Until}}<p class="small">It lifts on its own at {{.Until}}.</p>{{end}}{{end}}
</main>
</body>
</html>
`))

/*
 * -----------------------------------------------------------------------------
 * TYPES
 * -----------------------------------------------------------------------------
 */

type pageData struct {
	Title     string
	Style     template.CSS
	Captcha   bool
	Notice    string
	Image     template.URL
	Width     int
	Height    int
	Alt       string
	Question  string
	Action    string
	TriesLeft int
	TriesMax  int
	Subject   string
	Aside     string
	Lead      string
	Until     string
}

// captchaWording is what a captcha page says around its picture: a scene for a flagged address, the rows for an
// onion session.
type captchaWording struct {
	title   string
	lead    string
	alt     string
	subject string
	aside   string
	notices map[Notice]string
}

var captchaNoticesCommon = map[Notice]string{
	NoticeNone:    "",
	NoticeWrong:   "That answer was not right. Here is a new picture.",
	NoticeExpired: "That picture had expired. Here is a new one.",
}

var sceneWording = captchaWording{
	title:   "One question before you continue",
	lead:    "This address looked automated to the lab. Answer one question about the picture to go on.",
	alt:     "Coloured shapes, each with a six-character label beneath it",
	subject: "this address",
	aside:   "Can't solve it? The house network and WireGuard are never asked.",
	notices: captchaNoticesCommon,
}

var onionWording = captchaWording{
	title: "Check the address before you continue",
	lead: "Copies of onion sites pass the real one through to read what you type. Exactly one address in the picture " +
		"is this site's: the one in your address bar, every character of it.",
	alt:     "Onion addresses, each with a six-character label beside it",
	subject: "this browser",
	aside:   "Does no address in the picture match yours exactly? Then this page is a copy: close it.",
	notices: map[Notice]string{
		NoticeNone:    captchaNoticesCommon[NoticeNone],
		NoticeWrong:   captchaNoticesCommon[NoticeWrong],
		NoticeExpired: captchaNoticesCommon[NoticeExpired],
		NoticeDecoy: "That label stood beside another address than this site's. Compare every character with your " +
			"address bar: if no row matches it, this page is a copy.",
	},
}

/*
 * -----------------------------------------------------------------------------
 * INTERNAL
 * -----------------------------------------------------------------------------
 */

func cssDigest() string {
	digest := sha256.Sum256([]byte(pageStyle))
	return base64.StdEncoding.EncodeToString(digest[:])
}

func plural(count int64, unit string) string {
	if count == 1 {
		return "1 " + unit
	}
	return strconv.FormatInt(count, 10) + " " + unit + "s"
}

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// durationHuman is a remaining time in its two largest units, rounded down: what a person reads at a glance.
func durationHuman(d time.Duration) string {
	if d < time.Minute {
		return "less than a minute"
	}
	units := []struct {
		name string
		size time.Duration
	}{{"day", 24 * time.Hour}, {"hour", time.Hour}, {"minute", time.Minute}}
	var parts []string
	for i, unit := range units {
		count := int64(d / unit.size)
		if count == 0 {
			continue
		}
		parts = append(parts, plural(count, unit.name))
		if next := i + 1; next < len(units) {
			if rest := int64((d - time.Duration(count)*unit.size) / units[next].size); rest > 0 {
				parts = append(parts, plural(rest, units[next].name))
			}
		}
		break
	}
	return strings.Join(parts, " ")
}

// pageWrite answers with a gate page; the outcome header is what the access log and crowdsec's scenarios read.
func pageWrite(w http.ResponseWriter, status int, outcome string, data pageData) {
	data.Style = template.CSS(pageStyle)
	header := w.Header()
	header.Set("Content-Type", "text/html; charset=utf-8")
	header.Set("Cache-Control", pageCacheControl)
	header.Set("Content-Security-Policy", pageCSP)
	header.Set("X-Content-Type-Options", "nosniff")
	header.Set("X-Frame-Options", "DENY")
	header.Set("Referrer-Policy", "no-referrer")
	header.Set(headerOutcome, outcome)
	w.WriteHeader(status)
	// the template is fixed and its data typed: a failure is the client gone mid-page, with nobody left to tell
	_ = pageTemplate.Execute(w, data)
}
