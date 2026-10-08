package main

import (
	"errors"
	"reflect"
	"testing"
	"time"
)

func TestNormalizeCard(t *testing.T) {
	cases := map[string]string{"AH": "Ah", "th": "Th", "10H": "Th", "[KD]": "Kd", " 2c ": "2c", "QS": "Qs"}
	for in, want := range cases {
		got, ok := normalizeCard(in)
		if !ok || got != want {
			t.Errorf("normalizeCard(%q) = %q,%v want %q", in, got, ok, want)
		}
	}
	for _, bad := range []string{"", "X", "XX", "1H", "AX", "ZZZZ", "11H"} {
		if got, ok := normalizeCard(bad); ok {
			t.Errorf("normalizeCard(%q) = %q, want rejected", bad, got)
		}
	}
}

func TestShownHoleCardsOnlyShowingPlayers(t *testing.T) {
	players := []Player{
		{Seat: 1, Status: "showing", HoleCards: []string{"KD", "QS"}},
		{Seat: 2, Status: "folded", HoleCards: []string{"2C", "7D"}},
		{Seat: 3, Status: "active", HoleCards: []string{"AH", "AS"}},
		{Seat: 4, Status: "mucked", HoleCards: []string{"9S", "9H"}},
		{Seat: 5, Status: "showing", HoleCards: []string{"X", "X"}}, // masked
		{Seat: 6, Status: "showing", HoleCards: []string{"TH", "JH"}},
	}
	want := []string{"Kd", "Qs", "Th", "Jh"}
	if got := shownHoleCards(players); !reflect.DeepEqual(got, want) {
		t.Fatalf("shownHoleCards = %v, want %v", got, want)
	}
	if got := shownHoleCards([]Player{{Status: "folded", HoleCards: []string{"2C", "7D"}}}); len(got) != 0 {
		t.Fatalf("no showing players should yield no cards, got %v", got)
	}
}

func TestSplitCards(t *testing.T) {
	if got := splitCards("8C,TH,AC,KS,2H"); !reflect.DeepEqual(got, []string{"8c", "Th", "Ac", "Ks", "2h"}) {
		t.Fatalf("splitCards = %v", got)
	}
	if got := splitCards(""); got != nil {
		t.Fatalf("empty attr should give nil, got %v", got)
	}
}

func TestHandEndSnapshot(t *testing.T) {
	states := map[int64]*GameState{
		100: {HandNumber: 7, Round: "end"},
		200: {HandNumber: 9, Round: "ante"}, // next hand already started this block
		199: {HandNumber: 8, Round: "showdown"},
		300: {HandNumber: 3, Round: "flop"},
		299: {HandNumber: 3, Round: "turn"},
	}
	fetch := func(h int64) (*GameState, error) { return states[h], nil }

	if st, err := handEndSnapshot(fetch, 7, 100); err != nil || st == nil || st.HandNumber != 7 {
		t.Fatalf("end block holds the state: got %v %v", st, err)
	}
	if st, err := handEndSnapshot(fetch, 8, 200); err != nil || st == nil || st.Round != "showdown" {
		t.Fatalf("falls back to the block before when the next hand started: got %v %v", st, err)
	}
	if st, err := handEndSnapshot(fetch, 3, 300); err != nil || st != nil {
		t.Fatalf("an unfinished hand yields nothing: got %v %v", st, err)
	}

	pruned := func(int64) (*GameState, error) {
		return nil, errors.New("codespace sdk code 38: not found: failed to load state at height 5; version does not exist")
	}
	if _, err := handEndSnapshot(pruned, 1, 5); !errors.Is(err, errStatePruned) {
		t.Fatalf("pruned state should map to errStatePruned, got %v", err)
	}
}

func TestParseGameStateResponse(t *testing.T) {
	bare := []byte(`{"game_state":"{\"handNumber\":20,\"round\":\"end\",\"communityCards\":[\"8C\"],\"players\":[{\"seat\":2,\"status\":\"showing\",\"holeCards\":[\"KD\",\"QS\"]}]}"}`)
	st, err := parseGameStateResponse(bare)
	if err != nil || st.HandNumber != 20 || len(st.Players) != 1 || st.Players[0].Status != "showing" {
		t.Fatalf("bare DTO: %+v %v", st, err)
	}
	wrapped := []byte(`{"game_state":"{\"format\":\"sit-and-go\",\"gameState\":{\"handNumber\":4,\"round\":\"showdown\"}}"}`)
	if st, err := parseGameStateResponse(wrapped); err != nil || st.HandNumber != 4 || st.Round != "showdown" {
		t.Fatalf("wrapped DTO: %+v %v", st, err)
	}
	if _, err := parseGameStateResponse([]byte(`{"game_state":""}`)); err == nil {
		t.Fatal("empty game_state should fail")
	}
}

