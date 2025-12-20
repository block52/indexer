-- Poker Hands Indexer Schema
-- For tracking card distribution and proving randomness

-- Extension for statistical functions
CREATE EXTENSION IF NOT EXISTS tablefunc;

-- ============================================
-- Core Tables
-- ============================================

-- Track each hand that was started
CREATE TABLE IF NOT EXISTS poker_hands (
    id SERIAL PRIMARY KEY,
    game_id TEXT NOT NULL,
    hand_number INTEGER NOT NULL,
    block_height BIGINT NOT NULL,
    deck_seed TEXT NOT NULL,
    deck TEXT NOT NULL,
    tx_hash TEXT,
    indexed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

    -- Ensure uniqueness per game/hand combination
    UNIQUE(game_id, hand_number)
);

-- Track completed hands with revealed cards
CREATE TABLE IF NOT EXISTS hand_results (
    id SERIAL PRIMARY KEY,
    game_id TEXT NOT NULL,
    hand_number INTEGER NOT NULL,
    block_height BIGINT NOT NULL,
    community_cards TEXT[] NOT NULL DEFAULT '{}',
    winner_count INTEGER NOT NULL DEFAULT 0,
    tx_hash TEXT,
    indexed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

    UNIQUE(game_id, hand_number)
);

-- Track individual revealed cards for distribution analysis
CREATE TABLE IF NOT EXISTS revealed_cards (
    id SERIAL PRIMARY KEY,
    game_id TEXT NOT NULL,
    hand_number INTEGER NOT NULL,
    block_height BIGINT NOT NULL,
    card TEXT NOT NULL,
    card_type TEXT NOT NULL, -- 'hole' or 'community'
    position INTEGER, -- position in sequence (0-4 for community, seat for hole cards)
    indexed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Aggregate card distribution statistics (materialized for performance)
CREATE TABLE IF NOT EXISTS card_distribution_stats (
    id SERIAL PRIMARY KEY,
    card TEXT NOT NULL UNIQUE,
    rank CHAR(1) NOT NULL,      -- '2'-'9', 'T', 'J', 'Q', 'K', 'A'
    suit CHAR(1) NOT NULL,      -- 'h', 'd', 'c', 's'
    total_appearances INTEGER NOT NULL DEFAULT 0,
    community_appearances INTEGER NOT NULL DEFAULT 0,
    hole_card_appearances INTEGER NOT NULL DEFAULT 0,
    last_updated TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Initialize card distribution stats with all 52 cards
INSERT INTO card_distribution_stats (card, rank, suit, total_appearances, community_appearances, hole_card_appearances)
SELECT
    rank || suit as card,
    rank,
    suit,
    0, 0, 0
FROM
    (VALUES ('2'),('3'),('4'),('5'),('6'),('7'),('8'),('9'),('T'),('J'),('Q'),('K'),('A')) AS ranks(rank),
    (VALUES ('h'),('d'),('c'),('s')) AS suits(suit)
ON CONFLICT (card) DO NOTHING;

-- ============================================
-- Indexes for Query Performance
-- ============================================

CREATE INDEX IF NOT EXISTS idx_poker_hands_game_id ON poker_hands(game_id);
CREATE INDEX IF NOT EXISTS idx_poker_hands_block_height ON poker_hands(block_height);
CREATE INDEX IF NOT EXISTS idx_poker_hands_deck_seed ON poker_hands(deck_seed);

CREATE INDEX IF NOT EXISTS idx_hand_results_game_id ON hand_results(game_id);
CREATE INDEX IF NOT EXISTS idx_hand_results_block_height ON hand_results(block_height);

CREATE INDEX IF NOT EXISTS idx_revealed_cards_card ON revealed_cards(card);
CREATE INDEX IF NOT EXISTS idx_revealed_cards_game_hand ON revealed_cards(game_id, hand_number);
CREATE INDEX IF NOT EXISTS idx_revealed_cards_block_height ON revealed_cards(block_height);

-- ============================================
-- Views for Analysis
-- ============================================

-- View: Card frequency with expected vs actual
CREATE OR REPLACE VIEW card_frequency_analysis AS
SELECT
    cds.card,
    cds.rank,
    cds.suit,
    cds.total_appearances,
    (SELECT COUNT(*) FROM revealed_cards) as total_cards_dealt,
    CASE
        WHEN (SELECT COUNT(*) FROM revealed_cards) > 0
        THEN ROUND(cds.total_appearances::NUMERIC / (SELECT COUNT(*) FROM revealed_cards) * 100, 4)
        ELSE 0
    END as actual_percentage,
    ROUND(100.0 / 52, 4) as expected_percentage,
    CASE
        WHEN (SELECT COUNT(*) FROM revealed_cards) > 0
        THEN ROUND(
            (cds.total_appearances::NUMERIC / (SELECT COUNT(*) FROM revealed_cards) - 1.0/52) * 100,
            4
        )
        ELSE 0
    END as deviation_percentage
FROM card_distribution_stats cds
ORDER BY cds.total_appearances DESC;

-- View: Rank distribution (aggregated by rank)
CREATE OR REPLACE VIEW rank_distribution AS
SELECT
    cds.rank,
    SUM(cds.total_appearances) as total_appearances,
    CASE
        WHEN (SELECT COUNT(*) FROM revealed_cards) > 0
        THEN ROUND(SUM(cds.total_appearances)::NUMERIC / (SELECT COUNT(*) FROM revealed_cards) * 100, 4)
        ELSE 0
    END as actual_percentage,
    ROUND(100.0 / 13, 4) as expected_percentage
FROM card_distribution_stats cds
GROUP BY cds.rank
ORDER BY
    CASE cds.rank
        WHEN 'A' THEN 14
        WHEN 'K' THEN 13
        WHEN 'Q' THEN 12
        WHEN 'J' THEN 11
        WHEN 'T' THEN 10
        ELSE cds.rank::INTEGER
    END DESC;

-- View: Suit distribution (aggregated by suit)
CREATE OR REPLACE VIEW suit_distribution AS
SELECT
    cds.suit,
    CASE cds.suit
        WHEN 'h' THEN 'Hearts'
        WHEN 'd' THEN 'Diamonds'
        WHEN 'c' THEN 'Clubs'
        WHEN 's' THEN 'Spades'
    END as suit_name,
    SUM(cds.total_appearances) as total_appearances,
    CASE
        WHEN (SELECT COUNT(*) FROM revealed_cards) > 0
        THEN ROUND(SUM(cds.total_appearances)::NUMERIC / (SELECT COUNT(*) FROM revealed_cards) * 100, 4)
        ELSE 0
    END as actual_percentage,
    ROUND(100.0 / 4, 4) as expected_percentage
FROM card_distribution_stats cds
GROUP BY cds.suit
ORDER BY SUM(cds.total_appearances) DESC;

-- View: Deck seed entropy analysis
CREATE OR REPLACE VIEW seed_entropy_analysis AS
SELECT
    deck_seed,
    COUNT(*) as times_used,
    MIN(block_height) as first_block,
    MAX(block_height) as last_block,
    ARRAY_AGG(DISTINCT game_id) as games
FROM poker_hands
GROUP BY deck_seed
HAVING COUNT(*) > 1
ORDER BY COUNT(*) DESC;

-- ============================================
-- Functions
-- ============================================

-- Function to update card distribution stats from revealed_cards
CREATE OR REPLACE FUNCTION update_card_distribution_stats()
RETURNS void AS $$
BEGIN
    UPDATE card_distribution_stats cds
    SET
        total_appearances = subq.total,
        community_appearances = subq.community,
        hole_card_appearances = subq.hole,
        last_updated = NOW()
    FROM (
        SELECT
            card,
            COUNT(*) as total,
            COUNT(*) FILTER (WHERE card_type = 'community') as community,
            COUNT(*) FILTER (WHERE card_type = 'hole') as hole
        FROM revealed_cards
        GROUP BY card
    ) subq
    WHERE cds.card = subq.card;
END;
$$ LANGUAGE plpgsql;

-- Function to calculate chi-squared statistic for randomness test
CREATE OR REPLACE FUNCTION calculate_chi_squared()
RETURNS TABLE(
    test_name TEXT,
    chi_squared NUMERIC,
    degrees_of_freedom INTEGER,
    total_observations BIGINT,
    p_value_hint TEXT
) AS $$
DECLARE
    total_cards BIGINT;
    expected_per_card NUMERIC;
BEGIN
    SELECT COUNT(*) INTO total_cards FROM revealed_cards;

    IF total_cards = 0 THEN
        RETURN QUERY SELECT
            'Card Distribution'::TEXT,
            0::NUMERIC,
            51,
            0::BIGINT,
            'No data'::TEXT;
        RETURN;
    END IF;

    expected_per_card := total_cards::NUMERIC / 52;

    -- Chi-squared for individual cards (51 degrees of freedom)
    RETURN QUERY
    SELECT
        'Card Distribution'::TEXT as test_name,
        SUM(POWER(total_appearances - expected_per_card, 2) / expected_per_card)::NUMERIC as chi_squared,
        51 as degrees_of_freedom,
        total_cards,
        CASE
            WHEN SUM(POWER(total_appearances - expected_per_card, 2) / expected_per_card) < 68.67 THEN 'PASS (p > 0.05)'
            WHEN SUM(POWER(total_appearances - expected_per_card, 2) / expected_per_card) < 76.15 THEN 'MARGINAL (0.01 < p < 0.05)'
            ELSE 'FAIL (p < 0.01) - Non-random distribution detected'
        END as p_value_hint
    FROM card_distribution_stats;
END;
$$ LANGUAGE plpgsql;

-- Trigger to auto-update stats when cards are inserted
CREATE OR REPLACE FUNCTION trigger_update_card_stats()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE card_distribution_stats
    SET
        total_appearances = total_appearances + 1,
        community_appearances = community_appearances + CASE WHEN NEW.card_type = 'community' THEN 1 ELSE 0 END,
        hole_card_appearances = hole_card_appearances + CASE WHEN NEW.card_type = 'hole' THEN 1 ELSE 0 END,
        last_updated = NOW()
    WHERE card = NEW.card;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER after_card_insert
AFTER INSERT ON revealed_cards
FOR EACH ROW
EXECUTE FUNCTION trigger_update_card_stats();
