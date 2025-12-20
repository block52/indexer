-- ============================================
-- Player Statistics & VIP System Schema
-- ============================================

-- ============================================
-- 1. CORE TABLES
-- ============================================

-- Player actions log (raw data from blockchain)
CREATE TABLE IF NOT EXISTS player_actions (
    id SERIAL PRIMARY KEY,
    player_address TEXT NOT NULL,
    game_id TEXT NOT NULL,
    hand_number INTEGER,
    block_height BIGINT NOT NULL,
    action TEXT NOT NULL,
    amount BIGINT DEFAULT 0,
    round TEXT,
    indexed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Player session tracking
CREATE TABLE IF NOT EXISTS player_sessions (
    id SERIAL PRIMARY KEY,
    player_address TEXT NOT NULL,
    game_id TEXT NOT NULL,
    join_block BIGINT NOT NULL,
    leave_block BIGINT,
    buy_in_amount BIGINT DEFAULT 0,
    cash_out_amount BIGINT DEFAULT 0,
    hands_played INTEGER DEFAULT 0,
    indexed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

    UNIQUE(player_address, game_id, join_block)
);

-- Aggregated player statistics (updated periodically)
CREATE TABLE IF NOT EXISTS player_stats (
    player_address TEXT PRIMARY KEY,

    -- Volume metrics
    total_hands INTEGER DEFAULT 0,
    total_actions INTEGER DEFAULT 0,
    total_buy_in BIGINT DEFAULT 0,
    total_cash_out BIGINT DEFAULT 0,
    net_profit BIGINT DEFAULT 0,

    -- Rake & VIP
    total_rake_contributed BIGINT DEFAULT 0,
    current_month_rake BIGINT DEFAULT 0,
    vip_tier TEXT DEFAULT 'bronze',
    vip_points BIGINT DEFAULT 0,

    -- Playing style (percentages stored as integers, e.g., 2550 = 25.50%)
    vpip INTEGER DEFAULT 0,              -- Voluntarily Put $ In Pot
    pfr INTEGER DEFAULT 0,               -- Pre-Flop Raise %
    aggression_factor INTEGER DEFAULT 0, -- (bets+raises)/calls * 100
    wtsd INTEGER DEFAULT 0,              -- Went To Showdown %
    won_at_showdown INTEGER DEFAULT 0,   -- W$SD %

    -- Action counts for calculating ratios
    hands_vpip INTEGER DEFAULT 0,        -- Hands where player voluntarily put money in
    hands_pfr INTEGER DEFAULT 0,         -- Hands where player raised preflop
    hands_to_showdown INTEGER DEFAULT 0, -- Hands that went to showdown
    showdowns_won INTEGER DEFAULT 0,     -- Showdowns won
    total_bets INTEGER DEFAULT 0,
    total_raises INTEGER DEFAULT 0,
    total_calls INTEGER DEFAULT 0,
    total_folds INTEGER DEFAULT 0,
    total_checks INTEGER DEFAULT 0,

    -- Records
    biggest_pot_won BIGINT DEFAULT 0,
    biggest_hand_profit BIGINT DEFAULT 0,
    longest_session_blocks INTEGER DEFAULT 0,

    -- Timestamps
    first_seen_block BIGINT,
    last_seen_block BIGINT,
    first_seen_at TIMESTAMP WITH TIME ZONE,
    last_seen_at TIMESTAMP WITH TIME ZONE,
    stats_updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Monthly stats for VIP tier calculation
CREATE TABLE IF NOT EXISTS player_monthly_stats (
    id SERIAL PRIMARY KEY,
    player_address TEXT NOT NULL,
    year INTEGER NOT NULL,
    month INTEGER NOT NULL,

    hands_played INTEGER DEFAULT 0,
    rake_contributed BIGINT DEFAULT 0,
    net_profit BIGINT DEFAULT 0,
    vip_points_earned BIGINT DEFAULT 0,

    UNIQUE(player_address, year, month)
);

-- VIP tier history
CREATE TABLE IF NOT EXISTS vip_tier_history (
    id SERIAL PRIMARY KEY,
    player_address TEXT NOT NULL,
    old_tier TEXT,
    new_tier TEXT NOT NULL,
    reason TEXT,
    changed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- ============================================
-- 2. INDEXES
-- ============================================

CREATE INDEX IF NOT EXISTS idx_player_actions_address ON player_actions(player_address);
CREATE INDEX IF NOT EXISTS idx_player_actions_game ON player_actions(game_id);
CREATE INDEX IF NOT EXISTS idx_player_actions_block ON player_actions(block_height);
CREATE INDEX IF NOT EXISTS idx_player_actions_action ON player_actions(action);

CREATE INDEX IF NOT EXISTS idx_player_sessions_address ON player_sessions(player_address);
CREATE INDEX IF NOT EXISTS idx_player_sessions_game ON player_sessions(game_id);

CREATE INDEX IF NOT EXISTS idx_player_stats_vip ON player_stats(vip_tier);
CREATE INDEX IF NOT EXISTS idx_player_stats_profit ON player_stats(net_profit DESC);
CREATE INDEX IF NOT EXISTS idx_player_stats_hands ON player_stats(total_hands DESC);

CREATE INDEX IF NOT EXISTS idx_monthly_stats_player ON player_monthly_stats(player_address);
CREATE INDEX IF NOT EXISTS idx_monthly_stats_period ON player_monthly_stats(year, month);

-- ============================================
-- 3. VIP TIER FUNCTIONS
-- ============================================

-- VIP tier thresholds (in micro-units, e.g., USDC with 6 decimals)
-- $50 = 50,000,000 micro-units
CREATE OR REPLACE FUNCTION get_vip_tier(monthly_rake BIGINT)
RETURNS TEXT AS $$
BEGIN
    IF monthly_rake >= 2000000000 THEN  -- $2000+
        RETURN 'diamond';
    ELSIF monthly_rake >= 500000000 THEN  -- $500+
        RETURN 'platinum';
    ELSIF monthly_rake >= 200000000 THEN  -- $200+
        RETURN 'gold';
    ELSIF monthly_rake >= 50000000 THEN   -- $50+
        RETURN 'silver';
    ELSE
        RETURN 'bronze';
    END IF;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Get rakeback percentage for tier
CREATE OR REPLACE FUNCTION get_rakeback_percentage(tier TEXT)
RETURNS INTEGER AS $$
BEGIN
    CASE tier
        WHEN 'diamond' THEN RETURN 20;
        WHEN 'platinum' THEN RETURN 15;
        WHEN 'gold' THEN RETURN 10;
        WHEN 'silver' THEN RETURN 5;
        ELSE RETURN 0;
    END CASE;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Calculate VIP points from rake (1 point per $0.01 rake)
CREATE OR REPLACE FUNCTION calculate_vip_points(rake_amount BIGINT)
RETURNS BIGINT AS $$
BEGIN
    RETURN rake_amount / 10000;  -- 1 point per $0.01 (10000 micro-units)
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ============================================
-- 4. STATS CALCULATION FUNCTIONS
-- ============================================

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
        COALESCE(session_totals.total_hands, action_counts.unique_hands),
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

-- Refresh all player stats
CREATE OR REPLACE FUNCTION refresh_all_player_stats()
RETURNS void AS $$
DECLARE
    player RECORD;
BEGIN
    FOR player IN SELECT DISTINCT player_address FROM player_actions LOOP
        PERFORM update_player_stats(player.player_address);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Update VIP tiers for current month
CREATE OR REPLACE FUNCTION update_vip_tiers()
RETURNS void AS $$
DECLARE
    player RECORD;
    new_tier TEXT;
BEGIN
    FOR player IN SELECT player_address, current_month_rake FROM player_stats LOOP
        new_tier := get_vip_tier(player.current_month_rake);

        -- Update if tier changed
        UPDATE player_stats
        SET vip_tier = new_tier
        WHERE player_address = player.player_address
          AND vip_tier != new_tier;

        -- Log tier changes
        IF FOUND THEN
            INSERT INTO vip_tier_history (player_address, old_tier, new_tier, reason)
            SELECT
                player.player_address,
                ps.vip_tier,
                new_tier,
                'Monthly rake threshold'
            FROM player_stats ps
            WHERE ps.player_address = player.player_address;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- 5. LEADERBOARD VIEWS
-- ============================================

-- Top players by profit
CREATE OR REPLACE VIEW leaderboard_profit AS
SELECT
    player_address,
    net_profit,
    total_hands,
    total_buy_in,
    total_cash_out,
    vip_tier,
    RANK() OVER (ORDER BY net_profit DESC) as rank
FROM player_stats
WHERE total_hands > 0
ORDER BY net_profit DESC;

-- Top players by hands played
CREATE OR REPLACE VIEW leaderboard_volume AS
SELECT
    player_address,
    total_hands,
    total_actions,
    net_profit,
    vip_tier,
    RANK() OVER (ORDER BY total_hands DESC) as rank
FROM player_stats
WHERE total_hands > 0
ORDER BY total_hands DESC;

-- Top players by aggression
CREATE OR REPLACE VIEW leaderboard_aggression AS
SELECT
    player_address,
    aggression_factor / 100.0 as af,
    total_bets + total_raises as aggressive_actions,
    total_calls as passive_actions,
    total_hands,
    RANK() OVER (ORDER BY aggression_factor DESC) as rank
FROM player_stats
WHERE total_hands >= 10  -- Minimum sample size
ORDER BY aggression_factor DESC;

-- VIP tier distribution
CREATE OR REPLACE VIEW vip_distribution AS
SELECT
    vip_tier,
    COUNT(*) as player_count,
    SUM(total_rake_contributed) as total_rake,
    AVG(total_hands) as avg_hands,
    AVG(net_profit) as avg_profit
FROM player_stats
GROUP BY vip_tier
ORDER BY
    CASE vip_tier
        WHEN 'diamond' THEN 1
        WHEN 'platinum' THEN 2
        WHEN 'gold' THEN 3
        WHEN 'silver' THEN 4
        ELSE 5
    END;

-- Monthly leaderboard
CREATE OR REPLACE VIEW leaderboard_monthly AS
SELECT
    pms.player_address,
    pms.year,
    pms.month,
    pms.hands_played,
    pms.rake_contributed,
    pms.net_profit,
    ps.vip_tier,
    RANK() OVER (PARTITION BY pms.year, pms.month ORDER BY pms.rake_contributed DESC) as rank
FROM player_monthly_stats pms
JOIN player_stats ps ON pms.player_address = ps.player_address
ORDER BY pms.year DESC, pms.month DESC, pms.rake_contributed DESC;

-- ============================================
-- 6. PLAYER PROFILE VIEW
-- ============================================

CREATE OR REPLACE VIEW player_profiles AS
SELECT
    ps.player_address,
    ps.vip_tier,
    get_rakeback_percentage(ps.vip_tier) as rakeback_pct,
    ps.vip_points,
    ps.total_hands,
    ps.total_actions,
    ps.net_profit / 1000000.0 as net_profit_usd,
    ps.total_buy_in / 1000000.0 as total_buy_in_usd,
    ps.total_cash_out / 1000000.0 as total_cash_out_usd,
    ps.total_rake_contributed / 1000000.0 as rake_contributed_usd,
    ps.aggression_factor / 100.0 as aggression_factor,
    ps.total_bets,
    ps.total_raises,
    ps.total_calls,
    ps.total_folds,
    ps.total_checks,
    ps.biggest_pot_won / 1000000.0 as biggest_pot_usd,
    ps.first_seen_block,
    ps.last_seen_block,
    ps.stats_updated_at
FROM player_stats ps;

-- ============================================
-- 7. SUMMARY STATS
-- ============================================

CREATE OR REPLACE VIEW player_summary AS
SELECT
    COUNT(*) as total_players,
    COUNT(*) FILTER (WHERE total_hands > 0) as active_players,
    SUM(total_hands) as total_hands_played,
    SUM(total_actions) as total_actions,
    SUM(total_rake_contributed) as total_rake,
    AVG(net_profit) as avg_profit,
    COUNT(*) FILTER (WHERE vip_tier = 'diamond') as diamond_players,
    COUNT(*) FILTER (WHERE vip_tier = 'platinum') as platinum_players,
    COUNT(*) FILTER (WHERE vip_tier = 'gold') as gold_players,
    COUNT(*) FILTER (WHERE vip_tier = 'silver') as silver_players,
    COUNT(*) FILTER (WHERE vip_tier = 'bronze') as bronze_players
FROM player_stats;

-- ============================================
-- 8. TRIGGERS FOR AUTO-UPDATES
-- ============================================

-- Trigger to update stats when actions are inserted
CREATE OR REPLACE FUNCTION trigger_update_player_stats()
RETURNS TRIGGER AS $$
BEGIN
    -- Queue the player for stats update (could be batch processed)
    -- For now, just increment counts directly
    INSERT INTO player_stats (player_address, total_actions, first_seen_block, last_seen_block)
    VALUES (NEW.player_address, 1, NEW.block_height, NEW.block_height)
    ON CONFLICT (player_address) DO UPDATE SET
        total_actions = player_stats.total_actions + 1,
        last_seen_block = NEW.block_height,
        stats_updated_at = NOW();

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger (commented out - enable if you want real-time updates)
-- CREATE TRIGGER after_player_action_insert
-- AFTER INSERT ON player_actions
-- FOR EACH ROW
-- EXECUTE FUNCTION trigger_update_player_stats();
