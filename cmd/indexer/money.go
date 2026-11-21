package main

import (
	"fmt"
	"log"
	"sort"
	"strconv"
	"strings"
)

// Money-flow events (block52/indexer#26): games from game_created, Sit & Go
// sessions closed with their prize, and tournament registrations, refunds and
// payouts in tournament_entries. All amounts here are micro-USDC — tournament
// table seats are chip-stack directives and never emit these events.

// moneyEventTypes are the event types processMoneyEvent handles.
var moneyEventTypes = map[string]bool{
	"game_created":             true,
	"tournament_table_created": true,
	"sng_pre_start_leave":      true,
	"sng_prize_claimed":        true,
	"sng_finalized":            true,
	"tournament_registered":    true,
	"tournament_unregistered":  true,
	"tournament_finished":      true,
	"tournament_cancelled":     true,
}

// processMoneyEvent routes one money-flow event. Failures are logged, not
// fatal: a bad event must not stop the block scan.
func (idx *Indexer) processMoneyEvent(eventType string, attrs map[string]string, height int64) {
	var err error
	switch eventType {
	case "game_created":
		err = idx.recordGameCreated(attrs, height)
	case "tournament_table_created":
		err = idx.recordTournamentTable(attrs, height)
	case "sng_pre_start_leave":
		err = idx.closeSession(attrs["game_id"], attrs["player"], attrs["refund_amount"], height)
	case "sng_prize_claimed":
		// The claim is the withdrawal of a prize sng_finalized already closed
		// the session with; this only closes a session the finalize was missed
		// for (closeSession only touches open sessions).
		err = idx.closeSession(attrs["game_id"], attrs["player"], attrs["amount"], height)
	case "sng_finalized":
		err = idx.finalizeSNG(attrs, height)
	case "tournament_registered":
		err = idx.recordTournamentRegistered(attrs, height)
	case "tournament_unregistered":
		err = idx.recordTournamentUnregistered(attrs, height)
	case "tournament_finished":
		err = idx.recordTournamentFinished(attrs, height)
	case "tournament_cancelled":
		err = idx.recordTournamentCancelled(attrs)
	}
	if err != nil {
		log.Printf("Warning: %s at block %d: %v", eventType, height, err)
	}
}

// recordGameCreated stores a table's details from its game_created event.
func (idx *Indexer) recordGameCreated(attrs map[string]string, height int64) error {
	gameID := attrs["game_id"]
	if gameID == "" {
		return fmt.Errorf("no game_id")
	}
	_, err := idx.db.Exec(`
		INSERT INTO games (game_id, creator, game_format, game_variant,
			min_players, max_players, min_buy_in, max_buy_in, entry_fee, created_block)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
		ON CONFLICT (game_id) DO UPDATE SET
			creator = EXCLUDED.creator, game_format = EXCLUDED.game_format,
			game_variant = EXCLUDED.game_variant, min_players = EXCLUDED.min_players,
			max_players = EXCLUDED.max_players, min_buy_in = EXCLUDED.min_buy_in,
			max_buy_in = EXCLUDED.max_buy_in, entry_fee = EXCLUDED.entry_fee,
			created_block = EXCLUDED.created_block
	`, gameID, attrs["creator"], attrs["game_format"], attrs["game_variant"],
		nullableInt(attrs["min_players"]), nullableInt(attrs["max_players"]),
		nullableInt(attrs["min_buy_in"]), nullableInt(attrs["max_buy_in"]),
		nullableInt(attrs["entry_fee"]), height)
	return err
}

// recordTournamentTable links a tournament-directed table's game_id to its
// tournament. Directed tables are host-created and emit no game_created.
func (idx *Indexer) recordTournamentTable(attrs map[string]string, height int64) error {
	gameID := attrs["game_id"]
	tournamentID := attrs["tournament_id"]
	if gameID == "" || tournamentID == "" {
		return fmt.Errorf("missing game_id or tournament_id")
	}
	_, err := idx.db.Exec(`
		INSERT INTO games (game_id, game_format, tournament_id, created_block)
		VALUES ($1, 'tournament', $2, $3)
		ON CONFLICT (game_id) DO UPDATE SET
			game_format = 'tournament', tournament_id = EXCLUDED.tournament_id
	`, gameID, tournamentID, height)
	return err
}

// closeSession closes a player's open session on a game with the given
// cash-out. A no-op when the session is already closed.
func (idx *Indexer) closeSession(gameID, player, amountStr string, height int64) error {
	if gameID == "" || player == "" {
		return fmt.Errorf("missing game_id or player")
	}
	amount, _ := strconv.ParseInt(amountStr, 10, 64)
	_, err := idx.db.Exec(`
		UPDATE player_sessions
		SET leave_block = $1, cash_out_amount = $2
		WHERE player_address = $3 AND game_id = $4 AND leave_block IS NULL
	`, height, amount, player, gameID)
	return err
}

