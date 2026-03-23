// derive-cards extracts revealed cards from stored deck data
// This backfills the revealed_cards and hand_results tables from poker_hands
package main

import (
	"database/sql"
	"flag"
	"fmt"
	"log"
	"strings"

	"github.com/lib/pq"
)

// PokerHand represents a hand with deck data
type PokerHand struct {
	GameID      string
	HandNumber  int
	BlockHeight int64
	Deck        string
}

func main() {
	// Parse flags
	dbHost := flag.String("db-host", "localhost", "PostgreSQL host")
	dbPort := flag.Int("db-port", 5432, "PostgreSQL port")
	dbUser := flag.String("db-user", "poker", "PostgreSQL user")
	dbPass := flag.String("db-pass", "poker_indexer_dev", "PostgreSQL password")
	dbName := flag.String("db-name", "poker_hands", "PostgreSQL database")
	numPlayers := flag.Int("players", 2, "Number of players in each hand (default 2)")
	dryRun := flag.Bool("dry-run", false, "Show what would be done without making changes")

	flag.Parse()

	// Connect to database
	connStr := fmt.Sprintf("host=%s port=%d user=%s password=%s dbname=%s sslmode=disable",
		*dbHost, *dbPort, *dbUser, *dbPass, *dbName)

	db, err := sql.Open("postgres", connStr)
	if err != nil {
		log.Fatalf("Failed to connect to database: %v", err)
	}
	defer db.Close()

	if err := db.Ping(); err != nil {
		log.Fatalf("Failed to ping database: %v", err)
	}
	log.Println("Connected to PostgreSQL")

	// Get hands with deck data that don't have revealed cards yet
	hands, err := getHandsWithDecks(db)
	if err != nil {
		log.Fatalf("Failed to get hands: %v", err)
	}

	log.Printf("Found %d hands with deck data to process", len(hands))

	if *dryRun {
		log.Println("DRY RUN - no changes will be made")
	}

	processed := 0
	skipped := 0

	for _, hand := range hands {
		cards := parseDeck(hand.Deck)
		if len(cards) < 52 {
			log.Printf("Skipping hand %s/%d: invalid deck (only %d cards)", hand.GameID, hand.HandNumber, len(cards))
			skipped++
			continue
		}

		// Derive cards based on number of players
		holeCards, communityCards := deriveCards(cards, *numPlayers)

		if *dryRun {
			log.Printf("Would process hand %s/%d:", hand.GameID, hand.HandNumber)
			log.Printf("  Hole cards: %v", holeCards)
			log.Printf("  Community cards: %v", communityCards)
			processed++
			continue
		}

		// Insert hand result
		err := insertHandResult(db, hand, communityCards)
		if err != nil {
			log.Printf("Warning: failed to insert hand result for %s/%d: %v", hand.GameID, hand.HandNumber, err)
		}

		// Insert revealed cards
		err = insertRevealedCards(db, hand, holeCards, communityCards)
		if err != nil {
			log.Printf("Warning: failed to insert revealed cards for %s/%d: %v", hand.GameID, hand.HandNumber, err)
		}

		processed++
		if processed%10 == 0 {
			log.Printf("Processed %d/%d hands", processed, len(hands))
		}
	}

	log.Printf("Done! Processed: %d, Skipped: %d", processed, skipped)
}

// getHandsWithDecks retrieves hands that have deck data but no revealed cards
func getHandsWithDecks(db *sql.DB) ([]PokerHand, error) {
	rows, err := db.Query(`
		SELECT ph.game_id, ph.hand_number, ph.block_height, ph.deck
		FROM poker_hands ph
		LEFT JOIN hand_results hr ON ph.game_id = hr.game_id AND ph.hand_number = hr.hand_number
		WHERE ph.deck <> '' AND hr.game_id IS NULL
		ORDER BY ph.block_height
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var hands []PokerHand
	for rows.Next() {
		var h PokerHand
		if err := rows.Scan(&h.GameID, &h.HandNumber, &h.BlockHeight, &h.Deck); err != nil {
			return nil, err
		}
		hands = append(hands, h)
	}

	return hands, nil
}

// parseDeck parses a deck string like "[AS]-KH-QD-..." into card codes
// Returns lowercase card codes to match card_distribution_stats format
func parseDeck(deck string) []string {
	if deck == "" {
		return nil
	}

	// Remove the brackets from first card
	deck = strings.ReplaceAll(deck, "[", "")
	deck = strings.ReplaceAll(deck, "]", "")

	// Split by dash
	cards := strings.Split(deck, "-")

	// Clean up any whitespace and convert to lowercase
	var result []string
	for _, card := range cards {
		card = strings.TrimSpace(card)
		if card != "" {
			result = append(result, strings.ToLower(card))
		}
	}

	return result
}

// deriveCards extracts hole cards and community cards from deck based on player count
// In Texas Hold'em:
// - Deal 2 cards to each player (one at a time, rotating)
// - Then deal 5 community cards (3 flop + 1 turn + 1 river)
func deriveCards(deck []string, numPlayers int) (holeCards []string, communityCards []string) {
	if len(deck) < numPlayers*2+5 {
		return nil, nil
	}

	// Hole cards: first 2*numPlayers cards
	// Cards are dealt one at a time rotating, so player 1 gets cards 0, numPlayers, player 2 gets 1, numPlayers+1, etc.
	// But we'll just record all hole cards as a flat list for now
	totalHoleCards := numPlayers * 2
	holeCards = deck[:totalHoleCards]

	// Community cards: next 5 cards after hole cards
	communityCards = deck[totalHoleCards : totalHoleCards+5]

	return holeCards, communityCards
}

// insertHandResult inserts a completed hand result
func insertHandResult(db *sql.DB, hand PokerHand, communityCards []string) error {
	_, err := db.Exec(`
		INSERT INTO hand_results (game_id, hand_number, block_height, community_cards, winner_count, tx_hash)
		VALUES ($1, $2, $3, $4, 1, '')
		ON CONFLICT (game_id, hand_number) DO UPDATE SET
			community_cards = EXCLUDED.community_cards
	`, hand.GameID, hand.HandNumber, hand.BlockHeight, pq.Array(communityCards))
	return err
}

// insertRevealedCards inserts individual revealed cards
func insertRevealedCards(db *sql.DB, hand PokerHand, holeCards []string, communityCards []string) error {
	// Insert hole cards
	for i, card := range holeCards {
		_, err := db.Exec(`
			INSERT INTO revealed_cards (game_id, hand_number, block_height, card, card_type, position)
			VALUES ($1, $2, $3, $4, 'hole', $5)
			ON CONFLICT DO NOTHING
		`, hand.GameID, hand.HandNumber, hand.BlockHeight, card, i)
		if err != nil {
			return err
		}
	}

	// Insert community cards
	for i, card := range communityCards {
		_, err := db.Exec(`
			INSERT INTO revealed_cards (game_id, hand_number, block_height, card, card_type, position)
			VALUES ($1, $2, $3, $4, 'community', $5)
			ON CONFLICT DO NOTHING
		`, hand.GameID, hand.HandNumber, hand.BlockHeight, card, i)
		if err != nil {
			return err
		}
	}

	return nil
}
