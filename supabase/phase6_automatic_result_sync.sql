-- ============================================================
-- Phase 6: Automatic match result sync metadata + RPC source support
-- Run this in the Supabase SQL editor after Phase 5.
-- ============================================================

ALTER TABLE matches ADD COLUMN IF NOT EXISTS external_provider TEXT;
ALTER TABLE matches ADD COLUMN IF NOT EXISTS external_match_id TEXT;
ALTER TABLE matches ADD COLUMN IF NOT EXISTS last_synced_at TIMESTAMPTZ;
ALTER TABLE matches ADD COLUMN IF NOT EXISTS result_source TEXT;
ALTER TABLE matches ADD COLUMN IF NOT EXISTS manual_override BOOLEAN NOT NULL DEFAULT FALSE;

CREATE UNIQUE INDEX IF NOT EXISTS idx_matches_external_provider_match
  ON matches (external_provider, external_match_id)
  WHERE external_provider IS NOT NULL
    AND external_match_id IS NOT NULL;

DROP FUNCTION IF EXISTS record_match_result(INTEGER, TEXT);
DROP FUNCTION IF EXISTS record_match_result(INTEGER, TEXT, TEXT);

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
    RAISE EXCEPTION
      'Winner "%" must be one of "%" or "%"',
      v_winner,
      v_match.home_team,
      v_match.away_team;
  END IF;

  IF v_match.is_completed = TRUE
     AND v_match.winner = v_winner
     AND COALESCE(v_match.result_source, '') = v_source THEN
    UPDATE matches
    SET last_synced_at = CASE WHEN v_source <> 'manual' THEN NOW() ELSE last_synced_at END
    WHERE id = match_id_input;

    RETURN jsonb_build_object(
      'success', true,
      'skipped', true,
      'match_id', match_id_input,
      'winner', v_winner,
      'message', FORMAT('Match % already recorded with winner %s.', match_id_input, v_winner)
    );
  END IF;

  v_loser := CASE
    WHEN v_winner = v_match.home_team THEN v_match.away_team
    ELSE v_match.home_team
  END;

  UPDATE matches
  SET winner = v_winner,
      is_completed = TRUE,
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
    'manual_override', (v_source = 'manual'),
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