// Older chain events carry a `deck` attribute on hand_started; the parsed
// state and the GameState type must have nowhere to keep it.
func TestDeckIsNeverParsed(t *testing.T) {
	if _, ok := reflect.TypeOf(GameState{}).FieldByName("Deck"); ok {
		t.Fatal("GameState must not have a Deck field")
	}
	idx := &Indexer{}
	attrs := idx.parseEventAttrs(Event{Type: "hand_started", Attributes: []struct {
		Key   string `json:"key"`
		Value string `json:"value"`
		Index bool   `json:"index"`
	}{{Key: "hand_number", Value: "20"}, {Key: "deck", Value: "[KD]-QC-QS"}}})
	if attrs["hand_number"] != "20" {
		t.Fatalf("attrs not parsed: %v", attrs)
	}
	// The attribute is present in the raw event map, but handleHandStarted
	// never reads it; that's asserted structurally by the INSERT having no deck
	// column (covered by the schema) and here by GameState having no field.
}

func TestThrottle(t *testing.T) {
	idx := &Indexer{config: Config{BlockDelay: 20 * time.Millisecond}}
	start := time.Now()
	idx.throttle()
	if time.Since(start) < 20*time.Millisecond {
		t.Fatal("throttle should sleep the configured delay")
	}
	idx.config.BlockDelay = 0
	start = time.Now()
	idx.throttle()
	if time.Since(start) > 5*time.Millisecond {
		t.Fatal("zero delay should not sleep")
	}
}

func TestHandPlayersFromTheHandsOwnActions(t *testing.T) {
	// A 4-seat SNG: seat 4 busted in an earlier hand and is still listed in
	// players[]; seat 3 joined but sat this hand out. Neither played it.
	raw := []byte(`{"game_state":"{\"handNumber\":13,\"round\":\"end\",` +
		`\"players\":[` +
		`{\"address\":\"b52a\",\"seat\":1,\"status\":\"folded\"},` +
		`{\"address\":\"b52b\",\"seat\":2,\"status\":\"active\"},` +
		`{\"address\":\"b52c\",\"seat\":3,\"status\":\"sitting-out\"},` +
		`{\"address\":\"b52d\",\"seat\":4,\"status\":\"busted\"}],` +
		`\"winners\":[{\"address\":\"b52b\",\"amount\":\"120\"}],` +
		`\"previousActions\":[` +
		`{\"playerId\":\"b52c\",\"seat\":3,\"action\":\"sit-out\"},` +
		`{\"playerId\":\"b52a\",\"seat\":1,\"action\":\"post-small-blind\"},` +
		`{\"playerId\":\"b52b\",\"seat\":2,\"action\":\"post-big-blind\"},` +
		`{\"playerId\":\"b52a\",\"seat\":1,\"action\":\"deal\"},` +
		`{\"playerId\":\"b52a\",\"seat\":1,\"action\":\"fold\"}]}"}`)
	snap, err := parseGameStateResponse(raw)
	if err != nil {
		t.Fatal(err)
	}

	got := handPlayers(snap)
	want := []handPlayer{
		{Address: "b52a", Seat: 1, Status: "folded", Won: 0},
		{Address: "b52b", Seat: 2, Status: "active", Won: 120},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("handPlayers = %+v, want %+v", got, want)
	}
}

func TestHandPlayersKeepsAPlayerWhoLeftAndAWinnerWithoutActions(t *testing.T) {
	snap := &GameState{
		Players: []Player{{Address: "b52w", Seat: 5, Status: "active"}},
		Winners: []Winner{{Address: "b52w", Amount: "400000"}, {Address: "b52w", Amount: "100000"}},
		PreviousActions: []HandAction{
			{PlayerID: "b52gone", Seat: 2, Action: "post-small-blind"},
			{PlayerID: "b52gone", Seat: 2, Action: "fold"},
		},
	}
	got := handPlayers(snap)
	want := []handPlayer{
		{Address: "b52gone", Seat: 2, Status: "", Won: 0},
		{Address: "b52w", Seat: 5, Status: "active", Won: 500000},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("handPlayers = %+v, want %+v", got, want)
	}
	if handPlayers(nil) != nil {
		t.Error("handPlayers(nil) should be nil")
	}
}
