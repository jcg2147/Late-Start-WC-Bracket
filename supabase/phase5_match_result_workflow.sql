-- ============================================================
-- Phase 5: Official match result workflow
-- Run this in the Supabase SQL editor after Phase 4.
-- ============================================================

-- Retire the prototype result RPC that accepted scores and was broadly
-- executable by default when created in schema.sql.
DROP FUNCTION IF EXISTS record_match_result(INTEGER, INTEGER, INTEGER, TEXT);

-- Score recalculation should be invoked by protected workflows, not directly
-- by regular app users.
REVOKE ALL ON FUNCTION recalculate_scores() FROM PUBLIC;
REVOKE ALL ON FUNCTION recalculate_scores() FROM anon;
REVOKE ALL ON FUNCTION recalculate_scores() FROM authenticated;
GRANT EXECUTE ON FUNCTION recalculate_scores() TO service_role;

CREATE OR REPLACE FUNCTION record_match_result(
  match_id_input INTEGER,
  winner_team_input TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_match matches%ROWTYPE;
  v_winner TEXT := NULLIF(TRIM(winner_team_input), '');
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

  IF v_match.home_team IS NULL OR v_match.away_team IS NULL THEN
    RAISE EXCEPTION 'Match % does not have both teams set yet', match_id_input;
  END IF;

  IF v_winner <> v_match.home_team AND v_winner <> v_match.away_team THEN
    RAISE EXCEPTION
      'Winner "%" must be one of "%" or "%"',
      v_winner,
      v_match.home_team,
      v_match.away_team;
  END IF;

  v_loser := CASE
    WHEN v_winner = v_match.home_team THEN v_match.away_team
    ELSE v_match.home_team
  END;

  UPDATE matches
  SET winner = v_winner,
      is_completed = TRUE
  WHERE id = match_id_input;

  -- Advance winner into any downstream winner-fed slot.
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

  -- Advance semifinal losers into the third-place match. The schema marks
  -- those slots with *_source_is_loser = TRUE.
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
    'match_id', match_id_input,
    'winner', v_winner,
    'loser', v_loser,
    'advanced_winner_slots', v_next_winner_slots,
    'advanced_third_place_slots', v_third_place_slots,
    'message', FORMAT('Recorded %s as winner of match %s and recalculated scores.', v_winner, match_id_input)
  );
END;
$$;

REVOKE ALL ON FUNCTION record_match_result(INTEGER, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION record_match_result(INTEGER, TEXT) FROM anon;
REVOKE ALL ON FUNCTION record_match_result(INTEGER, TEXT) FROM authenticated;
GRANT EXECUTE ON FUNCTION record_match_result(INTEGER, TEXT) TO service_role;
