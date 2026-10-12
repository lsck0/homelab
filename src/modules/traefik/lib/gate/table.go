package main

import "sync"

/*
 * -----------------------------------------------------------------------------
 * TYPES
 * -----------------------------------------------------------------------------
 */

// table is a map keyed by client with a hard size bound: every per-client state the gate keeps is one, so no client
// population, however large or spoofed, grows the gate past countMax entries per table.
type table[V any] struct {
	mu       sync.Mutex
	entries  map[string]V
	countMax int
}

/*
 * -----------------------------------------------------------------------------
 * LIFETIME
 * -----------------------------------------------------------------------------
 */

func tableCreate[V any](countMax int) *table[V] {
	if countMax < 1 {
		panic("table: countMax must be positive")
	}
	return &table[V]{entries: make(map[string]V), countMax: countMax}
}

func tableDestroy[V any](t *table[V]) {
	if t == nil {
		return
	}
	t.mu.Lock()
	t.entries = nil
	t.mu.Unlock()
}

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// tableRoomMake frees a slot before an insert, the lock held: stale entries go first, then arbitrary ones (go's map
// order is randomized) down to three quarters, so a flood of new clients costs the old ones their state, not memory.
func tableRoomMake[V any](t *table[V], stale func(V) bool) {
	if len(t.entries) < t.countMax {
		return
	}
	for key, value := range t.entries {
		if stale(value) {
			delete(t.entries, key)
		}
	}
	for key := range t.entries {
		if len(t.entries) <= t.countMax*3/4 {
			break
		}
		delete(t.entries, key)
	}
	if len(t.entries) >= t.countMax {
		panic("table: no room after eviction")
	}
}
