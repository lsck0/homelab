package main

import (
	"context"
	"log/slog"
	"net"
	"net/netip"
	"sync"
	"time"
)

/*
 * -----------------------------------------------------------------------------
 * CONSTANTS
 * -----------------------------------------------------------------------------
 */

const (
	// the house's public address rotates rarely; a request after this long resolves it again, in the background
	allowResolveInterval = 5 * time.Minute
	allowResolveTimeout  = 5 * time.Second
)

/*
 * -----------------------------------------------------------------------------
 * TYPES
 * -----------------------------------------------------------------------------
 */

// Allow is every source the gate never stops: fixed networks, and names resolved lazily to the addresses they have.
type Allow struct {
	prefixes []netip.Prefix
	hosts    []string

	mu         sync.Mutex
	resolved   []netip.Addr
	resolvedAt time.Time
	resolving  bool
}

/*
 * -----------------------------------------------------------------------------
 * LIFETIME
 * -----------------------------------------------------------------------------
 */

func allowCreate(settings SettingsAllow) *Allow {
	allow := &Allow{hosts: settings.Hosts}
	for _, cidr := range settings.Cidrs {
		// settingsParse has parsed every one
		allow.prefixes = append(allow.prefixes, netip.MustParsePrefix(cidr))
	}
	// the house is known before its first request
	if len(allow.hosts) > 0 {
		allow.resolving = true
		go allowResolve(allow)
	}
	return allow
}

func allowDestroy(_ *Allow) {}

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

func allowResolve(a *Allow) {
	ctx, cancel := context.WithTimeout(context.Background(), allowResolveTimeout)
	defer cancel()
	var addresses []netip.Addr
	for _, host := range a.hosts {
		found, err := net.DefaultResolver.LookupNetIP(ctx, "ip4", host)
		if err != nil {
			slog.Warn("allow: host does not resolve, keeping its last address", "host", host, "err", err)
			a.mu.Lock()
			a.resolvedAt, a.resolving = time.Now(), false
			a.mu.Unlock()
			return
		}
		addresses = append(addresses, found...)
	}
	a.mu.Lock()
	a.resolved, a.resolvedAt, a.resolving = addresses, time.Now(), false
	a.mu.Unlock()
}

// allowContains is true for a never-stopped client; a stale resolution is refreshed beside the request, never in it.
func allowContains(a *Allow, client netip.Addr, now time.Time) bool {
	client = client.Unmap()
	for _, prefix := range a.prefixes {
		if prefix.Contains(client) {
			return true
		}
	}
	if len(a.hosts) == 0 {
		return false
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if now.Sub(a.resolvedAt) >= allowResolveInterval && !a.resolving {
		a.resolving = true
		go allowResolve(a)
	}
	for _, address := range a.resolved {
		if address == client {
			return true
		}
	}
	return false
}
