-- Migration: add rounds table and round_id to strokes
BEGIN;

-- Add rounds table
CREATE TABLE IF NOT EXISTS rounds (
  id SERIAL PRIMARY KEY,
  game_id INTEGER NOT NULL REFERENCES games(id) ON DELETE CASCADE,
  round_number INTEGER NOT NULL,
  created_by INTEGER NULL REFERENCES users(id),
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at TIMESTAMPTZ NULL
);

-- Add round_id column to strokes
ALTER TABLE strokes
  ADD COLUMN IF NOT EXISTS round_id INTEGER NULL REFERENCES rounds(id) ON DELETE SET NULL;

COMMIT;
