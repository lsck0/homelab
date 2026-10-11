// Package clientip makes the request's real client its only client address: the nearest address of its forwarding
// chain that is not a trusted proxy becomes X-Real-Ip and the request's remote address, and X-Forwarded-For is
// dropped, so traefik forwards exactly that client as the backend's X-Forwarded-For.
//
// The chain is X-Forwarded-For as received, oldest hop first, then the socket peer. Walking it from the peer
// backwards, every address in trustedIPs is a proxy that appended the one before it; the first address that is not,
// is the client. A client can prepend anything to X-Forwarded-For, but never after the first trusted proxy, which
// appends the address it saw: so the result is the client as the outermost trusted proxy saw it, and an untrusted
// peer is its own client whatever headers it sends.
//
// Traefik's own sources fall short of this: X-Real-Ip from a trusted sender is whatever that sender passed on
// (Cloudflare passes a client-sent one through), and an ipStrategy over X-Forwarded-For sees no header at all for a
// direct client, so every direct client shares the key "". Rate limits, anubis and the access log read X-Real-Ip
// after this middleware (modules/traefik puts it first on every websecure router); the crowdsec bouncer, forwardauth
// and every backend read the remote address and the X-Forwarded-For traefik derives from it, so no backend has to
// know the ingress's trusted proxies to find the client.
//
// Interpreted by traefik's yaegi, so the standard library only.
package clientip

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"strings"
)

const headerRealIP = "X-Real-Ip"
const headerForwardedFor = "X-Forwarded-For"

// Config is the middleware's options: the proxies whose X-Forwarded-For entries are believed.
type Config struct {
	TrustedIPs []string `json:"trustedIPs,omitempty"`
}

// CreateConfig returns the default options: no proxy is trusted, every peer is its own client.
func CreateConfig() *Config {
	return &Config{}
}

// ClientIP is the middleware.
type ClientIP struct {
	next    http.Handler
	trusted []*net.IPNet
}

// New parses the trusted networks; a malformed one is a configuration error, the router does not start.
func New(_ context.Context, next http.Handler, config *Config, name string) (http.Handler, error) {
	trusted := make([]*net.IPNet, 0, len(config.TrustedIPs))
	for _, cidr := range config.TrustedIPs {
		_, network, err := net.ParseCIDR(cidr)
		if err != nil {
			return nil, fmt.Errorf("%s: trustedIPs: %w", name, err)
		}
		trusted = append(trusted, network)
	}
	return &ClientIP{next: next, trusted: trusted}, nil
}

func (c *ClientIP) isTrusted(ip net.IP) bool {
	for _, network := range c.trusted {
		if network.Contains(ip) {
			return true
		}
	}
	return false
}

// client walks the chain from the peer backwards and returns the first untrusted address; a hop that is no address
// ends the walk at the last address that was one, since nothing before garbage can be believed.
func (c *ClientIP) client(req *http.Request, peer string) string {
	client := peer
	peerIP := net.ParseIP(peer)
	if peerIP == nil || !c.isTrusted(peerIP) {
		return client
	}
	hops := strings.Split(strings.Join(req.Header.Values(headerForwardedFor), ","), ",")
	for i := len(hops) - 1; i >= 0; i-- {
		hop := strings.TrimSpace(hops[i])
		if hop == "" {
			continue
		}
		hopIP := net.ParseIP(hop)
		if hopIP == nil {
			return client
		}
		client = hopIP.String()
		if !c.isTrusted(hopIP) {
			return client
		}
	}
	return client
}

func (c *ClientIP) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
	peer, port, err := net.SplitHostPort(req.RemoteAddr)
	if err != nil {
		peer, port = req.RemoteAddr, "0"
	}
	client := c.client(req, peer)
	req.Header.Set(headerRealIP, client)
	req.Header.Del(headerForwardedFor)
	req.RemoteAddr = net.JoinHostPort(client, port)
	c.next.ServeHTTP(rw, req)
}
