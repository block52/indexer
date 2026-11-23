package db

import (
	"testing"

	"github.com/block52/indexer/internal/models"
)

// Needs TEST_DATABASE_URL; see statsDB in player_stats_test.go.
func sessionsDB(t *testing.T) *DB {
	t.Helper()
	sqlDB := statsDB(t)
	clean := func() { exec(t, sqlDB, "DELETE FROM games WHERE game_id LIKE 'statstest-%'") }
	clean()
	t.Cleanup(clean)

	exec(t, sqlDB, `INSERT INTO games (game_id, game_format, game_variant, tournament_id) VALUES
		('statstest-cash1', 'cash', 'texas-holdem', NULL),
		('statstest-cash2', 'cash', 'texas-holdem', NULL),
		('statstest-omaha', 'cash', 'omaha', NULL),
		('statstest-mtt', 'tournament', 'texas-holdem', 'statstest-t1')`)
	// statstest-unknown has no games row: the indexer hasn't recorded that game yet.
	exec(t, sqlDB, `INSERT INTO player_sessions (player_address, game_id, join_block, leave_block, buy_in_amount, cash_out_amount) VALUES
		('statstest-dave', 'statstest-cash1', 100, 150, 1000000, 1200000),
		('statstest-dave', 'statstest-cash2', 200, 250, 1000000, 900000),
		('statstest-dave', 'statstest-omaha', 300, 350, 2000000, 2000000),
		('statstest-dave', 'statstest-mtt', 400, 450, 5000000, 0),
		('statstest-dave', 'statstest-unknown', 500, NULL, 1000000, NULL)`)
	return &DB{sqlDB}
}

func gameIDs(sessions []models.PlayerSession) []string {
	ids := make([]string, len(sessions))
	for i, s := range sessions {
		ids[i] = s.GameID
	}
	return ids
}

func sameStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestGetPlayerSessionsJoinsTheGame(t *testing.T) {
	db := sessionsDB(t)

	sessions, total, err := db.GetPlayerSessions("statstest-dave", models.SessionFilter{}, 50, 0)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"statstest-unknown", "statstest-mtt", "statstest-omaha", "statstest-cash2", "statstest-cash1"}
	if total != 5 || !sameStrings(gameIDs(sessions), want) {
		t.Fatalf("got %d total, %v; want 5, %v", total, gameIDs(sessions), want)
	}

	unknown, mtt, omaha := sessions[0], sessions[1], sessions[2]
	if unknown.GameFormat != nil || unknown.GameVariant != nil || unknown.TournamentID != nil {
		t.Errorf("unrecorded game: got format %v, variant %v, tournament %v; want all nil", unknown.GameFormat, unknown.GameVariant, unknown.TournamentID)
	}
	if unknown.LeaveBlock != nil || unknown.CashOutAmount != nil {
		t.Errorf("open session: got leave %v, cash-out %v; want nil", unknown.LeaveBlock, unknown.CashOutAmount)
	}
	if mtt.GameFormat == nil || *mtt.GameFormat != "tournament" || mtt.TournamentID == nil || *mtt.TournamentID != "statstest-t1" {
		t.Errorf("tournament session: got format %v, tournament %v", mtt.GameFormat, mtt.TournamentID)
	}
	if omaha.GameVariant == nil || *omaha.GameVariant != "omaha" || omaha.TournamentID != nil {
		t.Errorf("omaha session: got variant %v, tournament %v", omaha.GameVariant, omaha.TournamentID)
	}
}

func TestGetPlayerSessionsFiltersByGame(t *testing.T) {
	db := sessionsDB(t)

	cases := []struct {
		filter models.SessionFilter
		want   []string
	}{
		{models.SessionFilter{GameFormat: "cash"}, []string{"statstest-omaha", "statstest-cash2", "statstest-cash1"}},
		{models.SessionFilter{GameFormat: "cash", GameVariant: "texas-holdem"}, []string{"statstest-cash2", "statstest-cash1"}},
		{models.SessionFilter{GameVariant: "texas-holdem"}, []string{"statstest-mtt", "statstest-cash2", "statstest-cash1"}},
		{models.SessionFilter{GameFormat: "sit-and-go"}, []string{}},
	}
	for _, c := range cases {
		sessions, total, err := db.GetPlayerSessions("statstest-dave", c.filter, 50, 0)
		if err != nil {
			t.Fatal(err)
		}
		if sessions == nil {
			t.Errorf("%+v: got nil, want an empty slice", c.filter)
		}
		if total != int64(len(c.want)) || !sameStrings(gameIDs(sessions), c.want) {
			t.Errorf("%+v: got %d total, %v; want %v", c.filter, total, gameIDs(sessions), c.want)
		}
	}

	// The total counts the filtered sessions, not the page.
	page, total, err := db.GetPlayerSessions("statstest-dave", models.SessionFilter{GameFormat: "cash"}, 1, 1)
	if err != nil {
		t.Fatal(err)
	}
	if total != 3 || !sameStrings(gameIDs(page), []string{"statstest-cash2"}) {
		t.Fatalf("page 2 of 1: got %d total, %v; want 3, [statstest-cash2]", total, gameIDs(page))
	}
}

func TestGetPlayerSessionGamesCountsEveryKindPlayed(t *testing.T) {
	db := sessionsDB(t)

	games, err := db.GetPlayerSessionGames("statstest-dave")
	if err != nil {
		t.Fatal(err)
	}
	want := []models.SessionGameCount{
		{GameFormat: "cash", GameVariant: "texas-holdem", Sessions: 2},
		{GameFormat: "cash", GameVariant: "omaha", Sessions: 1},
		{GameFormat: "tournament", GameVariant: "texas-holdem", Sessions: 1},
	}
	if len(games) != len(want) {
		t.Fatalf("got %+v, want %+v", games, want)
	}
	for i := range want {
		if games[i] != want[i] {
			t.Errorf("games[%d]: got %+v, want %+v", i, games[i], want[i])
		}
	}

	none, err := db.GetPlayerSessionGames("statstest-nobody")
	if err != nil {
		t.Fatal(err)
	}
	if none == nil || len(none) != 0 {
		t.Fatalf("no sessions: got %#v, want an empty slice", none)
	}
}
