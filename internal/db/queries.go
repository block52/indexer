package db

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"github.com/block52/indexer/internal/models"
	"github.com/lib/pq"
)

const queryTimeout = 30 * time.Second

func getContext() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), queryTimeout)
}

// GetHands retrieves poker hands with pagination
func (db *DB) GetHands(limit, offset int, gameID string, startBlock, endBlock int64) ([]models.PokerHand, int64, error) {
	ctx, cancel := getContext()
	defer cancel()

	// Build query with optional filters
	query := `SELECT game_id, hand_number, block_height, deck_seed, deck, tx_hash, created_at
	          FROM poker_hands WHERE 1=1`
	countQuery := `SELECT COUNT(*) FROM poker_hands WHERE 1=1`
	args := []interface{}{}
	argPos := 1

	if gameID != "" {
		query += fmt.Sprintf(" AND game_id = $%d", argPos)
		countQuery += fmt.Sprintf(" AND game_id = $%d", argPos)
		args = append(args, gameID)
		argPos++
	}
	if startBlock > 0 {
		query += fmt.Sprintf(" AND block_height >= $%d", argPos)
		countQuery += fmt.Sprintf(" AND block_height >= $%d", argPos)
		args = append(args, startBlock)
		argPos++
	}
	if endBlock > 0 {
		query += fmt.Sprintf(" AND block_height <= $%d", argPos)
		countQuery += fmt.Sprintf(" AND block_height <= $%d", argPos)
		args = append(args, endBlock)
		argPos++
	}

	// Get total count
	var total int64
	if err := db.QueryRowContext(ctx, countQuery, args...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("failed to count hands: %w", err)
	}

	// Get paginated results
	query += fmt.Sprintf(" ORDER BY block_height DESC, hand_number DESC LIMIT $%d OFFSET $%d", argPos, argPos+1)
	args = append(args, limit, offset)

	rows, err := db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, 0, fmt.Errorf("failed to query hands: %w", err)
	}
	defer rows.Close()

	var hands []models.PokerHand
	for rows.Next() {
		var hand models.PokerHand
		if err := rows.Scan(&hand.GameID, &hand.HandNumber, &hand.BlockHeight, &hand.DeckSeed, &hand.Deck, &hand.TxHash, &hand.CreatedAt); err != nil {
			return nil, 0, fmt.Errorf("failed to scan hand: %w", err)
		}
		hands = append(hands, hand)
	}

	return hands, total, nil
}

