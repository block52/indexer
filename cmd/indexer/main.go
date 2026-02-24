// Standalone poker hand indexer for backfilling historical blocks
package main

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/lib/pq"
)

// Config holds indexer configuration
type Config struct {
	NodeRPC    string
	NodeAPI    string // REST API endpoint for game state queries
	DBHost     string
	DBPort     int
	DBUser     string
	DBPassword string
	DBName     string
	StartBlock int64
	EndBlock   int64
	BatchSize  int
}

// BlockResult from RPC
type BlockResult struct {
	Result struct {
		Block struct {
			Header struct {
				Height  string `json:"height"`
				AppHash string `json:"app_hash"`
			} `json:"header"`
			Data struct {
				Txs []string `json:"txs"`
			} `json:"data"`
		} `json:"block"`
	} `json:"result"`
}

// BlockResultsResponse from RPC
type BlockResultsResponse struct {
	Result struct {
		Height     string `json:"height"`
		TxsResults []struct {
			Events []Event `json:"events"`
		} `json:"txs_results"`
		BeginBlockEvents []Event `json:"begin_block_events"`
		EndBlockEvents   []Event `json:"end_block_events"`
	} `json:"result"`
}

// Event from Cosmos
type Event struct {
	Type       string `json:"type"`
	Attributes []struct {
		Key   string `json:"key"`
		Value string `json:"value"`
		Index bool   `json:"index"`
	} `json:"attributes"`
}

// StatusResult from RPC
type StatusResult struct {
	Result struct {
		SyncInfo struct {
			LatestBlockHeight string `json:"latest_block_height"`
		} `json:"sync_info"`
	} `json:"result"`
}

// GameStateResponse from REST API
type GameStateResponse struct {
	GameState *GameState `json:"game_state"`
}

// GameState represents the poker game state
type GameState struct {
	Type           string   `json:"type"`
	Address        string   `json:"address"`
	Dealer         int      `json:"dealer"`
	Players        []Player `json:"players"`
	CommunityCards []string `json:"communityCards"`
	Deck           string   `json:"deck"`
	Round          string   `json:"round"`
	HandNumber     int      `json:"handNumber"`
	Winners        []Winner `json:"winners"`
}

// Player in game state
type Player struct {
	Address   string   `json:"address"`
	Seat      int      `json:"seat"`
	Stack     string   `json:"stack"`
	HoleCards []string `json:"holeCards"`
	Status    string   `json:"status"`
}

// Winner info
type Winner struct {
	Address string   `json:"address"`
	Amount  string   `json:"amount"`
	Cards   []string `json:"cards"`
}

func main() {
	// Parse flags
	nodeRPC := flag.String("node", "", "Node RPC URL (e.g., http://localhost:26657)")
	nodeAPI := flag.String("api", "", "Node REST API URL (e.g., http://localhost:1317) - derived from RPC if not set")
	dbHost := flag.String("db-host", "localhost", "PostgreSQL host")
	dbPort := flag.Int("db-port", 5432, "PostgreSQL port")
	dbUser := flag.String("db-user", "poker", "PostgreSQL user")
	dbPass := flag.String("db-pass", "poker_indexer_dev", "PostgreSQL password")
	dbName := flag.String("db-name", "poker_hands", "PostgreSQL database")
	startBlock := flag.Int64("start", 1, "Start block height")
	endBlock := flag.Int64("end", 0, "End block height (0 = latest)")
	batchSize := flag.Int("batch", 100, "Blocks per batch")

	flag.Parse()

	if *nodeRPC == "" {
		*nodeRPC = os.Getenv("NODE_RPC")
		if *nodeRPC == "" {
			log.Fatal("Node RPC URL required. Use -node flag or NODE_RPC env var")
		}
	}

	// Derive API URL from RPC if not provided
	if *nodeAPI == "" {
		*nodeAPI = os.Getenv("NODE_API")
		if *nodeAPI == "" {
			// Try to derive from RPC URL (replace port or path)
			*nodeAPI = strings.Replace(*nodeRPC, ":26657", ":1317", 1)
			*nodeAPI = strings.Replace(*nodeAPI, "/rpc", "/api", 1)
		}
	}

	config := Config{
		NodeRPC:    strings.TrimSuffix(*nodeRPC, "/"),
		NodeAPI:    strings.TrimSuffix(*nodeAPI, "/"),
		DBHost:     *dbHost,
		DBPort:     *dbPort,
		DBUser:     *dbUser,
		DBPassword: *dbPass,
		DBName:     *dbName,
		StartBlock: *startBlock,
		EndBlock:   *endBlock,
		BatchSize:  *batchSize,
	}

	// Connect to database
	connStr := fmt.Sprintf("host=%s port=%d user=%s password=%s dbname=%s sslmode=disable",
		config.DBHost, config.DBPort, config.DBUser, config.DBPassword, config.DBName)

	db, err := sql.Open("postgres", connStr)
	if err != nil {
		log.Fatalf("Failed to connect to database: %v", err)
	}
	defer db.Close()

	if err := db.Ping(); err != nil {
		log.Fatalf("Failed to ping database: %v", err)
	}
	log.Println("Connected to PostgreSQL")

	// Get latest block if end not specified
	if config.EndBlock == 0 {
		latest, err := getLatestBlockHeight(config.NodeRPC)
		if err != nil {
			log.Fatalf("Failed to get latest block: %v", err)
		}
		config.EndBlock = latest
		log.Printf("Latest block: %d", latest)
	}

	log.Printf("Using RPC: %s", config.NodeRPC)
	log.Printf("Using API: %s", config.NodeAPI)

	// Run indexer
	indexer := NewIndexer(db, config)
	if err := indexer.Run(context.Background()); err != nil {
		log.Fatalf("Indexer failed: %v", err)
	}

	log.Println("Indexing complete!")
}