// finalizeSNG closes every open session on a finalized Sit & Go: the placed
// players with their payout, everyone else (busted entrants) with 0. Prizes
// are escrowed until claimed, but the finalize decides them — net profit uses
// the decided amount, not the later withdrawal.
func (idx *Indexer) finalizeSNG(attrs map[string]string, height int64) error {
	gameID := attrs["game_id"]
	if gameID == "" {
		return fmt.Errorf("no game_id")
	}
	for _, p := range placePayouts(attrs) {
		if err := idx.closeSession(gameID, p.Player, strconv.FormatInt(p.Payout, 10), height); err != nil {
			return err
		}
	}
	_, err := idx.db.Exec(`
		UPDATE player_sessions
		SET leave_block = $1, cash_out_amount = 0
		WHERE game_id = $2 AND leave_block IS NULL
	`, height, gameID)
	return err
}

// recordTournamentRegistered opens an MTT entry with its gross buy-in.
func (idx *Indexer) recordTournamentRegistered(attrs map[string]string, height int64) error {
	tournamentID, player := attrs["tournament_id"], attrs["player"]
	if tournamentID == "" || player == "" {
		return fmt.Errorf("missing tournament_id or player")
	}
	buyIn, _ := strconv.ParseInt(attrs["buy_in"], 10, 64)
	netBuyIn, _ := strconv.ParseInt(attrs["net_buy_in"], 10, 64)
	entryFee, _ := strconv.ParseInt(attrs["entry_fee"], 10, 64)
	_, err := idx.db.Exec(`
		INSERT INTO tournament_entries (tournament_id, player_address, buy_in, net_buy_in, entry_fee, registered_block)
		VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (tournament_id, player_address, registered_block) DO NOTHING
	`, tournamentID, player, buyIn, netBuyIn, entryFee, height)
	return err
}

// recordTournamentUnregistered closes the player's open entry with its refund
// (the net buy-in; fees are kept by the chain).
func (idx *Indexer) recordTournamentUnregistered(attrs map[string]string, height int64) error {
	tournamentID, player := attrs["tournament_id"], attrs["player"]
	if tournamentID == "" || player == "" {
		return fmt.Errorf("missing tournament_id or player")
	}
	refund, _ := strconv.ParseInt(attrs["refund"], 10, 64)
	_, err := idx.db.Exec(`
		UPDATE tournament_entries
		SET unregistered_block = $1, refund = $2
		WHERE tournament_id = $3 AND player_address = $4
		  AND unregistered_block IS NULL AND refund IS NULL AND payout IS NULL
	`, height, refund, tournamentID, player)
	return err
}

// recordTournamentFinished stores each finisher's place and payout, then
// closes the remaining live entries with a payout of 0.
func (idx *Indexer) recordTournamentFinished(attrs map[string]string, height int64) error {
	tournamentID := attrs["tournament_id"]
	if tournamentID == "" {
		return fmt.Errorf("no tournament_id")
	}
	for _, p := range placePayouts(attrs) {
		if _, err := idx.db.Exec(`
			UPDATE tournament_entries
			SET place = $1, payout = $2, payout_block = $3
			WHERE tournament_id = $4 AND player_address = $5 AND payout IS NULL
		`, p.Place, p.Payout, height, tournamentID, p.Player); err != nil {
			return err
		}
	}
	_, err := idx.db.Exec(`
		UPDATE tournament_entries
		SET payout = 0, payout_block = $1
		WHERE tournament_id = $2 AND payout IS NULL
		  AND unregistered_block IS NULL AND refund IS NULL
	`, height, tournamentID)
	return err
}

// recordTournamentCancelled refunds every live entry its net buy-in. The
// tournament_cancelled event carries only a count; the chain refunds each
// registered-and-not-unregistered entrant their net buy-in from escrow.
func (idx *Indexer) recordTournamentCancelled(attrs map[string]string) error {
	tournamentID := attrs["tournament_id"]
	if tournamentID == "" {
		return fmt.Errorf("no tournament_id")
	}
	_, err := idx.db.Exec(`
		UPDATE tournament_entries
		SET refund = net_buy_in
		WHERE tournament_id = $1
		  AND unregistered_block IS NULL AND refund IS NULL AND payout IS NULL
	`, tournamentID)
	return err
}

// PlacePayout is one finisher from a sng_finalized or tournament_finished
// event's place_N_player/place_N_payout attribute pairs.
type PlacePayout struct {
	Place  int
	Player string
	Payout int64
}

// placePayouts extracts the place_N_player/place_N_payout pairs, ordered by
// place. Pairs with a missing player or an unreadable payout are dropped (the
// chain omits zero payouts).
func placePayouts(attrs map[string]string) []PlacePayout {
	var out []PlacePayout
	for key, player := range attrs {
		if !strings.HasPrefix(key, "place_") || !strings.HasSuffix(key, "_player") || player == "" {
			continue
		}
		place, err := strconv.Atoi(strings.TrimSuffix(strings.TrimPrefix(key, "place_"), "_player"))
		if err != nil || place < 1 {
			continue
		}
		payout, err := strconv.ParseInt(attrs[fmt.Sprintf("place_%d_payout", place)], 10, 64)
		if err != nil || payout < 0 {
			continue
		}
		out = append(out, PlacePayout{Place: place, Player: player, Payout: payout})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Place < out[j].Place })
	return out
}

// nullableInt parses an attribute as an integer, or NULL when absent/bad.
func nullableInt(s string) interface{} {
	if n, err := strconv.ParseInt(s, 10, 64); err == nil {
		return n
	}
	return nil
}
