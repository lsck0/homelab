package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/netip"
	"os"
	"strings"
	"time"
)

// A request whose user agent names a search crawler is that crawler from the crawler's published ranges, or from an
// address whose reverse name lies in the crawler's domains and resolves back to it (forward-confirmed reverse dns); from
// anywhere else it forged the name. dns is never asked inside a request: an address's first request is unknown and
// judged like any other, a lookup beside it settles the address for a while.
//
// Rejected: forging on the published ranges alone. The gate's ranges are a snapshot (anubis' data/crawlers) and the
// crawlers add ranges every few weeks, so a real crawler from a new one would get the deception and a day's ban; a
// crawler the gate judges always has domains (settingsParse), the ranges only spare its lookup.
const (
	crawlerLookupTimeout = 5 * time.Second
	// crawler ranges and names change over months
	crawlerSettledTTL = time.Hour
	// a lookup that failed, or is under way, is asked again after this long
	crawlerUnknownTTL = time.Minute
	// addresses remembered at once: far above the crawlers' own, a few MiB at most
	crawlerAddressCountMax = 16384
	// lookups at once: forged names from many addresses wait for a later request rather than flood the resolver
	crawlerLookupsMax = 8
)

// CrawlerVerdict is what a request's user agent and address say about a search crawler.
type CrawlerVerdict int

const (
	// the user agent names no search crawler
	CrawlerNone CrawlerVerdict = iota
	CrawlerVerified
	CrawlerForged
	// dns has not answered yet, or failed: the request is judged like any other
	CrawlerUnknown
)

// CrawlerResolver is the dns a reverse name is checked with, as net.Resolver.
type CrawlerResolver interface {
	LookupAddr(ctx context.Context, address string) ([]string, error)
	LookupNetIP(ctx context.Context, network, host string) ([]netip.Addr, error)
}

// Crawler is one search crawler: the token its user agent carries and where it may come from.
type Crawler struct {
	name string
	// lowercase; a user agent naming it contains it in any case
	userAgent string
	prefixes  []netip.Prefix
	// lowercase, without the root's dot
	domains []string
}

type crawlerEntry struct {
	verdict   CrawlerVerdict
	checkedAt time.Time
}

// Crawlers judges requests naming a search crawler, remembering each address's dns verdict.
type Crawlers struct {
	list     []Crawler
	resolver CrawlerResolver
	lookups  chan struct{}
	// crawler name and address -> its verdict
	settled *table[crawlerEntry]
}

// crawlersCreate reads each crawler's ranges file (a json list of cidrs) once, at startup.
func crawlersCreate(settings []SettingsCrawler, resolver CrawlerResolver) (*Crawlers, error) {
	c := &Crawlers{resolver: resolver, lookups: make(chan struct{}, crawlerLookupsMax), settled: tableCreate[crawlerEntry](crawlerAddressCountMax)}
	for _, s := range settings {
		crawler := Crawler{name: s.Name, userAgent: strings.ToLower(s.UserAgent)}
		for _, domain := range s.ReverseDomains {
			crawler.domains = append(crawler.domains, strings.ToLower(strings.TrimSuffix(domain, ".")))
		}
		if len(crawler.domains) == 0 {
			panic("crawlers: " + s.Name + " has no reverse domains, which settingsParse requires")
		}
		if s.RangesFile != nil {
			data, err := os.ReadFile(*s.RangesFile)
			if err != nil {
				return nil, fmt.Errorf("crawler %s: %w", s.Name, err)
			}
			var cidrs []string
			if err := json.Unmarshal(data, &cidrs); err != nil || len(cidrs) == 0 {
				return nil, fmt.Errorf("crawler %s: %s is no non-empty json list of cidrs", s.Name, *s.RangesFile)
			}
			for _, cidr := range cidrs {
				prefix, err := netip.ParsePrefix(cidr)
				if err != nil {
					return nil, fmt.Errorf("crawler %s: %w", s.Name, err)
				}
				crawler.prefixes = append(crawler.prefixes, prefix)
			}
		}
		c.list = append(c.list, crawler)
	}
	return c, nil
}

