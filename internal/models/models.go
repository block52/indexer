package models

import "time"

// PokerHand represents a poker hand record
type PokerHand struct {
	GameID      string    `json:"game_id"`
	HandNumber  int       `json:"hand_number"`
	BlockHeight int64     `json:"block_height"`
	DeckSeed    string    `json:"deck_seed"`
	Deck        string    `json:"deck"`
	TxHash      string    `json:"tx_hash"`
	CreatedAt   time.Time `json:"created_at"`
}

// HandResult represents the result of a completed hand
type HandResult struct {
	GameID         string   `json:"game_id"`
	HandNumber     int      `json:"hand_number"`
	BlockHeight    int64    `json:"block_height"`
	CommunityCards []string `json:"community_cards"`
	WinnerCount    int      `json:"winner_count"`
	TxHash         string   `json:"tx_hash"`
	CreatedAt      time.Time `json:"created_at"`
}

// RevealedCard represents a single revealed card
type RevealedCard struct {
	ID          int64     `json:"id"`
	GameID      string    `json:"game_id"`
	HandNumber  int       `json:"hand_number"`
	BlockHeight int64     `json:"block_height"`
	Card        string    `json:"card"`
	CardType    string    `json:"card_type"` // "community" or "hole"
	Position    int       `json:"position"`
	CreatedAt   time.Time `json:"created_at"`
}

// HandDetails combines hand info with results and cards
type HandDetails struct {
	PokerHand
	Result        *HandResult    `json:"result,omitempty"`
	RevealedCards []RevealedCard `json:"revealed_cards,omitempty"`
}

// CardStats represents card frequency statistics
type CardStats struct {
	Card              string  `json:"card"`
	Rank              string  `json:"rank"`
	Suit              string  `json:"suit"`
	TotalAppearances  int64   `json:"total_appearances"`
	ExpectedFrequency float64 `json:"expected_frequency"`
	ActualFrequency   float64 `json:"actual_frequency"`
	Deviation         float64 `json:"deviation"`
	DeviationPercent  float64 `json:"deviation_percent"`
}

// SuitStats represents suit distribution statistics
type SuitStats struct {
	Suit              string  `json:"suit"`
	TotalAppearances  int64   `json:"total_appearances"`
	ExpectedFrequency float64 `json:"expected_frequency"`
	ActualFrequency   float64 `json:"actual_frequency"`
	Deviation         float64 `json:"deviation"`
}

// RankStats represents rank distribution statistics
type RankStats struct {
	Rank              string  `json:"rank"`
	TotalAppearances  int64   `json:"total_appearances"`
	ExpectedFrequency float64 `json:"expected_frequency"`
	ActualFrequency   float64 `json:"actual_frequency"`
	Deviation         float64 `json:"deviation"`
}

// ChiSquaredResult represents chi-squared test results
type ChiSquaredResult struct {
	ChiSquared      float64 `json:"chi_squared"`
	DegreesOfFreedom int    `json:"degrees_of_freedom"`
	PValue          float64 `json:"p_value"`
	Result          string  `json:"result"`
	Interpretation  string  `json:"interpretation"`
}

// StatsSummary represents overall statistics
type StatsSummary struct {
	TotalHands         int64     `json:"total_hands"`
	TotalCompletedHands int64    `json:"total_completed_hands"`
	TotalRevealedCards int64     `json:"total_revealed_cards"`
	UniqueGames        int64     `json:"unique_games"`
	BlockHeightRange   string    `json:"block_height_range"`
	FirstIndexedAt     time.Time `json:"first_indexed_at,omitempty"`
	LastIndexedAt      time.Time `json:"last_indexed_at,omitempty"`
}

// RandomnessReport represents a comprehensive randomness analysis
type RandomnessReport struct {
	Summary          StatsSummary      `json:"summary"`
	CardChiSquared   ChiSquaredResult  `json:"card_chi_squared"`
	SuitChiSquared   ChiSquaredResult  `json:"suit_chi_squared"`
	RankChiSquared   ChiSquaredResult  `json:"rank_chi_squared"`
	OutlierCards     []CardStats       `json:"outlier_cards"`
	DuplicateSeeds   int64             `json:"duplicate_seeds"`
}

// PlayerStats represents player statistics
type PlayerStats struct {
	PlayerAddress    string  `json:"player_address"`
	TotalHands       int64   `json:"total_hands"`
	TotalActions     int64   `json:"total_actions"`
	TotalBuyIns      int64   `json:"total_buy_ins"`
	TotalCashOuts    int64   `json:"total_cash_outs"`
	NetProfit        int64   `json:"net_profit"`
	SessionCount     int64   `json:"session_count"`
	AvgSessionLength float64 `json:"avg_session_length"`
}

// PlayerSession represents a player's game session
type PlayerSession struct {
	PlayerAddress  string     `json:"player_address"`
	GameID         string     `json:"game_id"`
	JoinBlock      int64      `json:"join_block"`
	LeaveBlock     *int64     `json:"leave_block,omitempty"`
	BuyInAmount    int64      `json:"buy_in_amount"`
	CashOutAmount  *int64     `json:"cash_out_amount,omitempty"`
	CreatedAt      time.Time  `json:"created_at"`
}

// TimelineDataPoint represents distribution over time
type TimelineDataPoint struct {
	BlockRange       string  `json:"block_range"`
	TotalCards       int64   `json:"total_cards"`
	ChiSquared       float64 `json:"chi_squared"`
	PassesTest       bool    `json:"passes_test"`
}

// SeedEntropyData represents deck seed analysis
type SeedEntropyData struct {
	TotalSeeds     int64 `json:"total_seeds"`
	UniqueSeeds    int64 `json:"unique_seeds"`
	DuplicateCount int64 `json:"duplicate_count"`
	EntropyScore   float64 `json:"entropy_score"`
}

// PaginationParams represents pagination parameters
type PaginationParams struct {
	Limit  int `form:"limit" binding:"omitempty,min=1,max=1000"`
	Offset int `form:"offset" binding:"omitempty,min=0"`
}

// PaginatedResponse wraps paginated data
type PaginatedResponse struct {
	Data       interface{} `json:"data"`
	Pagination struct {
		Limit  int   `json:"limit"`
		Offset int   `json:"offset"`
		Total  int64 `json:"total"`
	} `json:"pagination"`
}

// ErrorResponse represents an API error
type ErrorResponse struct {
	Error   string `json:"error"`
	Message string `json:"message,omitempty"`
	Code    int    `json:"code"`
}

// HealthStatus represents service health
type HealthStatus struct {
	Status   string `json:"status"`
	Database string `json:"database"`
	Uptime   string `json:"uptime"`
}

// IndexingStatus represents indexing progress and statistics
type IndexingStatus struct {
	TotalBlocks      int64   `json:"total_blocks"`
	BlocksIndexed    int64   `json:"blocks_indexed"`
	PercentComplete  float64 `json:"percent_complete"`
	LastBlockIndexed int64   `json:"last_block_indexed"`
	FirstBlockIndexed int64  `json:"first_block_indexed"`
	TotalHands       int64   `json:"total_hands"`
	TotalGames       int64   `json:"total_games"`
	BlocksPerSecond  float64 `json:"blocks_per_second,omitempty"`
	EstimatedTimeRemaining string `json:"estimated_time_remaining,omitempty"`
}
