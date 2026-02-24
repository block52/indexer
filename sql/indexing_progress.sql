-- Table to track indexing progress
CREATE TABLE IF NOT EXISTS indexing_progress (
    id SERIAL PRIMARY KEY,
    last_scanned_block BIGINT NOT NULL DEFAULT 0,
    total_blocks_scanned BIGINT NOT NULL DEFAULT 0,
    last_updated TIMESTAMP NOT NULL DEFAULT NOW(),
    CONSTRAINT single_row CHECK (id = 1)
);

-- Insert initial row (only one row allowed)
INSERT INTO indexing_progress (id, last_scanned_block, total_blocks_scanned, last_updated)
VALUES (1, 0, 0, NOW())
ON CONFLICT (id) DO NOTHING;

-- Create index for faster lookups
CREATE INDEX IF NOT EXISTS idx_indexing_progress_last_scanned ON indexing_progress(last_scanned_block);
