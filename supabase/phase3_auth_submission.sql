-- ============================================================
-- Phase 3: Google Auth + one-time locked bracket submission
-- Run this in the Supabase SQL editor after schema.sql.
-- ============================================================

ALTER TABLE matches     ENABLE ROW LEVEL SECURITY;
ALTER TABLE users       ENABLE ROW LEVEL SECURITY;
ALTER TABLE submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE picks       ENABLE ROW LEVEL SECURITY;
ALTER TABLE scores      ENABLE ROW LEVEL SECURITY;

-- Replace broad read policies from the prototype phase.
DROP POLICY IF EXISTS "users_read" ON users;
DROP POLICY IF EXISTS "users_insert" ON users;
DROP POLICY IF EXISTS "submissions_read" ON submissions;
DROP POLICY IF EXISTS "submissions_insert" ON submissions;
DROP POLICY IF EXISTS "picks_read" ON picks;
DROP POLICY IF EXISTS "picks_insert" ON picks;
DROP POLICY IF EXISTS "picks_delete" ON picks;
DROP POLICY IF EXISTS "scores_read" ON scores;

-- Match data remains publicly readable. Do not add public write policies.
DROP POLICY IF EXISTS "matches_read" ON matches;
CREATE POLICY "matches_read" ON matches
  FOR SELECT TO anon, authenticated
  USING (true);

-- Users can only read/insert their own lightweight profile row.
CREATE POLICY "users_read_own" ON users
  FOR SELECT TO authenticated
  USING (id = auth.uid());

CREATE POLICY "users_insert_own" ON users
  FOR INSERT TO authenticated
  WITH CHECK (id = auth.uid());

-- Users can only read their own submission.
-- Inserts are handled by submit_bracket() so the bracket can be created,
-- populated, and locked atomically.
CREATE POLICY "submissions_read_own" ON submissions
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

-- Users can only read picks belonging to their own submission.
-- Inserts are handled by submit_bracket().
CREATE POLICY "picks_read_own" ON picks
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM submissions s
      WHERE s.id = picks.submission_id
        AND s.user_id = auth.uid()
    )
  );

-- Keep scores private for now. Leaderboard-safe reads can be added later.

CREATE OR REPLACE FUNCTION submit_bracket(
  p_picks         JSONB,
  p_final_goals   INTEGER,
  p_champion_pick TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id       UUID := auth.uid();
  v_submission_id UUID;
  v_username      TEXT;
  v_pick_count    INTEGER;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF p_final_goals IS NULL OR p_final_goals < 0 THEN
    RAISE EXCEPTION 'Final goals tiebreaker must be zero or greater';
  END IF;

  IF p_picks IS NULL OR jsonb_typeof(p_picks) <> 'array' THEN
    RAISE EXCEPTION 'Picks must be a JSON array';
  END IF;

  SELECT COUNT(*) INTO v_pick_count
  FROM jsonb_array_elements(p_picks) AS pick
  WHERE (pick ? 'match_id') AND (pick ? 'predicted_winner');

  IF v_pick_count <> jsonb_array_length(p_picks) THEN
    RAISE EXCEPTION 'Every pick must include match_id and predicted_winner';
  END IF;

  IF EXISTS (SELECT 1 FROM submissions WHERE user_id = v_user_id) THEN
    RAISE EXCEPTION 'Bracket already submitted';
  END IF;

  v_username := CONCAT(
    COALESCE(
      NULLIF(auth.jwt() ->> 'email', ''),
      NULLIF(auth.jwt() -> 'user_metadata' ->> 'full_name', ''),
      'user'
    ),
    '-',
    LEFT(v_user_id::TEXT, 8)
  );

  INSERT INTO users (id, username)
  VALUES (v_user_id, v_username)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO submissions (
    user_id,
    final_goals_tiebreaker,
    is_locked,
    submitted_at
  )
  VALUES (
    v_user_id,
    p_final_goals,
    TRUE,
    NOW()
  )
  RETURNING id INTO v_submission_id;

  INSERT INTO picks (submission_id, match_id, predicted_winner)
  SELECT
    v_submission_id,
    (pick ->> 'match_id')::INTEGER,
    pick ->> 'predicted_winner'
  FROM jsonb_array_elements(p_picks) AS pick;

  RETURN jsonb_build_object(
    'success', true,
    'submission_id', v_submission_id
  );
END;
$$;

REVOKE ALL ON FUNCTION submit_bracket(JSONB, INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION submit_bracket(JSONB, INTEGER, TEXT) TO authenticated;
