-- ============================================
-- Poker Hand Distribution Analysis Queries
-- ============================================
-- Run these queries to analyze randomness of card distribution

-- ============================================
-- 1. BASIC STATISTICS
-- ============================================

-- Total hands indexed
CREATE OR REPLACE VIEW total_hands_summary AS
SELECT
    COUNT(*) as total_hands_started,
    (SELECT COUNT(*) FROM hand_results) as total_hands_completed,
    (SELECT COUNT(*) FROM revealed_cards) as total_cards_revealed,
    (SELECT COUNT(DISTINCT game_id) FROM poker_hands) as unique_games,
    (SELECT MIN(block_height) FROM poker_hands) as first_block,
    (SELECT MAX(block_height) FROM poker_hands) as last_block;

-- ============================================
-- 2. CARD DISTRIBUTION TESTS
-- ============================================

-- Individual card frequency (should be ~1.92% each for uniform distribution)
-- Query: SELECT * FROM card_frequency_analysis ORDER BY deviation_percentage DESC;

-- Cards that appear significantly more or less than expected (>1% deviation)
CREATE OR REPLACE VIEW outlier_cards AS
SELECT * FROM card_frequency_analysis
WHERE ABS(deviation_percentage) > 1.0
ORDER BY ABS(deviation_percentage) DESC;

-- ============================================
-- 3. CHI-SQUARED TEST FOR RANDOMNESS
-- ============================================

-- Run chi-squared test
-- Query: SELECT * FROM calculate_chi_squared();

-- Chi-squared critical values for reference:
-- df=51, p=0.05: 68.67
-- df=51, p=0.01: 76.15
-- df=51, p=0.001: 86.66
-- If chi-squared < 68.67, distribution is consistent with random (p > 0.05)

-- ============================================
-- 4. SUIT DISTRIBUTION ANALYSIS
-- ============================================

-- Check suit balance (should be 25% each)
-- Query: SELECT * FROM suit_distribution;

-- Chi-squared for suits
-- Returns columns matching Go ChiSquaredResult struct
CREATE OR REPLACE FUNCTION suit_chi_squared()
RETURNS TABLE(
    chi_squared NUMERIC,
    degrees_of_freedom INTEGER,
    p_value NUMERIC,
    result TEXT,
    interpretation TEXT
) AS $$
DECLARE
    total_cards BIGINT;
    expected_per_suit NUMERIC;
    chi_sq_value NUMERIC;
BEGIN
    SELECT COUNT(*) INTO total_cards FROM revealed_cards;

    IF total_cards = 0 THEN
        RETURN QUERY SELECT
            0::NUMERIC,
            3,
            0::NUMERIC,
            'NO_DATA'::TEXT,
            'No card data available for analysis'::TEXT;
        RETURN;
    END IF;

    expected_per_suit := total_cards::NUMERIC / 4;

    -- Calculate chi-squared value
    SELECT SUM(POWER(total_appearances - expected_per_suit, 2) / expected_per_suit)
    INTO chi_sq_value
    FROM (
        SELECT suit, SUM(total_appearances) as total_appearances
        FROM card_distribution_stats
        GROUP BY suit
    ) s;

    -- Chi-squared for suits (3 degrees of freedom)
    -- Critical values: df=3, p=0.05: 7.81, p=0.01: 11.34
    RETURN QUERY
    SELECT
        chi_sq_value,
        3,
        CASE
            WHEN chi_sq_value < 7.81 THEN 0.10
            WHEN chi_sq_value < 11.34 THEN 0.03
            ELSE 0.005
        END::NUMERIC,
        CASE
            WHEN chi_sq_value < 7.81 THEN 'PASS'
            WHEN chi_sq_value < 11.34 THEN 'MARGINAL'
            ELSE 'FAIL'
        END::TEXT,
        CASE
            WHEN chi_sq_value < 7.81 THEN 'Suits are uniformly distributed (p > 0.05)'
            WHEN chi_sq_value < 11.34 THEN 'Suit distribution shows slight deviation (0.01 < p < 0.05)'
            ELSE 'Suit distribution may be biased (p < 0.01)'
        END::TEXT;
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- 5. RANK DISTRIBUTION ANALYSIS
-- ============================================

