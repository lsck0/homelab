package main

import (
	"fmt"
	"math/rand/v2"
	"net"
	"strings"
)

/*
 * -----------------------------------------------------------------------------
 * CONSTANTS
 * -----------------------------------------------------------------------------
 */

// An onion route's captcha shows its own address among lookalikes: a phishing proxy relays this page from the real
// address, so its visitor finds no row matching the address bar, while the lab's own visitor finds exactly one.
const (
	onionSuffix = ".onion"
	// a v3 address: the base32 of its key, checksum and version
	onionKeyChars = 56
	onionAlphabet = "abcdefghijklmnopqrstuvwxyz234567"
	// a decoy keeps these ends of the real address, where a vanity lookalike matches it and a hurried eye looks
	onionKeptPrefix = 6
	onionKeptSuffix = 6
	onionRows       = 4
	onionQuestion   = "Which label stands beside the address that is exactly the one in your browser's address bar?"
)

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// onionAddressValid is true for a v3 onion address as tor names it: 56 lowercase base32 characters and the suffix.
func onionAddressValid(address string) bool {
	key, found := strings.CutSuffix(address, onionSuffix)
	if !found || len(key) != onionKeyChars {
		return false
	}
	for _, c := range key {
		if !strings.ContainsRune(onionAlphabet, c) {
			return false
		}
	}
	return true
}

// onionRoutes inverts the settings' route -> address: a request names the address, the decoy metric the route.
func onionRoutes(onions map[string]string) (map[string]string, error) {
	routes := make(map[string]string, len(onions))
	for route, address := range onions {
		if !onionAddressValid(address) {
			return nil, fmt.Errorf("%s: %q is no onion address", route, address)
		}
		if other, taken := routes[address]; taken {
			return nil, fmt.Errorf("%s and %s share %s", other, route, address)
		}
		routes[address] = route
	}
	return routes, nil
}

// hostNormalize is a request's host as a router rule compares it: lowercase, without a port.
func hostNormalize(host string) string {
	if name, _, err := net.SplitHostPort(host); err == nil {
		host = name
	}
	return strings.ToLower(host)
}

// onionDecoys are addresses that look like the real one: its ends kept, its middle random, never the real one twice.
func onionDecoys(rng *rand.Rand, address string, count int) []string {
	middle := make([]byte, onionKeyChars-onionKeptPrefix-onionKeptSuffix)
	decoys := make([]string, 0, count)
	seen := map[string]bool{address: true}
	for len(decoys) < count {
		for i := range middle {
			middle[i] = onionAlphabet[rng.IntN(len(onionAlphabet))]
		}
		decoy := address[:onionKeptPrefix] + string(middle) + address[onionKeyChars-onionKeptSuffix:]
		if seen[decoy] {
			continue
		}
		seen[decoy] = true
		decoys = append(decoys, decoy)
	}
	return decoys
}

// onionPuzzleFromSeed is the rows of an onion route's captcha: its address and the decoys in a random order, each
// with a label of its own; the real row's label answers, a decoy's is the lookalike signal.
func onionPuzzleFromSeed(seed uint64, address string) Puzzle {
	if !onionAddressValid(address) {
		panic("puzzle: not an onion address: " + address)
	}
	rng := puzzleRandom(seed)
	addresses := append([]string{address}, onionDecoys(rng, address, onionRows-1)...)
	codes := labelsGenerate(rng, onionRows, func() []byte { return labelRandom(rng) })
	backwards := rng.IntN(backwardsOneIn) == 0
	puzzle := Puzzle{Question: onionQuestion}
	for _, i := range rng.Perm(onionRows) {
		puzzle.Rows = append(puzzle.Rows, Row{Address: addresses[i], Code: codes[i]})
		answer := codes[i]
		if backwards {
			answer = labelReverse(answer)
		}
		if i == 0 {
			puzzle.Answer = answer
		} else {
			puzzle.Decoys = append(puzzle.Decoys, answer)
		}
	}
	if backwards {
		puzzle.Question += backwardsSentence
	}
	return puzzle
}
