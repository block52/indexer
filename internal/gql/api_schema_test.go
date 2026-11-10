package gql

import (
	"context"
	"strings"
	"testing"
)

// GraphQL serves from the api schema of views (sql/09-api-views.sql, #17),
// and the view column comments become field docs.
func TestServesFromAPISchema(t *testing.T) {
	db := testDB(t)
	cat, err := LoadCatalog(context.Background(), db, Specs)
	if err != nil {
		t.Fatal(err)
	}
	if cat.Schema != "api" {
		t.Fatalf("catalog schema = %q, want api (run sql/09-api-views.sql)", cat.Schema)
	}
	c := cat.Tables["hand_players"].Column("won_amount")
	if c == nil {
		t.Fatal("api.hand_players has no won_amount")
	}
	if !strings.Contains(c.Description, "micro-USDC") {
		t.Errorf("won_amount description = %q, want the units from the view's column comment", c.Description)
	}
}

// The point of the api schema: a public column can change while the view
// keeps the GraphQL field, so key holders' queries keep answering.
func TestAPIViewKeepsFieldWhenPublicChanges(t *testing.T) {
	db := testDB(t)
	if _, err := db.Exec(`INSERT INTO vip_tier_history (player_address, old_tier, new_tier, reason)
		VALUES ('gqltest-alice', 'bronze', 'gold', 'rake')`); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		db.Exec(`DELETE FROM vip_tier_history WHERE player_address LIKE 'gqltest-%'`)
	})

	query := `{ vip_tier_history(where: {player_address: {_eq: "gqltest-alice"}}) { player_address old_tier new_tier reason } }`
	want := `{"vip_tier_history":[{"player_address":"gqltest-alice","old_tier":"bronze","new_tier":"gold","reason":"rake"}]}`
	expectJSON(t, run(t, testService(t, db), query, nil), want)

	// Storage changes: the column is renamed in public…
	if _, err := db.Exec(`ALTER TABLE public.vip_tier_history RENAME COLUMN reason TO change_reason`); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		db.Exec(`ALTER TABLE public.vip_tier_history RENAME COLUMN change_reason TO reason`)
		db.Exec(`CREATE OR REPLACE VIEW api.vip_tier_history AS
			SELECT id, player_address, old_tier, new_tier, reason, changed_at FROM public.vip_tier_history`)
	})
	// …and the view keeps the old name as an alias.
	if _, err := db.Exec(`CREATE OR REPLACE VIEW api.vip_tier_history AS
		SELECT id, player_address, old_tier, new_tier, change_reason AS reason, changed_at FROM public.vip_tier_history`); err != nil {
		t.Fatal(err)
	}

	// A service built against the changed database answers the same query
	// with the same field name and the same rows.
	expectJSON(t, run(t, testService(t, db), query, nil), want)
}

// The runnable example queries in API.md (the ones that don't need #15's
// tables) keep working against the api schema.
func TestAPIMDExamples(t *testing.T) {
	svc := testService(t, testDB(t))
	run(t, svc, `query ($player: String!) {
		hand_players(where: {player_address: {_eq: $player}}, order_by: {block_height: desc}, limit: 20) {
			game_id hand_number won_amount ended_at
			hand { result { community_cards winner_count } }
		}
	}`, map[string]interface{}{"player": "gqltest-alice"})
	run(t, svc, `{
		poker_hands(where: {game_id: {_eq: "gqltest-g1"}, players: {player_address: {_eq: "gqltest-alice"}, won_amount: {_gt: 0}}}) {
			hand_number
			players(order_by: {won_amount: desc}) { player_address seat won_amount }
		}
	}`, nil)
	run(t, svc, `{ hand_players_aggregate(where: {ended_at: {_gte: "2026-11-01"}}) { aggregate { count sum { won_amount } } } }`, nil)
}
