-- transfers: every bank transfer the chain records (block52/indexer, for block52-club#91).
--
-- One row per coin of each `transfer` event: player deposits and sends
-- (/cosmos.bank.v1beta1.MsgSend), buy-ins into and cash-outs from the poker
-- module (MsgJoinGame / MsgLeaveGame), fees, and block-level movements. msg_type
-- says which message moved the coins, so a reader can tell a deposit from a
-- buy-in without decoding the transaction.
--
-- Unique on (block_height, tx_index, event_index, denom), so indexing a block
-- again (a backfill with -transfers-only) adds nothing twice.
--
-- Safe to run again. Run after 09-api-views.sql.

CREATE TABLE IF NOT EXISTS transfers (
    id           BIGSERIAL PRIMARY KEY,
    block_height BIGINT      NOT NULL,
    block_time   TIMESTAMPTZ,
    tx_hash      TEXT        NOT NULL DEFAULT '',
    -- Position of the transaction in its block; -1 for a block-level transfer (finalize_block_events).
    tx_index     INTEGER     NOT NULL,
    -- Position of the event in its transaction (or in the block's finalize events).
    event_index  INTEGER     NOT NULL,
    -- Which message of the transaction emitted it; NULL for fees and block-level transfers.
    msg_index    INTEGER,
    msg_type     TEXT        NOT NULL DEFAULT '',
    sender       TEXT        NOT NULL,
    recipient    TEXT        NOT NULL,
    amount       BIGINT      NOT NULL,
    denom        TEXT        NOT NULL,
    indexed_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (block_height, tx_index, event_index, denom)
);

CREATE INDEX IF NOT EXISTS idx_transfers_sender ON transfers (sender, block_height);
CREATE INDEX IF NOT EXISTS idx_transfers_recipient ON transfers (recipient, block_height);
CREATE INDEX IF NOT EXISTS idx_transfers_tx_hash ON transfers (tx_hash);

CREATE SCHEMA IF NOT EXISTS api;

CREATE OR REPLACE VIEW api.transfers AS
    SELECT id, block_height, block_time, tx_hash, msg_type, sender, recipient, amount, denom, indexed_at
    FROM public.transfers;
COMMENT ON COLUMN api.transfers.block_time IS 'When the block was made (UTC).';
COMMENT ON COLUMN api.transfers.tx_hash IS 'The transaction''s hash (upper-case hex); empty for a block-level transfer.';
COMMENT ON COLUMN api.transfers.msg_type IS 'The message that moved the coins, e.g. /cosmos.bank.v1beta1.MsgSend (a send or deposit), /pokerchain.poker.v1.MsgJoinGame (a buy-in), /pokerchain.poker.v1.MsgLeaveGame (a cash-out); empty for fees and block-level transfers.';
COMMENT ON COLUMN api.transfers.amount IS 'In the denom''s base unit: micro-USDC for usdc.';
COMMENT ON COLUMN api.transfers.denom IS 'The coin, e.g. usdc.';

GRANT SELECT ON api.transfers TO indexer_ro;