// Indexer handles block indexing
type Indexer struct {
	db           *sql.DB
	config       Config
	client       *http.Client
	seenNewHands map[string]bool // track game_id to avoid duplicate queries
}

// NewIndexer creates a new indexer
func NewIndexer(db *sql.DB, config Config) *Indexer {
	return &Indexer{
		db:           db,
		config:       config,
		client:       &http.Client{Timeout: 30 * time.Second},
		seenNewHands: make(map[string]bool),
	}
}

// Run starts the indexing process
func (idx *Indexer) Run(ctx context.Context) error {
	totalBlocks := idx.config.EndBlock - idx.config.StartBlock + 1
	log.Printf("Indexing blocks %d to %d (%d total)", idx.config.StartBlock, idx.config.EndBlock, totalBlocks)

	processed := int64(0)
	actionsFound := 0
	newHandsFound := 0
	showdownsFound := 0
	startTime := time.Now()

	for height := idx.config.StartBlock; height <= idx.config.EndBlock; height++ {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		blockInfo, events, err := idx.fetchBlockWithEvents(height)
		if err != nil {
			log.Printf("Warning: failed to fetch block %d: %v", height, err)
			continue
		}

		// Update progress tracking after each block
		idx.updateProgress(height)

		for _, event := range events {
			// Handle new event types (v0.1.33+)
			if event.Type == "hand_started" || event.Type == "hand_completed" {
				if err := idx.processNewEvent(event, height, ""); err != nil {
					log.Printf("Warning: failed to process event at block %d: %v", height, err)
				} else {
					if event.Type == "hand_started" {
						newHandsFound++
					} else {
						showdownsFound++
					}
				}
				continue
			}

			// Handle legacy action_performed events
			if event.Type == "action_performed" {
				actionsFound++
				attrs := idx.parseEventAttrs(event)
				action := attrs["action"]
				gameID := attrs["game_id"]
				player := attrs["player"]

				// Record player action for stats
				if player != "" && gameID != "" {
					idx.recordPlayerAction(player, gameID, action, attrs["amount"], height)
				}

				// New hand started - record deck info
				if action == "new-hand" {
					newHandsFound++
					if err := idx.handleNewHandAction(attrs, height, blockInfo.AppHash); err != nil {
						log.Printf("Warning: failed to handle new-hand at block %d: %v", height, err)
					}
				}

				// Check for showdown by querying game state
				if gameID != "" && (action == "show" || action == "muck" || action == "fold") {
					if err := idx.checkAndHandleShowdown(gameID, height); err != nil {
						// Don't log every error - showdowns are rare
						if strings.Contains(err.Error(), "showdown") {
							showdownsFound++
						}
					}
				}
			}

			// Handle player join/leave events
			if event.Type == "player_joined_game" {
				attrs := idx.parseEventAttrs(event)
				idx.recordPlayerSession(attrs, height, true)
			}
			if event.Type == "player_left_game" {
				attrs := idx.parseEventAttrs(event)
				idx.recordPlayerSession(attrs, height, false)
			}
		}

		processed++
		if processed%100 == 0 {
			elapsed := time.Since(startTime)
			blocksPerSec := float64(processed) / elapsed.Seconds()
			remaining := float64(totalBlocks-processed) / blocksPerSec
			log.Printf("Progress: %d/%d (%.1f%%), actions: %d, new-hands: %d, showdowns: %d, %.1f blk/s, ETA: %s",
				processed, totalBlocks,
				float64(processed)/float64(totalBlocks)*100,
				actionsFound, newHandsFound, showdownsFound,
				blocksPerSec,
				time.Duration(remaining*float64(time.Second)).Round(time.Second))
		}
	}

	log.Printf("Finished: %d blocks, %d actions, %d new-hands, %d showdowns",
		processed, actionsFound, newHandsFound, showdownsFound)
	return nil
}

