package main

import (
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"os"
	"sync"
	"time"
)

/*
 * -----------------------------------------------------------------------------
 * CONSTANTS
 * -----------------------------------------------------------------------------
 */

const (
	// time to read the scene and type six characters, with room to think; an answer after it counts as wrong
	puzzleLifetime = 10 * time.Minute
	// the window the page counts wrong answers in, the same crowdsec's captcha scenario leaks over
	failureWindow = time.Hour
	// clients holding a puzzle at once
	challengeCountMax = 16384
)

/*
 * -----------------------------------------------------------------------------
 * TYPES
 * -----------------------------------------------------------------------------
 */

// Notice is what the next captcha page tells its client about the last answer.
type Notice int

const (
	NoticeNone Notice = iota
	NoticeWrong
	NoticeExpired
)

// Outcome is what one answer did; wrong and expired both regenerate the puzzle and count against the client.
type Outcome int

const (
	OutcomeSolved Outcome = iota
	OutcomeWrong
	OutcomeExpired
)

var outcomeNames = map[Outcome]string{OutcomeSolved: "solved", OutcomeWrong: "wrong", OutcomeExpired: "expired"}

// challenge is one client's captcha state: the seed of its current puzzle, if any, and its recent failures.
type challenge struct {
	seed       uint64
	issuedAt   time.Time
	hasPuzzle  bool
	notice     Notice
	failuresAt []time.Time
}

// Challenges holds every flagged client's current puzzle; one try each.
type Challenges struct {
	colorCount       int
	regenerationsMax int
	answerLog        *os.File
	answerLogMu      sync.Mutex
	clients          *table[challenge]
}

/*
 * -----------------------------------------------------------------------------
 * LIFETIME
 * -----------------------------------------------------------------------------
 */

func challengesCreate(regenerationsMax int, answerLogPath *string) (*Challenges, error) {
	c := &Challenges{colorCount: len(shapeColors), regenerationsMax: regenerationsMax, clients: tableCreate[challenge](challengeCountMax)}
	if answerLogPath != nil {
		file, err := os.OpenFile(*answerLogPath, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
		if err != nil {
			return nil, err
		}
		c.answerLog = file
	}
	return c, nil
}

func challengesDestroy(c *Challenges) {
	if c == nil {
		return
	}
	if c.answerLog != nil {
		c.answerLog.Close()
	}
	tableDestroy(c.clients)
}

/*
 * -----------------------------------------------------------------------------
 * INTERNAL
 * -----------------------------------------------------------------------------
 */

func seedRandom() uint64 {
	var bytes [8]byte
	// crypto/rand never fails on linux (go 1.24 and later crash the program instead of returning an error)
	_, _ = rand.Read(bytes[:])
	return binary.LittleEndian.Uint64(bytes[:])
}

func failuresRecent(failures []time.Time, now time.Time) []time.Time {
	var recent []time.Time
	for _, at := range failures {
		if now.Sub(at) < failureWindow {
			recent = append(recent, at)
		}
	}
	return recent
}

func challengeStale(c challenge, now time.Time) bool {
	return (!c.hasPuzzle || now.Sub(c.issuedAt) >= puzzleLifetime) && len(failuresRecent(c.failuresAt, now)) == 0
}

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// challengesShow is the puzzle a client sees now: its current one while it lasts, else a new one. A reload shows the
// same puzzle, so reloading earns nothing; the notice is shown once.
func challengesShow(c *Challenges, client string, now time.Time) (puzzle Puzzle, notice Notice, triesLeft int, err error) {
	c.clients.mu.Lock()
	state, found := c.clients.entries[client]
	if !found {
		tableRoomMake(c.clients, func(s challenge) bool { return challengeStale(s, now) })
	}
	fresh := !state.hasPuzzle || now.Sub(state.issuedAt) >= puzzleLifetime
	if fresh {
		state.seed, state.issuedAt, state.hasPuzzle = seedRandom(), now, true
	}
	notice = state.notice
	state.notice = NoticeNone
	state.failuresAt = failuresRecent(state.failuresAt, now)
	triesLeft = max(0, c.regenerationsMax-len(state.failuresAt))
	c.clients.entries[client] = state
	c.clients.mu.Unlock()

	puzzle = puzzleFromSeed(state.seed, c.colorCount)
	if fresh && c.answerLog != nil {
		c.answerLogMu.Lock()
		_, err = fmt.Fprintf(c.answerLog, "%s %s\n", client, puzzle.Answer)
		c.answerLogMu.Unlock()
	}
	return puzzle, notice, triesLeft, err
}

// challengesAnswer spends the client's one try: the puzzle is gone afterwards whatever the answer was.
func challengesAnswer(c *Challenges, client string, typed string, now time.Time) Outcome {
	c.clients.mu.Lock()
	defer c.clients.mu.Unlock()
	state, found := c.clients.entries[client]
	if !found {
		tableRoomMake(c.clients, func(s challenge) bool { return challengeStale(s, now) })
	}
	outcome := OutcomeExpired
	if state.hasPuzzle && now.Sub(state.issuedAt) < puzzleLifetime {
		outcome = OutcomeWrong
		answer, valid := answerNormalize(typed)
		if valid && answer == puzzleFromSeed(state.seed, c.colorCount).Answer {
			outcome = OutcomeSolved
		}
	}
	if outcome == OutcomeSolved {
		delete(c.clients.entries, client)
		return outcome
	}
	state.hasPuzzle = false
	state.notice = map[Outcome]Notice{OutcomeWrong: NoticeWrong, OutcomeExpired: NoticeExpired}[outcome]
	state.failuresAt = append(failuresRecent(state.failuresAt, now), now)
	// the page counts up to the limit, crowdsec bans past it: more than that is never read
	if excess := len(state.failuresAt) - c.regenerationsMax; excess > 0 {
		state.failuresAt = state.failuresAt[excess:]
	}
	c.clients.entries[client] = state
	return outcome
}
