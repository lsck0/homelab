package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

const (
	// how stale a client's verdict may be: a new ban or captcha reaches its client this much later at most, and a
	// page load of tens of requests asks crowdsec once
	decisionCacheTTL = 5 * time.Second
	// crowdsec answers on loopback in milliseconds; this only bounds a hung one
	lapiTimeout       = 2 * time.Second
	lapiDecisionsPath = "/v1/decisions"
	lapiKeyHeader     = "X-Api-Key"
	lapiBodyBytesMax  = 1 << 20
	// clients remembered at once: far above a flood's distinct addresses per ttl, a few MiB at most
	decisionCountMax = 65536
)

// DecisionKind is the strongest remediation crowdsec holds for a client.
type DecisionKind int

const (
	DecisionNone DecisionKind = iota
	DecisionCaptcha
	DecisionBan
	// crowdsec did not answer: nobody knows
	DecisionUnknown
)

// Decision is a client's remediation and when the longest decision of that kind ends.
type Decision struct {
	Kind  DecisionKind
	Until time.Time
	// the ban's id at crowdsec, so a ban is counted once however often its client returns
	BanID int64
}

type decisionEntry struct {
	decision  Decision
	checkedAt time.Time
}

// Decisions asks crowdsec's local api for a client's decisions, through a short per-client cache.
type Decisions struct {
	http    *http.Client
	baseURL string
	key     string
	cache   *table[decisionEntry]
}

type lapiDecision struct {
	ID       int64  `json:"id"`
	Type     string `json:"type"`
	Duration string `json:"duration"`
}

func decisionsCreate(baseURL, key string) *Decisions {
	return &Decisions{
		http:    &http.Client{Timeout: lapiTimeout},
		baseURL: baseURL,
		key:     key,
		cache:   tableCreate[decisionEntry](decisionCountMax),
	}
}

func decisionsDestroy(d *Decisions) {
	if d == nil {
		return
	}
	d.http.CloseIdleConnections()
	tableDestroy(d.cache)
}

// decisionFromLapi folds crowdsec's answer for one client: ban beats captcha, an unknown type counts as a ban (deny
// by default), the remaining durations are crowdsec's own.
func decisionFromLapi(body []byte, now time.Time) (Decision, error) {
	var decisions []lapiDecision
	if err := json.Unmarshal(body, &decisions); err != nil {
		return Decision{}, fmt.Errorf("lapi: %w", err)
	}
	result := Decision{Kind: DecisionNone}
	for _, d := range decisions {
		remaining, err := time.ParseDuration(d.Duration)
		if err != nil {
			return Decision{}, fmt.Errorf("lapi: decision %d: %w", d.ID, err)
		}
		kind := DecisionBan
		if d.Type == "captcha" {
			kind = DecisionCaptcha
		}
		until := now.Add(remaining)
		switch {
		case kind > result.Kind:
			result = Decision{Kind: kind, Until: until}
		case kind == result.Kind && until.After(result.Until):
			result.Until = until
		}
		if kind == DecisionBan && (result.BanID == 0 || d.ID < result.BanID) {
			result.BanID = d.ID
		}
	}
	return result, nil
}

func decisionsFetch(ctx context.Context, d *Decisions, client string, now time.Time) (Decision, error) {
	query := url.Values{"ip": {client}}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, d.baseURL+lapiDecisionsPath+"?"+query.Encode(), nil)
	if err != nil {
		return Decision{}, err
	}
	request.Header.Set(lapiKeyHeader, d.key)
	response, err := d.http.Do(request)
	if err != nil {
		return Decision{}, err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, lapiBodyBytesMax))
	if err != nil {
		return Decision{}, err
	}
	if response.StatusCode != http.StatusOK {
		return Decision{}, fmt.Errorf("lapi: status %d", response.StatusCode)
	}
	return decisionFromLapi(body, now)
}

// decisionsGet is the client's decision as of at most decisionCacheTTL ago; an unreachable crowdsec is Unknown, cached
// as briefly, so an outage costs one failed call per client per ttl. newBan is true the first time a ban id is seen.
func decisionsGet(ctx context.Context, d *Decisions, client string, now time.Time) (decision Decision, newBan bool, err error) {
	d.cache.mu.Lock()
	entry, found := d.cache.entries[client]
	d.cache.mu.Unlock()
	if found && now.Sub(entry.checkedAt) < decisionCacheTTL {
		return entry.decision, false, nil
	}
	decision, err = decisionsFetch(ctx, d, client, now)
	if err != nil {
		decision = Decision{Kind: DecisionUnknown}
	}
	// the client gave up, crowdsec did not fail: nothing learnt worth keeping
	if ctx.Err() != nil {
		return decision, false, err
	}
	newBan = decision.Kind == DecisionBan && (!found || entry.decision.BanID != decision.BanID)
	d.cache.mu.Lock()
	defer d.cache.mu.Unlock()
	tableRoomMake(d.cache, func(e decisionEntry) bool {
		return now.Sub(e.checkedAt) >= decisionCacheTTL && !e.decision.Until.After(now)
	})
	d.cache.entries[client] = decisionEntry{decision: decision, checkedAt: now}
	return decision, newBan, err
}