// GetHandDetails retrieves detailed information about a specific hand
func (db *DB) GetHandDetails(gameID string, handNumber int) (*models.HandDetails, error) {
	ctx, cancel := getContext()
	defer cancel()

	details := &models.HandDetails{}

	// Get hand info
	err := db.QueryRowContext(ctx, `
		SELECT game_id, hand_number, block_height, deck_seed, deck, tx_hash, created_at
		FROM poker_hands
		WHERE game_id = $1 AND hand_number = $2
	`, gameID, handNumber).Scan(
		&details.GameID, &details.HandNumber, &details.BlockHeight,
		&details.DeckSeed, &details.Deck, &details.TxHash, &details.CreatedAt,
	)
	if err == sql.ErrNoRows {
		return nil, fmt.Errorf("hand not found")
	}
	if err != nil {
		return nil, fmt.Errorf("failed to get hand: %w", err)
	}

	// Get result if available
	var result models.HandResult
	err = db.QueryRowContext(ctx, `
		SELECT game_id, hand_number, block_height, community_cards, winner_count, tx_hash, created_at
		FROM hand_results
		WHERE game_id = $1 AND hand_number = $2
	`, gameID, handNumber).Scan(
		&result.GameID, &result.HandNumber, &result.BlockHeight,
		pq.Array(&result.CommunityCards), &result.WinnerCount, &result.TxHash, &result.CreatedAt,
	)
	if err == nil {
		details.Result = &result
	} else if err != sql.ErrNoRows {
		return nil, fmt.Errorf("failed to get hand result: %w", err)
	}

	// Get revealed cards
	rows, err := db.QueryContext(ctx, `
		SELECT id, game_id, hand_number, block_height, card, card_type, position, created_at
		FROM revealed_cards
		WHERE game_id = $1 AND hand_number = $2
		ORDER BY card_type, position
	`, gameID, handNumber)
	if err != nil {
		return nil, fmt.Errorf("failed to query revealed cards: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		var card models.RevealedCard
		if err := rows.Scan(&card.ID, &card.GameID, &card.HandNumber, &card.BlockHeight, &card.Card, &card.CardType, &card.Position, &card.CreatedAt); err != nil {
			return nil, fmt.Errorf("failed to scan revealed card: %w", err)
		}
		details.RevealedCards = append(details.RevealedCards, card)
	}

	return details, nil
}

// GetRevealedCards retrieves all revealed cards for a specific hand
func (db *DB) GetRevealedCards(gameID string, handNumber int) ([]models.RevealedCard, error) {
	ctx, cancel := getContext()
	defer cancel()

	rows, err := db.QueryContext(ctx, `
		SELECT id, game_id, hand_number, block_height, card, card_type, position, created_at
		FROM revealed_cards
		WHERE game_id = $1 AND hand_number = $2
		ORDER BY card_type DESC, position
	`, gameID, handNumber)
	if err != nil {
		return nil, fmt.Errorf("failed to query revealed cards: %w", err)
	}
	defer rows.Close()

	var cards []models.RevealedCard
	for rows.Next() {
		var card models.RevealedCard
		if err := rows.Scan(&card.ID, &card.GameID, &card.HandNumber, &card.BlockHeight, &card.Card, &card.CardType, &card.Position, &card.CreatedAt); err != nil {
			return nil, fmt.Errorf("failed to scan revealed card: %w", err)
		}
		cards = append(cards, card)
	}

	return cards, nil
}

// GetStatsSummary retrieves overall statistics
func (db *DB) GetStatsSummary() (*models.StatsSummary, error) {
	ctx, cancel := getContext()
	defer cancel()

	summary := &models.StatsSummary{}

	err := db.QueryRowContext(ctx, `
		SELECT
			(SELECT COUNT(*) FROM poker_hands) as total_hands,
			(SELECT COUNT(*) FROM hand_results) as total_completed_hands,
			(SELECT COUNT(*) FROM revealed_cards) as total_revealed_cards,
			(SELECT COUNT(DISTINCT game_id) FROM poker_hands) as unique_games,
			(SELECT CONCAT(MIN(block_height), '-', MAX(block_height)) FROM poker_hands) as block_range,
			(SELECT MIN(created_at) FROM poker_hands) as first_indexed,
			(SELECT MAX(created_at) FROM poker_hands) as last_indexed
	`).Scan(
		&summary.TotalHands,
		&summary.TotalCompletedHands,
		&summary.TotalRevealedCards,
		&summary.UniqueGames,
		&summary.BlockHeightRange,
		&summary.FirstIndexedAt,
		&summary.LastIndexedAt,
	)

	if err != nil {
		return nil, fmt.Errorf("failed to get summary: %w", err)
	}

	return summary, nil
}

// GetCardStats retrieves card frequency statistics
func (db *DB) GetCardStats(card string) ([]models.CardStats, error) {
	ctx, cancel := getContext()
	defer cancel()

	query := `SELECT * FROM card_frequency_analysis WHERE 1=1`
	args := []interface{}{}

	if card != "" {
		query += ` AND card = $1`
		args = append(args, card)
	}

	query += ` ORDER BY total_appearances DESC`

	rows, err := db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("failed to query card stats: %w", err)
	}
	defer rows.Close()

	var stats []models.CardStats
	for rows.Next() {
		var stat models.CardStats
		if err := rows.Scan(&stat.Card, &stat.Rank, &stat.Suit, &stat.TotalAppearances, &stat.ExpectedFrequency, &stat.ActualFrequency, &stat.Deviation, &stat.DeviationPercent); err != nil {
			return nil, fmt.Errorf("failed to scan card stat: %w", err)
		}
		stats = append(stats, stat)
	}

	return stats, nil
}

// GetSuitStats retrieves suit distribution statistics
func (db *DB) GetSuitStats() ([]models.SuitStats, error) {
	ctx, cancel := getContext()
	defer cancel()

	rows, err := db.QueryContext(ctx, `SELECT * FROM suit_distribution ORDER BY suit`)
	if err != nil {
		return nil, fmt.Errorf("failed to query suit stats: %w", err)
	}
	defer rows.Close()

	var stats []models.SuitStats
	for rows.Next() {
		var stat models.SuitStats
		if err := rows.Scan(&stat.Suit, &stat.TotalAppearances, &stat.ExpectedFrequency, &stat.ActualFrequency, &stat.Deviation); err != nil {
			return nil, fmt.Errorf("failed to scan suit stat: %w", err)
		}
		stats = append(stats, stat)
	}

	return stats, nil
}

