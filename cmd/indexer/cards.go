package main

import (
	"errors"
	"strings"
)

// Card privacy rules for the indexer:
//   - Decks are never read or stored. (Older chain events carry a `deck`
//     attribute on hand_started; it is ignored.)
//   - The only hole cards recorded are those of players whose status was
//     "showing" in the chain's masked public game state when the hand ended.
//     The `revealed_hole_cards` event attribute is NOT trusted: on older blocks
//     it lists every seat's cards, folded hands included.

// statusShowing is the chain's PlayerStatus for a player who showed their cards.
const statusShowing = "showing"

// errStatePruned means the node no longer keeps state at the requested height.
var errStatePruned = errors.New("state at height is pruned")

// normalizeCard converts a chain card code ("AH", "TH", "10h", "[AS]") into the
// canonical form used by card_distribution_stats: rank upper + suit lower
// ("Ah", "Th"). It reports false for masked ("X") or malformed codes.
func normalizeCard(raw string) (string, bool) {
	c := strings.TrimSpace(strings.Trim(strings.TrimSpace(raw), "[]"))
	if len(c) < 2 || len(c) > 3 {
		return "", false
	}
	rank := strings.ToUpper(c[:len(c)-1])
	suit := strings.ToLower(c[len(c)-1:])
	if rank == "10" {
		rank = "T"
	}
	if len(rank) != 1 || !strings.Contains("23456789TJQKA", rank) || !strings.Contains("hdcs", suit) {
		return "", false
	}
	return rank + suit, true
}

// normalizeCards normalizes a list, dropping masked/malformed entries.
func normalizeCards(raw []string) []string {
	var out []string
	for _, r := range raw {
		if c, ok := normalizeCard(r); ok {
			out = append(out, c)
		}
	}
	return out
}

// splitCards parses a comma-separated card list from an event attribute.
func splitCards(s string) []string {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	return normalizeCards(strings.Split(s, ","))
}

// shownHoleCards returns the hole cards of players who showed (status
// "showing"). Folded, active, mucked or masked hands contribute nothing.
func shownHoleCards(players []Player) []string {
	var out []string
	for _, p := range players {
		if p.Status != statusShowing {
			continue
		}
		out = append(out, normalizeCards(p.HoleCards)...)
	}
	return out
}

// isPrunedError reports whether a node error means the state at that height is
// no longer kept (Cosmos SDK: "version does not exist ... pruned").
func isPrunedError(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "version does not exist") ||
		strings.Contains(msg, "pruned") ||
		strings.Contains(msg, "failed to load state at height")
}

// handEndSnapshot finds the public game state of hand `handNumber` as it ended,
// given the block where the end was observed. That block's state normally holds
// the final state; if the next hand started in the same block, the block before
// has it. It returns errStatePruned when the node no longer keeps the state, and
// (nil, nil) when neither block shows that hand finished.
func handEndSnapshot(fetch func(height int64) (*GameState, error), handNumber int, height int64) (*GameState, error) {
	heights := []int64{height}
	if height > 1 {
		heights = append(heights, height-1)
	}
	for _, h := range heights {
		st, err := fetch(h)
		if err != nil {
			if isPrunedError(err) {
				return nil, errStatePruned
			}
			return nil, err
		}
		if st != nil && st.HandNumber == handNumber && (st.Round == "showdown" || st.Round == "end") {
			return st, nil
		}
	}
	return nil, nil
}
