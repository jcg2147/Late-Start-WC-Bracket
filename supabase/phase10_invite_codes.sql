-- ============================================================
-- Phase 10: Private invite-code access
-- Run this in the Supabase SQL editor after Phase 9.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

ALTER TABLE users ADD COLUMN IF NOT EXISTS invite_verified BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE users ADD COLUMN IF NOT EXISTS invite_verified_at TIMESTAMPTZ;

-- Invite verification happens before username setup, so usernames must be
-- allowed to remain NULL until the user chooses a public display name.
ALTER TABLE users ALTER COLUMN username DROP NOT NULL;

ALTER TABLE users DROP CONSTRAINT IF EXISTS users_username_length;
ALTER TABLE users ADD CONSTRAINT users_username_length
  CHECK (
    username IS NULL
    OR char_length(btrim(username)) BETWEEN 3 AND 20
  );

ALTER TABLE users DROP CONSTRAINT IF EXISTS users_username_chars;
ALTER TABLE users ADD CONSTRAINT users_username_chars
  CHECK (
    username IS NULL
    OR username ~ '^[A-Za-z0-9_ ]+$'
  );

CREATE TABLE IF NOT EXISTS invite_codes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code_hash TEXT NOT NULL UNIQUE,
  label TEXT,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  used_count INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE invite_codes ENABLE ROW LEVEL SECURITY;

-- Do not expose invite code hashes to browser clients.
DROP POLICY IF EXISTS "invite_codes_read" ON invite_codes;
DROP POLICY IF EXISTS "invite_codes_insert" ON invite_codes;
DROP POLICY IF EXISTS "invite_codes_update" ON invite_codes;
DROP POLICY IF EXISTS "invite_codes_delete" ON invite_codes;

-- Profile updates are handled by SECURITY DEFINER RPCs so users cannot
-- directly flip invite_verified from the browser.
DROP POLICY IF EXISTS "users_insert_own" ON users;
DROP POLICY IF EXISTS "users_update_own_username" ON users;

CREATE OR REPLACE FUNCTION hash_invite_code(code_input TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT encode(
    extensions.digest(
      convert_to(upper(btrim(COALESCE(code_input, ''))), 'UTF8'),
      'sha256'
    ),
    'hex'
  );
$$;

CREATE OR REPLACE FUNCTION verify_invite_code(code_input TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_code TEXT := upper(btrim(COALESCE(code_input, '')));
  v_code_id UUID;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF v_code = '' THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Enter an invite code.'
    );
  END IF;

  SELECT id
  INTO v_code_id
  FROM invite_codes
  WHERE code_hash = hash_invite_code(v_code)
    AND is_active = TRUE
  LIMIT 1;

  IF v_code_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'That invite code is not valid.'
    );
  END IF;

  INSERT INTO users (id, invite_verified, invite_verified_at, updated_at)
  VALUES (v_user_id, TRUE, NOW(), NOW())
  ON CONFLICT (id) DO UPDATE
    SET invite_verified = TRUE,
        invite_verified_at = COALESCE(users.invite_verified_at, NOW()),
        updated_at = NOW();

  UPDATE invite_codes
  SET used_count = used_count + 1
  WHERE id = v_code_id;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Invite verified.'
  );
END;
$$;

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

  IF NOT EXISTS (
    SELECT 1 FROM users
    WHERE id = v_user_id
      AND invite_verified = TRUE
  ) THEN
    RAISE EXCEPTION 'Enter a valid invite code before choosing a username';
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

  INSERT INTO users (id, username, invite_verified, invite_verified_at, updated_at)
  VALUES (v_user_id, v_username, TRUE, NOW(), NOW())
  ON CONFLICT (id) DO UPDATE
    SET username = EXCLUDED.username,
        updated_at = NOW();

  RETURN jsonb_build_object('success', true, 'username', v_username);
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'Username is already taken';
END;
$$;

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
  v_submitted_at  TIMESTAMPTZ := NOW();
  v_invalid_count INTEGER;
  v_missing_count INTEGER;
  v_duplicate_count INTEGER;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM users
    WHERE id = v_user_id
      AND invite_verified = TRUE
      AND username IS NOT NULL
      AND btrim(username) <> ''
  ) THEN
    RAISE EXCEPTION 'Enter a valid invite code and choose a username before submitting';
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

  WITH submitted_picks AS (
    SELECT (pick ->> 'match_id')::INTEGER AS match_id
    FROM jsonb_array_elements(p_picks) AS pick
    GROUP BY (pick ->> 'match_id')::INTEGER
    HAVING COUNT(*) > 1
  )
  SELECT COUNT(*) INTO v_duplicate_count
  FROM submitted_picks;

  IF v_duplicate_count > 0 THEN
    RAISE EXCEPTION 'Only one pick is allowed per match';
  END IF;

  WITH submitted_picks AS (
    SELECT
      (pick ->> 'match_id')::INTEGER AS match_id,
      btrim(pick ->> 'predicted_winner') AS predicted_winner
    FROM jsonb_array_elements(p_picks) AS pick
  )
  SELECT COUNT(*) INTO v_invalid_count
  FROM submitted_picks sp
  JOIN matches m ON m.id = sp.match_id
  WHERE is_match_pickable_for_submission(sp.match_id, v_submitted_at) = FALSE
     OR sp.predicted_winner NOT IN (m.home_team, m.away_team);

  IF v_invalid_count > 0 THEN
    RAISE EXCEPTION 'One or more picks are for locked, started, completed, or invalid matches';
  END IF;

  WITH pickable_matches AS (
    SELECT id
    FROM matches
    WHERE is_match_pickable_for_submission(id, v_submitted_at) = TRUE
      AND home_team IS NOT NULL
      AND away_team IS NOT NULL
  ),
  submitted_picks AS (
    SELECT (pick ->> 'match_id')::INTEGER AS match_id
    FROM jsonb_array_elements(p_picks) AS pick
  )
  SELECT COUNT(*) INTO v_missing_count
  FROM pickable_matches pm
  LEFT JOIN submitted_picks sp ON sp.match_id = pm.id
  WHERE sp.match_id IS NULL;

  IF v_missing_count > 0 THEN
    RAISE EXCEPTION 'Complete every match that has not started yet before submitting';
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
    v_submitted_at
  )
  RETURNING id INTO v_submission_id;

  INSERT INTO picks (submission_id, match_id, predicted_winner)
  SELECT
    v_submission_id,
    (pick ->> 'match_id')::INTEGER,
    btrim(pick ->> 'predicted_winner')
  FROM jsonb_array_elements(p_picks) AS pick;

  RETURN jsonb_build_object(
    'success', true,
    'submission_id', v_submission_id
  );
END;
$$;

-- Preserve access for existing users in this private app.
UPDATE users
SET invite_verified = TRUE,
    invite_verified_at = COALESCE(invite_verified_at, NOW()),
    updated_at = NOW()
WHERE invite_verified = FALSE;

REVOKE ALL ON FUNCTION hash_invite_code(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION verify_invite_code(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION update_username(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION submit_bracket(JSONB, INTEGER, TEXT) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION verify_invite_code(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION update_username(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION submit_bracket(JSONB, INTEGER, TEXT) TO authenticated;