// GetRankStats retrieves rank distribution statistics
func (db *DB) GetRankStats() ([]models.RankStats, error) {
	ctx, cancel := getContext()
	defer cancel()

	rows, err := db.QueryContext(ctx, `SELECT * FROM rank_distribution ORDER BY rank`)
	if err != nil {
		return nil, fmt.Errorf("failed to query rank stats: %w", err)
	}
	defer rows.Close()

	var stats []models.RankStats
	for rows.Next() {
		var stat models.RankStats
		if err := rows.Scan(&stat.Rank, &stat.TotalAppearances, &stat.ExpectedFrequency, &stat.ActualFrequency, &stat.Deviation); err != nil {
			return nil, fmt.Errorf("failed to scan rank stat: %w", err)
		}
		stats = append(stats, stat)
	}

	return stats, nil
}

// GetChiSquaredTest retrieves chi-squared test results
func (db *DB) GetChiSquaredTest() (*models.ChiSquaredResult, error) {
	ctx, cancel := getContext()
	defer cancel()

	result := &models.ChiSquaredResult{}
	err := db.QueryRowContext(ctx, `SELECT * FROM calculate_chi_squared()`).Scan(
		&result.ChiSquared,
		&result.DegreesOfFreedom,
		&result.PValue,
		&result.Result,
		&result.Interpretation,
	)

	if err != nil {
		return nil, fmt.Errorf("failed to get chi-squared test: %w", err)
	}

	return result, nil
}

// GetOutlierCards retrieves cards with significant deviation
func (db *DB) GetOutlierCards(threshold float64) ([]models.CardStats, error) {
	ctx, cancel := getContext()
	defer cancel()

	if threshold <= 0 {
		threshold = 1.0 // Default 1% deviation
	}

	rows, err := db.QueryContext(ctx, `
		SELECT * FROM card_frequency_analysis
		WHERE ABS(deviation_percent) > $1
		ORDER BY ABS(deviation_percent) DESC
	`, threshold)
	if err != nil {
		return nil, fmt.Errorf("failed to query outlier cards: %w", err)
	}
	defer rows.Close()

	var stats []models.CardStats
	for rows.Next() {
		var stat models.CardStats
		if err := rows.Scan(&stat.Card, &stat.Rank, &stat.Suit, &stat.TotalAppearances, &stat.ExpectedFrequency, &stat.ActualFrequency, &stat.Deviation, &stat.DeviationPercent); err != nil {
			return nil, fmt.Errorf("failed to scan card stat: %w", err)
		}
		stats = append(stats, stat)
	}

	return stats, nil
}

// GetSeedEntropy retrieves seed entropy analysis
func (db *DB) GetSeedEntropy() (*models.SeedEntropyData, error) {
	ctx, cancel := getContext()
	defer cancel()

	data := &models.SeedEntropyData{}
	err := db.QueryRowContext(ctx, `
		SELECT
			COUNT(*) as total_seeds,
			COUNT(DISTINCT deck_seed) as unique_seeds,
			COUNT(*) - COUNT(DISTINCT deck_seed) as duplicate_count,
			(COUNT(DISTINCT deck_seed)::float / NULLIF(COUNT(*), 0)) * 100 as entropy_score
		FROM poker_hands
		WHERE deck_seed != ''
	`).Scan(&data.TotalSeeds, &data.UniqueSeeds, &data.DuplicateCount, &data.EntropyScore)

	if err != nil {
		return nil, fmt.Errorf("failed to get seed entropy: %w", err)
	}

	return data, nil
}

