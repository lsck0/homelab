package main

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"net/url"
	"os"
	"strings"
)

// Settings is the gate's one configuration file, rendered by modules/traefik/gate.nix; an unknown field is an error.
type Settings struct {
	Listen       string            `json:"listen"`
	TarpitListen string            `json:"tarpitListen"`
	Lapi         SettingsLapi      `json:"lapi"`
	Allow        SettingsAllow     `json:"allow"`
	Captcha      *SettingsCaptcha  `json:"captcha"`
	Session      *SettingsSession  `json:"session"`
	Anonymous    SettingsAnonymous `json:"anonymous"`
	Tarpit       SettingsTarpit    `json:"tarpit"`
	// cookies only the sso portal may read, which /strip removes from a request
	StripCookies []string `json:"stripCookies"`
}

// SettingsLapi is crowdsec's local api, asked for a client's decisions with the gate's bouncer key.
type SettingsLapi struct {
	URL     string `json:"url"`
	KeyFile string `json:"keyFile"`
}

// SettingsAllow is who the gate never stops: networks, and names resolved to the house's changing address and prefix.
type SettingsAllow struct {
	Cidrs []string            `json:"cidrs"`
	Hosts []SettingsAllowHost `json:"hosts"`
}

// SettingsAllowHost is a name whose addresses of one family ("ip4", "ip6") each stand for the prefix of Bits around it.
type SettingsAllowHost struct {
	Name    string `json:"name"`
	Network string `json:"network"`
	Bits    int    `json:"bits"`
}

// SettingsCaptcha turns the captcha on; without it captcha decisions pass, left to the ingress in front that asks it.
type SettingsCaptcha struct {
	KeyFile          string  `json:"keyFile"`
	CookieDomain     string  `json:"cookieDomain"`
	AnswerPath       string  `json:"answerPath"`
	RegenerationsMax int     `json:"regenerationsMax"`
	AnswerLog        *string `json:"answerLog"`
	// route name -> its onion address (src/generated/onions.json): a request to one gets the onion captcha
	Onions map[string]string `json:"onions"`
}

// SettingsSession is authelia's session state endpoint, reached through an ingress under the portal's name.
type SettingsSession struct {
	URL    string `json:"url"`
	Host   string `json:"host"`
	Cookie string `json:"cookie"`
}

// SettingsAnonymous is the per-client token bucket of clients without a session, at a route's scale 1.
type SettingsAnonymous struct {
	AveragePerSecond int `json:"averagePerSecond"`
	Burst            int `json:"burst"`
}

// SettingsTarpit is the labyrinth the tarpit trickles.
type SettingsTarpit struct {
	Upstream string `json:"upstream"`
}

// settingsParse reads the file strictly: every rule a later stage relies on is checked here, once.
func settingsParse(data []byte) (Settings, error) {
	var settings Settings
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&settings); err != nil {
		return Settings{}, fmt.Errorf("settings: %w", err)
	}
	if _, err := netip.ParseAddrPort(settings.Listen); err != nil {
		return Settings{}, fmt.Errorf("settings: listen: %w", err)
	}
	if _, err := netip.ParseAddrPort(settings.TarpitListen); err != nil {
		return Settings{}, fmt.Errorf("settings: tarpitListen: %w", err)
	}
	for _, field := range []struct{ name, value string }{
		{"lapi.url", settings.Lapi.URL},
		{"tarpit.upstream", settings.Tarpit.Upstream},
	} {
		if _, err := url.ParseRequestURI(field.value); err != nil {
			return Settings{}, fmt.Errorf("settings: %s: %w", field.name, err)
		}
	}
	for _, cidr := range settings.Allow.Cidrs {
		if _, err := netip.ParsePrefix(cidr); err != nil {
			return Settings{}, fmt.Errorf("settings: allow.cidrs: %w", err)
		}
	}
	for _, host := range settings.Allow.Hosts {
		bitsMax, known := allowNetworkBits[host.Network]
		if host.Name == "" || !known || host.Bits < 1 || host.Bits > bitsMax {
			return Settings{}, fmt.Errorf("settings: allow.hosts: %q needs a name, network ip4 or ip6 and bits within it", host.Name)
		}
	}
	if settings.Anonymous.AveragePerSecond < 1 || settings.Anonymous.Burst < settings.Anonymous.AveragePerSecond {
		return Settings{}, errors.New("settings: anonymous: averagePerSecond must be at least 1 and burst at least the average")
	}
	if captcha := settings.Captcha; captcha != nil {
		if !strings.HasPrefix(captcha.AnswerPath, "/") || captcha.CookieDomain == "" || captcha.RegenerationsMax < 1 {
			return Settings{}, errors.New("settings: captcha: answerPath must start with /, cookieDomain be set, regenerationsMax be positive")
		}
		if _, err := onionRoutes(captcha.Onions); err != nil {
			return Settings{}, fmt.Errorf("settings: captcha.onions: %w", err)
		}
	}
	for _, name := range settings.StripCookies {
		if name == "" || strings.ContainsAny(name, cookieDelimiter+"= ") {
			return Settings{}, fmt.Errorf("settings: stripCookies: %q is no cookie name", name)
		}
	}
	if session := settings.Session; session != nil {
		if _, err := url.ParseRequestURI(session.URL); err != nil || session.Host == "" || session.Cookie == "" {
			return Settings{}, errors.New("settings: session: url, host and cookie must be set")
		}
	}
	return settings, nil
}

// keyFileLoad reads a secret file: a hex key (the captcha's hmac key) or a raw token (the bouncer key).
func keyFileLoad(path string, hexKeyBytesMin int) ([]byte, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	text := strings.TrimSpace(string(data))
	if hexKeyBytesMin == 0 {
		if text == "" {
			return nil, fmt.Errorf("%s is empty", path)
		}
		return []byte(text), nil
	}
	key, err := hex.DecodeString(text)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if len(key) < hexKeyBytesMin {
		return nil, fmt.Errorf("%s: %d bytes, at least %d needed", path, len(key), hexKeyBytesMin)
	}
	return key, nil
}
