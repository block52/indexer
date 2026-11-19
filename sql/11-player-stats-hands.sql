-- 11: player_stats.total_hands was 0 for every player.
--
-- update_player_stats() set total_hands = COALESCE(session_hands, unique_hands), but
-- session_hands is COALESCE(SUM(player_sessions.hands_played), 0), which is never NULL,
-- so the fallback to the distinct hands a player acted in never applied. Sessions do
-- not record hands_played, so /api/v1/players showed 0 hands for everyone while the
-- profile (which counts player_actions directly) was right.
--
-- This redefines the function with the fix and recomputes every player once. The
-- indexer also refreshes the stats after each run, so this only makes it immediate.
-- Safe to run again.

-- Update player stats from actions
CREATE OR REPLACE FUNCTION update_player_stats(p_address TEXT)
RETURNS void AS $$
DECLARE
    action_counts RECORD;
    session_totals RECORD;
BEGIN
    -- Count actions by type
    SELECT
        COUNT(*) as total_actions,
        COUNT(*) FILTER (WHERE action = 'bet') as bets,
        COUNT(*) FILTER (WHERE action = 'raise') as raises,
        COUNT(*) FILTER (WHERE action = 'call') as calls,
        COUNT(*) FILTER (WHERE action = 'fold') as folds,
        COUNT(*) FILTER (WHERE action = 'check') as checks,
        COUNT(*) FILTER (WHERE action = 'all-in') as allins,
        COUNT(DISTINCT (game_id, hand_number)) as unique_hands,
        MIN(block_height) as first_block,
        MAX(block_height) as last_block
    INTO action_counts
    FROM player_actions
    WHERE player_address = p_address;

    -- Get session totals
    SELECT
        COALESCE(SUM(buy_in_amount), 0) as total_buy_in,
        COALESCE(SUM(cash_out_amount), 0) as total_cash_out,
        COALESCE(SUM(hands_played), 0) as total_hands
    INTO session_totals
    FROM player_sessions
    WHERE player_address = p_address;

    -- Upsert player stats
    INSERT INTO player_stats (
        player_address,
        total_hands,
        total_actions,
        total_buy_in,
        total_cash_out,
        net_profit,
        total_bets,
        total_raises,
        total_calls,
        total_folds,
        total_checks,
        first_seen_block,
        last_seen_block,
        stats_updated_at
    ) VALUES (
        p_address,
        -- Sessions only know hands_played when the indexer filled it in. SUM(...) over
        -- sessions is never NULL (COALESCE(..., 0) above), so a plain COALESCE never
        -- fell back and every player showed 0 hands. Use the distinct hands the player
        -- acted in unless the sessions actually counted some.
        COALESCE(NULLIF(session_totals.total_hands, 0), action_counts.unique_hands),
        action_counts.total_actions,
        session_totals.total_buy_in,
        session_totals.total_cash_out,
        session_totals.total_cash_out - session_totals.total_buy_in,
        action_counts.bets + action_counts.allins,
        action_counts.raises,
        action_counts.calls,
        action_counts.folds,
        action_counts.checks,
        action_counts.first_block,
        action_counts.last_block,
        NOW()
    )
    ON CONFLICT (player_address) DO UPDATE SET
        total_hands = EXCLUDED.total_hands,
        total_actions = EXCLUDED.total_actions,
        total_buy_in = EXCLUDED.total_buy_in,
        total_cash_out = EXCLUDED.total_cash_out,
        net_profit = EXCLUDED.net_profit,
        total_bets = EXCLUDED.total_bets,
        total_raises = EXCLUDED.total_raises,
        total_calls = EXCLUDED.total_calls,
        total_folds = EXCLUDED.total_folds,
        total_checks = EXCLUDED.total_checks,
        last_seen_block = EXCLUDED.last_seen_block,
        stats_updated_at = NOW();

    -- Calculate playing style percentages
    UPDATE player_stats
    SET
        -- Aggression factor: (bets + raises) / calls * 100
        aggression_factor = CASE
            WHEN total_calls > 0 THEN ((total_bets + total_raises) * 100) / total_calls
            ELSE 0
        END
    WHERE player_address = p_address;
END;
$$ LANGUAGE plpgsql;

SELECT refresh_all_player_stats();