// BlockInfo contains parsed block header info
type BlockInfo struct {
	Height  int64
	AppHash string
}

// fetchBlockWithEvents gets block info and events
func (idx *Indexer) fetchBlockWithEvents(height int64) (*BlockInfo, []Event, error) {
	// Get block results (events)
	url := fmt.Sprintf("%s/block_results?height=%d", idx.config.NodeRPC, height)
	resp, err := idx.client.Get(url)
	if err != nil {
		return nil, nil, fmt.Errorf("HTTP request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, string(body))
	}

	var result BlockResultsResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, nil, fmt.Errorf("JSON decode failed: %w", err)
	}

	// Get block header for app hash
	blockURL := fmt.Sprintf("%s/block?height=%d", idx.config.NodeRPC, height)
	blockResp, err := idx.client.Get(blockURL)
	if err != nil {
		return nil, nil, fmt.Errorf("block request failed: %w", err)
	}
	defer blockResp.Body.Close()

	var blockResult BlockResult
	if err := json.NewDecoder(blockResp.Body).Decode(&blockResult); err != nil {
		return nil, nil, fmt.Errorf("block JSON decode failed: %w", err)
	}

	blockInfo := &BlockInfo{
		Height:  height,
		AppHash: blockResult.Result.Block.Header.AppHash,
	}

	var events []Event
	for _, txResult := range result.Result.TxsResults {
		events = append(events, txResult.Events...)
	}
	events = append(events, result.Result.BeginBlockEvents...)
	events = append(events, result.Result.EndBlockEvents...)

	return blockInfo, events, nil
}

// parseEventAttrs extracts attributes from an event
func (idx *Indexer) parseEventAttrs(event Event) map[string]string {
	attrs := make(map[string]string)
	for _, attr := range event.Attributes {
		key := decodeIfBase64(attr.Key)
		value := decodeIfBase64(attr.Value)
		attrs[key] = value
	}
	return attrs
}

// handleNewHandAction processes a new-hand action from action_performed event
func (idx *Indexer) handleNewHandAction(attrs map[string]string, blockHeight int64, appHash string) error {
	gameID := attrs["game_id"]
	if gameID == "" {
		return fmt.Errorf("no game_id in event")
	}

	// Query current game state to get hand number and deck
	gameState, err := idx.queryGameState(gameID)
	if err != nil {
		// Game state query failed - store what we have
		_, err := idx.db.Exec(`
			INSERT INTO poker_hands (game_id, hand_number, block_height, deck_seed, deck, tx_hash)
			VALUES ($1, 0, $2, $3, '', '')
			ON CONFLICT (game_id, hand_number) DO NOTHING
		`, gameID, blockHeight, appHash)
		return err
	}

	// Store hand with deck info from game state
	_, err = idx.db.Exec(`
		INSERT INTO poker_hands (game_id, hand_number, block_height, deck_seed, deck, tx_hash)
		VALUES ($1, $2, $3, $4, $5, '')
		ON CONFLICT (game_id, hand_number) DO UPDATE SET
			deck_seed = EXCLUDED.deck_seed,
			deck = EXCLUDED.deck
	`, gameID, gameState.HandNumber, blockHeight, appHash, gameState.Deck)

	return err
}

