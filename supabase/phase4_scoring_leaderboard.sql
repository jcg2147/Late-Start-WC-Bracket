-- ============================================================
-- Phase 4: Scoring engine + current standings leaderboard
-- Run this in the Supabase SQL editor after Phase 3.
-- ============================================================

ALTER TABLE scores ENABLE ROW LEVEL SECURITY;

ALTER TABLE scores ADD COLUMN IF NOT EXISTS r32_points INTEGER NOT NULL DEFAULT 0;
ALTER TABLE scores ADD COLUMN IF NOT EXISTS r16_points INTEGER NOT NULL DEFAULT 0;
ALTER TABLE scores ADD COLUMN IF NOT EXISTS qf_points INTEGER NOT NULL DEFAULT 0;
ALTER TABLE scores ADD COLUMN IF NOT EXISTS sf_points INTEGER NOT NULL DEFAULT 0;
ALTER TABLE scores ADD COLUMN IF NOT EXISTS third_place_points INTEGER NOT NULL DEFAULT 0;
ALTER TABLE scores ADD COLUMN IF NOT EXISTS final_points INTEGER NOT NULL DEFAULT 0;

-- Keep raw scores private. The leaderboard RPC below exposes only safe fields.
DROP POLICY IF EXISTS "scores_read" ON scores;

CREATE OR REPLACE FUNCTION recalculate_scores()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Refresh pick correctness from official completed match winners.
  -- Match 73 was completed before the challenge began and is worth 0.
  UPDATE picks p
  SET
    is_correct = CASE
      WHEN m.is_completed = TRUE
        AND m.winner IS NOT NULL
        AND p.match_id <> 73
      THEN p.predicted_winner = m.winner
      ELSE NULL
    END,
    points_earned = CASE
      WHEN m.is_completed = TRUE
        AND m.winner IS NOT NULL
        AND p.match_id <> 73
        AND p.predicted_winner = m.winner
      THEN m.round_points
      ELSE 0
    END
  FROM matches m, submissions s
  WHERE m.id = p.match_id
    AND s.id = p.submission_id
    AND s.is_locked = TRUE;

  INSERT INTO scores (
    submission_id,
    total_points,
    correct_picks,
    max_possible_points,
    remaining_correct_possible,
    champion_pick,
    r32_points,
    r16_points,
    qf_points,
    sf_points,
    third_place_points,
    final_points,
    updated_at
  )
  SELECT
    s.id AS submission_id,
    COALESCE(SUM(p.points_earned), 0)::INTEGER AS total_points,
    COUNT(*) FILTER (WHERE p.is_correct = TRUE)::INTEGER AS correct_picks,
    COALESCE(SUM(p.points_earned), 0)::INTEGER AS max_possible_points,
    COUNT(*) FILTER (
      WHERE m.is_completed = FALSE OR m.winner IS NULL
    )::INTEGER AS remaining_correct_possible,
    MAX(p.predicted_winner) FILTER (WHERE m.round = 'F') AS champion_pick,
    COALESCE(SUM(p.points_earned) FILTER (WHERE m.round = 'R32'), 0)::INTEGER AS r32_points,
    COALESCE(SUM(p.points_earned) FILTER (WHERE m.round = 'R16'), 0)::INTEGER AS r16_points,
    COALESCE(SUM(p.points_earned) FILTER (WHERE m.round = 'QF'), 0)::INTEGER AS qf_points,
    COALESCE(SUM(p.points_earned) FILTER (WHERE m.round = 'SF'), 0)::INTEGER AS sf_points,
    COALESCE(SUM(p.points_earned) FILTER (WHERE m.round = '3P'), 0)::INTEGER AS third_place_points,
    COALESCE(SUM(p.points_earned) FILTER (WHERE m.round = 'F'), 0)::INTEGER AS final_points,
    NOW() AS updated_at
  FROM submissions s
  LEFT JOIN picks p ON p.submission_id = s.id
  LEFT JOIN matches m ON m.id = p.match_id
  WHERE s.is_locked = TRUE
  GROUP BY s.id
  ON CONFLICT (submission_id) DO UPDATE
    SET total_points = EXCLUDED.total_points,
        correct_picks = EXCLUDED.correct_picks,
        max_possible_points = EXCLUDED.max_possible_points,
        remaining_correct_possible = EXCLUDED.remaining_correct_possible,
        champion_pick = EXCLUDED.champion_pick,
        r32_points = EXCLUDED.r32_points,
        r16_points = EXCLUDED.r16_points,
        qf_points = EXCLUDED.qf_points,
        sf_points = EXCLUDED.sf_points,
        third_place_points = EXCLUDED.third_place_points,
        final_points = EXCLUDED.final_points,
        updated_at = EXCLUDED.updated_at;
END;
$$;

REVOKE ALL ON FUNCTION recalculate_scores() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION recalculate_scores() TO authenticated;

CREATE OR REPLACE FUNCTION get_current_standings()
RETURNS TABLE (
  rank BIGINT,
  username TEXT,
  total_points INTEGER,
  correct_picks INTEGER,
  champion_pick TEXT,
  final_goals_tiebreaker INTEGER,
  r32_points INTEGER,
  r16_points INTEGER,
  qf_points INTEGER,
  sf_points INTEGER,
  third_place_points INTEGER,
  final_points INTEGER,
  submitted_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  WITH standings AS (
    SELECT
      u.username,
      COALESCE(sc.total_points, 0) AS total_points,
      COALESCE(sc.correct_picks, 0) AS correct_picks,
      COALESCE(
        sc.champion_pick,
        MAX(p.predicted_winner) FILTER (WHERE m.round = 'F')
      ) AS champion_pick,
      s.final_goals_tiebreaker,
      COALESCE(sc.r32_points, 0) AS r32_points,
      COALESCE(sc.r16_points, 0) AS r16_points,
      COALESCE(sc.qf_points, 0) AS qf_points,
      COALESCE(sc.sf_points, 0) AS sf_points,
      COALESCE(sc.third_place_points, 0) AS third_place_points,
      COALESCE(sc.final_points, 0) AS final_points,
      s.submitted_at,
      sc.updated_at
    FROM submissions s
    JOIN users u ON u.id = s.user_id
    LEFT JOIN scores sc ON sc.submission_id = s.id
    LEFT JOIN picks p ON p.submission_id = s.id
    LEFT JOIN matches m ON m.id = p.match_id
    WHERE s.is_locked = TRUE
    GROUP BY
      u.username,
      sc.total_points,
      sc.correct_picks,
      sc.champion_pick,
      sc.r32_points,
      sc.r16_points,
      sc.qf_points,
      sc.sf_points,
      sc.third_place_points,
      sc.final_points,
      sc.updated_at,
      s.final_goals_tiebreaker,
      s.submitted_at
  )
  SELECT
    RANK() OVER (ORDER BY total_points DESC, correct_picks DESC, submitted_at ASC) AS rank,
    username,
    total_points,
    correct_picks,
    champion_pick,
    final_goals_tiebreaker,
    r32_points,
    r16_points,
    qf_points,
    sf_points,
    third_place_points,
    final_points,
    submitted_at,
    updated_at
  FROM standings
  ORDER BY total_points DESC, correct_picks DESC, submitted_at ASC;
$$;

REVOKE ALL ON FUNCTION get_current_standings() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_current_standings() TO anon, authenticated;
