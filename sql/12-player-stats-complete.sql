-- Migration: finish the player stats the schema always promised (block52/indexer#26).
-- Numbered 12 so it runs after 11-player-stats-hands.sql, whose narrower
-- update_player_stats() (the hands-count fix, included here) it replaces.
-- Idempotent: safe to run more than once, and a no-op on a fresh database.
--
-- Three gaps closed:
--   1. player_actions.hand_number was never written (every row NULL), so
--      COUNT(DISTINCT (game_id, hand_number)) counted games. The indexer now
--      stores the event's hand_number; backfill_action_hand_numbers() matches
--      old rows to the hand whose blocks contain them.
--   2. update_player_stats() stopped after volume + aggression. It now computes
--      VPIP, PFR, WTSD, W$SD, biggest pot, biggest hand profit and longest
--      session from data the raw tables already hold.
--   3. Sit & Go and tournament sessions never closed, so prizes were invisible
--      to net_profit. The indexer closes them (sng_finalized and friends); the
--      new tournament_entries table carries MTT buy-ins, refunds and payouts,
--      and net_profit includes them.
--
-- Street derivation: the chain's action_performed event has no round attribute.
-- Preflop is derived from the action order instead: preflop has no 'bet'
-- (the blinds are the live bet) and its only 'check' is the big blind's option,
-- which closes the round — so an action is preflop iff no 'bet' or 'check'
-- came before it in the hand. The rare postflop open-shove ('all-in' with no
-- earlier bet or check in the hand) is misread as preflop.
--
-- Units: session and tournament_entries money is micro-USDC (MTT table seats
-- are chip-stack directives and never create sessions). hand_players.won_amount
-- and action amounts are micro-USDC on cash tables but chips on Sit & Go and
-- tournament tables, so the biggest-pot and biggest-hand-profit records only
-- count hands whose game is known to be cash (games.game_format = 'cash').
-- Antes and dead blinds exist only as engine entries in the hand log, not as
-- action_performed events, so contributions omit them (none configured today).

-- ============================================
-- 1. GAMES (from game_created / tournament_table_created)
-- ============================================

CREATE TABLE IF NOT EXISTS games (
    game_id TEXT PRIMARY KEY,
    creator TEXT,
    game_format TEXT,            -- cash | sit-and-go | tournament
    game_variant TEXT,           -- texas-holdem | omaha
    min_players INTEGER,
    max_players INTEGER,
    min_buy_in BIGINT,
    max_buy_in BIGINT,
    entry_fee BIGINT,
    tournament_id TEXT,          -- set for tournament-directed tables
    created_block BIGINT,
    indexed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_games_format ON games(game_format);
CREATE INDEX IF NOT EXISTS idx_games_tournament ON games(tournament_id) WHERE tournament_id IS NOT NULL;

-- ============================================
-- 2. TOURNAMENT ENTRIES (from tournament_* events)
-- ============================================

-- One row per registration. Money is micro-USDC. refund is set by an
-- unregistration (the net buy-in back) or a cancellation; payout and place by
-- tournament_finished. A row with everything NULL past registered_block is a
-- live entry in a running or pending tournament.
CREATE TABLE IF NOT EXISTS tournament_entries (
    id SERIAL PRIMARY KEY,
    tournament_id TEXT NOT NULL,
    player_address TEXT NOT NULL,
    buy_in BIGINT NOT NULL DEFAULT 0,      -- gross: net + entry fee + protocol fee
    net_buy_in BIGINT NOT NULL DEFAULT 0,
    entry_fee BIGINT NOT NULL DEFAULT 0,
    registered_block BIGINT NOT NULL,
    unregistered_block BIGINT,
    refund BIGINT,
    place INTEGER,
    payout BIGINT,
    payout_block BIGINT,
    indexed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

    UNIQUE(tournament_id, player_address, registered_block)
);

CREATE INDEX IF NOT EXISTS idx_tournament_entries_player ON tournament_entries(player_address);
CREATE INDEX IF NOT EXISTS idx_tournament_entries_tournament ON tournament_entries(tournament_id);

-- ============================================
-- 3. OPEN SESSIONS HAVE NO CASH-OUT
-- ============================================

-- cash_out_amount = 0 meant both "cashed out nothing" and "still seated".
-- Open sessions now carry NULL (the API model already omits it when absent).
ALTER TABLE player_sessions ALTER COLUMN cash_out_amount DROP DEFAULT;
UPDATE player_sessions SET cash_out_amount = NULL
WHERE leave_block IS NULL AND cash_out_amount = 0;

-- ============================================
-- 4. HAND-NUMBER BACKFILL
-- ============================================

-- Matches each legacy action row (hand_number NULL) to the hand whose block
-- range contains it: from the hand's first block up to the next hand's first
-- block in the same game. An action in the exact block a new hand starts is
-- assigned to the new hand. Safe to re-run; new rows carry the event's own
-- hand_number and are never touched.
CREATE OR REPLACE FUNCTION backfill_action_hand_numbers()
RETURNS bigint AS $$
DECLARE
    updated bigint;
BEGIN
    UPDATE player_actions pa
    SET hand_number = ph.hand_number
    FROM (
        SELECT game_id, hand_number, block_height,
               LEAD(block_height) OVER (PARTITION BY game_id ORDER BY hand_number) AS next_start
        FROM poker_hands
    ) ph
    WHERE pa.hand_number IS NULL
      AND pa.game_id = ph.game_id
      AND pa.block_height >= ph.block_height
      AND (ph.next_start IS NULL OR pa.block_height < ph.next_start);
    GET DIAGNOSTICS updated = ROW_COUNT;
    RETURN updated;
END;
$$ LANGUAGE plpgsql;

SELECT backfill_action_hand_numbers();

CREATE INDEX IF NOT EXISTS idx_player_actions_hand ON player_actions(game_id, hand_number);

-- The event's `index` attribute is the action's global index within its hand
-- (pokerchain#388), so (game, hand, index) identifies one action. The partial
-- unique index makes re-indexing a block range idempotent: the indexer inserts
-- with ON CONFLICT DO NOTHING. Legacy rows (no index on the event) stay NULL
-- and can still duplicate under a re-scan — dedupe them by hand if ever needed.
ALTER TABLE player_actions ADD COLUMN IF NOT EXISTS action_index INTEGER;
CREATE UNIQUE INDEX IF NOT EXISTS uniq_player_actions_hand_index
    ON player_actions(game_id, hand_number, action_index)
    WHERE action_index IS NOT NULL AND hand_number IS NOT NULL;

-- ============================================
-- 5. STATS CALCULATION (replaces player_stats.sql's version)
-- ============================================

-- Actions that put a player in a hand. 'timeout' is a forced fold/check — the
-- player was dealt in. join/leave/sit-out/new-hand/deal/top-up are not a hand.
CREATE OR REPLACE FUNCTION hand_action_names()
RETURNS text[] AS $$
    SELECT ARRAY['post-small-blind','post-big-blind','bet','call','raise',
                 'check','fold','all-in','show','muck','timeout'];
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION update_player_stats(p_address TEXT)
RETURNS void AS $$
DECLARE
    action_counts RECORD;
    session_totals RECORD;
    tournament_totals RECORD;
    showdown_counts RECORD;
    style_counts RECORD;
    cash_records RECORD;
    v_total_hands INTEGER;
    v_net_profit BIGINT;
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
        COUNT(DISTINCT (game_id, hand_number))
            FILTER (WHERE hand_number IS NOT NULL
                      AND action = ANY(hand_action_names())) as unique_hands,
        MIN(block_height) as first_block,
        MAX(block_height) as last_block
    INTO action_counts
    FROM player_actions
    WHERE player_address = p_address;

    -- Session totals (micro-USDC; SUM skips the NULL cash-outs of open
    -- sessions). Longest session only counts closed sessions.
    SELECT
        COALESCE(SUM(buy_in_amount), 0) as total_buy_in,
        COALESCE(SUM(cash_out_amount), 0) as total_cash_out,
        COALESCE(MAX(leave_block - join_block), 0) as longest_session
    INTO session_totals
    FROM player_sessions
    WHERE player_address = p_address;

    -- Tournament money (micro-USDC): what went in at registration, what came
    -- back from unregistrations/cancellations, and what the finish paid.
    SELECT
        COALESCE(SUM(buy_in), 0) as buy_ins,
        COALESCE(SUM(refund), 0) as refunds,
        COALESCE(SUM(payout), 0) as payouts
    INTO tournament_totals
    FROM tournament_entries
    WHERE player_address = p_address;

    -- Hands dealt in: distinct hands the player posted or acted in. This
    -- matches hand_players (every dealt-in player posts or acts) and still
    -- counts hands whose end-state the node had pruned.
    v_total_hands := action_counts.unique_hands;

    -- Tournament buy-ins count as money in; payouts and refunds as money out.
    v_net_profit := (session_totals.total_cash_out + tournament_totals.payouts + tournament_totals.refunds)
                  - (session_totals.total_buy_in + tournament_totals.buy_ins);

    -- Showdowns, from the hand-end status: 'showing' or 'mucked' reached one.
    SELECT
        COUNT(*) FILTER (WHERE status IN ('showing', 'mucked')) as to_showdown,
        COUNT(*) FILTER (WHERE status IN ('showing', 'mucked') AND won_amount > 0) as won
    INTO showdown_counts
    FROM hand_players
    WHERE player_address = p_address;

    -- VPIP and PFR. An action is preflop iff nothing before it in the hand was
    -- a 'bet' or 'check' (see the header). Voluntary preflop money is a call,
    -- raise or all-in — blind posts are not voluntary. PFR counts raises only:
    -- an 'all-in' can be a call for less, which the log cannot distinguish.
    WITH hand_scope AS (
        SELECT DISTINCT game_id, hand_number
        FROM player_actions
        WHERE player_address = p_address
          AND hand_number IS NOT NULL
          AND action = ANY(hand_action_names())
    ),
    bounds AS (
        SELECT a.game_id, a.hand_number,
               MIN(a.id) FILTER (WHERE a.action IN ('bet', 'check')) as postflop_id
        FROM player_actions a
        JOIN hand_scope USING (game_id, hand_number)
        GROUP BY a.game_id, a.hand_number
    )
    SELECT
        COUNT(DISTINCT (a.game_id, a.hand_number))
            FILTER (WHERE a.action IN ('call', 'raise', 'all-in')
                      AND (b.postflop_id IS NULL OR a.id < b.postflop_id)) as vpip_hands,
        COUNT(DISTINCT (a.game_id, a.hand_number))
            FILTER (WHERE a.action = 'raise'
                      AND (b.postflop_id IS NULL OR a.id < b.postflop_id)) as pfr_hands
    INTO style_counts
    FROM player_actions a
    JOIN bounds b USING (game_id, hand_number)
    WHERE a.player_address = p_address;

    -- Records, cash games only (chip amounts on Sit & Go / tournament tables
    -- are not money). Contribution is the sum of this player's chip-moving
    -- amounts (event amounts are deltas: a raise is the extra chips). When
    -- another player was all-in for less, the uncalled excess over the highest
    -- other contribution never entered the awarded pot and is subtracted.
    WITH cash_hands AS (
        SELECT hp.game_id, hp.hand_number, hp.won_amount
        FROM hand_players hp
        JOIN games g ON g.game_id = hp.game_id AND g.game_format = 'cash'
        WHERE hp.player_address = p_address
    ),
    contrib AS (
        SELECT a.game_id, a.hand_number, a.player_address,
               COALESCE(SUM(a.amount) FILTER (WHERE a.action IN
                   ('post-small-blind', 'post-big-blind', 'bet', 'call', 'raise', 'all-in')), 0) as put_in,
               BOOL_OR(a.action = 'all-in') as went_all_in
        FROM player_actions a
        JOIN cash_hands USING (game_id, hand_number)
        WHERE a.hand_number IS NOT NULL
        GROUP BY a.game_id, a.hand_number, a.player_address
    ),
    mine AS (
        SELECT game_id, hand_number, put_in
        FROM contrib WHERE player_address = p_address
    ),
    opponents AS (
        SELECT c.game_id, c.hand_number,
               MAX(c.put_in) as highest_other,
               BOOL_OR(c.went_all_in AND c.put_in < m.put_in) as shorter_all_in
        FROM contrib c
        JOIN mine m USING (game_id, hand_number)
        WHERE c.player_address <> p_address
        GROUP BY c.game_id, c.hand_number
    )
    SELECT
        COALESCE(MAX(ch.won_amount), 0) as biggest_pot,
        -- Floored at 0: a player yet to win a hand has no record, not a least-bad loss.
        GREATEST(COALESCE(MAX(ch.won_amount - CASE
            WHEN o.shorter_all_in AND m.put_in > o.highest_other THEN o.highest_other
            ELSE m.put_in END), 0), 0) as biggest_profit
    INTO cash_records
    FROM cash_hands ch
    JOIN mine m USING (game_id, hand_number)
    LEFT JOIN opponents o USING (game_id, hand_number);

    -- Upsert player stats. Percentages are stored x100 (2550 = 25.50%).
    INSERT INTO player_stats (
        player_address,
        total_hands, total_actions,
        total_buy_in, total_cash_out, net_profit,
        total_bets, total_raises, total_calls, total_folds, total_checks,
        hands_vpip, hands_pfr, hands_to_showdown, showdowns_won,
        vpip, pfr, wtsd, won_at_showdown,
        biggest_pot_won, biggest_hand_profit, longest_session_blocks,
        first_seen_block, last_seen_block,
        stats_updated_at
    ) VALUES (
        p_address,
        v_total_hands,
        action_counts.total_actions,
        session_totals.total_buy_in + tournament_totals.buy_ins,
        session_totals.total_cash_out + tournament_totals.payouts + tournament_totals.refunds,
        v_net_profit,
        action_counts.bets + action_counts.allins,
        action_counts.raises,
        action_counts.calls,
        action_counts.folds,
        action_counts.checks,
        style_counts.vpip_hands,
        style_counts.pfr_hands,
        showdown_counts.to_showdown,
        showdown_counts.won,
        CASE WHEN v_total_hands > 0 THEN (style_counts.vpip_hands * 10000) / v_total_hands ELSE 0 END,
        CASE WHEN v_total_hands > 0 THEN (style_counts.pfr_hands * 10000) / v_total_hands ELSE 0 END,
        CASE WHEN v_total_hands > 0 THEN (showdown_counts.to_showdown * 10000) / v_total_hands ELSE 0 END,
        CASE WHEN showdown_counts.to_showdown > 0 THEN (showdown_counts.won * 10000) / showdown_counts.to_showdown ELSE 0 END,
        cash_records.biggest_pot,
        cash_records.biggest_profit,
        session_totals.longest_session,
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
        hands_vpip = EXCLUDED.hands_vpip,
        hands_pfr = EXCLUDED.hands_pfr,
        hands_to_showdown = EXCLUDED.hands_to_showdown,
        showdowns_won = EXCLUDED.showdowns_won,
        vpip = EXCLUDED.vpip,
        pfr = EXCLUDED.pfr,
        wtsd = EXCLUDED.wtsd,
        won_at_showdown = EXCLUDED.won_at_showdown,
        biggest_pot_won = EXCLUDED.biggest_pot_won,
        biggest_hand_profit = EXCLUDED.biggest_hand_profit,
        longest_session_blocks = EXCLUDED.longest_session_blocks,
        first_seen_block = LEAST(player_stats.first_seen_block, EXCLUDED.first_seen_block),
        last_seen_block = EXCLUDED.last_seen_block,
        stats_updated_at = NOW();

    -- Aggression factor: (bets + raises) / calls * 100
    UPDATE player_stats
    SET aggression_factor = CASE
            WHEN total_calls > 0 THEN ((total_bets + total_raises) * 100) / total_calls
            ELSE 0
        END
    WHERE player_address = p_address;
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- 6. API VIEWS (sql/09-api-views.sql pattern; here because the tables are)
-- ============================================

CREATE SCHEMA IF NOT EXISTS api;

-- Re-list api.player_actions with the new action_index (09 defined it
-- without). Appended last: CREATE OR REPLACE VIEW can only add at the end.
CREATE OR REPLACE VIEW api.player_actions AS
    SELECT id, player_address, game_id, hand_number, block_height, action, amount, round, indexed_at, action_index
    FROM public.player_actions;
COMMENT ON COLUMN api.player_actions.action_index IS 'The action''s index within its hand''s log; null on rows indexed before it was recorded.';

CREATE OR REPLACE VIEW api.games AS
    SELECT game_id, creator, game_format, game_variant, min_players, max_players,
           min_buy_in, max_buy_in, entry_fee, tournament_id, created_block, indexed_at
    FROM public.games;
COMMENT ON COLUMN api.games.game_format IS 'cash, sit-and-go or tournament.';
COMMENT ON COLUMN api.games.tournament_id IS 'The tournament this table belongs to; null for cash and Sit & Go.';
COMMENT ON COLUMN api.games.min_buy_in IS 'Micro-USDC.';
COMMENT ON COLUMN api.games.max_buy_in IS 'Micro-USDC.';
COMMENT ON COLUMN api.games.entry_fee IS 'Micro-USDC.';

CREATE OR REPLACE VIEW api.tournament_entries AS
    SELECT id, tournament_id, player_address, buy_in, net_buy_in, entry_fee,
           registered_block, unregistered_block, refund, place, payout, payout_block, indexed_at
    FROM public.tournament_entries;
COMMENT ON COLUMN api.tournament_entries.buy_in IS 'Micro-USDC, gross: net buy-in plus entry and protocol fees.';
COMMENT ON COLUMN api.tournament_entries.refund IS 'Micro-USDC returned by an unregistration or cancellation; null otherwise.';
COMMENT ON COLUMN api.tournament_entries.payout IS 'Micro-USDC the finish paid; 0 for an eliminated entrant, null while the tournament runs.';
COMMENT ON COLUMN api.tournament_entries.place IS 'Finishing place; null if unplaced or still running.';

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'indexer_ro') THEN
        GRANT SELECT ON api.games, api.tournament_entries TO indexer_ro;
    END IF;
END $$;

-- A player who only registered a tournament, or whose actions were pruned,
-- still gets a stats row.
CREATE OR REPLACE FUNCTION refresh_all_player_stats()
RETURNS void AS $$
DECLARE
    player RECORD;
BEGIN
    FOR player IN
        SELECT player_address FROM player_actions
        UNION
        SELECT player_address FROM player_sessions
        UNION
        SELECT player_address FROM tournament_entries
    LOOP
        PERFORM update_player_stats(player.player_address);
    END LOOP;
END;
$$ LANGUAGE plpgsql;