func crawlersDestroy(c *Crawlers) {
	if c == nil {
		return
	}
	tableDestroy(c.settled)
}

func crawlerNamed(c *Crawlers, userAgent string) (*Crawler, bool) {
	lower := strings.ToLower(userAgent)
	for i := range c.list {
		if strings.Contains(lower, c.list[i].userAgent) {
			return &c.list[i], true
		}
	}
	return nil, false
}

func domainContains(domain, name string) bool {
	return name == domain || strings.HasSuffix(name, "."+domain)
}

func dnsNotFound(err error) bool {
	var dnsError *net.DNSError
	return errors.As(err, &dnsError) && dnsError.IsNotFound
}

// crawlerLookup settles an address by forward-confirmed reverse dns: a name in the crawler's domains that resolves
// back to the address verifies it, no such name forges it, a failing resolver leaves it unknown.
func crawlerLookup(ctx context.Context, c *Crawlers, crawler *Crawler, client netip.Addr) CrawlerVerdict {
	names, err := c.resolver.LookupAddr(ctx, client.String())
	if err != nil {
		if dnsNotFound(err) {
			return CrawlerForged
		}
		return CrawlerUnknown
	}
	verdict := CrawlerForged
	for _, name := range names {
		name = strings.ToLower(strings.TrimSuffix(name, "."))
		inDomains := false
		for _, domain := range crawler.domains {
			inDomains = inDomains || domainContains(domain, name)
		}
		if !inDomains {
			continue
		}
		addresses, err := c.resolver.LookupNetIP(ctx, "ip", name)
		if err != nil {
			if !dnsNotFound(err) {
				verdict = CrawlerUnknown
			}
			continue
		}
		for _, address := range addresses {
			if address.Unmap() == client {
				return CrawlerVerified
			}
		}
	}
	return verdict
}

func crawlerSettle(c *Crawlers, crawler *Crawler, client netip.Addr, key string) {
	defer func() { <-c.lookups }()
	ctx, cancel := context.WithTimeout(context.Background(), crawlerLookupTimeout)
	defer cancel()
	verdict := crawlerLookup(ctx, c, crawler, client)
	if verdict == CrawlerUnknown {
		slog.Warn("crawler: reverse dns failed, the address stays unknown", "crawler", crawler.name, "client", client)
	}
	c.settled.mu.Lock()
	defer c.settled.mu.Unlock()
	now := time.Now()
	tableRoomMake(c.settled, func(e crawlerEntry) bool { return crawlerEntryStale(e, now) })
	c.settled.entries[key] = crawlerEntry{verdict: verdict, checkedAt: now}
}

func crawlerEntryStale(e crawlerEntry, now time.Time) bool {
	ttl := crawlerSettledTTL
	if e.verdict == CrawlerUnknown {
		ttl = crawlerUnknownTTL
	}
	return now.Sub(e.checkedAt) >= ttl
}

// crawlerJudge says whether a request naming a search crawler comes from it; a dns check starts beside the request
// when the address is not settled, and the request is unknown meanwhile.
func crawlerJudge(c *Crawlers, userAgent string, client netip.Addr, now time.Time) CrawlerVerdict {
	crawler, named := crawlerNamed(c, userAgent)
	if !named {
		return CrawlerNone
	}
	client = client.Unmap()
	for _, prefix := range crawler.prefixes {
		if prefix.Contains(client) {
			return CrawlerVerified
		}
	}
	key := crawler.name + " " + client.String()
	c.settled.mu.Lock()
	defer c.settled.mu.Unlock()
	if entry, found := c.settled.entries[key]; found && !crawlerEntryStale(entry, now) {
		return entry.verdict
	}
	select {
	case c.lookups <- struct{}{}:
	default:
		return CrawlerUnknown
	}
	// the lookup under way answers every request of the address until it settles it
	tableRoomMake(c.settled, func(e crawlerEntry) bool { return crawlerEntryStale(e, now) })
	c.settled.entries[key] = crawlerEntry{verdict: CrawlerUnknown, checkedAt: now}
	go crawlerSettle(c, crawler, client, key)
	return CrawlerUnknown
}
