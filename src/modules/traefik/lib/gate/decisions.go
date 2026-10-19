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

// DecisionKind is the strongest remediation crowdsec holds for a client, in order of strength.
type DecisionKind int

const (
	DecisionNone DecisionKind = iota
	DecisionCaptcha
	DecisionBan
	// a scanner's: the ladder decides it with the ban that follows it (lib/ladder.nix), so it outranks the ban while
	// it lasts and the ban takes over when it ends
	DecisionDeceive
	// crowdsec did not answer: nobody knows
	DecisionUnknown
	DecisionKindCount
)

var decisionKindNames = [DecisionKindCount]string{"none", "captcha", "ban", "deceive", "unknown"}

// crowdsec's decision types the gate tells apart; any other one is a ban
const (
	lapiTypeCaptcha = "captcha"
	lapiTypeDeceive = "deceive"
)

// Decision is a client's remediation and when the longest decision of that kind ends.
type Decision struct {
	Kind  DecisionKind
	Until time.Time
	// the earliest id at crowdsec of that kind, so a ban or a deception is counted once however often its client returns
	ID int64
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

// decisionFromLapi folds crowdsec's answer for one client: deceive beats ban beats captcha, an unknown type counts as
// a ban (deny by default), the remaining durations are crowdsec's own.
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
		switch d.Type {
		case lapiTypeCaptcha:
			kind = DecisionCaptcha
		case lapiTypeDeceive:
			kind = DecisionDeceive
		}
		until := now.Add(remaining)
		switch {
		case kind > result.Kind:
			result = Decision{Kind: kind, Until: until, ID: d.ID}
		case kind == result.Kind:
			if until.After(result.Until) {
				result.Until = until
			}
			result.ID = min(result.ID, d.ID)
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
// as briefly, so an outage costs one failed call per client per ttl. fresh is true the first time a ban's or a
// deception's id is seen.
func decisionsGet(ctx context.Context, d *Decisions, client string, now time.Time) (decision Decision, fresh bool, err error) {
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
	counted := decision.Kind == DecisionBan || decision.Kind == DecisionDeceive
	fresh = counted && (!found || entry.decision.Kind != decision.Kind || entry.decision.ID != decision.ID)
	d.cache.mu.Lock()
	defer d.cache.mu.Unlock()
	tableRoomMake(d.cache, func(e decisionEntry) bool {
		return now.Sub(e.checkedAt) >= decisionCacheTTL && !e.decision.Until.After(now)
	})
	d.cache.entries[client] = decisionEntry{decision: decision, checkedAt: now}
	return decision, fresh, err
}
