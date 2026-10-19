package main

import (
	"net/http"
	"strings"
)

const (
	headerCookie    = "Cookie"
	cookieDelimiter = ";"
	cookieJoin      = "; "
)

// cookiesStrip is the request's cookies without the named ones, each other pair kept byte for byte; one value for
// every Cookie header the request carried (http/2 sends one per cookie).
func cookiesStrip(values []string, names map[string]bool) string {
	kept := make([]string, 0, len(values))
	for _, value := range values {
		for _, pair := range strings.Split(value, cookieDelimiter) {
			pair = strings.TrimSpace(pair)
			name, _, _ := strings.Cut(pair, "=")
			if pair == "" || names[strings.TrimSpace(name)] {
				continue
			}
			kept = append(kept, pair)
		}
	}
	return strings.Join(kept, cookieJoin)
}

// gateStrip answers forwardauth on a route the sso portal does not guard: traefik puts the Cookie header it returns
// in place of the client's (authResponseHeaders), none when nothing is left, so the backend never sees the session.
func gateStrip(g *Gate, w http.ResponseWriter, r *http.Request) {
	if kept := cookiesStrip(r.Header.Values(headerCookie), g.stripCookies); kept != "" {
		w.Header().Set(headerCookie, kept)
	}
	w.WriteHeader(http.StatusOK)
}
