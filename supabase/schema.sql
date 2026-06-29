-- ============================================================
-- World Cup Bracket Challenge — Schema
-- Run this entire file in the Supabase SQL editor once.
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- TABLES
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS matches (
  id                    INTEGER PRIMARY KEY,
  round                 TEXT    NOT NULL CHECK (round IN ('R32','R16','QF','SF','3P','F')),
  match_number          INTEGER NOT NULL,           -- 1-indexed within each round
  home_team             TEXT,                       -- NULL = TBD (filled when source match completes)
  away_team             TEXT,
  home_score            INTEGER,
  away_score            INTEGER,
  winner                TEXT,
  is_completed          BOOLEAN NOT NULL DEFAULT FALSE,
  scheduled_at          TIMESTAMPTZ,
  venue                 TEXT,
  home_source_match_id  INTEGER,                   -- which prior match supplies home_team
  away_source_match_id  INTEGER,                   -- which prior match supplies away_team
  home_source_is_loser  BOOLEAN NOT NULL DEFAULT FALSE,  -- TRUE for the 3rd-place match
  away_source_is_loser  BOOLEAN NOT NULL DEFAULT FALSE,
  round_points          INTEGER NOT NULL DEFAULT 1, -- points awarded for correctly predicting winner
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- One row per participant; id = auth.uid() from Supabase anonymous auth
CREATE TABLE IF NOT EXISTS users (
  id          UUID PRIMARY KEY,
  username    TEXT UNIQUE NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- One bracket submission per user; locked permanently on submit
CREATE TABLE IF NOT EXISTS submissions (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                 UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  final_goals_tiebreaker  INTEGER,   -- predicted total goals in the Final
  is_locked               BOOLEAN NOT NULL DEFAULT FALSE,
  submitted_at            TIMESTAMPTZ,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id)
);

-- One row per match per submission
CREATE TABLE IF NOT EXISTS picks (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  submission_id    UUID    NOT NULL REFERENCES submissions(id) ON DELETE CASCADE,
  match_id         INTEGER NOT NULL REFERENCES matches(id),
  predicted_winner TEXT    NOT NULL,
  is_correct       BOOLEAN,          -- NULL until match is complete
  points_earned    INTEGER NOT NULL DEFAULT 0,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (submission_id, match_id)
);

-- Pre-computed leaderboard data; refreshed after every match result
CREATE TABLE IF NOT EXISTS scores (
  id                         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  submission_id              UUID NOT NULL REFERENCES submissions(id) ON DELETE CASCADE UNIQUE,
  total_points               INTEGER NOT NULL DEFAULT 0,
  correct_picks              INTEGER NOT NULL DEFAULT 0,
  max_possible_points        INTEGER NOT NULL DEFAULT 0,
  remaining_correct_possible INTEGER NOT NULL DEFAULT 0,
  champion_pick              TEXT,
  updated_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────
-- INDEXES
-- ─────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_picks_submission  ON picks(submission_id);
CREATE INDEX IF NOT EXISTS idx_picks_match       ON picks(match_id);
CREATE INDEX IF NOT EXISTS idx_submissions_user  ON submissions(user_id);

-- ─────────────────────────────────────────────────────────────
-- ROW LEVEL SECURITY
-- ─────────────────────────────────────────────────────────────

ALTER TABLE matches     ENABLE ROW LEVEL SECURITY;
ALTER TABLE users       ENABLE ROW LEVEL SECURITY;
ALTER TABLE submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE picks       ENABLE ROW LEVEL SECURITY;
ALTER TABLE scores      ENABLE ROW LEVEL SECURITY;

-- matches: anyone can read; only service-role (admin) can write
CREATE POLICY "matches_read"  ON matches  FOR SELECT TO anon, authenticated USING (true);

-- users: anyone can read (leaderboard); authenticated users insert their own row
CREATE POLICY "users_read"   ON users    FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "users_insert" ON users    FOR INSERT TO authenticated
  WITH CHECK (id = auth.uid());

-- submissions: anyone can read; authenticated users insert their own
CREATE POLICY "submissions_read"   ON submissions FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "submissions_insert" ON submissions FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

-- picks: anyone can read; users can only write into their own UNLOCKED submission
CREATE POLICY "picks_read"   ON picks FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "picks_insert" ON picks FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM submissions s
      WHERE s.id = submission_id
        AND s.user_id = auth.uid()
        AND s.is_locked = FALSE
    )
  );
CREATE POLICY "picks_delete" ON picks FOR DELETE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM submissions s
      WHERE s.id = submission_id
        AND s.user_id = auth.uid()
        AND s.is_locked = FALSE
    )
  );

-- scores: anyone can read; only service-role writes
CREATE POLICY "scores_read" ON scores FOR SELECT TO anon, authenticated USING (true);

-- ─────────────────────────────────────────────────────────────
-- FUNCTIONS
-- ─────────────────────────────────────────────────────────────

