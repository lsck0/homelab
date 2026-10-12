package main

import (
	"context"
	"io"
	"net/http"
	"strconv"
	"sync"
	"time"
)

/*
 * -----------------------------------------------------------------------------
 * CONSTANTS
 * -----------------------------------------------------------------------------
 */

// A labyrinth answer leaves at 32 bytes a second for two minutes at most: a crawler waits minutes per page for a few
// kilobytes of nonsense, the edge holds one idle connection and goroutine per trickle. The bounds keep that cheap
// whatever arrives: two trickles per client, 128 in all; past them the request is refused at once, which costs less
// than serving it.
const (
	tarpitChunkBytes      = 16
	tarpitChunkInterval   = 500 * time.Millisecond
	tarpitDurationMax     = 2 * time.Minute
	tarpitPerClientMax    = 2
	tarpitTotalMax        = 128
	tarpitUpstreamTimeout = 10 * time.Second
	// everything the trickle can send in its time, so the upstream's page is never read past it
	tarpitBodyBytesMax = int64(tarpitDurationMax / tarpitChunkInterval * tarpitChunkBytes)
	// a refused crawler may come back after this long
	tarpitRetryAfterSeconds = 60
)

// the upstream's own headers that describe the body as it was, not as it trickles
var tarpitDroppedHeaders = []string{"Content-Length", "Content-Encoding", "Transfer-Encoding", "Connection"}

/*
 * -----------------------------------------------------------------------------
 * TYPES
 * -----------------------------------------------------------------------------
 */

// Tarpit proxies the labyrinth and trickles its answers, bounded per client and in total.
type Tarpit struct {
	http     *http.Client
	upstream string
	metrics  *Metrics
	interval time.Duration

	mu       sync.Mutex
	perIP    map[string]int
	total    int
	totalMax int
}

/*
 * -----------------------------------------------------------------------------
 * LIFETIME
 * -----------------------------------------------------------------------------
 */

func tarpitCreate(upstream string, metrics *Metrics) *Tarpit {
	return &Tarpit{
		http:     &http.Client{Timeout: tarpitUpstreamTimeout},
		upstream: upstream,
		metrics:  metrics,
		interval: tarpitChunkInterval,
		perIP:    map[string]int{},
		totalMax: tarpitTotalMax,
	}
}

func tarpitDestroy(t *Tarpit) {
	if t == nil {
		return
	}
	t.http.CloseIdleConnections()
}

/*
 * -----------------------------------------------------------------------------
 * INTERNAL
 * -----------------------------------------------------------------------------
 */

func tarpitAcquire(t *Tarpit, client string) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.total >= t.totalMax || t.perIP[client] >= tarpitPerClientMax {
		return false
	}
	t.total++
	t.perIP[client]++
	return true
}

func tarpitRelease(t *Tarpit, client string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.total < 1 || t.perIP[client] < 1 {
		panic("tarpit: release without acquire")
	}
	t.total--
	t.perIP[client]--
	if t.perIP[client] == 0 {
		delete(t.perIP, client)
	}
}

func tarpitFetch(ctx context.Context, t *Tarpit, r *http.Request) (*http.Response, []byte, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, t.upstream+r.URL.RequestURI(), nil)
	if err != nil {
		return nil, nil, err
	}
	request.Host = r.Host
	request.Header.Set("User-Agent", r.Header.Get("User-Agent"))
	response, err := t.http.Do(request)
	if err != nil {
		return nil, nil, err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, tarpitBodyBytesMax))
	return response, body, err
}

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// tarpitServe is the labyrinth's service: the upstream's page, a few bytes at a time, until it ends, the client goes
// or the time is up.
func tarpitServe(t *Tarpit, w http.ResponseWriter, r *http.Request) {
	client := r.Header.Get(headerClient)
	if !tarpitAcquire(t, client) {
		metricsAdd(t.metrics, metricTarpit, "refused", 1)
		w.Header().Set("Retry-After", strconv.Itoa(tarpitRetryAfterSeconds))
		w.WriteHeader(http.StatusTooManyRequests)
		return
	}
	defer tarpitRelease(t, client)
	metricsAdd(t.metrics, metricTarpit, "trickled", 1)
	metricsAdd(t.metrics, metricTarpitActive, "", 1)
	defer metricsAdd(t.metrics, metricTarpitActive, "", -1)

	ctx, cancel := context.WithTimeout(r.Context(), tarpitDurationMax)
	defer cancel()
	response, body, err := tarpitFetch(ctx, t, r)
	if err != nil {
		metricsAdd(t.metrics, metricErrors, "labyrinth", 1)
		w.WriteHeader(http.StatusBadGateway)
		return
	}
	for name, values := range response.Header {
		w.Header()[name] = values
	}
	for _, name := range tarpitDroppedHeaders {
		w.Header().Del(name)
	}
	w.WriteHeader(response.StatusCode)
	controller := http.NewResponseController(w)
	ticker := time.NewTicker(t.interval)
	defer ticker.Stop()
	for sent := 0; sent < len(body); sent += tarpitChunkBytes {
		if _, err := w.Write(body[sent:min(sent+tarpitChunkBytes, len(body))]); err != nil {
			return
		}
		if err := controller.Flush(); err != nil {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
