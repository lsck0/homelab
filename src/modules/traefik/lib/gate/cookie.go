package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"strconv"
	"strings"
	"time"
)

/*
 * -----------------------------------------------------------------------------
 * CONSTANTS
 * -----------------------------------------------------------------------------
 */

const (
	cookieName = "lab_gate"
	// a solved captcha lets its client through this long; past it a still-flagged client solves another
	cookieLifetime = time.Hour
	// the mac's domain: a key reused elsewhere cannot mint these
	cookieContext   = "lab-gate/v1"
	cookieSeparator = "."
)

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

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