-- Check rank balance (should be ~7.69% each)
-- Query: SELECT * FROM rank_distribution;

-- Chi-squared for ranks
-- Returns columns matching Go ChiSquaredResult struct
CREATE OR REPLACE FUNCTION rank_chi_squared()
RETURNS TABLE(
    chi_squared NUMERIC,
    degrees_of_freedom INTEGER,
    p_value NUMERIC,
    result TEXT,
    interpretation TEXT
) AS $$
DECLARE
    total_cards BIGINT;
    expected_per_rank NUMERIC;
    chi_sq_value NUMERIC;
BEGIN
    SELECT COUNT(*) INTO total_cards FROM revealed_cards;

    IF total_cards = 0 THEN
        RETURN QUERY SELECT
            0::NUMERIC,
            12,
            0::NUMERIC,
            'NO_DATA'::TEXT,
            'No card data available for analysis'::TEXT;
        RETURN;
    END IF;

    expected_per_rank := total_cards::NUMERIC / 13;

    -- Calculate chi-squared value
    SELECT SUM(POWER(total_appearances - expected_per_rank, 2) / expected_per_rank)
    INTO chi_sq_value
    FROM (
        SELECT rank, SUM(total_appearances) as total_appearances
        FROM card_distribution_stats
        GROUP BY rank
    ) r;

    -- Chi-squared for ranks (12 degrees of freedom)
    -- Critical values: df=12, p=0.05: 21.03, p=0.01: 26.22
    RETURN QUERY
    SELECT
        chi_sq_value,
        12,
        CASE
            WHEN chi_sq_value < 21.03 THEN 0.10
            WHEN chi_sq_value < 26.22 THEN 0.03
            ELSE 0.005
        END::NUMERIC,
        CASE
            WHEN chi_sq_value < 21.03 THEN 'PASS'
            WHEN chi_sq_value < 26.22 THEN 'MARGINAL'
            ELSE 'FAIL'
        END::TEXT,
        CASE
            WHEN chi_sq_value < 21.03 THEN 'Ranks are uniformly distributed (p > 0.05)'
            WHEN chi_sq_value < 26.22 THEN 'Rank distribution shows slight deviation (0.01 < p < 0.05)'
            ELSE 'Rank distribution may be biased (p < 0.01)'
        END::TEXT;
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- 6. SEQUENTIAL PATTERN ANALYSIS
-- ============================================

