-- Migration: who played each finished hand, for per-wallet hand history (block52/ui#721).
-- Idempotent: safe to run more than once, and a no-op on a fresh database.
--
-- Rows come from the hand-end public state (the hand's own actions name its
-- players and seats; winners give the amounts). Hands indexed before this
-- table existed have no rows until the indexer re-runs over their blocks.

CREATE TABLE IF NOT EXISTS hand_players (
    id SERIAL PRIMARY KEY,
    game_id TEXT NOT NULL,
    hand_number INTEGER NOT NULL,
    player_address TEXT NOT NULL,
    seat INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT '',     -- status at the hand's end ('' if since left)
    won_amount BIGINT NOT NULL DEFAULT 0, -- chips (SNG/tournament) or micro-USDC (cash)
    block_height BIGINT NOT NULL,
    ended_at TIMESTAMP WITH TIME ZONE,    -- block time of the hand's end
    indexed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

    UNIQUE(game_id, hand_number, player_address)
);

CREATE INDEX IF NOT EXISTS idx_hand_players_player ON hand_players (player_address, block_height DESC, hand_number DESC);
