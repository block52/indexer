-- Migration: store and serve only cards SHOWN at the table (no decks).
-- Idempotent: safe to run more than once, and a no-op on a fresh database.
--
-- Upgrading an existing database:
--   psql ... -f sql/init.sql            -- idempotent: views/functions/trigger
--   psql ... -f sql/analysis.sql        -- idempotent: analysis functions
--   psql ... -f sql/05-shown-cards-only.sql
--   then re-run the indexer from block 1 (or your earliest block) to repopulate
--   the shown hole cards from the chain's public state.

-- 1. Decks are never stored.
ALTER TABLE poker_hands DROP COLUMN IF EXISTS deck;

-- 2. Stored hole cards can't be trusted to be "shown": older rows were derived
--    from decks, or taken from events that listed every seat's cards. Remove them
--    all; re-indexing restores only the cards players showed.
DELETE FROM revealed_cards WHERE card_type = 'hole';

-- 3. Card codes: one canonical form, rank upper + suit lower (e.g. "Ah", "Th"),
--    matching card_distribution_stats. Older rows mixed "AH", "ah" and "10h".
UPDATE revealed_cards
SET card = CASE
        WHEN upper(left(card, length(card) - 1)) = '10' THEN 'T'
        ELSE upper(left(card, length(card) - 1))
    END || lower(right(card, 1))
WHERE length(card) BETWEEN 2 AND 3;

-- 4. Recompute the aggregate counts from what's left.
UPDATE card_distribution_stats
SET total_appearances = 0, community_appearances = 0, hole_card_appearances = 0, last_updated = NOW();
SELECT update_card_distribution_stats();
