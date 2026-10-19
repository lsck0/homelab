package main

import (
	"math"
	"strconv"
	"time"
)

// anonymous clients bucketed at once, per client and route scale
const limitCountMax = 65536

type bucket struct {
	tokens float64
	at     time.Time
	rate   float64
	burst  float64
}

// Limiter is a token bucket per anonymous client and route scale, below the ingress's own per-client limit.
type Limiter struct {
	averagePerSecond float64
	burst            float64
	buckets          *table[bucket]
}

func limiterCreate(settings SettingsAnonymous) *Limiter {
	return &Limiter{
		averagePerSecond: float64(settings.AveragePerSecond),
		burst:            float64(settings.Burst),
		buckets:          tableCreate[bucket](limitCountMax),
	}
}

func limiterDestroy(l *Limiter) {
	if l == nil {
		return
	}
	tableDestroy(l.buckets)
}

// limiterTake spends one token of the client's bucket at the route's scale; false: the client is over its limit.
func limiterTake(l *Limiter, client string, scale int, now time.Time) bool {
	if scale < 1 {
		panic("limiter: scale must be positive")
	}
	rate, burst := l.averagePerSecond*float64(scale), l.burst*float64(scale)
	key := client + "/" + strconv.Itoa(scale)
	l.buckets.mu.Lock()
	defer l.buckets.mu.Unlock()
	current, found := l.buckets.entries[key]
	if !found {
		// a bucket that has refilled is no different from a new one
		tableRoomMake(l.buckets, func(b bucket) bool { return b.tokens+now.Sub(b.at).Seconds()*b.rate >= b.burst })
		current = bucket{tokens: burst, at: now, rate: rate, burst: burst}
	}
	current.tokens = math.Min(burst, current.tokens+now.Sub(current.at).Seconds()*rate)
	current.at = now
	allowed := current.tokens >= 1
	if allowed {
		current.tokens--
	}
	l.buckets.entries[key] = current
	return allowed
}
