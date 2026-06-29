-- ============================================================
-- Phase 8: Custom usernames
-- Run this in the Supabase SQL editor after Phase 7/Phase 6.
-- ============================================================

ALTER TABLE users ENABLE ROW LEVEL SECURITY;

ALTER TABLE users ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- Existing rows may contain auto-generated email-style names from earlier
-- phases. Convert any invalid existing username into a valid temporary value
-- before adding stricter username constraints.
UPDATE users
SET username = CONCAT('user_', LEFT(id::TEXT, 8)),
    updated_at = NOW()
WHERE username IS NULL
   OR char_length(btrim(username)) < 3
   OR char_length(btrim(username)) > 20
   OR username !~ '^[A-Za-z0-9_ ]+$';

ALTER TABLE users DROP CONSTRAINT IF EXISTS users_username_length;
ALTER TABLE users ADD CONSTRAINT users_username_length
  CHECK (char_length(btrim(username)) BETWEEN 3 AND 20);

ALTER TABLE users DROP CONSTRAINT IF EXISTS users_username_chars;
ALTER TABLE users ADD CONSTRAINT users_username_chars
  CHECK (username ~ '^[A-Za-z0-9_ ]+$');

CREATE UNIQUE INDEX IF NOT EXISTS users_username_lower_unique
  ON users (lower(btrim(username)));

DROP POLICY IF EXISTS "users_read_own" ON users;
DROP POLICY IF EXISTS "users_insert_own" ON users;
DROP POLICY IF EXISTS "users_update_own" ON users;

-- User profiles are public enough for standings/display names.
-- Only username/id/created_at/updated_at exist in this table.
CREATE POLICY "users_read_public" ON users
  FOR SELECT TO anon, authenticated
  USING (true);

CREATE POLICY "users_insert_own" ON users
  FOR INSERT TO authenticated
  WITH CHECK (id = auth.uid());

CREATE POLICY "users_update_own_username" ON users
  FOR UPDATE TO authenticated
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid());

CREATE OR REPLACE FUNCTION update_username(username_input TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_username TEXT := btrim(COALESCE(username_input, ''));
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF char_length(v_username) < 3 OR char_length(v_username) > 20 THEN
    RAISE EXCEPTION 'Username must be 3 to 20 characters';
  END IF;

  IF v_username !~ '^[A-Za-z0-9_ ]+$' THEN
    RAISE EXCEPTION 'Username can only use letters, numbers, spaces, and underscores';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM users
    WHERE lower(btrim(username)) = lower(v_username)
      AND id <> v_user_id
  ) THEN
    RAISE EXCEPTION 'Username is already taken';
  END IF;

  INSERT INTO users (id, username, updated_at)
  VALUES (v_user_id, v_username, NOW())
  ON CONFLICT (id) DO UPDATE
    SET username = EXCLUDED.username,
        updated_at = NOW();

  RETURN jsonb_build_object('success', true, 'username', v_username);
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'Username is already taken';
END;
$$;

REVOKE ALL ON FUNCTION update_username(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION update_username(TEXT) TO authenticated;

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
  v_pick_count    INTEGER;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM users WHERE id = v_user_id) THEN
    RAISE EXCEPTION 'Choose a username before submitting';
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
