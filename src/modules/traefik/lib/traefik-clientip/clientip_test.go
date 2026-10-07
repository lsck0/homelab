package clientip

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestClient(t *testing.T) {
	cases := []struct {
		name   string
		peer   string
		xff    []string
		realIP string
		want   string
	}{
		{"direct client is its own", "198.51.100.7:4000", nil, "", "198.51.100.7"},
		{"direct client cannot forge", "198.51.100.7:4000", []string{"1.2.3.4"}, "9.9.9.9", "198.51.100.7"},
		{"through cloudflare", "104.16.0.10:4000", []string{"203.0.113.9"}, "6.6.6.6", "203.0.113.9"},
		{"forged hop before cloudflare's", "104.16.0.10:4000", []string{"1.2.3.4, 203.0.113.9"}, "", "203.0.113.9"},
		{"cloudflare then the edge", "10.200.0.200:4000", []string{"1.2.3.4, 203.0.113.9, 104.16.0.10"}, "", "203.0.113.9"},
		{"edge without cloudflare", "10.200.0.200:4000", []string{"198.51.100.7"}, "", "198.51.100.7"},
		{"headers split over lines", "10.200.0.200:4000", []string{"203.0.113.9", "104.16.0.10"}, "", "203.0.113.9"},
		{"garbage stops the walk", "10.200.0.200:4000", []string{"203.0.113.9, nonsense, 104.16.0.10"}, "", "104.16.0.10"},
		{"trusted peer without a chain", "10.200.0.200:4000", nil, "", "10.200.0.200"},
	}
	config := CreateConfig()
	config.TrustedIPs = []string{"104.16.0.0/13", "10.200.0.200/32"}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var got, remote string
			var forwarded []string
			next := http.HandlerFunc(func(_ http.ResponseWriter, req *http.Request) {
				got, remote, forwarded = req.Header.Get(headerRealIP), req.RemoteAddr, req.Header.Values(headerForwardedFor)
			})
			handler, err := New(context.Background(), next, config, "client-ip")
			if err != nil {
				t.Fatal(err)
			}
			req := httptest.NewRequest(http.MethodGet, "https://wat.lsck0.dev/", nil)
			req.RemoteAddr = tc.peer
			for _, v := range tc.xff {
				req.Header.Add(headerForwardedFor, v)
			}
			if tc.realIP != "" {
				req.Header.Set(headerRealIP, tc.realIP)
			}
			handler.ServeHTTP(httptest.NewRecorder(), req)
			if got != tc.want {
				t.Fatalf("X-Real-Ip = %q, want %q", got, tc.want)
			}
			// the proxy appends the remote address to X-Forwarded-For: the backend sees the client alone
			if host, _, err := net.SplitHostPort(remote); err != nil || host != tc.want {
				t.Fatalf("remote address = %q, want the client %q", remote, tc.want)
			}
			if len(forwarded) != 0 {
				t.Fatalf("X-Forwarded-For = %q, want none", forwarded)
			}
		})
	}
}

func TestMalformedTrustedIPs(t *testing.T) {
	config := CreateConfig()
	config.TrustedIPs = []string{"not-a-cidr"}
	if _, err := New(context.Background(), http.NotFoundHandler(), config, "client-ip"); err == nil {
		t.Fatal("a malformed trusted network was accepted")
	}
}
