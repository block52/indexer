package db

import (
	"database/sql"
	"os"
	"testing"

	_ "github.com/lib/pq"
)

// These tests need a Postgres with the indexer schema (sql/init.sql, sql/player_stats.sql).
// Set TEST_DATABASE_URL, e.g.
//
//	TEST_DATABASE_URL="postgres://poker:poker_indexer_dev@localhost:5432/poker_hands?sslmode=disable" go test ./internal/db/
//
// They add rows whose addresses start with "statstest-" and remove them afterwards.
func statsDB(t *testing.T) *sql.DB {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL not set")
	}
	db, err := sql.Open("postgres", url)
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Ping(); err != nil {
		t.Fatal(err)
	}
	clean := func() {
		for _, table := range []string{"player_actions", "player_sessions", "player_stats"} {
			if _, err := db.Exec("DELETE FROM " + table + " WHERE player_address LIKE 'statstest-%'"); err != nil {
				t.Fatal(err)
			}
		}
	}
	clean()
	t.Cleanup(func() { clean(); db.Close() })
	return db
}

func exec(t *testing.T, db *sql.DB, query string, args ...any) {
	t.Helper()
	if _, err := db.Exec(query, args...); err != nil {
		t.Fatalf("%s: %v", query, err)
	}
}

func statsFor(t *testing.T, db *sql.DB, address string) (hands, actions int64) {
	t.Helper()
	exec(t, db, "SELECT update_player_stats($1)", address)
	if err := db.QueryRow("SELECT total_hands, total_actions FROM player_stats WHERE player_address = $1", address).Scan(&hands, &actions); err != nil {
		t.Fatal(err)
	}
	return hands, actions
}

// The indexer never fills in player_sessions.hands_played, so the hand count has to come from the hands the
// player acted in. It used to stay 0 for everyone: SUM(hands_played) is 0, not NULL, so the fallback never ran.
func TestUpdatePlayerStatsCountsHandsFromActionsWhenSessionsDoNot(t *testing.T) {
	db := statsDB(t)
	exec(t, db, `INSERT INTO player_actions (player_address, game_id, hand_number, block_height, action) VALUES
		('statstest-alice', 'g1', 1, 100, 'call'), ('statstest-alice', 'g1', 1, 101, 'check'),
		('statstest-alice', 'g1', 2, 110, 'fold'), ('statstest-alice', 'g2', 1, 120, 'bet')`)
	exec(t, db, `INSERT INTO player_sessions (player_address, game_id, join_block, buy_in_amount) VALUES ('statstest-alice', 'g1', 90, 1000000)`)

	hands, actions := statsFor(t, db, "statstest-alice")
	if hands != 3 || actions != 4 {
		t.Fatalf("got %d hands and %d actions, want 3 and 4", hands, actions)
	}
}

func TestUpdatePlayerStatsCountsHandsWithoutAnySession(t *testing.T) {
	db := statsDB(t)
	exec(t, db, `INSERT INTO player_actions (player_address, game_id, hand_number, block_height, action) VALUES
		('statstest-carol', 'g1', 1, 100, 'call'), ('statstest-carol', 'g1', 2, 110, 'fold')`)

	if hands, _ := statsFor(t, db, "statstest-carol"); hands != 2 {
		t.Fatalf("got %d hands, want 2", hands)
	}
}

// If a session does record hands_played, that count wins, as it did before.
func TestUpdatePlayerStatsPrefersSessionHandsWhenRecorded(t *testing.T) {
	db := statsDB(t)
	exec(t, db, `INSERT INTO player_actions (player_address, game_id, hand_number, block_height, action) VALUES ('statstest-bob', 'g1', 1, 100, 'call')`)
	exec(t, db, `INSERT INTO player_sessions (player_address, game_id, join_block, hands_played) VALUES ('statstest-bob', 'g1', 90, 5)`)

	if hands, _ := statsFor(t, db, "statstest-bob"); hands != 5 {
		t.Fatalf("got %d hands, want 5 (from the session)", hands)
	}
}