// checkAndHandleShowdown checks if game is at showdown and records revealed cards
func (idx *Indexer) checkAndHandleShowdown(gameID string, blockHeight int64) error {
	gameState, err := idx.queryGameState(gameID)
	if err != nil {
		return err
	}

	// Only process if at showdown with winners
	if gameState.Round != "showdown" || len(gameState.Winners) == 0 {
		return nil
	}

	// Collect revealed hole cards
	var revealedCards []string
	for _, player := range gameState.Players {
		if len(player.HoleCards) > 0 {
			revealedCards = append(revealedCards, player.HoleCards...)
		}
	}

	// Insert hand result
	_, err = idx.db.Exec(`
		INSERT INTO hand_results (game_id, hand_number, block_height, community_cards, winner_count, tx_hash)
		VALUES ($1, $2, $3, $4, $5, '')
		ON CONFLICT (game_id, hand_number) DO UPDATE SET
			community_cards = EXCLUDED.community_cards,
			winner_count = EXCLUDED.winner_count
	`, gameID, gameState.HandNumber, blockHeight, pq.Array(gameState.CommunityCards), len(gameState.Winners))

	if err != nil {
		return fmt.Errorf("failed to insert hand result: %w", err)
	}

	// Insert community cards
	for i, card := range gameState.CommunityCards {
		if card == "" {
			continue
		}
		idx.db.Exec(`
			INSERT INTO revealed_cards (game_id, hand_number, block_height, card, card_type, position)
			VALUES ($1, $2, $3, $4, 'community', $5)
			ON CONFLICT DO NOTHING
		`, gameID, gameState.HandNumber, blockHeight, card, i)
	}

	// Insert revealed hole cards
	for i, card := range revealedCards {
		if card == "" {
			continue
		}
		idx.db.Exec(`
			INSERT INTO revealed_cards (game_id, hand_number, block_height, card, card_type, position)
			VALUES ($1, $2, $3, $4, 'hole', $5)
			ON CONFLICT DO NOTHING
		`, gameID, gameState.HandNumber, blockHeight, card, i)
	}

	return fmt.Errorf("showdown processed") // Signal that we found one
}

// queryGameState fetches game state from the REST API
func (idx *Indexer) queryGameState(gameID string) (*GameState, error) {
	url := fmt.Sprintf("%s/pokerchain/poker/v1/game_state_public/%s", idx.config.NodeAPI, gameID)

	resp, err := idx.client.Get(url)
	if err != nil {
		return nil, fmt.Errorf("game state request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("game state HTTP %d: %s", resp.StatusCode, string(body))
	}

	var result GameStateResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("game state JSON decode failed: %w", err)
	}

	if result.GameState == nil {
		return nil, fmt.Errorf("no game state in response")
	}

	return result.GameState, nil
}

// processNewEvent handles the new hand_started/hand_completed events (v0.1.33+)
func (idx *Indexer) processNewEvent(event Event, blockHeight int64, txHash string) error {
	attrs := idx.parseEventAttrs(event)

	switch event.Type {
	case "hand_started":
		return idx.handleHandStarted(attrs, blockHeight, txHash)
	case "hand_completed":
		return idx.handleHandCompleted(attrs, blockHeight, txHash)
	}
	return nil
}

// handleHandStarted processes hand_started events
func (idx *Indexer) handleHandStarted(attrs map[string]string, blockHeight int64, txHash string) error {
	gameID := attrs["game_id"]
	handNumber, _ := strconv.Atoi(attrs["hand_number"])
	deckSeed := attrs["deck_seed"]
	deck := attrs["deck"]

	if h, ok := attrs["block_height"]; ok {
		if parsed, err := strconv.ParseInt(h, 10, 64); err == nil {
			blockHeight = parsed
		}
	}

	_, err := idx.db.Exec(`
		INSERT INTO poker_hands (game_id, hand_number, block_height, deck_seed, deck, tx_hash)
		VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (game_id, hand_number) DO UPDATE SET
			deck_seed = EXCLUDED.deck_seed,
			deck = EXCLUDED.deck
	`, gameID, handNumber, blockHeight, deckSeed, deck, txHash)

	return err
}