-- Atomically saves all picks and permanently locks the submission.
-- Called client-side via supabase.rpc('submit_bracket', {...})
CREATE OR REPLACE FUNCTION submit_bracket(
  p_picks         JSONB,    -- [{"match_id": 75, "predicted_winner": "Netherlands"}, ...]
  p_final_goals   INTEGER,  -- tiebreaker: predicted goals in the Final
  p_champion_pick TEXT      -- name of predicted champion (cached for leaderboard display)
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id       UUID := auth.uid();
  v_submission_id UUID;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- Must have an open (unlocked) submission
  SELECT id INTO v_submission_id
  FROM submissions
  WHERE user_id = v_user_id AND is_locked = FALSE;

  IF v_submission_id IS NULL THEN
    RAISE EXCEPTION 'No open submission found for this user';
  END IF;

  -- Upsert every pick
  INSERT INTO picks (submission_id, match_id, predicted_winner)
  SELECT v_submission_id,
         (pick->>'match_id')::INTEGER,
         pick->>'predicted_winner'
  FROM jsonb_array_elements(p_picks) AS pick
  ON CONFLICT (submission_id, match_id)
    DO UPDATE SET predicted_winner = EXCLUDED.predicted_winner;

  -- Lock the submission permanently
  UPDATE submissions
  SET is_locked              = TRUE,
      submitted_at           = NOW(),
      final_goals_tiebreaker = p_final_goals
  WHERE id = v_submission_id;

  -- Seed the scores row
  INSERT INTO scores (submission_id, champion_pick, updated_at)
  VALUES (v_submission_id, p_champion_pick, NOW())
  ON CONFLICT (submission_id)
    DO UPDATE SET champion_pick = EXCLUDED.champion_pick,
                  updated_at   = NOW();

  RETURN jsonb_build_object('success', true, 'submission_id', v_submission_id);
END;
$$;


-- Records an official match result, marks picks correct/incorrect,
-- advances the winner (and losers for 3P) to the next match,
-- then refreshes all scores. Called from the admin page via service key.
CREATE OR REPLACE FUNCTION record_match_result(
  p_match_id    INTEGER,
  p_home_score  INTEGER,
  p_away_score  INTEGER,
  p_winner      TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_loser TEXT;
  v_match matches%ROWTYPE;
BEGIN
  UPDATE matches
  SET home_score   = p_home_score,
      away_score   = p_away_score,
      winner       = p_winner,
      is_completed = TRUE
  WHERE id = p_match_id
  RETURNING * INTO v_match;

  -- Derive loser for 3P advancement
  IF v_match.home_team = p_winner THEN
    v_loser := v_match.away_team;
  ELSE
    v_loser := v_match.home_team;
  END IF;

  -- Mark picks on this match correct or incorrect
  UPDATE picks
  SET is_correct    = (predicted_winner = p_winner),
      points_earned = CASE WHEN predicted_winner = p_winner THEN v_match.round_points ELSE 0 END
  WHERE match_id = p_match_id;

  -- Advance winner into the next match (home slot)
  UPDATE matches
  SET home_team = p_winner
  WHERE home_source_match_id = p_match_id
    AND home_source_is_loser = FALSE;

  -- Advance winner into the next match (away slot)
  UPDATE matches
  SET away_team = p_winner
  WHERE away_source_match_id = p_match_id
    AND away_source_is_loser = FALSE;

  -- Advance loser into the 3rd-place match (home slot)
  UPDATE matches
  SET home_team = v_loser
  WHERE home_source_match_id = p_match_id
    AND home_source_is_loser = TRUE;

  -- Advance loser into the 3rd-place match (away slot)
  UPDATE matches
  SET away_team = v_loser
  WHERE away_source_match_id = p_match_id
    AND away_source_is_loser = TRUE;

  -- Refresh leaderboard scores
  PERFORM recalculate_scores();
END;
$$;


-- Recomputes scores for every locked submission.
-- Called automatically by record_match_result; can also be called manually.
CREATE OR REPLACE FUNCTION recalculate_scores()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  sub             RECORD;
  v_total_pts     INTEGER;
  v_correct       INTEGER;
  v_max_possible  INTEGER;
  v_remaining     INTEGER;
BEGIN
  FOR sub IN SELECT id FROM submissions WHERE is_locked = TRUE LOOP
    -- Points earned so far
    SELECT
      COALESCE(SUM(p.points_earned), 0),
      COUNT(*) FILTER (WHERE p.is_correct = TRUE)
    INTO v_total_pts, v_correct
    FROM picks p
    WHERE p.submission_id = sub.id;

    -- Maximum still achievable: points already earned + points from undecided matches
    -- (simplified: we count every pick where is_correct IS NULL as still winnable)
    SELECT COALESCE(SUM(m.round_points), 0)
    INTO v_max_possible
    FROM picks p
    JOIN matches m ON m.id = p.match_id
    WHERE p.submission_id = sub.id
      AND p.is_correct IS NULL;

    SELECT COUNT(*)
    INTO v_remaining
    FROM picks p
    WHERE p.submission_id = sub.id
      AND p.is_correct IS NULL;

    INSERT INTO scores (
      submission_id, total_points, correct_picks,
      max_possible_points, remaining_correct_possible, updated_at
    )
    VALUES (
      sub.id, v_total_pts, v_correct,
      v_total_pts + v_max_possible, v_remaining, NOW()
    )
    ON CONFLICT (submission_id) DO UPDATE
      SET total_points               = EXCLUDED.total_points,
          correct_picks              = EXCLUDED.correct_picks,
          max_possible_points        = EXCLUDED.max_possible_points,
          remaining_correct_possible = EXCLUDED.remaining_correct_possible,
          updated_at                 = EXCLUDED.updated_at;
  END LOOP;
END;
$$;
