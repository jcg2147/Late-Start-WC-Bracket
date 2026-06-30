-- Phase 11: Store penalty shootout scores for completed knockout matches.

ALTER TABLE matches ADD COLUMN IF NOT EXISTS home_penalty_score INTEGER;
ALTER TABLE matches ADD COLUMN IF NOT EXISTS away_penalty_score INTEGER;
