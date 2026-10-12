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
	// the house's public address and prefix rotate rarely; a request after this long resolves them again, in the background
	allowResolveInterval = 5 * time.Minute
	allowResolveTimeout  = 5 * time.Second
)

// a host's network and the bits of an address of it
var allowNetworkBits = map[string]int{"ip4": 32, "ip6": 128}

/*
 * -----------------------------------------------------------------------------
 * TYPES
 * -----------------------------------------------------------------------------
 */

// AllowLookup resolves a name to its addresses of one network, as net.Resolver.LookupNetIP.
type AllowLookup func(ctx context.Context, network, host string) ([]netip.Addr, error)

// Allow is every source the gate never stops: fixed networks, and names resolved lazily to the prefixes around their
// addresses; a name that stops resolving keeps its last ones.
type Allow struct {
	prefixes []netip.Prefix
	hosts    []SettingsAllowHost
	lookup   AllowLookup

	mu sync.Mutex
	// per host, its last answer
	resolved   [][]netip.Prefix
	resolvedAt time.Time
	resolving  bool
}

/*
 * -----------------------------------------------------------------------------
 * LIFETIME
 * -----------------------------------------------------------------------------
 */

func allowCreate(settings SettingsAllow) *Allow {
	return allowCreateWith(settings, net.DefaultResolver.LookupNetIP)
}

// allowCreateWith resolves the hosts with lookup: a test's stand-in for dns
func allowCreateWith(settings SettingsAllow, lookup AllowLookup) *Allow {
	allow := &Allow{hosts: settings.Hosts, lookup: lookup, resolved: make([][]netip.Prefix, len(settings.Hosts))}
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
	answers := make([][]netip.Prefix, len(a.hosts))
	for i, host := range a.hosts {
		found, err := a.lookup(ctx, host.Network, host.Name)
		if err != nil {
			slog.Warn("allow: host does not resolve, keeping its last address", "host", host.Name, "err", err)
			continue
		}
		for _, address := range found {
			// a v4 answer to a v6 name (mapped) is not the prefix asked for
			address = address.Unmap()
			if address.BitLen() != allowNetworkBits[host.Network] {
				continue
			}
			// settingsParse has bounded the bits by the network
			prefix, _ := address.Prefix(host.Bits)
			answers[i] = append(answers[i], prefix)
		}
	}
	a.mu.Lock()
	for i, answer := range answers {
		if answer != nil {
			a.resolved[i] = answer
		}
	}
	a.resolvedAt, a.resolving = time.Now(), false
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
	for _, prefixes := range a.resolved {
		for _, prefix := range prefixes {
			if prefix.Contains(client) {
				return true
			}
		}
	}
	return false
}
