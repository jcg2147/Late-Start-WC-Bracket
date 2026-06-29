-- ============================================================
-- Phase 9: Late entry + match locking rules
-- Run this in the Supabase SQL editor after Phase 8.
-- ============================================================

ALTER TABLE matches ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'scheduled';
ALTER TABLE matches ADD COLUMN IF NOT EXISTS is_locked BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE matches DROP CONSTRAINT IF EXISTS matches_status_valid;
ALTER TABLE matches ADD CONSTRAINT matches_status_valid
  CHECK (status IN ('scheduled', 'in_progress', 'completed'));

UPDATE matches
SET status = CASE
    WHEN is_completed = TRUE THEN 'completed'
    WHEN status IS NULL THEN 'scheduled'
    ELSE status
  END,
  is_locked = CASE
    WHEN is_completed = TRUE THEN TRUE
    WHEN scheduled_at IS NOT NULL AND NOW() >= scheduled_at THEN TRUE
    ELSE is_locked
  END;

-- Match 73 was already started/completed before this challenge opened.
UPDATE matches
SET is_locked = TRUE
WHERE id = 73;

CREATE OR REPLACE FUNCTION is_match_pickable_for_submission(p_match_id INTEGER, p_submitted_at TIMESTAMPTZ)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM matches m
    WHERE m.id = p_match_id
      AND COALESCE(m.is_locked, FALSE) = FALSE
      AND COALESCE(m.is_completed, FALSE) = FALSE
      AND COALESCE(m.status, 'scheduled') = 'scheduled'
      AND (
        m.scheduled_at IS NULL
        OR p_submitted_at < m.scheduled_at
      )
  );
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

REVOKE ALL ON FUNCTION is_match_pickable_for_submission(INTEGER, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION is_match_pickable_for_submission(INTEGER, TIMESTAMPTZ) TO authenticated, service_role;

REVOKE ALL ON FUNCTION submit_bracket(JSONB, INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION submit_bracket(JSONB, INTEGER, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION record_match_result(
  match_id_input INTEGER,
  winner_team_input TEXT,
  result_source_input TEXT DEFAULT 'manual'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_match matches%ROWTYPE;
  v_winner TEXT := NULLIF(TRIM(winner_team_input), '');
  v_source TEXT := COALESCE(NULLIF(TRIM(result_source_input), ''), 'manual');
  v_loser TEXT;
  v_next_winner_slots INTEGER := 0;
  v_third_place_slots INTEGER := 0;
  v_row_count INTEGER := 0;
BEGIN
  IF match_id_input IS NULL THEN
    RAISE EXCEPTION 'match_id_input is required';
  END IF;

  IF v_winner IS NULL THEN
    RAISE EXCEPTION 'winner_team_input is required';
  END IF;

  SELECT *
  INTO v_match
  FROM matches
  WHERE id = match_id_input
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Match % does not exist', match_id_input;
  END IF;

  IF v_match.manual_override = TRUE AND v_source <> 'manual' THEN
    RETURN jsonb_build_object(
      'success', false,
      'skipped', true,
      'match_id', match_id_input,
      'message', FORMAT('Match % has manual_override=true and was not changed.', match_id_input)
    );
  END IF;

  IF v_match.home_team IS NULL OR v_match.away_team IS NULL THEN
    RAISE EXCEPTION 'Match % does not have both teams set yet', match_id_input;
  END IF;

  IF v_winner <> v_match.home_team AND v_winner <> v_match.away_team THEN
    RAISE EXCEPTION 'Winner "%" must be one of "%" or "%"', v_winner, v_match.home_team, v_match.away_team;
  END IF;

  v_loser := CASE
    WHEN v_winner = v_match.home_team THEN v_match.away_team
    ELSE v_match.home_team
  END;

  UPDATE matches
  SET winner = v_winner,
      is_completed = TRUE,
      status = 'completed',
      is_locked = TRUE,
      external_provider = CASE WHEN v_source <> 'manual' THEN v_source ELSE external_provider END,
      external_match_id = CASE WHEN v_source <> 'manual' THEN match_id_input::TEXT ELSE external_match_id END,
      result_source = v_source,
      manual_override = (v_source = 'manual'),
      last_synced_at = CASE WHEN v_source <> 'manual' THEN NOW() ELSE last_synced_at END
  WHERE id = match_id_input;

  UPDATE matches
  SET home_team = v_winner
  WHERE home_source_match_id = match_id_input
    AND home_source_is_loser = FALSE;
  GET DIAGNOSTICS v_row_count = ROW_COUNT;
  v_next_winner_slots := v_next_winner_slots + v_row_count;

  UPDATE matches
  SET away_team = v_winner
  WHERE away_source_match_id = match_id_input
    AND away_source_is_loser = FALSE;
  GET DIAGNOSTICS v_row_count = ROW_COUNT;
  v_next_winner_slots := v_next_winner_slots + v_row_count;

  UPDATE matches
  SET home_team = v_loser
  WHERE home_source_match_id = match_id_input
    AND home_source_is_loser = TRUE;
  GET DIAGNOSTICS v_row_count = ROW_COUNT;
  v_third_place_slots := v_third_place_slots + v_row_count;

  UPDATE matches
  SET away_team = v_loser
  WHERE away_source_match_id = match_id_input
    AND away_source_is_loser = TRUE;
  GET DIAGNOSTICS v_row_count = ROW_COUNT;
  v_third_place_slots := v_third_place_slots + v_row_count;

  PERFORM recalculate_scores();

  RETURN jsonb_build_object(
    'success', true,
    'skipped', false,
    'match_id', match_id_input,
    'winner', v_winner,
    'loser', v_loser,
    'result_source', v_source,
    'advanced_winner_slots', v_next_winner_slots,
    'advanced_third_place_slots', v_third_place_slots,
    'message', FORMAT('Recorded %s as winner of match %s and recalculated scores.', v_winner, match_id_input)
  );
END;
$$;

REVOKE ALL ON FUNCTION record_match_result(INTEGER, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION record_match_result(INTEGER, TEXT, TEXT) FROM anon;
REVOKE ALL ON FUNCTION record_match_result(INTEGER, TEXT, TEXT) FROM authenticated;
GRANT EXECUTE ON FUNCTION record_match_result(INTEGER, TEXT, TEXT) TO service_role;
