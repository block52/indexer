-- api: a stable schema of views for GraphQL (block52/indexer#17).
--
-- GraphQL serves from these views instead of the public tables the indexer
-- writes to, so storage can change shape (rename a column, split a table)
-- without breaking key holders' queries: the view keeps the old name as an
-- alias until the field is deprecated and removed. Column comments carry the
-- units and appear as field docs in the GraphQL schema.
--
-- Each view lists its columns explicitly: a new public column is only exposed
-- once it is added here. When sql/07-club-reporting.sql (#15) lands, add
-- api.hands_meta and api.games the same way.
--
-- Safe to run again. Run after init.sql, indexing_progress.sql,
-- player_stats.sql, 05, 06 and 08.

CREATE SCHEMA IF NOT EXISTS api;

CREATE OR REPLACE VIEW api.poker_hands AS
    SELECT id, game_id, hand_number, block_height, deck_seed, tx_hash, indexed_at, created_at
    FROM public.poker_hands;
COMMENT ON COLUMN api.poker_hands.deck_seed IS 'The public shuffle seed: the hash of the block the hand was dealt in.';
COMMENT ON COLUMN api.poker_hands.block_height IS 'The block the hand was dealt in.';

CREATE OR REPLACE VIEW api.hand_results AS
    SELECT id, game_id, hand_number, block_height, community_cards, winner_count, tx_hash, indexed_at, created_at
    FROM public.hand_results;
COMMENT ON COLUMN api.hand_results.community_cards IS 'The board, e.g. {As,Kd,7h,2c,9s}; empty if the hand ended before the flop.';

CREATE OR REPLACE VIEW api.revealed_cards AS
    SELECT id, game_id, hand_number, block_height, card, card_type, position, indexed_at, created_at
    FROM public.revealed_cards;
COMMENT ON COLUMN api.revealed_cards.card_type IS 'community, or hole for a hole card shown at showdown. Unshown cards are never stored.';

CREATE OR REPLACE VIEW api.hand_players AS
    SELECT id, game_id, hand_number, player_address, seat, status, won_amount, block_height, ended_at, indexed_at
    FROM public.hand_players;
COMMENT ON COLUMN api.hand_players.won_amount IS 'What the player won in the hand: micro-USDC for cash games, chips for Sit & Go and tournaments.';
COMMENT ON COLUMN api.hand_players.status IS 'The player''s state when the hand ended (active, folded, all-in, sitting-out).';

CREATE OR REPLACE VIEW api.player_actions AS
    SELECT id, player_address, game_id, hand_number, block_height, action, amount, round, indexed_at
    FROM public.player_actions;
COMMENT ON COLUMN api.player_actions.amount IS 'Micro-USDC for cash games, chips for Sit & Go and tournaments; 0 for actions without an amount.';
COMMENT ON COLUMN api.player_actions.round IS 'The betting round: ante, preflop, flop, turn, river or showdown.';

CREATE OR REPLACE VIEW api.player_sessions AS
    SELECT id, player_address, game_id, join_block, leave_block, buy_in_amount, cash_out_amount, hands_played, indexed_at
    FROM public.player_sessions;
COMMENT ON COLUMN api.player_sessions.buy_in_amount IS 'Micro-USDC for cash games, chips for Sit & Go and tournaments.';
COMMENT ON COLUMN api.player_sessions.cash_out_amount IS 'Micro-USDC for cash games, chips for Sit & Go and tournaments; null while the session is open.';

CREATE OR REPLACE VIEW api.player_stats AS
    SELECT player_address, total_hands, total_actions, total_buy_in, total_cash_out, net_profit,
           total_rake_contributed, current_month_rake, vip_tier, vip_points,
           vpip, pfr, aggression_factor, wtsd, won_at_showdown,
           hands_vpip, hands_pfr, hands_to_showdown, showdowns_won,
           total_bets, total_raises, total_calls, total_folds, total_checks,
           biggest_pot_won, biggest_hand_profit, longest_session_blocks,
           first_seen_block, last_seen_block, first_seen_at, last_seen_at, stats_updated_at
    FROM public.player_stats;
COMMENT ON COLUMN api.player_stats.total_buy_in IS 'Micro-USDC for cash games, chips for Sit & Go and tournaments.';
COMMENT ON COLUMN api.player_stats.total_cash_out IS 'Micro-USDC for cash games, chips for Sit & Go and tournaments.';
COMMENT ON COLUMN api.player_stats.net_profit IS 'total_cash_out - total_buy_in, in the same units.';
COMMENT ON COLUMN api.player_stats.total_rake_contributed IS 'Micro-USDC.';
COMMENT ON COLUMN api.player_stats.current_month_rake IS 'Micro-USDC, this calendar month.';
COMMENT ON COLUMN api.player_stats.vpip IS 'Voluntarily put money in pot, percent of hands.';
COMMENT ON COLUMN api.player_stats.pfr IS 'Preflop raise, percent of hands.';
COMMENT ON COLUMN api.player_stats.aggression_factor IS '(bets + raises) / calls.';
COMMENT ON COLUMN api.player_stats.wtsd IS 'Went to showdown, percent of hands.';
COMMENT ON COLUMN api.player_stats.won_at_showdown IS 'Showdowns won, percent of showdowns reached.';
COMMENT ON COLUMN api.player_stats.biggest_pot_won IS 'Micro-USDC for cash games, chips for Sit & Go and tournaments.';
COMMENT ON COLUMN api.player_stats.biggest_hand_profit IS 'Micro-USDC for cash games, chips for Sit & Go and tournaments.';
COMMENT ON COLUMN api.player_stats.longest_session_blocks IS 'Length of the longest session, in blocks.';

CREATE OR REPLACE VIEW api.player_monthly_stats AS
    SELECT id, player_address, year, month, hands_played, rake_contributed, net_profit, vip_points_earned
    FROM public.player_monthly_stats;
COMMENT ON COLUMN api.player_monthly_stats.rake_contributed IS 'Micro-USDC.';
COMMENT ON COLUMN api.player_monthly_stats.net_profit IS 'Micro-USDC for cash games, chips for Sit & Go and tournaments.';

CREATE OR REPLACE VIEW api.vip_tier_history AS
    SELECT id, player_address, old_tier, new_tier, reason, changed_at
    FROM public.vip_tier_history;

CREATE OR REPLACE VIEW api.card_distribution_stats AS
    SELECT id, card, rank, suit, total_appearances, community_appearances, hole_card_appearances, last_updated
    FROM public.card_distribution_stats;

CREATE OR REPLACE VIEW api.indexing_progress AS
    SELECT id, last_scanned_block, total_blocks_scanned, last_updated
    FROM public.indexing_progress;

-- indexer_ro can read the api views and nothing else (not the public tables,
-- not api_keys). The views run as their owner, so SELECT on api is enough.
-- To use it for GRAPHQL_DB_USER, give it a login by hand:
--   ALTER ROLE indexer_ro LOGIN PASSWORD '…';
--   GRANT CONNECT ON DATABASE poker_hands TO indexer_ro;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'indexer_ro') THEN
        CREATE ROLE indexer_ro NOLOGIN;
    END IF;
END $$;

GRANT USAGE ON SCHEMA api TO indexer_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA api TO indexer_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA api GRANT SELECT ON TABLES TO indexer_ro;