// GetPlayerStats retrieves player statistics
func (db *DB) GetPlayerStats(playerAddress string) (*models.PlayerStats, error) {
	ctx, cancel := getContext()
	defer cancel()

	stats := &models.PlayerStats{PlayerAddress: playerAddress}

	err := db.QueryRowContext(ctx, `
		SELECT
			COALESCE(COUNT(DISTINCT ps.game_id), 0) as total_hands,
			COALESCE(COUNT(pa.id), 0) as total_actions,
			COALESCE(SUM(ps.buy_in_amount), 0) as total_buy_ins,
			COALESCE(SUM(ps.cash_out_amount), 0) as total_cash_outs,
			COALESCE(SUM(ps.cash_out_amount) - SUM(ps.buy_in_amount), 0) as net_profit,
			COALESCE(COUNT(ps.id), 0) as session_count,
			COALESCE(AVG(NULLIF(ps.leave_block - ps.join_block, 0)), 0) as avg_session_length
		FROM player_sessions ps
		LEFT JOIN player_actions pa ON pa.player_address = ps.player_address
		WHERE ps.player_address = $1
		GROUP BY ps.player_address
	`, playerAddress).Scan(
		&stats.TotalHands,
		&stats.TotalActions,
		&stats.TotalBuyIns,
		&stats.TotalCashOuts,
		&stats.NetProfit,
		&stats.SessionCount,
		&stats.AvgSessionLength,
	)

	if err == sql.ErrNoRows {
		// Return empty stats for player with no data
		return stats, nil
	}
	if err != nil {
		return nil, fmt.Errorf("failed to get player stats: %w", err)
	}

	return stats, nil
}

// GetPlayerSessions retrieves player game sessions
func (db *DB) GetPlayerSessions(playerAddress string, limit, offset int) ([]models.PlayerSession, int64, error) {
	ctx, cancel := getContext()
	defer cancel()

	// Get total count
	var total int64
	if err := db.QueryRowContext(ctx, `SELECT COUNT(*) FROM player_sessions WHERE player_address = $1`, playerAddress).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("failed to count sessions: %w", err)
	}

	// Get paginated sessions
	rows, err := db.QueryContext(ctx, `
		SELECT player_address, game_id, join_block, leave_block, buy_in_amount, cash_out_amount, created_at
		FROM player_sessions
		WHERE player_address = $1
		ORDER BY join_block DESC
		LIMIT $2 OFFSET $3
	`, playerAddress, limit, offset)
	if err != nil {
		return nil, 0, fmt.Errorf("failed to query sessions: %w", err)
	}
	defer rows.Close()

	var sessions []models.PlayerSession
	for rows.Next() {
		var session models.PlayerSession
		if err := rows.Scan(&session.PlayerAddress, &session.GameID, &session.JoinBlock, &session.LeaveBlock, &session.BuyInAmount, &session.CashOutAmount, &session.CreatedAt); err != nil {
			return nil, 0, fmt.Errorf("failed to scan session: %w", err)
		}
		sessions = append(sessions, session)
	}

	return sessions, total, nil
}

// GetIndexingStatus retrieves indexing progress and statistics
func (db *DB) GetIndexingStatus() (*models.IndexingStatus, error) {
	ctx, cancel := getContext()
	defer cancel()

	status := &models.IndexingStatus{}

	// Get indexing progress from progress table and poker hands
	err := db.QueryRowContext(ctx, `
		SELECT
			COALESCE((SELECT last_scanned_block FROM indexing_progress WHERE id = 1), 0) as last_scanned,
			COALESCE((SELECT total_blocks_scanned FROM indexing_progress WHERE id = 1), 0) as total_scanned,
			COALESCE((SELECT MAX(block_height) FROM poker_hands), 0) as last_block_with_hand,
			COALESCE((SELECT MIN(block_height) FROM poker_hands), 0) as first_block_with_hand,
			COALESCE((SELECT COUNT(*) FROM poker_hands), 0) as total_hands,
			COALESCE((SELECT COUNT(DISTINCT game_id) FROM poker_hands), 0) as total_games
	`).Scan(
		&status.LastBlockIndexed,
		&status.BlocksIndexed,
		&status.TotalBlocks, // Temporarily using this for last block with hand
		&status.FirstBlockIndexed,
		&status.TotalHands,
		&status.TotalGames,
	)

	if err != nil {
		return nil, fmt.Errorf("failed to get indexing status: %w", err)
	}

	// Calculate percentage (blocks scanned vs last scanned block)
	if status.LastBlockIndexed > 0 {
		status.PercentComplete = float64(status.BlocksIndexed) / float64(status.LastBlockIndexed) * 100
	}

	// TotalBlocks will be set to 0 (we don't know total chain height from DB)
	status.TotalBlocks = 0

	return status, nil
}