// handleHandCompleted processes hand_completed events
func (idx *Indexer) handleHandCompleted(attrs map[string]string, blockHeight int64, txHash string) error {
	gameID := attrs["game_id"]
	handNumber, _ := strconv.Atoi(attrs["hand_number"])
	communityCardsStr := attrs["community_cards"]
	revealedHoleCardsStr := attrs["revealed_hole_cards"]
	winnerCount, _ := strconv.Atoi(attrs["winner_count"])

	if h, ok := attrs["block_height"]; ok {
		if parsed, err := strconv.ParseInt(h, 10, 64); err == nil {
			blockHeight = parsed
		}
	}

	var communityCards []string
	if communityCardsStr != "" {
		communityCards = strings.Split(communityCardsStr, ",")
	}

	_, err := idx.db.Exec(`
		INSERT INTO hand_results (game_id, hand_number, block_height, community_cards, winner_count, tx_hash)
		VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (game_id, hand_number) DO UPDATE SET
			community_cards = EXCLUDED.community_cards,
			winner_count = EXCLUDED.winner_count
	`, gameID, handNumber, blockHeight, pq.Array(communityCards), winnerCount, txHash)

	if err != nil {
		return fmt.Errorf("failed to insert hand result: %w", err)
	}

	for i, card := range communityCards {
		if card == "" {
			continue
		}
		idx.db.Exec(`
			INSERT INTO revealed_cards (game_id, hand_number, block_height, card, card_type, position)
			VALUES ($1, $2, $3, $4, 'community', $5)
			ON CONFLICT DO NOTHING
		`, gameID, handNumber, blockHeight, card, i)
	}

	if revealedHoleCardsStr != "" {
		holeCards := strings.Split(revealedHoleCardsStr, ",")
		for i, card := range holeCards {
			if card == "" {
				continue
			}
			idx.db.Exec(`
				INSERT INTO revealed_cards (game_id, hand_number, block_height, card, card_type, position)
				VALUES ($1, $2, $3, $4, 'hole', $5)
				ON CONFLICT DO NOTHING
			`, gameID, handNumber, blockHeight, card, i)
		}
	}

	return nil
}

// getLatestBlockHeight fetches the current chain height
func getLatestBlockHeight(nodeRPC string) (int64, error) {
	url := fmt.Sprintf("%s/status", nodeRPC)

	resp, err := http.Get(url)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()

	var result StatusResult
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return 0, err
	}

	return strconv.ParseInt(result.Result.SyncInfo.LatestBlockHeight, 10, 64)
}

// decodeIfBase64 attempts to decode a base64 string, returns original if not base64
func decodeIfBase64(s string) string {
	decoded, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		return s
	}
	return string(decoded)
}

// recordPlayerAction stores a player action for stats tracking
func (idx *Indexer) recordPlayerAction(player, gameID, action, amountStr string, blockHeight int64) {
	amount, _ := strconv.ParseInt(amountStr, 10, 64)

	idx.db.Exec(`
		INSERT INTO player_actions (player_address, game_id, block_height, action, amount)
		VALUES ($1, $2, $3, $4, $5)
	`, player, gameID, blockHeight, action, amount)
}

// recordPlayerSession tracks player join/leave for session stats
func (idx *Indexer) recordPlayerSession(attrs map[string]string, blockHeight int64, isJoin bool) {
	player := attrs["player"]
	gameID := attrs["game_id"]

	if player == "" || gameID == "" {
		return
	}

	if isJoin {
		buyIn, _ := strconv.ParseInt(attrs["buy_in_amount"], 10, 64)
		idx.db.Exec(`
			INSERT INTO player_sessions (player_address, game_id, join_block, buy_in_amount)
			VALUES ($1, $2, $3, $4)
			ON CONFLICT (player_address, game_id, join_block) DO NOTHING
		`, player, gameID, blockHeight, buyIn)
	} else {
		refund, _ := strconv.ParseInt(attrs["refund_amount"], 10, 64)
		// Update the most recent session for this player/game
		idx.db.Exec(`
			UPDATE player_sessions
			SET leave_block = $1, cash_out_amount = $2
			WHERE player_address = $3 AND game_id = $4 AND leave_block IS NULL
		`, blockHeight, refund, player, gameID)
	}
}

// updateProgress updates the indexing progress in the database
func (idx *Indexer) updateProgress(blockHeight int64) {
	// Update every 100 blocks to reduce database writes
	if blockHeight%100 == 0 {
		_, err := idx.db.Exec(`
			INSERT INTO indexing_progress (id, last_scanned_block, total_blocks_scanned, last_updated)
			VALUES (1, $1, $1 - $2 + 1, NOW())
			ON CONFLICT (id) DO UPDATE SET
				last_scanned_block = EXCLUDED.last_scanned_block,
				total_blocks_scanned = EXCLUDED.total_blocks_scanned,
				last_updated = EXCLUDED.last_updated
		`, blockHeight, idx.config.StartBlock)
		if err != nil {
			log.Printf("Warning: failed to update progress at block %d: %v", blockHeight, err)
		}
	}
}