-- Check for patterns in community cards (consecutive cards shouldn't correlate)
CREATE OR REPLACE VIEW community_card_sequences AS
SELECT
    c1.card as first_card,
    c2.card as second_card,
    COUNT(*) as occurrences,
    ROUND(COUNT(*)::NUMERIC / (SELECT COUNT(*) FROM revealed_cards WHERE card_type = 'community' AND position = 0) * 100, 2) as percentage
FROM revealed_cards c1
JOIN revealed_cards c2 ON c1.game_id = c2.game_id
    AND c1.hand_number = c2.hand_number
    AND c1.card_type = 'community'
    AND c2.card_type = 'community'
    AND c1.position = 0
    AND c2.position = 1
GROUP BY c1.card, c2.card
HAVING COUNT(*) > 1
ORDER BY COUNT(*) DESC
LIMIT 50;

-- ============================================
-- 7. DECK SEED ANALYSIS
-- ============================================

-- Check if any deck seeds are being reused (should be unique per block)
-- Query: SELECT * FROM seed_entropy_analysis;

-- Deck seed character distribution (should be uniform hex)
CREATE OR REPLACE VIEW seed_character_distribution AS
SELECT
    char,
    COUNT(*) as occurrences,
    ROUND(COUNT(*)::NUMERIC / SUM(COUNT(*)) OVER () * 100, 2) as percentage,
    ROUND(100.0 / 16, 2) as expected_percentage
FROM (
    SELECT unnest(string_to_array(deck_seed, NULL)) as char
    FROM poker_hands
    WHERE deck_seed IS NOT NULL AND deck_seed != ''
) chars
WHERE char ~ '^[0-9a-f]$'
GROUP BY char
ORDER BY char;

-- ============================================
-- 8. TIME SERIES ANALYSIS
-- ============================================

-- Card distribution over time (by block ranges)
CREATE OR REPLACE VIEW distribution_over_time AS
SELECT
    (block_height / 1000) * 1000 as block_range_start,
    COUNT(*) as cards_dealt,
    COUNT(DISTINCT card) as unique_cards,
    ROUND(COUNT(DISTINCT card)::NUMERIC / 52 * 100, 2) as card_coverage_pct
FROM revealed_cards
GROUP BY (block_height / 1000)
ORDER BY block_range_start;

-- ============================================
-- 9. COMPREHENSIVE RANDOMNESS REPORT
-- ============================================

CREATE OR REPLACE FUNCTION generate_randomness_report()
RETURNS TABLE(
    test_name TEXT,
    result TEXT,
    details TEXT
) AS $$
DECLARE
    total_cards BIGINT;
    chi_sq NUMERIC;
BEGIN
    SELECT COUNT(*) INTO total_cards FROM revealed_cards;

    IF total_cards < 100 THEN
        RETURN QUERY SELECT
            'INSUFFICIENT DATA'::TEXT,
            'SKIP'::TEXT,
            format('Only %s cards indexed. Need at least 100 for statistical significance.', total_cards)::TEXT;
        RETURN;
    END IF;

    -- Test 1: Overall chi-squared
    RETURN QUERY
    SELECT
        'Overall Card Distribution'::TEXT,
        chi_squared.p_value_hint,
        format('Chi-squared: %s, df: %s, n: %s', chi_squared.chi_squared, chi_squared.degrees_of_freedom, chi_squared.total_observations)
    FROM calculate_chi_squared() chi_squared;

    -- Test 2: Suit distribution
    RETURN QUERY
    SELECT
        'Suit Distribution'::TEXT,
        s.interpretation,
        format('Chi-squared: %s, df: %s', s.chi_squared, s.degrees_of_freedom)
    FROM suit_chi_squared() s;

    -- Test 3: Rank distribution
    RETURN QUERY
    SELECT
        'Rank Distribution'::TEXT,
        r.interpretation,
        format('Chi-squared: %s, df: %s', r.chi_squared, r.degrees_of_freedom)
    FROM rank_chi_squared() r;

    -- Test 4: Seed uniqueness
    RETURN QUERY
    SELECT
        'Seed Uniqueness'::TEXT,
        CASE
            WHEN (SELECT COUNT(*) FROM seed_entropy_analysis) = 0 THEN 'PASS'
            ELSE 'WARNING'
        END::TEXT,
        format('%s duplicate seeds found', (SELECT COUNT(*) FROM seed_entropy_analysis))::TEXT;

    -- Test 5: Card coverage
    RETURN QUERY
    SELECT
        'Card Coverage'::TEXT,
        CASE
            WHEN (SELECT COUNT(DISTINCT card) FROM revealed_cards) = 52 THEN 'PASS'
            ELSE 'PARTIAL'
        END::TEXT,
        format('%s of 52 unique cards observed', (SELECT COUNT(DISTINCT card) FROM revealed_cards))::TEXT;
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- 10. QUICK SUMMARY QUERIES
-- ============================================

-- Run this for a quick health check
-- SELECT * FROM generate_randomness_report();

-- Run this for detailed card stats
-- SELECT * FROM card_frequency_analysis ORDER BY total_appearances DESC;

-- Run this for suit balance
-- SELECT * FROM suit_distribution;

-- Run this for rank balance
-- SELECT * FROM rank_distribution;
