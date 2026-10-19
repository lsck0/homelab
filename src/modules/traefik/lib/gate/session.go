package main

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"time"
)

const (
	// a logout or an expired session keeps passing the gate this long at most
	sessionCacheTTL = time.Minute
	// one hop to the internal ingress and authelia; this only bounds a hung one
	sessionTimeout      = 2 * time.Second
	sessionBodyBytesMax = 64 << 10
	// sessions remembered at once, keyed by the cookie's hash
	sessionCountMax = 16384
	// checks in flight at once: forged cookies, each new, cannot turn the gate into a flood of authelia; past it a
	// cookie counts as no session until a slot frees
	sessionChecksMax = 16
	// authelia's level for a first factor; zero is anonymous
	sessionLevelMin = 1
)

type sessionEntry struct {
	authenticated bool
	checkedAt     time.Time
}

// Sessions asks authelia whether a session cookie belongs to a logged-in user: the gate never stops one.
type Sessions struct {
	http   *http.Client
	url    string
	host   string
	cookie string
	cache  *table[sessionEntry]
	slots  chan struct{}
}

type autheliaState struct {
	Status string `json:"status"`
	Data   struct {
		AuthenticationLevel int `json:"authentication_level"`
	} `json:"data"`
}

func sessionsCreate(settings SettingsSession) *Sessions {
	// the ingress serves the portal's certificate; it is verified for the portal's name, whatever address carries it
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = &tls.Config{ServerName: settings.Host, MinVersion: tls.VersionTLS12}
	return &Sessions{
		http:   &http.Client{Timeout: sessionTimeout, Transport: transport},
		url:    settings.URL,
		host:   settings.Host,
		cookie: settings.Cookie,
		cache:  tableCreate[sessionEntry](sessionCountMax),
		slots:  make(chan struct{}, sessionChecksMax),
	}
}

func sessionsDestroy(s *Sessions) {
	if s == nil {
		return
	}
	s.http.CloseIdleConnections()
	tableDestroy(s.cache)
}

func sessionsCheck(ctx context.Context, s *Sessions, value string) (bool, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, s.url, nil)
	if err != nil {
		return false, err
	}
	request.Host = s.host
	request.AddCookie(&http.Cookie{Name: s.cookie, Value: value})
	response, err := s.http.Do(request)
	if err != nil {
		return false, err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, sessionBodyBytesMax))
	if err != nil || response.StatusCode != http.StatusOK {
		return false, err
	}
	var state autheliaState
	if err := json.Unmarshal(body, &state); err != nil {
		return false, err
	}
	return state.Status == "OK" && state.Data.AuthenticationLevel >= sessionLevelMin, nil
}

// sessionsAuthenticated is true when the request carries a session authelia knows as logged in; a missing cookie
// costs nothing, a known one a map lookup.
func sessionsAuthenticated(ctx context.Context, s *Sessions, request *http.Request, now time.Time) (bool, error) {
	if s == nil {
		return false, nil
	}
	cookie, err := request.Cookie(s.cookie)
	if err != nil || cookie.Value == "" {
		return false, nil
	}
	digest := sha256.Sum256([]byte(cookie.Value))
	key := hex.EncodeToString(digest[:])
	s.cache.mu.Lock()
	entry, found := s.cache.entries[key]
	s.cache.mu.Unlock()
	if found && now.Sub(entry.checkedAt) < sessionCacheTTL {
		return entry.authenticated, nil
	}
	select {
	case s.slots <- struct{}{}:
	default:
		return false, nil
	}
	authenticated, err := sessionsCheck(ctx, s, cookie.Value)
	<-s.slots
	if err != nil {
		return false, err
	}
	s.cache.mu.Lock()
	defer s.cache.mu.Unlock()
	tableRoomMake(s.cache, func(e sessionEntry) bool { return now.Sub(e.checkedAt) >= sessionCacheTTL })
	s.cache.entries[key] = sessionEntry{authenticated: authenticated, checkedAt: now}
	return authenticated, nil
}
