package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const (
	cookieName = "lab_gate"
	// a solved captcha lets its client through this long; past it a still-flagged client solves another
	cookieLifetime = time.Hour
	// the mac's domain: a key reused elsewhere cannot mint these
	cookieContext   = "lab-gate/v1"
	cookieSeparator = "."
	// every tor visitor arrives from the router: a random id per browser names its puzzle, its failures and its ban
	onionSessionCookie   = "lab_gate_onion"
	onionSessionIDBytes  = 16
	onionClientSeparator = "/"
)

func cookieMac(key []byte, client string, expiresUnix int64) []byte {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(cookieContext + "\n" + client + "\n" + strconv.FormatInt(expiresUnix, 10)))
	return mac.Sum(nil)
}

// cookieEncode is the value proving client solved a captcha until expires: the expiry and a mac over the client too,
// so the cookie is worthless from any other address.
func cookieEncode(key []byte, client string, expires time.Time) string {
	expiresUnix := expires.Unix()
	return strconv.FormatInt(expiresUnix, 10) + cookieSeparator + base64.RawURLEncoding.EncodeToString(cookieMac(key, client, expiresUnix))
}

// cookieDecode is true for a value cookieEncode made for this client that has not expired at now.
func cookieDecode(key []byte, client string, value string, now time.Time) bool {
	expiresText, macText, found := strings.Cut(value, cookieSeparator)
	if !found {
		return false
	}
	expiresUnix, err := strconv.ParseInt(expiresText, 10, 64)
	if err != nil || now.Unix() >= expiresUnix {
		return false
	}
	mac, err := base64.RawURLEncoding.DecodeString(macText)
	if err != nil {
		return false
	}
	return hmac.Equal(mac, cookieMac(key, client, expiresUnix))
}

func onionSessionNew() string {
	id := make([]byte, onionSessionIDBytes)
	// crypto/rand never fails on linux (go 1.24 and later crash the program instead of returning an error)
	_, _ = rand.Read(id)
	return hex.EncodeToString(id)
}

// onionSessionOf is the request's onion session id, if it carries one onionSessionNew could have made.
func onionSessionOf(r *http.Request) (string, bool) {
	cookie, err := r.Cookie(onionSessionCookie)
	if err != nil {
		return "", false
	}
	id, err := hex.DecodeString(cookie.Value)
	return cookie.Value, err == nil && len(id) == onionSessionIDBytes && cookie.Value == hex.EncodeToString(id)
}

// onionClient is what an onion session is known by where a clearnet client is by its address: the challenge's key,
// the pass cookie's subject. A slash is in no ip address, so the two never meet.
func onionClient(address, session string) string {
	return address + onionClientSeparator + session
}
